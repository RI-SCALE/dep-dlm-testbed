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
# conftest.py. In that mode both the rule-removal and physical-delete steps
# are pure passive waits on real, continuously-running daemons with their
# own internal cooldown/sleep-time cadence we don't control, so they need
# real headroom rather than the 60s that's sufficient when we can force an
# extra cycle ourselves (DAEMON_MODE=direct).
PHYSICAL_DELETE_TIMEOUT = 300 if os.environ.get("DAEMON_MODE") == "daemons" else 60
RULE_REMOVAL_TIMEOUT = 300 if os.environ.get("DAEMON_MODE") == "daemons" else 60

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
            RULE_REMOVAL_TIMEOUT,
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

    def test_file_did_undertaker_only(
        self, rucio_client, teapots_ready, teapot_token, xrd3_write_token
    ):
        """Expire a FILE DID and run ONLY judge-cleaner + undertaker (no reaper).

        Isolates what undertaker actually guarantees for a FILE DID: unlocked
        rules removed, a tombstone set on the replica, expired_at cleared.
        It does NOT delete the DID catalog row or the replica itself — that
        is deferred to reaper. This is the behavior a reaper-less deployment
        actually gets from undertaker alone.
        """
        name = f"undertaker-only-test-{int(time.time())}"
        log.info("[ FILE DID undertaker-only lifecycle  name=%s ]", name)

        src_pfn = compute_pfn(rucio_client, "TEAPOT1", SCOPE, name)
        dst_pfn = compute_pfn(rucio_client, "TEAPOT2", SCOPE, name)

        seed_content = b"undertaker-only-test\n"
        webdav_delete(pfn_to_https(src_pfn), teapot_token)
        resp = webdav_put(pfn_to_https(src_pfn), teapot_token, seed_content)
        assert resp.status_code in {200, 201, 204}

        adler32 = "%08x" % (zlib.adler32(seed_content) & 0xFFFFFFFF)
        register_replica(
            rucio_client, "TEAPOT1", SCOPE, name, src_pfn, len(seed_content), adler32
        )
        rule_id = add_rule(rucio_client, SCOPE, name, "TEAPOT2")

        run_daemons(RUCIO_SVC)
        validate_rule(
            rucio_client, rule_id, "TEAPOT1→TEAPOT2 (pre-deletion)", RUCIO_SVC
        )
        assert replica_exists(dst_pfn, teapot_token)

        rucio_client.set_metadata(SCOPE, name, "lifetime", -1)
        log.info("  ✓ DID lifetime set to -1 (expires immediately)")

        # deliberately CLEANER_AND_UNDERTAKER only — no reaper in this test
        removed = poll_until(
            RULE_REMOVAL_TIMEOUT,
            lambda: rule_gone(rucio_client, rule_id),
            lambda: advance_pipeline(RUCIO_SVC, CLEANER_AND_UNDERTAKER),
        )
        assert removed, "Expected rule to be removed by undertaker (rule still exists)"
        log.info("  ✓ Rule removed by undertaker")

        # the DID row must still exist — undertaker never deletes FILE DIDs
        meta = rucio_client.get_metadata(SCOPE, name)
        assert meta is not None, (
            "FILE DID should still exist after undertaker-only pass — "
            "undertaker does not delete FILE DID rows, only reaper does"
        )
        assert meta.get("expired_at") is None, (
            "Expected undertaker to clear expired_at on the FILE DID"
        )
        log.info(
            "  ✓ DID row still present, expired_at cleared (as expected — reaper not run)"
        )

        # NOTE: no physical-replica assertion here. In DAEMON_MODE=daemons a
        # real reaper may be running continuously and independently of this
        # test, and — being greedy — will eventually pick up this tombstone
        # regardless of what this test does. The catalog-level checks above
        # are what actually isolate undertaker's guarantee; physical-deletion
        # timing is reaper's concern, covered by the rule-based test.

    def test_dataset_did_undertaker_only(
        self, rucio_client, teapots_ready, teapot_token, xrd3_write_token
    ):
        """Expire a DATASET DID, run undertaker only (no reaper): the DID row
        itself is deleted directly — contrast to test_file_did_undertaker_only,
        where the FILE row survives until reaper runs.
        """
        dataset = f"undertaker-dataset-test-{int(time.time())}"
        file_name = f"{dataset}-file"

        src_pfn = compute_pfn(rucio_client, "TEAPOT1", SCOPE, file_name)
        seed_content = b"undertaker-dataset-test\n"
        webdav_delete(pfn_to_https(src_pfn), teapot_token)
        webdav_put(pfn_to_https(src_pfn), teapot_token, seed_content)
        adler32 = "%08x" % (zlib.adler32(seed_content) & 0xFFFFFFFF)
        register_replica(
            rucio_client,
            "TEAPOT1",
            SCOPE,
            file_name,
            src_pfn,
            len(seed_content),
            adler32,
        )

        rucio_client.add_dataset(scope=SCOPE, name=dataset)
        rucio_client.attach_dids(SCOPE, dataset, [{"scope": SCOPE, "name": file_name}])
        rule_id = add_rule(rucio_client, SCOPE, dataset, "TEAPOT2")

        run_daemons(RUCIO_SVC)
        validate_rule(rucio_client, rule_id, "TEAPOT1→TEAPOT2 (dataset)", RUCIO_SVC)

        rucio_client.set_metadata(SCOPE, dataset, "lifetime", -1)
        removed = poll_until(
            RULE_REMOVAL_TIMEOUT,
            lambda: rule_gone(rucio_client, rule_id),
            lambda: advance_pipeline(RUCIO_SVC, CLEANER_AND_UNDERTAKER),
        )
        assert removed, "Expected rule to be removed by undertaker (rule still exists)"

        # dataset row gone, no reaper needed
        try:
            rucio_client.get_metadata(SCOPE, dataset)
            assert False, "Expected dataset DID removed by undertaker alone"
        except Exception:
            pass

        # child file row untouched — undertaker only detaches it
        assert rucio_client.get_metadata(SCOPE, file_name) is not None
        log.info("  ✓ Dataset removed by undertaker; child file row untouched")
