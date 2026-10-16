#!/usr/bin/env bash
set -euo pipefail

RUNTIME="${RUNTIME:-compose}"
K8S_NAMESPACE="${K8S_NAMESPACE:-dep-dlm-sandbox}"

# ── Cross-runtime helpers (identical to init-testbed.sh) ─────────

_exec() {
    local svc=$1; shift
    case "$RUNTIME" in
        compose)
            docker exec "compose-${svc}-1" "$@"
            ;;
        k8s)
            local target
            local -a cflag=()
            case "$svc" in
                ftsdb|ruciodb)
                    target="pod/${svc}-0" ;;
                rucio-server)
                    target="deploy/${svc}"; cflag=(-c "$svc") ;;
                *)
                    target="deploy/${svc}" ;;
            esac
            kubectl -n "$K8S_NAMESPACE" exec "$target" "${cflag[@]}" -- "$@"
            ;;
        *) echo "Unknown RUNTIME: $RUNTIME" >&2; return 2 ;;
    esac
}

ra() { _exec rucio-server rucio-admin -S userpass -u ddmlab --password secret "$@"; }

# Testbed's known RSEs — sandbox internal + validation-storage external.
# Harmless to reference ones that don't exist for this run (guarded
# throughout), so this list is deliberately the union of both.
ALL_RSES=(XRD3 XRD4 TEAPOT1 TEAPOT2 COPERNICUS_S3)

# Scopes the testbed's own test suites write into — matches
# test_rucio_transfers.py's SCOPE="ddmlab" and init-testbed.sh's
# SEED_ACCOUNTS, not an exhaustive guess.
TEST_SCOPES=(ddmlab randomaccount test)

# ── Rule + replica cleanup ──────────────────────────────────────
# No CLI equivalent for "delete every rule matching X", and the
# daemon-driven physical deletion path needs core-level calls anyway.

delete_test_rules_and_replicas() {
    echo "=== Deleting replication rules (scopes: ${TEST_SCOPES[*]}) ==="

    _exec rucio-server env \
        TEST_SCOPES="$(IFS=,; echo "${TEST_SCOPES[*]}")" \
        python3 -c "
import os
from rucio.client import Client
from rucio.common.exception import RucioException

client = Client()
scopes = [s for s in os.environ['TEST_SCOPES'].split(',') if s]

deleted = 0
for scope in scopes:
    try:
        dids = list(client.list_dids(scope=scope, filters={}))
    except RucioException as e:
        print(f'  ⚠ Could not list DIDs in scope {scope}: {e}')
        continue
    for name in dids:
        try:
            rules = list(client.list_did_rules(scope=scope, name=name))
        except RucioException:
            continue
        for rule in rules:
            rid = rule['id']
            try:
                client.delete_replication_rule(rid, purge_replicas=True)
                print(f'  ✓ Deleted rule {rid} ({scope}:{name} -> {rule[\"rse_expression\"]})')
                deleted += 1
            except RucioException as e:
                print(f'  ⚠ Could not delete rule {rid}: {e}')

print(f'  {deleted} rule(s) deleted')
"

    echo "=== Draining deletions via judge-cleaner + reaper ==="
    echo "  purge_replicas=True above marks locks for immediate deletion;"
    echo "  these daemon passes actually remove the physical files."
    for _ in 1 2 3; do
        _exec rucio-server rucio-judge-cleaner --run-once || true
        _exec rucio-server rucio-reaper --run-once --greedy || true
    done
}

# ── RSE distance cleanup ──────────────────────────────────────────

delete_rse_distances() {
    echo "=== Deleting RSE distances ==="
    local pairs=(
        "XRD3 XRD4" "XRD4 XRD3"
        "TEAPOT1 TEAPOT2" "TEAPOT2 TEAPOT1"
        "XRD3 TEAPOT1" "TEAPOT1 XRD3"
        "COPERNICUS_S3 TEAPOT2" "COPERNICUS_S3 XRD4"
    )
    for pair in "${pairs[@]}"; do
        read -r src dst <<< "$pair"
        ra rse delete-distance "$src" "$dst" 2>/dev/null \
            && echo "  ✓ Deleted distance $src -> $dst" \
            || echo "  (no distance $src -> $dst, or already gone)"
    done
}

# ── RSE hard deletion ──────────────────────────────────────────────
# Deletes protocols/attributes/limits/usage/distance rows for each RSE,
# then the RSE row itself, via raw SQL against table names (not ORM
# model classes — those have shifted across Rucio versions and guessing
# them wrong just raises AttributeError; table names are far more
# stable). Not core.rse.del_rse() either — see header comment for why
# that soft-delete is unsafe here. Each table delete is wrapped
# separately so a table that doesn't exist in this Rucio version
# (rse_transfer_limits, distances' exact column names) doesn't abort
# the whole RSE's cleanup.

delete_rses() {
    echo "=== Hard-deleting RSEs: ${ALL_RSES[*]} ==="
    _exec rucio-server env \
        RSE_NAMES="$(IFS=,; echo "${ALL_RSES[*]}")" \
        python3 -c "
import os
from sqlalchemy import text
from rucio.db.sqla.session import get_session

session = get_session()
names = [n for n in os.environ['RSE_NAMES'].split(',') if n]

# (table, column referencing rse_id) — tried in order, each independently
CHILD_TABLES = [
    ('rse_protocols', 'rse_id'),
    ('rse_attr_map', 'rse_id'),
    ('rse_limits', 'rse_id'),
    ('rse_usage', 'rse_id'),
    ('rse_usage_history', 'rse_id'),
    ('rse_transfer_limits', 'rse_id'),
    ('account_limits', 'rse_id'),
    ('account_usage', 'rse_id'),
    ('distances', 'src_rse_id'),
    ('distances', 'dest_rse_id'),
]

for name in names:
    row = session.execute(
        text('SELECT id FROM rses WHERE rse = :name'), {'name': name}
    ).fetchone()
    if not row:
        print(f'  (RSE {name} not found — already gone)')
        continue
    rse_id = row[0]

    for table, col in CHILD_TABLES:
        try:
            session.execute(
                text(f'DELETE FROM {table} WHERE {col} = :rse_id'),
                {'rse_id': rse_id},
            )
            session.commit()
        except Exception as e:
            session.rollback()
            # Table/column not present in this Rucio version, or nothing
            # to delete there — not fatal, keep going.
            print(f'    (skipped {table}.{col}: {e.__class__.__name__})')

    try:
        session.execute(text('DELETE FROM rses WHERE id = :rse_id'), {'rse_id': rse_id})
        session.commit()
        print(f'  ✓ Deleted RSE {name}')
    except Exception as e:
        session.rollback()
        print(f'  ⚠ Could not delete RSE {name} (row still referenced somewhere): {e}')
"
}

# ── Main ────────────────────────────────────────────────────────

restart_rucio_server() {
    # Hard-deleting RSEs via raw SQL bypasses Rucio's application layer
    # entirely, so the already-running rucio-server process never
    # invalidates its in-process RSE name->id cache (dogpile.cache,
    # backing core.rse.get_rse_id()). Without this restart, the next
    # `rucio-admin rse add` inserts a fresh row fine, but a subsequent
    # `set-attribute`/`add-protocol` call resolves the name via the
    # STALE cached id (pointing at the now-deleted row) and fails with
    # an unhandled 500 ("no error information passed") on the resulting
    # FK violation — confirmed via a real teardown+init cycle.
    echo "=== Restarting rucio-server to flush its stale RSE-id cache ==="
    case "$RUNTIME" in
        compose)
            docker compose -f "${COMPOSE_FILE:-deploy/compose/docker-compose.managed.yml}" restart rucio-server ;;
        k8s)
            kubectl -n "$K8S_NAMESPACE" rollout restart deploy/rucio-server
            kubectl -n "$K8S_NAMESPACE" rollout status deploy/rucio-server --timeout=120s ;;
    esac
}

main() {
    delete_test_rules_and_replicas
    delete_rse_distances
    delete_rses
    restart_rucio_server
    echo -e "\n=== Teardown complete — re-run 'make init' to fully recreate the testbed ==="
}

main
