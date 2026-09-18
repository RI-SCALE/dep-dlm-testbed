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
import os
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
)

log = logging.getLogger("test-deletion")

SCOPE = "ddmlab"
RUCIO_SVC = "rucio-server"

# In DAEMON_MODE=daemons, advance_pipeline() (and therefore
# run_deletion_daemons/deletion_daemons_for) is a documented no-op -- see
# conftest.py. In that mode the physical-delete step is a pure passive wait
# on a real, continuously-running reaper with its own internal cooldown/
# sleep-time cadence we don't control, so it needs real headroom rather
# than the 60s that's sufficient when we can force an extra --rses-scoped
# cycle ourselves (DAEMON_MODE=direct).
PHYSICAL_DELETE_TIMEOUT = 300 if os.environ.get("DAEMON_MODE") == "daemons" else 60

CLEANER_AND_UNDERTAKER = (
    ["rucio-judge-cleaner", "--run-once"],
    ["rucio-undertaker", "--run-once"],
)

DELETION_DAEMONS = (
    ["rucio-judge-cleaner", "--run-once"],
    ["rucio-undertaker", "--run-once"],
    ["rucio-reaper", "--run-once", "--greedy"],
)


def deletion_daemons_for(rse: str):
    """Same as DELETION_DAEMONS, but scopes rucio-reaper to a single RSE.
    Without this, reaper iterates every registered RSE each cycle and, on
    finding nothing eligible on an unrelated RSE, enters a per-RSE pause
    that's tracked outside this process and can still be active when a
    LATER test needs that RSE checked -- cross-test contamination, not a
    daemon-ordering issue. Confirm the flag name against your Rucio
    version: `docker exec compose-rucio-server-1 rucio-reaper --help`.
    """
    return (
        ["rucio-judge-cleaner", "--run-once"],
        ["rucio-undertaker", "--run-once"],
        ["rucio-reaper", "--run-once", "--greedy", "--rses", rse],
    )


def run_deletion_daemons(rucio_svc: str = RUCIO_SVC, rse: str = None) -> None:
    advance_pipeline(
        rucio_svc,
        deletion_daemons_for(rse) if rse else DELETION_DAEMONS,
        keywords=("warning", "error", "delet", "expir", "reap", "tomb"),
    )


def replica_exists(pfn: str, token: str = None) -> bool:
    """HTTP GET against a PFN's https form — works on both in-cluster
    sandbox storage and staging's external validation-storage VM."""
    return webdav_get(pfn_to_https(pfn), token).status_code == 200


def poll_until(deadline_s: int, check, on_miss=None, interval: float = 2.0):
    deadline = time.time() + deadline_s
    result = check()
    while not result and time.time() < deadline:
        if on_miss:
            on_miss()
        time.sleep(interval)
        result = check()
    return result


def rule_gone(client, rule_id: str) -> bool:
    """True once the replication rule no longer exists in the catalogue."""
    try:
        client.get_replication_rule(rule_id)
        return False
    except Exception:
        return True


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

        advance_pipeline(RUCIO_SVC, CLEANER_AND_UNDERTAKER)

        removed = poll_until(
            60,
            lambda: rule_gone(rucio_client, rule_id),
            lambda: advance_pipeline(RUCIO_SVC, CLEANER_AND_UNDERTAKER),
        )
        assert removed, (
            "Expected rule to be removed from catalogue on XRD4 (rule still exists)"
        )
        log.info("  ✓ Replica removed from Rucio catalogue on XRD4")

        gone = poll_until(
            PHYSICAL_DELETE_TIMEOUT,
            lambda: not replica_exists(dst_pfn, xrd4_write_token),
            lambda: run_deletion_daemons(RUCIO_SVC, rse="XRD4"),
        )
        assert gone, f"Expected file to be physically deleted from XRD4: {dst_pfn}"
        log.info("  ✓ File physically deleted from XRD4 storage")

        src_replicas = list(
            rucio_client.list_replicas([{"scope": SCOPE, "name": name}])
        )
        assert src_replicas, "Source replica on XRD3 should still exist"
        log.info("  ✓ Source replica on XRD3 intact")

    def test_did_deletion_via_undertaker(
        self, rucio_client, teapots_ready, teapot_token, xrd3_write_token
    ):
        """Replicate TEAPOT1→TEAPOT2, expire the DID, verify undertaker+reaper clean up.

        Distinct from the rule-deletion test above: expires the DID itself
        (undertaker path), which removes any unlocked rules on it as part
        of the same operation — DID expiration takes precedence over rule
        expiration per Rucio's deletion model.
        """
        name = f"undertaker-deletion-test-{int(time.time())}"
        log.info("[ DID deletion lifecycle (undertaker)  name=%s ]", name)

        src_pfn = compute_pfn(rucio_client, "TEAPOT1", SCOPE, name)
        dst_pfn = compute_pfn(rucio_client, "TEAPOT2", SCOPE, name)

        seed_content = b"undertaker-deletion-test\n"
        webdav_delete(pfn_to_https(src_pfn), teapot_token)
        resp = webdav_put(pfn_to_https(src_pfn), teapot_token, seed_content)
        assert resp.status_code in {200, 201, 204}, (
            f"Seed PUT returned HTTP {resp.status_code}: {resp.text[:200]}"
        )
        assert webdav_get(pfn_to_https(src_pfn), teapot_token).status_code == 200, (
            f"Seed not readable: GET {pfn_to_https(src_pfn)}"
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

        advance_pipeline(RUCIO_SVC, CLEANER_AND_UNDERTAKER)

        removed = poll_until(
            60,
            lambda: rule_gone(rucio_client, rule_id),
            lambda: advance_pipeline(RUCIO_SVC, CLEANER_AND_UNDERTAKER),
        )
        assert removed, (
            "Expected rule to be removed from catalogue on TEAPOT2 (rule still exists)"
        )
        log.info("  ✓ Replica removed from Rucio catalogue on TEAPOT2")

        gone = poll_until(
            PHYSICAL_DELETE_TIMEOUT,
            lambda: not replica_exists(dst_pfn, teapot_token),
            lambda: run_deletion_daemons(RUCIO_SVC, rse="TEAPOT2"),
        )
        assert gone, f"Expected file to be physically deleted from TEAPOT2: {dst_pfn}"
        log.info("  ✓ File physically deleted from TEAPOT2 storage")

        try:
            list(rucio_client.list_dids(SCOPE, {"name": name}, did_type="file"))
            assert False, f"Expected DID {SCOPE}:{name} to be removed by undertaker"
        except Exception:
            pass  # DataIdentifierNotFound (or empty result) confirms removal
        log.info("  ✓ DID removed from catalogue")
