#!/usr/bin/env bash
set -euo pipefail

# ── Global Config ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GITOPS_DIR="${REPO_ROOT}/deploy/gitops"

# shellcheck source=common.sh disable=SC1091
source "${SCRIPT_DIR}/common.sh"

GITOPS_ENV="${GITOPS_ENV:-sandbox}"
FLUX_NAMESPACE="${FLUX_NAMESPACE:-flux-system}"
REPO_URL="${REPO_URL:-}"
REVISION="${REVISION:-}"
FLOW="${FLOW:-managed}"
SCOPE_PROFILE="${SCOPE_PROFILE:-local}"
CORE_WAIT_TIMEOUT="${CORE_WAIT_TIMEOUT:-600s}"
WAIT=1
SEED=1

OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-}"
OIDC_CLIENT_SECRET="${OIDC_CLIENT_SECRET:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)            GITOPS_ENV="$2"; shift 2 ;;
    --repo-url)       REPO_URL="$2"; shift 2 ;;
    --revision)       REVISION="$2"; shift 2 ;;
    --flow)           FLOW="$2"; shift 2 ;;
    --scope-profile)  SCOPE_PROFILE="$2"; shift 2 ;;
    --timeout)        CORE_WAIT_TIMEOUT="$2"; shift 2 ;;
    --no-wait)        WAIT=0; shift ;;
    --no-seed)        SEED=0; shift ;;
    --oidc-client-id)      OIDC_CLIENT_ID="$2"; shift 2 ;;
    --oidc-client-secret)  OIDC_CLIENT_SECRET="$2"; shift 2 ;;
    -h|--help)        grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

GITREPO="${GITOPS_DIR}/flux/flux-system/gitrepository.yaml"
ENTRYPOINT="${GITOPS_DIR}/flux/entrypoints/${GITOPS_ENV}.yaml"
APP_NS="${APP_NS:-dep-dlm-${GITOPS_ENV}}"
CORE_KS="dep-dlm-${GITOPS_ENV}-core"       # confirmed correct by CI
COMPONENTS_KS="dep-dlm-${GITOPS_ENV}"
# shellcheck disable=SC2034  # read by common.sh's provision_cluster_secret_store()
ESO_SA="external-secrets"
# shellcheck disable=SC2034  # read by common.sh's provision_cluster_secret_store()
ESO_SA_NAMESPACE="external-secrets"
# shellcheck disable=SC2034  # read by common.sh's bootstrap_rucio_db()
SECRETS_READY_HINT="flux get kustomization dep-dlm-${GITOPS_ENV}-secrets"

APPLY_GITREPO=""   # set by apply_gitrepository

# ── Logic Blocks ────────────────────────────────────────────────────────────

preflight() {
  require_cmd kubectl
  require_cluster
  [[ -f "$ENTRYPOINT" ]] || die "entrypoint not found: $ENTRYPOINT"
  [[ -f "$GITREPO" ]]    || die "gitrepository not found: $GITREPO"
  if [[ "$SEED" -eq 1 && "$GITOPS_ENV" == "sandbox" ]]; then
    require_cmd envsubst
  fi
  if command -v helm >/dev/null 2>&1; then
    if [[ ! -d "${HELM_PLUGINS:-$HOME/.local/share/helm/plugins}/helm-git" ]]; then
      log "Installing helm-git plugin (needed for git+https chart dependencies)"
      helm plugin install https://github.com/aslafy-z/helm-git \
        || die "helm-git plugin install failed — required for the rucio-server/rucio-daemons fork dependency in Chart.yaml"
    fi
    # helm dependency build (unlike dependency update) checks registered repos
    # rather than resolving git+https URLs live, so these must exist as named
    # repos even though Chart.yaml references them by URL, not by name.
    if ! helm repo list 2>/dev/null | grep -q '^rucio-server-fork'; then
      log "Registering rucio-server-fork repo (git+https, for helm dependency build)"
      helm repo add rucio-server-fork "git+https://github.com/mgajek-cern/helm-charts.git@charts/rucio-server?ref=master" \
        || die "failed to register rucio-server-fork helm repo"
    fi
    if ! helm repo list 2>/dev/null | grep -q '^rucio-daemons-fork'; then
      log "Registering rucio-daemons-fork repo (git+https, for helm dependency build)"
      helm repo add rucio-daemons-fork "git+https://github.com/mgajek-cern/helm-charts.git@charts/rucio-daemons?ref=master" \
        || die "failed to register rucio-daemons-fork helm repo"
    fi
  fi
  log "Target cluster:"
  kubectl config current-context || true
}

install_flux() {
  if kubectl get ns "$FLUX_NAMESPACE" >/dev/null 2>&1 \
     && kubectl -n "$FLUX_NAMESPACE" get deploy source-controller >/dev/null 2>&1; then
    log "Flux already present in '$FLUX_NAMESPACE' — skipping install"
    return 0
  fi

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
    kubectl apply --server-side --force-conflicts \
      -f "https://github.com/fluxcd/flux2/releases/latest/download/install.yaml"
  fi
}

wait_for_flux_ready() {
  [[ "$WAIT" -eq 1 ]] || return 0
  log "Waiting for Flux controllers to become Available (up to 5m)"
  wait_for_workload "$FLUX_NAMESPACE" deploy source-controller
  wait_for_workload "$FLUX_NAMESPACE" deploy kustomize-controller
  wait_for_workload "$FLUX_NAMESPACE" deploy helm-controller
}

# Applies the GitRepository source (with optional URL/revision overrides).
apply_gitrepository() {
  APPLY_GITREPO="$(patch_git_ref "$GITREPO" url branch "$REPO_URL" "$REVISION")"
  log "Applying GitRepository source"
  kubectl apply -f "$APPLY_GITREPO"
  [[ "$APPLY_GITREPO" != "$GITREPO" ]] && rm -f "$APPLY_GITREPO"
}

# Applies the FULL entrypoint in one shot (eso + core + secrets + components)
# and lets Flux's own dependsOn/wait graph handle ordering from there.
apply_entrypoint() {
  log "Applying ${GITOPS_ENV} entrypoint (eso + core + secrets + components)"
  kubectl apply -f "$ENTRYPOINT"
}

# Waits for the core Kustomization — the real gate for seeding.
wait_for_core_kustomization() {
  [[ "$SEED" -eq 1 && "$GITOPS_ENV" == "sandbox" && "$WAIT" -eq 1 ]] || return 0

  log "Waiting for Kustomization/${CORE_KS} to be Ready (up to ${CORE_WAIT_TIMEOUT})"
  kubectl -n "$FLUX_NAMESPACE" wait --for=condition=Ready "kustomization/${CORE_KS}" --timeout="$CORE_WAIT_TIMEOUT" \
    || die "${CORE_KS} not Ready within ${CORE_WAIT_TIMEOUT} — check 'flux get kustomization ${CORE_KS}' and 'flux get kustomization dep-dlm-${GITOPS_ENV}-eso'. Re-run with --timeout to allow more time, or re-run this script once Flux catches up (it's idempotent) — Flux keeps reconciling in the background even after this wait gives up."
}

report() {
  cat <<EOF

------------------------------------------------------------------------------
Next steps:
  # Watch Flux reconcile
  flux get kustomizations --watch        # (or) kubectl -n ${FLUX_NAMESPACE} get kustomizations
  flux get helmreleases -A
  kubectl -n ${APP_NS} get pods -w

  # Force a reconcile after pushing changes
  flux reconcile kustomization ${COMPONENTS_KS} --with-source

To re-seed Vault with different FLOW/SCOPE_PROFILE values (no commit needed):
  shared/scripts/seed-vault.sh --namespace ${APP_NS} \\
    --repo-url ${REPO_URL:-<repo>} --revision ${REVISION:-<ref>} \\
    --flow unmanaged --scope-profile egi-dev
------------------------------------------------------------------------------
EOF
  log "Done."
}

# ── Main Entry Point ────────────────────────────────────────────────────────

main() {
  preflight
  install_flux
  wait_for_flux_ready
  apply_gitrepository
  apply_entrypoint
  provision_cluster_secret_store   # from common.sh
  wait_for_core_kustomization
  render_testbed_configmaps        # from common.sh
  seed_vault                       # from common.sh
  bootstrap_rucio_db               # from common.sh
  report
}

main
