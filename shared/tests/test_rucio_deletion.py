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
    kubectl -n dep-dlm-testbed exec deploy/rucio-client -- \\
        bash -c "RUNTIME=k8s K8S_NAMESPACE=dep-dlm-testbed pytest /tests/test_rucio_deletion.py -v"
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
    svc_exec,
    validate_rule,
)

log = logging.getLogger("test-deletion")

SCOPE = "ddmlab"

# Both judge-cleaner and reaper run in the rucio server container.
# gfal2 is installed at container startup (see docker-compose.yml entrypoint)
# to satisfy the reaper's Python gfal2 dependency for davs:// physical deletion.
RUCIO_SVC = "rucio"


def run_deletion_daemons(rucio_svc: str = RUCIO_SVC) -> None:
    """Advance the deletion pipeline (judge-cleaner → reaper)."""
    for daemon in (
        [
            "rucio-judge-cleaner",
            "--run-once",
        ],  # expires rule → releases lock → OBSOLETE tombstone
        [
            "rucio-reaper",
            "--run-once",
            "--greedy",
        ],  # # OBSOLETE tombstone → physical deletion via davs://
    ):
        log.info("  → %s %s", rucio_svc, " ".join(daemon))
        out = svc_exec(rucio_svc, daemon)
        for line in out.decode(errors="replace").splitlines():
            if any(
                k in line.lower()
                for k in ("warning", "error", "delet", "expir", "reap", "tomb")
            ):
                log.info("    | %s", line)


def replica_exists_on_xrd(svc: str, pfn: str) -> bool:
    """Check whether a file exists at the given PFN path inside an XRootD container."""

    local_path = "/" + pfn.split("//", 1)[-1].split("/", 1)[-1]
    if RUCIO_SVC == "rucio":  # reuse svc_exec indirectly
        try:
            svc_exec(svc, ["test", "-f", local_path])
            return True
        except RuntimeError:
            return False
    return False


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

    def test_rule_deletion_via_judge_cleaner_and_reaper(self, rucio_client):
        """Replicate XRD3→XRD4, delete rule, verify judge-cleaner+reaper clean up."""
        name = f"deletion-test-{int(time.time())}"
        log.info("[ Rule deletion lifecycle  name=%s ]", name)

        # ── Step 1: seed and replicate ────────────────────────────────────
        src_pfn = compute_pfn(rucio_client, "XRD3", SCOPE, name)
        dst_pfn = compute_pfn(rucio_client, "XRD4", SCOPE, name)
        log.info("  src PFN: %s", src_pfn)
        log.info("  dst PFN: %s", dst_pfn)

        size, adler32 = seed_xrd("xrd3", src_pfn)
        log.info("  seeded %d bytes  adler32=%s", size, adler32)
        prepare_xrd_dest("xrd4", dst_pfn)

        register_replica(rucio_client, "XRD3", SCOPE, name, src_pfn, size, adler32)
        rule_id = add_rule(rucio_client, SCOPE, name, "XRD4")

        run_daemons(RUCIO_SVC)
        validate_rule(rucio_client, rule_id, "XRD3→XRD4 (pre-deletion)", RUCIO_SVC)

        # Confirm file exists on XRD4 before deletion
        assert replica_exists_on_xrd("xrd4", dst_pfn), (
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
        run_deletion_daemons(RUCIO_SVC)

        # ── Step 5: verify replica removed from catalogue ─────────────────
        replicas = list(
            rucio_client.list_replicas(
                [{"scope": SCOPE, "name": name}], rse_expression="XRD4"
            )
        )
        xrd4_pfns = [
            pfn for r in replicas for pfn in r.get("pfns", {}) if "xrd4" in pfn
        ]
        assert not xrd4_pfns, (
            f"Expected replica to be removed from Rucio catalogue on XRD4, "
            f"but found: {xrd4_pfns}"
        )
        log.info("  ✓ Replica removed from Rucio catalogue on XRD4")

        # ── Step 6: verify physical deletion from storage ─────────────────
        assert not replica_exists_on_xrd("xrd4", dst_pfn), (
            f"Expected file to be physically deleted from XRD4: {dst_pfn}"
        )
        log.info("  ✓ File physically deleted from XRD4 storage")

        # Source replica on XRD3 should still exist (rule only covered XRD4)
        src_replicas = list(
            rucio_client.list_replicas([{"scope": SCOPE, "name": name}])
        )
        assert src_replicas, "Source replica on XRD3 should still exist"
        log.info("  ✓ Source replica on XRD3 intact")
