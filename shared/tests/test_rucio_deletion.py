"""
test_rucio_deletion.py — Rucio replication rule deletion lifecycle tests.

Exercises the full deletion pipeline:
  judge-cleaner — finds rules with expires_at < now(), releases locks and
                  sets an OBSOLETE tombstone on replicas (purge_replicas=True)
  reaper        — finds replicas with OBSOLETE tombstone, physically deletes
                  from storage via davs:// (requires gfal2)

Runtime-agnostic: respects $RUNTIME (compose | k8s, default compose).

Typical invocations:
    # Compose
    docker exec compose-rucio-client-1 \\
        bash -c "RUNTIME=compose pytest /tests/test_rucio_deletion.py -v"

    # Kubernetes
    kubectl -n dep-dlm-sandbox exec deploy/rucio-client -- \\
        bash -c "RUNTIME=k8s K8S_NAMESPACE=dep-dlm-sandbox pytest /tests/test_rucio_deletion.py -v"
"""

import logging
import time

from conftest import (
    add_rule,
    compute_pfn,
    prepare_xrd_dest,
    register_replica,
    run_daemons,
    seed_xrd,
    validate_rule,
    advance_pipeline,
    webdav_get,
    pfn_to_https,
    DELETION_DAEMONS,
)

log = logging.getLogger("test-deletion")

SCOPE = "ddmlab"

# Both judge-cleaner and reaper run in the rucio server container.
# gfal2 is installed at container startup (see docker-compose.yml entrypoint)
# to satisfy the reaper's Python gfal2 dependency for davs:// physical deletion.
RUCIO_SVC = "rucio-server"


def run_deletion_daemons(rucio_svc: str = RUCIO_SVC) -> None:
    advance_pipeline(
        rucio_svc,
        DELETION_DAEMONS,
        keywords=("warning", "error", "delet", "expir", "reap", "tomb"),
    )


def replica_exists_on_xrd(pfn: str, token: str = None) -> bool:
    """Check whether a file exists at the given PFN via HTTP GET — same
    transport seed_xrd/prepare_xrd_dest use. Works against both sandbox's
    in-cluster XRootD pods and staging's external validation-storage VM;
    neither is reachable via svc_exec/kubectl exec on staging, where xrd3/
    xrd4 are plain Docker containers on a GCE VM, not Kubernetes Deployments.
    """
    resp = webdav_get(pfn_to_https(pfn), token)
    return resp.status_code == 200


class TestDeletionLifecycle:
    """
    Full rule deletion lifecycle: transfer → expire rule → judge-cleaner → reaper.

    Flow:
    1. Seed a file on XRD3 and replicate to XRD4 (establishes a replica lock)
    2. Set rule lifetime=-1 with purge_replicas=True (expires_at = past)
    3. Run judge-cleaner: finds expired rule, releases lock, sets OBSOLETE tombstone
    4. Run reaper: finds OBSOLETE tombstone, physically deletes from XRD4 via davs://
    5. Assert the replica is removed from the Rucio catalogue
    6. Assert the file no longer exists on the XRD4 storage backend
    """

    def test_rule_deletion_via_judge_cleaner_and_reaper(
        self, rucio_client, xrd3_write_token, xrd4_write_token
    ):
        """Replicate XRD3→XRD4, delete rule, verify judge-cleaner+reaper clean up."""
        name = f"deletion-test-{int(time.time())}"
        log.info("[ Rule deletion lifecycle  name=%s ]", name)

        # ── Step 1: seed and replicate ────────────────────────────────────
        src_pfn = compute_pfn(rucio_client, "XRD3", SCOPE, name)
        dst_pfn = compute_pfn(rucio_client, "XRD4", SCOPE, name)
        log.info("  src PFN: %s", src_pfn)
        log.info("  dst PFN: %s", dst_pfn)

        size, adler32 = seed_xrd("xrd3", src_pfn, token=xrd3_write_token)
        log.info("  seeded %d bytes  adler32=%s", size, adler32)
        prepare_xrd_dest(dst_pfn, token=xrd4_write_token)

        register_replica(rucio_client, "XRD3", SCOPE, name, src_pfn, size, adler32)
        rule_id = add_rule(rucio_client, SCOPE, name, "XRD4")

        run_daemons(RUCIO_SVC)
        validate_rule(rucio_client, rule_id, "XRD3→XRD4 (pre-deletion)", RUCIO_SVC)

        # Confirm file exists on XRD4 before deletion
        assert replica_exists_on_xrd(dst_pfn, xrd4_write_token), (
            f"Expected replica to exist on XRD4 before deletion: {dst_pfn}"
        )
        log.info("  ✓ Replica confirmed on XRD4 before deletion")

        # ── Step 2: delete the replication rule ──────────────────────────
        log.info("  Deleting rule %s", rule_id)
        rucio_client.update_replication_rule(
            rule_id, {"lifetime": -1, "purge_replicas": True}
        )
        log.info("  ✓ Rule lifetime set to -1 (expires immediately)")
        log.info("  ✓ Rule deletion requested")

        # ── Step 3+4: judge-cleaner releases lock, reaper deletes physically ─
        # In direct mode advance_pipeline runs the daemons synchronously;
        # in daemon mode it's a no-op and the long-running daemons converge
        # on their own loop — so poll until the replica is gone either way.
        # One pass isn't guaranteed to catch it — a tombstone set moments
        # earlier in the same reaper cycle can still be missed (observed on
        # staging: reaper's list_and_mark_unlocked_replicas returned 0 for
        # XRD4 on its first pass), so re-run the daemons on every iteration
        # of both polling loops below rather than relying on one pass here.
        run_deletion_daemons(RUCIO_SVC)

        # ── Step 5: poll for catalogue removal, re-running daemons each cycle
        deadline = time.time() + 120
        xrd4_pfns = None
        while time.time() < deadline:
            replicas = list(
                rucio_client.list_replicas(
                    [{"scope": SCOPE, "name": name}], rse_expression="XRD4"
                )
            )
            xrd4_pfns = [
                pfn for r in replicas for pfn in r.get("pfns", {}) if "xrd4" in pfn
            ]
            if not xrd4_pfns:
                break
            run_deletion_daemons(RUCIO_SVC)
            time.sleep(5)

        assert not xrd4_pfns, (
            f"Expected replica to be removed from Rucio catalogue on XRD4, "
            f"but found: {xrd4_pfns}"
        )
        log.info("  ✓ Replica removed from Rucio catalogue on XRD4")

        # ── Step 6: poll for physical deletion, re-running daemons each cycle
        # Rucio delinks the catalogue row (Step 5) before the physical davs://
        # DELETE against storage actually completes — a real race window,
        # not just eventual consistency — so this can't be a single
        # immediately-after check; keep re-running the daemons while polling.
        deadline = time.time() + 120
        still_exists = replica_exists_on_xrd(dst_pfn, xrd4_write_token)
        while still_exists and time.time() < deadline:
            run_deletion_daemons(RUCIO_SVC)
            time.sleep(5)
            still_exists = replica_exists_on_xrd(dst_pfn, xrd4_write_token)

        assert not still_exists, (
            f"Expected file to be physically deleted from XRD4: {dst_pfn}"
        )
        log.info("  ✓ File physically deleted from XRD4 storage")

        # Source replica on XRD3 should still exist (rule only covered XRD4)
        src_replicas = list(
            rucio_client.list_replicas([{"scope": SCOPE, "name": name}])
        )
        assert src_replicas, "Source replica on XRD3 should still exist"
        log.info("  ✓ Source replica on XRD3 intact")
