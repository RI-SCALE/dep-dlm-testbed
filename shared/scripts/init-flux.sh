#!/usr/bin/env bash
# ============================================================================
# init-flux.sh — install Flux and bootstrap the DEP DLM stack (env-aware)
# ============================================================================
# Installs the Flux controllers, then applies the GitRepository source and the
# chosen environment's entrypoint (flux/entrypoints/<env>.yaml), which defines
# the secrets + components Flux Kustomizations.
#
# Idempotent: safe to re-run. Honours an existing Flux install.
#
# Usage:
#   shared/scripts/init-flux.sh [--env sandbox|staging|production]
#                               [--repo-url URL] [--revision REF] [--no-wait]
#
# Env overrides:
#   FLUX_NAMESPACE   (default: flux-system)
#   GITOPS_ENV       (default: sandbox)
#   REPO_URL         git repo Flux pulls from (default: from gitrepository.yaml)
#   REVISION         git branch Flux tracks   (default: from gitrepository.yaml)
#
# Examples:
#   shared/scripts/init-flux.sh --env sandbox \
#     --repo-url https://github.com/ri-scale/dep-dlm-testbed.git \
#     --revision feat/gitops-deployment-blueprint
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GITOPS_DIR="${REPO_ROOT}/deploy/gitops"
GITOPS_ENV="${GITOPS_ENV:-sandbox}"
FLUX_NAMESPACE="${FLUX_NAMESPACE:-flux-system}"
REPO_URL="${REPO_URL:-}"
REVISION="${REVISION:-}"
WAIT=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)      GITOPS_ENV="$2"; shift 2 ;;
    --repo-url) REPO_URL="$2"; shift 2 ;;
    --revision) REVISION="$2"; shift 2 ;;
    --no-wait)  WAIT=0; shift ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

GITREPO="${GITOPS_DIR}/flux/flux-system/gitrepository.yaml"
ENTRYPOINT="${GITOPS_DIR}/flux/entrypoints/${GITOPS_ENV}.yaml"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null || die "kubectl not found in PATH"
kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach a cluster"
[[ -f "$ENTRYPOINT" ]] || die "entrypoint not found: $ENTRYPOINT"
[[ -f "$GITREPO" ]]    || die "gitrepository not found: $GITREPO"

log "Target cluster:"; kubectl config current-context || true

# --- 1. Install Flux --------------------------------------------------------
# Prefer the flux CLI if present (handles CRDs + controllers cleanly); else
# fall back to the published install manifest.
if kubectl get ns "$FLUX_NAMESPACE" >/dev/null 2>&1 \
   && kubectl -n "$FLUX_NAMESPACE" get deploy source-controller >/dev/null 2>&1; then
  log "Flux already present in '$FLUX_NAMESPACE' — skipping install"
else
  # Prefer the flux CLI. If it's missing, install it (official script), then
  # `flux install`. Fall back to the published manifest only if the CLI install
  # fails (e.g. no network to github releases).
  if ! command -v flux >/dev/null 2>&1; then
    log "flux CLI not found — installing it (fluxcd.io/install.sh)"
    if curl -s https://fluxcd.io/install.sh | bash >/dev/null 2>&1; then
      export PATH="$PATH:/usr/local/bin"
      log "flux CLI installed: $(flux --version 2>/dev/null || echo unknown)"
    else
      warn "flux CLI install failed — falling back to the published manifest"
    fi
  fi
  if command -v flux >/dev/null 2>&1; then
    log "Installing Flux via flux CLI"
    flux install --namespace="$FLUX_NAMESPACE"
  else
    log "Installing Flux from the published manifest"
    # --server-side avoids the 256KB last-applied annotation on large CRDs.
    kubectl apply --server-side --force-conflicts \
      -f "https://github.com/fluxcd/flux2/releases/latest/download/install.yaml"
  fi
fi

# --- 2. Wait for Flux controllers -------------------------------------------
if [[ "$WAIT" -eq 1 ]]; then
  log "Waiting for Flux controllers to become Available (up to 5m)"
  for d in source-controller kustomize-controller helm-controller; do
    kubectl -n "$FLUX_NAMESPACE" rollout status deploy/"$d" --timeout=300s \
      || warn "$d not ready within timeout"
  done
fi

# --- 3. Apply GitRepository (with optional URL/revision overrides) ----------
APPLY_GITREPO="$GITREPO"
if [[ -n "$REPO_URL" || -n "$REVISION" ]]; then
  TMP="$(mktemp)"; cp "$GITREPO" "$TMP"
  [[ -n "$REPO_URL" ]] && { sed -i "s#url:.*#url: ${REPO_URL}#" "$TMP"; log "Override url -> ${REPO_URL}"; }
  [[ -n "$REVISION" ]] && { sed -i "s#branch:.*#branch: ${REVISION}#" "$TMP"; log "Override branch -> ${REVISION}"; }
  APPLY_GITREPO="$TMP"
fi
log "Applying GitRepository source"
kubectl apply -f "$APPLY_GITREPO"
[[ "$APPLY_GITREPO" != "$GITREPO" ]] && rm -f "$APPLY_GITREPO"

# --- 4. Apply the environment entrypoint ------------------------------------
log "Applying ${GITOPS_ENV} entrypoint (secrets + components Kustomizations)"
kubectl apply -f "$ENTRYPOINT"

# --- 5. Report --------------------------------------------------------------
cat <<EOF

------------------------------------------------------------------------------
Next steps:
  # Watch Flux reconcile
  flux get kustomizations --watch        # (or) kubectl -n ${FLUX_NAMESPACE} get kustomizations
  flux get helmreleases -A
  kubectl -n dep-dlm-${GITOPS_ENV} get pods -w

  # Force a reconcile after pushing changes
  flux reconcile kustomization dep-dlm-${GITOPS_ENV} --with-source
------------------------------------------------------------------------------
EOF
log "Done."
