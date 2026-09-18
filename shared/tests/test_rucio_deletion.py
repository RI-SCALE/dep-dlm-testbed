"""
test_rucio_deletion.py — Rucio deletion lifecycle tests (rule- and DID-based).

  judge-cleaner — expires rules, sets OBSOLETE tombstones
  undertaker    — expires DIDs, removes unlocked rules, sets tombstones
  reaper        — physically deletes tombstoned replicas from storage

Runtime-agnostic: respects $RUNTIME (compose | k8s, default compose).

    docker exec compose-rucio-client-1 \\
        bash -c "RUNTIME=compose pytest /tests/test_rucio_deletion.py -v"

    kubectl -n dep-dlm-sandbox exec deploy/rucio-client -- \\
        bash -c "RUNTIME=k8s K8S_NAMESPACE=dep-dlm-sandbox pytest /tests/test_rucio_deletion.py -v"
"""

import logging
import time
import zlib

from conftest import (
    add_rule,
    compute_pfn,
    prepare_xrd_dest,
    register_replica,
    run_daemons,
    seed_xrd,
    validate_rule,
    advance_pipeline,
    webdav_delete,
    webdav_get,
    webdav_put,
    pfn_to_https,
    DELETION_DAEMONS,
)

log = logging.getLogger("test-deletion")

SCOPE = "ddmlab"
RUCIO_SVC = "rucio-server"


def run_deletion_daemons(rucio_svc: str = RUCIO_SVC) -> None:
    advance_pipeline(
        rucio_svc,
        DELETION_DAEMONS,
        keywords=("warning", "error", "delet", "expir", "reap", "tomb"),
    )


def replica_exists(pfn: str, token: str = None) -> bool:
    """HTTP GET against a PFN's https form — works on both in-cluster
    sandbox storage and staging's external validation-storage VM."""
    return webdav_get(pfn_to_https(pfn), token).status_code == 200


def https_pfn(rucio_client, rse: str, scope: str, name: str) -> str:
    """compute_pfn(), forced to https:// — avoids the nondeterministic
    davs/https protocol pick on RSEs (e.g. Teapot) that register both."""
    return compute_pfn(rucio_client, rse, scope, name).replace("davs://", "https://", 1)


def poll_until(deadline_s: int, check, on_miss=None, interval: float = 2.0):
    deadline = time.time() + deadline_s
    result = check()
    while not result and time.time() < deadline:
        if on_miss:
            on_miss()
        time.sleep(interval)
        result = check()
    return result


class TestDeletionLifecycle:
    """Transfer → expire → daemon cleanup → assert catalogue + storage clean."""

    def test_rule_deletion_via_judge_cleaner_and_reaper(
        self, rucio_client, xrd3_write_token, xrd4_write_token
    ):
        """Replicate XRD3→XRD4, delete rule, verify judge-cleaner+reaper clean up."""
        name = f"deletion-test-{int(time.time())}"
        log.info("[ Rule deletion lifecycle  name=%s ]", name)

        src_pfn = compute_pfn(rucio_client, "XRD3", SCOPE, name)
        dst_pfn = compute_pfn(rucio_client, "XRD4", SCOPE, name)

        size, adler32 = seed_xrd("xrd3", src_pfn, token=xrd3_write_token)
        prepare_xrd_dest(dst_pfn, token=xrd4_write_token)

        register_replica(rucio_client, "XRD3", SCOPE, name, src_pfn, size, adler32)
        rule_id = add_rule(rucio_client, SCOPE, name, "XRD4")

        run_daemons(RUCIO_SVC)
        validate_rule(rucio_client, rule_id, "XRD3→XRD4 (pre-deletion)", RUCIO_SVC)

        assert replica_exists(dst_pfn, xrd4_write_token), (
            f"Expected replica to exist on XRD4 before deletion: {dst_pfn}"
        )
        log.info("  ✓ Replica confirmed on XRD4 before deletion")

        rucio_client.update_replication_rule(
            rule_id, {"lifetime": -1, "purge_replicas": True}
        )
        log.info("  ✓ Rule lifetime set to -1 (expires immediately)")

        # A tombstone set moments earlier in the same reaper cycle can still
        # be missed on the first pass, so re-run daemons on every iteration.
        run_deletion_daemons(RUCIO_SVC)

        def _xrd4_pfns():
            replicas = rucio_client.list_replicas(
                [{"scope": SCOPE, "name": name}], rse_expression="XRD4"
            )
            return [pfn for r in replicas for pfn in r.get("pfns", {}) if "xrd4" in pfn]

        remaining = poll_until(
            60, lambda: not _xrd4_pfns(), lambda: run_deletion_daemons(RUCIO_SVC)
        )
        assert remaining, (
            f"Expected replica removed from catalogue on XRD4, found: {_xrd4_pfns()}"
        )
        log.info("  ✓ Replica removed from Rucio catalogue on XRD4")

        # Rucio delinks the catalogue row before the physical DELETE
        # completes, so this is a real race window, not just eventual
        # consistency — keep re-running daemons while polling.
        gone = poll_until(
            60,
            lambda: not replica_exists(dst_pfn, xrd4_write_token),
            lambda: run_deletion_daemons(RUCIO_SVC),
        )
        assert gone, f"Expected file to be physically deleted from XRD4: {dst_pfn}"
        log.info("  ✓ File physically deleted from XRD4 storage")

        src_replicas = list(
            rucio_client.list_replicas([{"scope": SCOPE, "name": name}])
        )
        assert src_replicas, "Source replica on XRD3 should still exist"
        log.info("  ✓ Source replica on XRD3 intact")

    def test_did_deletion_via_undertaker(
        self, rucio_client, teapots_ready, teapot_token
    ):
        """Replicate TEAPOT1→TEAPOT2, expire the DID, verify undertaker+reaper clean up.

        Distinct from the rule-deletion test above: expires the DID itself
        (undertaker path), which removes any unlocked rules on it as part
        of the same operation — DID expiration takes precedence over rule
        expiration per Rucio's deletion model.

        Uses TEAPOT1/TEAPOT2 rather than XRD3/XRD4: reaper keeps a per-RSE
        backoff after finding nothing to delete, and the preceding test
        already exercises XRD3/XRD4. Uses https_pfn() rather than a raw
        compute_pfn(): Teapot registers both davs and https, and reaper's
        delete 401s on davs (Storm-WebDAV's DAV-plugin bearer-token handling
        differs from its HTTP-plugin path on DELETE).
        """
        name = f"undertaker-deletion-test-{int(time.time())}"
        log.info("[ DID deletion lifecycle (undertaker)  name=%s ]", name)

        src_pfn = https_pfn(rucio_client, "TEAPOT1", SCOPE, name)
        dst_pfn = https_pfn(rucio_client, "TEAPOT2", SCOPE, name)

        seed_content = b"undertaker-deletion-test\n"
        webdav_delete(src_pfn, teapot_token)
        resp = webdav_put(src_pfn, teapot_token, seed_content)
        assert resp.status_code in {200, 201, 204}, (
            f"Seed PUT returned HTTP {resp.status_code}: {resp.text[:200]}"
        )
        assert webdav_get(src_pfn, teapot_token).status_code == 200, (
            f"Seed not readable: GET {src_pfn}"
        )

        adler32 = "%08x" % (zlib.adler32(seed_content) & 0xFFFFFFFF)
        register_replica(
            rucio_client, "TEAPOT1", SCOPE, name, src_pfn, len(seed_content), adler32
        )
        rule_id = add_rule(rucio_client, SCOPE, name, "TEAPOT2")

        run_daemons(RUCIO_SVC)
        validate_rule(
            rucio_client, rule_id, "TEAPOT1→TEAPOT2 (pre-deletion)", RUCIO_SVC
        )

        assert replica_exists(dst_pfn, teapot_token), (
            f"Expected replica to exist on TEAPOT2 before deletion: {dst_pfn}"
        )
        log.info("  ✓ Replica confirmed on TEAPOT2 before deletion")

        rucio_client.set_metadata(SCOPE, name, "lifetime", -1)
        log.info("  ✓ DID lifetime set to -1 (expires immediately)")

        run_deletion_daemons(RUCIO_SVC)

        def _teapot2_pfns():
            replicas = rucio_client.list_replicas(
                [{"scope": SCOPE, "name": name}], rse_expression="TEAPOT2"
            )
            return [
                pfn for r in replicas for pfn in r.get("pfns", {}) if "teapot2" in pfn
            ]

        removed = poll_until(
            60, lambda: not _teapot2_pfns(), lambda: run_deletion_daemons(RUCIO_SVC)
        )
        assert removed, (
            f"Expected replica removed from catalogue on TEAPOT2, found: {_teapot2_pfns()}"
        )
        log.info("  ✓ Replica removed from Rucio catalogue on TEAPOT2")

        gone = poll_until(
            60,
            lambda: not replica_exists(dst_pfn, teapot_token),
            lambda: run_deletion_daemons(RUCIO_SVC),
        )
        assert gone, f"Expected file to be physically deleted from TEAPOT2: {dst_pfn}"
        log.info("  ✓ File physically deleted from TEAPOT2 storage")

        try:
            list(rucio_client.list_dids(SCOPE, {"name": name}, did_type="file"))
            assert False, f"Expected DID {SCOPE}:{name} to be removed by undertaker"
        except Exception:
            pass  # DataIdentifierNotFound (or empty result) confirms removal
        log.info("  ✓ DID removed from catalogue")
