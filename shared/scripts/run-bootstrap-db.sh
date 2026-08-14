#!/usr/bin/env bash
set -euo pipefail

# ── Global Config ───────────────────────────────────────────────────────────
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

# Sandbox's bootstrap-db.py comes from testbed-scripts, already
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

# ── Logic Blocks ────────────────────────────────────────────────────────────

preflight() {
  require_cmd kubectl envsubst
  require_cluster
  [[ -f "$BOOTSTRAP_JOB_TMPL" ]] || die "bootstrap manifest template not found: $BOOTSTRAP_JOB_TMPL"
}

# Materializes testbed-scripts from the git checkout, staging/production
# only. Idempotent — safe to re-run.
generate_scripts_secret() {
  [[ "$GENERATE_SCRIPTS_SECRET" -eq 1 ]] || return 0
  local bootstrap_script="${REPO_ROOT}/shared/scripts/rucio/bootstrap-db.py"
  [[ -f "$bootstrap_script" ]] || die "bootstrap-db.py not found: $bootstrap_script"
  log "Materializing testbed-scripts from $bootstrap_script"
  kubectl create configmap testbed-scripts \
    --namespace "$K8S_NAMESPACE" \
    --from-file="bootstrap-db.py=${bootstrap_script}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

# The Job resolves DB_HOST as a plain TCP endpoint, not necessarily a
# Service DNS name — skip this check where there's no Service to wait for
# at all.
wait_for_db_service() {
  if [[ "$SKIP_SERVICE_CHECK" -eq 1 ]]; then
    log "Skipping Service existence check (--skip-service-check) — DB_HOST=${DB_HOST}"
    return 0
  fi
  log "Waiting for Service/${DB_SERVICE} to exist in ${K8S_NAMESPACE}"
  local i
  for i in $(seq 1 30); do
    if kubectl -n "$K8S_NAMESPACE" get service "$DB_SERVICE" >/dev/null 2>&1; then
      log "  ✓ Service/${DB_SERVICE} exists"
      return 0
    fi
    if [[ "$i" == "30" ]]; then
      die "Service/${DB_SERVICE} never appeared in ${K8S_NAMESPACE} — check 'kubectl -n ${K8S_NAMESPACE} get svc,pods'"
    fi
    echo "  [$i] waiting for Service/${DB_SERVICE}..."; sleep 5
  done
}

# Clears out any prior failed/completed attempt, then renders + applies.
apply_bootstrap_job() {
  kubectl -n "$K8S_NAMESPACE" delete job "$JOB_NAME" --ignore-not-found >/dev/null

  log "Rendering ${JOB_NAME} (DB_HOST=${DB_HOST})"
  # shellcheck disable=SC2016
  RENDER_DB_HOST="$DB_HOST" envsubst '${RENDER_DB_HOST}' < "$BOOTSTRAP_JOB_TMPL" \
    | kubectl apply -n "$K8S_NAMESPACE" -f -
}

# ── Main Entry Point ────────────────────────────────────────────────────────

main() {
  preflight
  generate_scripts_secret
  wait_for_db_service
  apply_bootstrap_job
  wait_for_job "$K8S_NAMESPACE" "$JOB_NAME" "$BOOTSTRAP_TIMEOUT" "rucio DB bootstrap failed"
  log "rucio-bootstrap-db complete."
}

main
