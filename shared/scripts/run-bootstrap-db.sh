#!/usr/bin/env bash
# ============================================================================
# run-bootstrap-db.sh — run the rucio-bootstrap-db Job imperatively
# ============================================================================
# base/bootstrap/ (and its kustomization.yaml, on both the Argo and Flux
# sides) is gone — the Job now lives as a plain manifest at
# shared/scripts/k8s/bootstrap-job.yaml and is applied here directly. It used
# to be GitOps-synced via Argo sync-wave "5" / a Flux dependsOn+healthCheck
# Kustomization, ordered after the secrets layer. That ordering was
# approximating the wrong dependency: the Job doesn't need the secrets layer
# per se, it needs the `ruciodb` Service to be reachable (it resolves
# DB_HOST=ruciodb and polls that directly) — which only exists once the
# *apps* root/components have been applied.
#
# Run this AFTER the apps root / components Kustomizations are applied —
# see the call sites in init-argocd.sh / init-flux.sh.
#
# Usage:
#   shared/scripts/run-bootstrap-db.sh --namespace dep-dlm-sandbox
#
# Env overrides (flags take precedence):
#   K8S_NAMESPACE     (default: dep-dlm-sandbox)
#   BOOTSTRAP_TIMEOUT (default: 300s)
#   DB_SERVICE        (default: ruciodb)  — must match bootstrap-job.yaml's DB_HOST
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh disable=SC1091
source "${SCRIPT_DIR}/common.sh"

K8S_NAMESPACE="${K8S_NAMESPACE:-dep-dlm-sandbox}"
BOOTSTRAP_TIMEOUT="${BOOTSTRAP_TIMEOUT:-300s}"
DB_SERVICE="${DB_SERVICE:-ruciodb}"
JOB_NAME="${JOB_NAME:-rucio-bootstrap-db}"
BOOTSTRAP_JOB="${SCRIPT_DIR}/k8s/bootstrap-job.yaml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) K8S_NAMESPACE="$2"; shift 2 ;;
    --timeout)   BOOTSTRAP_TIMEOUT="$2"; shift 2 ;;
    -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

require_cmd kubectl
require_cluster
[[ -f "$BOOTSTRAP_JOB" ]] || die "bootstrap manifest not found: $BOOTSTRAP_JOB"

# 1. The Job resolves DB_HOST=${DB_SERVICE} as a Service DNS name and already
#    retries internally (30 x 5s) once its pod starts — so this check isn't
#    trying to replace that, it's just failing fast if the Service was never
#    created at all (e.g. components Kustomization didn't apply cleanly),
#    rather than burning the Job's own retry budget against nothing.
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

# 2. Clean up any prior failed/completed attempt — Jobs are immutable by
#    name, so a stale one (e.g. from a run that started before ruciodb was
#    reachable under the old wiring) would block re-creation otherwise.
kubectl -n "$K8S_NAMESPACE" delete job "$JOB_NAME" --ignore-not-found >/dev/null

# 3. Apply and wait.
log "Applying ${JOB_NAME}"
kubectl apply -n "$K8S_NAMESPACE" -f "$BOOTSTRAP_JOB"

log "Waiting for ${JOB_NAME} to complete (up to ${BOOTSTRAP_TIMEOUT})"
if ! kubectl -n "$K8S_NAMESPACE" wait --for=condition=complete "job/${JOB_NAME}" --timeout="$BOOTSTRAP_TIMEOUT"; then
  warn "${JOB_NAME} did not complete in time — logs:"
  kubectl -n "$K8S_NAMESPACE" logs "job/${JOB_NAME}" --all-containers --tail=100 || true
  die "rucio DB bootstrap failed"
fi

log "rucio-bootstrap-db complete."
