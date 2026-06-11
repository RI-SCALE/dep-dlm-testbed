#!/usr/bin/env bash
# ============================================================================
# init-argocd.sh — install Argo CD and bootstrap the DEP DLM sandbox
# ============================================================================
# Installs Argo CD into the target cluster, waits for it to be ready, then
# applies the sandbox app-of-apps-sandbox.yaml which fans out into the per-component
# Applications under deploy/gitops/argocd/applications/.
#
# Idempotent: safe to re-run. Honours an existing Argo CD install.
#
# Usage:
#   shared/scripts/init-argocd.sh [--repo-url URL] [--revision REF] [--no-wait]
#
# Env overrides:
#   ARGOCD_NAMESPACE   (default: argocd)
#   ARGOCD_VERSION     (default: stable)         e.g. v2.12.4
#   APP_NS             (default: dep-dlm-sandbox) workload namespace
#   REPO_URL           git repo Argo pulls from  (default: from app-of-apps-sandbox.yaml)
#   REVISION           git ref Argo tracks       (default: current branch)
#   GITOPS_ENV         gitops overlay to apply    (default: sandbox)
#
# Examples:
#   # Test from your feature branch + fork
#   shared/scripts/init-argocd.sh \
#     --env sandbox \
#     --repo-url https://github.com/ri-scale/dep-dlm-testbed.git \
#     --revision feat/gitops-deployment-blueprint
set -euo pipefail

# --- Resolve paths ----------------------------------------------------------
# This script lives at shared/scripts/, i.e. two levels below the repo root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GITOPS_DIR="${REPO_ROOT}/deploy/gitops"
GITOPS_ENV="${GITOPS_ENV:-sandbox}"
APP_OF_APPS="${GITOPS_DIR}/argocd/app-of-apps-${GITOPS_ENV}.yaml"

# --- Config / defaults ------------------------------------------------------
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"
APP_NS="${APP_NS:-dep-dlm-${GITOPS_ENV}}"
REPO_URL="${REPO_URL:-}"
REVISION="${REVISION:-}"
WAIT=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-url) REPO_URL="$2"; shift 2 ;;
    --revision) REVISION="$2"; shift 2 ;;
    --env) GITOPS_ENV="$2"; shift 2 ;;
    --no-wait)  WAIT=0; shift ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Preflight --------------------------------------------------------------
command -v kubectl >/dev/null || die "kubectl not found in PATH"
kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach a cluster (check your context)"
[[ -f "$APP_OF_APPS" ]] || die "app-of-apps-${GITOPS_ENV}.yaml not found at $APP_OF_APPS"

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
  for d in argocd-repo-server argocd-server argocd-application-controller; do
    # application-controller is a StatefulSet on newer installs; try both.
    if kubectl -n "$ARGOCD_NAMESPACE" get deploy "$d" >/dev/null 2>&1; then
      kubectl -n "$ARGOCD_NAMESPACE" rollout status deploy/"$d" --timeout=300s || \
        warn "$d not ready within timeout"
    elif kubectl -n "$ARGOCD_NAMESPACE" get statefulset "$d" >/dev/null 2>&1; then
      kubectl -n "$ARGOCD_NAMESPACE" rollout status statefulset/"$d" --timeout=300s || \
        warn "$d not ready within timeout"
    fi
  done
fi

# --- 3. Patch app-of-apps-$(GITOPS_ENV).yaml repo/revision if overrides given ------------------
APPLY_FILE="$APP_OF_APPS"
if [[ -n "$REPO_URL" || -n "$REVISION" ]]; then
  TMP="$(mktemp)"
  cp "$APP_OF_APPS" "$TMP"
  if [[ -n "$REPO_URL" ]]; then
    sed -i "s#repoURL:.*#repoURL: ${REPO_URL}#" "$TMP"
    log "Overriding repoURL -> ${REPO_URL}"
  fi
  if [[ -n "$REVISION" ]]; then
    sed -i "s#targetRevision:.*#targetRevision: ${REVISION}#" "$TMP"
    log "Overriding targetRevision -> ${REVISION}"
  fi
  APPLY_FILE="$TMP"
  warn "Applied repo/revision overrides only to the app-of-apps-${GITOPS_ENV}.yaml root."
  warn "The child Applications under argocd/applications/ still carry their"
  warn "own repoURL/targetRevision — edit those for the bundled charts, or"
  warn "merge to your default branch so HEAD resolves."
fi

# --- 4. Apply the app-of-apps-$(GITOPS_ENV).yaml -----------------------------------------------
log "Applying ${GITOPS_ENV} app-of-apps-${GITOPS_ENV}.yaml"
kubectl apply -n "$ARGOCD_NAMESPACE" -f "$APPLY_FILE"
[[ "$APPLY_FILE" != "$APP_OF_APPS" ]] && rm -f "$APPLY_FILE"

# --- 5. Report --------------------------------------------------------------
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

If apps show 'ComparisonError' on repoURL/HEAD, the child Applications
under deploy/gitops/argocd/applications/ point at a repo/branch Argo can't
read yet. Either merge this branch to the tracked default branch, or edit
each child Application's repoURL/targetRevision to your fork/branch.
------------------------------------------------------------------------------
EOF

log "Done."
