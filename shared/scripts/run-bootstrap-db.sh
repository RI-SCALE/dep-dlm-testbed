#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=common.sh disable=SC1091
source "${SCRIPT_DIR}/common.sh"

K8S_NAMESPACE="${K8S_NAMESPACE:-dep-dlm-sandbox}"
BOOTSTRAP_TIMEOUT="${BOOTSTRAP_TIMEOUT:-300s}"
DB_SERVICE="${DB_SERVICE:-ruciodb}"
JOB_NAME="${JOB_NAME:-rucio-bootstrap-db}"
BOOTSTRAP_JOB_TMPL="${SCRIPT_DIR}/k8s/bootstrap-job.yaml.tmpl"

# DB_HOST default (ruciodb, the in-cluster Service) preserves sandbox's
# existing behavior exactly — rendering DB_HOST=ruciodb through envsubst
# produces byte-identical output to the old static bootstrap-job.yaml.
# staging/production pass their real Cloud SQL private IP instead.
DB_HOST="${DB_HOST:-ruciodb}"

# Sandbox's bootstrap-db.py comes from testbed-scripts-rucio, already
# ESO-managed from Vault — nothing to generate. staging/production have
# no Vault-sourced equivalent (scripts/tests were scoped out of the GCP
# secret set entirely, no counterpart exists), so this materializes the
# same secret name/key directly from the git checkout instead, same
# spirit as testbed-patches' Kustomize secretGenerator but simpler (one
# file, no Kustomize base needed) — imperative kubectl, not GitOps-owned,
# since it only exists for this one-shot Job's lifetime.
GENERATE_SCRIPTS_SECRET=0

# Sandbox's ruciodb is a real in-cluster Service — worth waiting for it
# to exist before applying the Job. staging/production's DB_HOST is a
# Cloud SQL private IP with no corresponding Service object to poll for,
# so this check is meaningless there and must be skipped, not redirected.
SKIP_SERVICE_CHECK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)              K8S_NAMESPACE="$2"; shift 2 ;;
    --timeout)                BOOTSTRAP_TIMEOUT="$2"; shift 2 ;;
    --db-host)                DB_HOST="$2"; shift 2 ;;
    --skip-service-check)     SKIP_SERVICE_CHECK=1; shift ;;
    --generate-scripts-secret) GENERATE_SCRIPTS_SECRET=1; shift ;;
    -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

require_cmd kubectl envsubst
require_cluster
[[ -f "$BOOTSTRAP_JOB_TMPL" ]] || die "bootstrap manifest template not found: $BOOTSTRAP_JOB_TMPL"

# 0. Materialize testbed-scripts-rucio from the git checkout, staging/
#    production only. Idempotent — safe to re-run. NOT done for sandbox:
#    that namespace's testbed-scripts-rucio is ESO-owned (Vault-sourced),
#    and this would fight it for ownership of the same object name.
if [[ "$GENERATE_SCRIPTS_SECRET" -eq 1 ]]; then
  BOOTSTRAP_SCRIPT="${REPO_ROOT}/shared/scripts/rucio/bootstrap-db.py"
  [[ -f "$BOOTSTRAP_SCRIPT" ]] || die "bootstrap-db.py not found: $BOOTSTRAP_SCRIPT"
  log "Materializing testbed-scripts-rucio from $BOOTSTRAP_SCRIPT"
  kubectl create secret generic testbed-scripts-rucio \
    --namespace "$K8S_NAMESPACE" \
    --from-file="bootstrap-db.py=${BOOTSTRAP_SCRIPT}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# 1. The Job resolves DB_HOST as a plain TCP endpoint, not necessarily a
#    Service DNS name — skip this check where there's no Service to wait
#    for at all.
if [[ "$SKIP_SERVICE_CHECK" -eq 0 ]]; then
  log "Waiting for Service/${DB_SERVICE} to exist in ${K8S_NAMESPACE}"
  for i in $(seq 1 30); do
    if kubectl -n "$K8S_NAMESPACE" get service "$DB_SERVICE" >/dev/null 2>&1; then
      log "  ✓ Service/${DB_SERVICE} exists"
      break
    fi
    if [[ "$i" == "30" ]]; then
      die "Service/${DB_SERVICE} never appeared in ${K8S_NAMESPACE} — check 'kubectl -n ${K8S_NAMESPACE} get svc,pods'"
    fi
    echo "  [$i] waiting for Service/${DB_SERVICE}..."; sleep 5
  done
else
  log "Skipping Service existence check (--skip-service-check) — DB_HOST=${DB_HOST}"
fi

# 2. Clean up any prior failed/completed attempt
kubectl -n "$K8S_NAMESPACE" delete job "$JOB_NAME" --ignore-not-found >/dev/null

# 3. Render + apply.
log "Rendering ${JOB_NAME} (DB_HOST=${DB_HOST})"
# shellcheck disable=SC2016
DB_HOST="$DB_HOST" envsubst '${DB_HOST}' < "$BOOTSTRAP_JOB_TMPL" \
  | kubectl apply -n "$K8S_NAMESPACE" -f -

log "Waiting for ${JOB_NAME} to complete (up to ${BOOTSTRAP_TIMEOUT})"
if ! kubectl -n "$K8S_NAMESPACE" wait --for=condition=complete "job/${JOB_NAME}" --timeout="$BOOTSTRAP_TIMEOUT"; then
  warn "${JOB_NAME} did not complete in time — logs:"
  kubectl -n "$K8S_NAMESPACE" logs "job/${JOB_NAME}" --all-containers --tail=100 || true
  die "rucio DB bootstrap failed"
fi

log "rucio-bootstrap-db complete."
