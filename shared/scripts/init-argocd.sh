#!/usr/bin/env bash
# ============================================================================
# init-argocd.sh — install Argo CD and bootstrap the DEP DLM sandbox
# ============================================================================
# Installs Argo CD, then bootstraps in the order the stack actually depends
# on, NOT the order the manifests happen to be organized in:
#
#   1. apps root (the ApplicationSet itself) — generates ALL component
#      Applications (vault-<env>, external-secrets-<env>, ruciodb-<env>,
#      rucio-server-<env>, ...) as independent, auto-syncing Applications.
#   2. wait for the CORE tier only: vault-<env> + external-secrets-<env>.
#      These are what seed-vault.sh and every ExternalSecret actually need.
#   3. apps root's OTHER components (rucio-server, fts, ...) may already be
#      mid-sync at this point too — that's fine, they'll just sit in
#      ContainerCreating/FailedMount until step 5 seeds their config. We
#      don't wait on them, and we don't wait on the secrets root's sync
#      status either — it isn't the real gate (only the Vault pod being
#      Ready matters here, already confirmed) and Argo's aggregate sync
#      status on that Application is noisy/flaky, not a reliable signal.
#   4. secrets root (ExternalSecrets + ClusterSecretStore) — applied, not
#      waited on.
#   5. seed-vault.sh, then force an immediate ExternalSecret refresh (their
#      default 1h refresh interval is too slow to just wait out) — pods with
#      FailedMount self-heal automatically once the target Secret exists,
#      no restart needed.
#   6. run-bootstrap-db.sh, called directly — NOT gated behind a wait on
#      component Application health. rucio-daemons specifically can never
#      become Healthy before this runs (it crash-loops on a missing
#      "heartbeats" table that bootstrap itself creates), so a pre-bootstrap
#      health wait would be a hard deadlock, not just slow. There used to be
#      such a wait here; it's gone now, not just reordered. Component pods
#      (rucio-server, xrd3/4, teapot1/2, fts, ...) recover on their own via
#      kubelet's mount retries + the forced ExternalSecret refresh in step
#      5 — run-bootstrap-db.sh has its own correct, non-circular
#      precondition instead (Service/ruciodb exists, then an in-Job
#      DB-reachability retry loop).
#
# IMPORTANT — why this isn't automatic: the `argocd.argoproj.io/sync-wave`
# annotations on each element in argocd/applicationsets/<env>.yaml do NOT
# order these Applications relative to each other. Sync-wave only orders
# resources within a single Application's own sync; these are independent
# top-level Applications the ApplicationSet controller creates side by side
# with no relative ordering guarantee. This script provides the ordering
# Argo doesn't.
#
# Idempotent: safe to re-run. Honours an existing Argo CD install.
#
# Usage:
#   shared/scripts/init-argocd.sh [--env sandbox|staging|production]
#                                 [--repo-url URL] [--revision REF]
#                                 [--flow managed|unmanaged]
#                                 [--scope-profile local|<profile>]
#                                 [--no-wait] [--no-seed]
#
# Env overrides:
#   ARGOCD_NAMESPACE   (default: argocd)
#   ARGOCD_VERSION     (default: stable)         e.g. v2.12.4
#   APP_NS             (default: dep-dlm-<env>)  workload namespace
#   REPO_URL           git repo Argo pulls from  (default: from app-of-apps-<env>.yaml)
#   REVISION           git ref Argo tracks       (default: current branch)
#   GITOPS_ENV         gitops overlay to apply    (default: sandbox)
#   FLOW               FTS token mode for vault seeding (default: managed)
#   SCOPE_PROFILE      OIDC scope profile for vault seeding (default: local)
#
# --no-seed skips both the seed-vault.sh AND run-bootstrap-db.sh steps, and
# the core-tier wait (steps 2/6) — use for staging/production, which don't
# run vault-<env>/external-secrets-<env> this way (see
# environments/<env>/secrets/README.md).
#
# ASSUMPTION FLAGGED: this script assumes the ApplicationSet element names
# "vault" and "external-secrets" (→ Applications vault-<env>,
# external-secrets-<env>). It previously also assumed Argo's ApplicationSet
# controller labels every generated Application with
# argocd.argoproj.io/application-set-name=<name> — that turned out to match
# ZERO Applications in practice, so step 8 now waits on the component
# Applications by explicit name (taken from argocd/applicationsets/<env>.yaml)
# instead of trusting that label.
#
# Examples:
#   shared/scripts/init-argocd.sh \
#     --env sandbox \
#     --repo-url https://github.com/ri-scale/dep-dlm-testbed.git \
#     --revision feat/gitops-deployment-blueprint \
#     --flow managed --scope-profile egi-dev
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GITOPS_DIR="${REPO_ROOT}/deploy/gitops"

# shellcheck source=common.sh disable=SC1091
source "${SCRIPT_DIR}/common.sh"

GITOPS_ENV="${GITOPS_ENV:-sandbox}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"
APP_NS="${APP_NS:-dep-dlm-${GITOPS_ENV}}"
REPO_URL="${REPO_URL:-}"
REVISION="${REVISION:-}"
FLOW="${FLOW:-managed}"
SCOPE_PROFILE="${SCOPE_PROFILE:-local}"
WAIT=1
SEED=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-url)       REPO_URL="$2"; shift 2 ;;
    --revision)       REVISION="$2"; shift 2 ;;
    --env)            GITOPS_ENV="$2"; shift 2 ;;
    --flow)           FLOW="$2"; shift 2 ;;
    --scope-profile)  SCOPE_PROFILE="$2"; shift 2 ;;
    --no-wait)        WAIT=0; shift ;;
    --no-seed)        SEED=0; shift ;;
    -h|--help)        grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

APP_OF_APPS="${GITOPS_DIR}/argocd/entrypoints/app-of-apps-${GITOPS_ENV}.yaml"
ASET_NAME="dep-dlm-${GITOPS_ENV}"   # matches argocd/applicationsets/<env>.yaml metadata.name

# --- Preflight --------------------------------------------------------------
require_cmd kubectl yq
require_cluster
[[ -f "$APP_OF_APPS" ]] || die "app-of-apps-${GITOPS_ENV}.yaml not found at $APP_OF_APPS"
if [[ "$SEED" -eq 1 && "$GITOPS_ENV" == "sandbox" ]]; then
  require_cmd envsubst
fi

log "Target cluster:"
kubectl config current-context || true

# --- 1. Install Argo CD -----------------------------------------------------
if kubectl get ns "$ARGOCD_NAMESPACE" >/dev/null 2>&1 \
   && kubectl -n "$ARGOCD_NAMESPACE" get deploy argocd-server >/dev/null 2>&1; then
  log "Argo CD already present in namespace '$ARGOCD_NAMESPACE' — skipping install"
else
  log "Installing Argo CD ($ARGOCD_VERSION) into namespace '$ARGOCD_NAMESPACE'"
  kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  # --server-side avoids kubectl's 256KB last-applied-configuration annotation,
  # which the large ApplicationSet CRD exceeds. --force-conflicts lets a re-run
  # (or a prior client-side apply) hand over field ownership cleanly.
  kubectl apply --server-side --force-conflicts -n "$ARGOCD_NAMESPACE" \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
fi

# --- 2. Wait for Argo CD to be ready ----------------------------------------
if [[ "$WAIT" -eq 1 ]]; then
  log "Waiting for Argo CD components to become Available (up to 5m)"
  # application-controller is a StatefulSet on newer installs; try both.
  wait_for_workload "$ARGOCD_NAMESPACE" deploy      argocd-repo-server
  wait_for_workload "$ARGOCD_NAMESPACE" deploy      argocd-server
  wait_for_workload "$ARGOCD_NAMESPACE" deploy      argocd-application-controller
  wait_for_workload "$ARGOCD_NAMESPACE" statefulset argocd-application-controller
fi

# --- 3. Patch app-of-apps-<env>.yaml repo/revision if overrides given -------
APPLY_FILE="$(patch_git_ref "$APP_OF_APPS" repoURL targetRevision "$REPO_URL" "$REVISION")"
if [[ "$APPLY_FILE" != "$APP_OF_APPS" ]]; then
  warn "Applied repo/revision overrides only to the app-of-apps-${GITOPS_ENV}.yaml root."
  warn "The child Applications under argocd/applicationsets/ still carry their"
  warn "own repoURL/targetRevision — edit those for the bundled charts, or"
  warn "merge to your default branch so HEAD resolves."
fi

# --- 4. Apply the apps root (the ApplicationSet) FIRST — this is what
# actually creates vault-<env>/external-secrets-<env>. See header: their
# sync-wave annotations don't order them relative to each other, so applying
# early is safe (nothing here depends on the secrets root existing yet).
log "Applying apps root (dep-dlm-${GITOPS_ENV}-apps)"
kubectl apply -n "$ARGOCD_NAMESPACE" -f <(yq 'select(.metadata.name == "'"${ASET_NAME}"'-apps")' "$APPLY_FILE")

# --- 5. Wait for the core tier: vault + external-secrets operator. This is
# the actual precondition for seeding and for any ExternalSecret to resolve.
if [[ "$SEED" -eq 1 && "$GITOPS_ENV" == "sandbox" && "$WAIT" -eq 1 ]]; then
  log "Waiting for the ApplicationSet to generate vault-${GITOPS_ENV} / external-secrets-${GITOPS_ENV}"
  for app in "vault-${GITOPS_ENV}" "external-secrets-${GITOPS_ENV}"; do
    for i in $(seq 1 30); do
      kubectl -n "$ARGOCD_NAMESPACE" get application "$app" >/dev/null 2>&1 && break
      if [[ "$i" == "30" ]]; then
        warn "Application/${app} never appeared — check the ApplicationSet controller: 'kubectl -n ${ARGOCD_NAMESPACE} get applicationset ${ASET_NAME}'"
      fi
      sleep 5
    done
  done

  log "Waiting for vault-${GITOPS_ENV} and external-secrets-${GITOPS_ENV} to become Healthy (up to 5m)"
  kubectl -n "$ARGOCD_NAMESPACE" wait --for=jsonpath='{.status.health.status}'=Healthy \
    "application/vault-${GITOPS_ENV}" "application/external-secrets-${GITOPS_ENV}" \
    --timeout=300s \
    || warn "core tier not Healthy within timeout — seeding will likely fail; check 'kubectl -n ${ARGOCD_NAMESPACE} get application vault-${GITOPS_ENV} external-secrets-${GITOPS_ENV}'"
fi

# --- 6. Apply the secrets root — Vault + ESO now exist, so ExternalSecrets
# CAN resolve once seeded. We deliberately do NOT wait on this Application's
# sync/health status: it isn't the real gate (seed-vault.sh only needs the
# Vault pod Ready, already confirmed in step 5) and Argo's aggregate
# sync.status here is prone to noisy perpetual OutOfSync from server-side-
# apply field-ownership churn on the ExternalSecret objects — polling it
# is what caused both prior stalls. "unchanged"/"created" in the apply
# output below is confirmation enough that the manifests landed.
log "Applying secrets root (dep-dlm-${GITOPS_ENV}-secrets)"
kubectl apply -n "$ARGOCD_NAMESPACE" -f <(yq 'select(.metadata.name == "'"${ASET_NAME}"'-secrets")' "$APPLY_FILE")
[[ "$APPLY_FILE" != "$APP_OF_APPS" ]] && rm -f "$APPLY_FILE"

# --- 7. Seed Vault (sandbox only) — Vault is reachable (step 5).
if [[ "$SEED" -eq 1 && "$GITOPS_ENV" == "sandbox" ]]; then
  "${SCRIPT_DIR}/seed-vault.sh" \
    --namespace "$APP_NS" \
    --repo-url "${REPO_URL:-https://github.com/ri-scale/dep-dlm-testbed.git}" \
    --revision "${REVISION:-main}" \
    --flow "$FLOW" \
    --scope-profile "$SCOPE_PROFILE"

elif [[ "$SEED" -eq 0 ]]; then
  log "Skipping Vault seeding (--no-seed)"
fi

# --- 8. Bootstrap the rucio DB schema (sandbox only) ------------------------
# NOTE: this used to wait for all component Applications (including
# rucio-daemons) to be Healthy before running bootstrap. That's a hard
# deadlock, not just flaky: rucio-daemons crash-loops on a missing
# "heartbeats" table until run-bootstrap-db.sh creates it, so it can NEVER
# become Healthy before bootstrap runs — Argo would just wait the full
# timeout every time. run-bootstrap-db.sh already has its own correct,
# non-circular precondition (waits for Service/ruciodb to exist, then the
# Job's own internal DB-reachability retry loop) — that's the real gate,
# so we call it directly rather than polling component health first.
if [[ "$SEED" -eq 1 && "$GITOPS_ENV" == "sandbox" ]]; then
  "${SCRIPT_DIR}/run-bootstrap-db.sh" --namespace "$APP_NS"
fi

# --- 9. Report --------------------------------------------------------------
log "Argo CD admin password (initial):"
if kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret >/dev/null 2>&1; then
  kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null \
    | base64 -d 2>/dev/null \
    || warn "Failed to decode initial admin password"
else
  warn "initial-admin-secret not found (already rotated?)"
fi

cat <<EOF

------------------------------------------------------------------------------
Next steps:
  # Watch the apps converge
  kubectl -n ${ARGOCD_NAMESPACE} get applications
  kubectl -n ${APP_NS} get pods -w

  # Access the UI (port-forward)
  kubectl -n ${ARGOCD_NAMESPACE} port-forward svc/argocd-server 8080:443
  # then open https://localhost:8080  (user: admin)

To re-seed Vault with different FLOW/SCOPE_PROFILE values (no commit needed):
  shared/scripts/seed-vault.sh --namespace ${APP_NS} \\
    --repo-url ${REPO_URL:-<repo>} --revision ${REVISION:-<ref>} \\
    --flow unmanaged --scope-profile egi-dev

If apps show 'ComparisonError' on repoURL/HEAD, the child Applications
under deploy/gitops/argocd/applicationsets/ point at a repo/branch Argo
can't read yet. Either merge this branch to the tracked default branch, or
edit each child Application's repoURL/targetRevision to your fork/branch.
------------------------------------------------------------------------------
EOF

log "Done."
