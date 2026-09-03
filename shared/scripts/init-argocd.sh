#!/usr/bin/env bash
set -euo pipefail

# ── Global Config ───────────────────────────────────────────────────────────
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
CORE_WAIT_TIMEOUT="${CORE_WAIT_TIMEOUT:-600s}"
WAIT=1
SEED=1

OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-}"
OIDC_CLIENT_SECRET="${OIDC_CLIENT_SECRET:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-url)       REPO_URL="$2"; shift 2 ;;
    --revision)       REVISION="$2"; shift 2 ;;
    --env)            GITOPS_ENV="$2"; shift 2 ;;
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

APP_OF_APPS="${GITOPS_DIR}/argocd/entrypoints/app-of-apps-${GITOPS_ENV}.yaml"
ASET_NAME="dep-dlm-${GITOPS_ENV}"          # matches argocd/applicationsets/<env>.yaml metadata.name
# shellcheck disable=SC2034  # read by common.sh's provision_cluster_secret_store()
ESO_SA="external-secrets-${GITOPS_ENV}"
# shellcheck disable=SC2034  # read by common.sh's provision_cluster_secret_store()
ESO_SA_NAMESPACE="${APP_NS}"               # ESO's ServiceAccount lives in the apps-root namespace, not argocd/
# shellcheck disable=SC2034  # read by common.sh's bootstrap_rucio_db()
SECRETS_READY_HINT="kubectl -n ${ARGOCD_NAMESPACE} get application dep-dlm-${GITOPS_ENV}-secrets"

APPLY_FILE=""   # set by apply_apps_root, consumed + cleaned up by apply_secrets_root

# ── Logic Blocks ────────────────────────────────────────────────────────────

preflight() {
  require_cmd kubectl yq timeout
  require_cluster
  [[ -f "$APP_OF_APPS" ]] || die "app-of-apps-${GITOPS_ENV}.yaml not found at $APP_OF_APPS"
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

install_argocd() {
  if kubectl get ns "$ARGOCD_NAMESPACE" >/dev/null 2>&1 \
     && kubectl -n "$ARGOCD_NAMESPACE" get deploy argocd-server >/dev/null 2>&1; then
    log "Argo CD already present in namespace '$ARGOCD_NAMESPACE' — skipping install"
    return 0
  fi
  log "Installing Argo CD ($ARGOCD_VERSION) into namespace '$ARGOCD_NAMESPACE'"
  kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  # --server-side avoids kubectl's 256KB last-applied-configuration annotation,
  # which the large ApplicationSet CRD exceeds. --force-conflicts lets a re-run
  # (or a prior client-side apply) hand over field ownership cleanly.
  kubectl apply --server-side --force-conflicts -n "$ARGOCD_NAMESPACE" \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
}

wait_for_argocd_ready() {
  [[ "$WAIT" -eq 1 ]] || return 0
  log "Waiting for Argo CD components to become Available (up to 5m)"
  # application-controller is a StatefulSet on newer installs; try both.
  wait_for_workload "$ARGOCD_NAMESPACE" deploy      argocd-repo-server
  wait_for_workload "$ARGOCD_NAMESPACE" deploy      argocd-server
  wait_for_workload "$ARGOCD_NAMESPACE" deploy      argocd-application-controller
  wait_for_workload "$ARGOCD_NAMESPACE" statefulset argocd-application-controller
}

# Patches app-of-apps-<env>.yaml repo/revision (if overrides given) and
# applies just the apps-root Application out of it.
apply_apps_root() {
  APPLY_FILE="$(patch_git_ref "$APP_OF_APPS" repoURL targetRevision "$REPO_URL" "$REVISION")"
  if [[ "$APPLY_FILE" != "$APP_OF_APPS" ]]; then
    warn "Applied repo/revision overrides only to the app-of-apps-${GITOPS_ENV}.yaml root."
    warn "The child Applications under argocd/applicationsets/ still carry their"
    warn "own repoURL/targetRevision — edit those for the bundled charts, or"
    warn "merge to your default branch so HEAD resolves."
  fi

  log "Applying apps root (dep-dlm-${GITOPS_ENV}-apps)"
  kubectl apply -n "$ARGOCD_NAMESPACE" -f <(yq 'select(.metadata.name == "'"${ASET_NAME}"'-apps")' "$APPLY_FILE")
}

# Waits for the core tier (vault + external-secrets operator) to come up,
# via the Applications the ApplicationSet generates for them.
wait_for_core_tier() {
  [[ "$SEED" -eq 1 && "$GITOPS_ENV" == "sandbox" && "$WAIT" -eq 1 ]] || return 0

  log "Waiting for the ApplicationSet to generate vault-${GITOPS_ENV} / external-secrets-${GITOPS_ENV} (up to ${CORE_WAIT_TIMEOUT})"
  local app
  for app in "vault-${GITOPS_ENV}" "external-secrets-${GITOPS_ENV}"; do
    if ! timeout "$CORE_WAIT_TIMEOUT" bash -c \
      "until kubectl -n '${ARGOCD_NAMESPACE}' get application '${app}' >/dev/null 2>&1; do sleep 5; done"
    then
      warn "Application/${app} never appeared — check the ApplicationSet controller: 'kubectl -n ${ARGOCD_NAMESPACE} get applicationset ${ASET_NAME}'"
    fi
  done

  log "Waiting for vault-${GITOPS_ENV} and external-secrets-${GITOPS_ENV} to become Healthy (up to ${CORE_WAIT_TIMEOUT})"
  kubectl -n "$ARGOCD_NAMESPACE" wait --for=jsonpath='{.status.health.status}'=Healthy \
    "application/vault-${GITOPS_ENV}" "application/external-secrets-${GITOPS_ENV}" \
    --timeout="$CORE_WAIT_TIMEOUT" \
    || warn "core tier not Healthy within ${CORE_WAIT_TIMEOUT} — seeding will likely fail; check 'kubectl -n ${ARGOCD_NAMESPACE} get application vault-${GITOPS_ENV} external-secrets-${GITOPS_ENV}'"
}

# Applies the secrets root — Vault + ESO now exist, so ExternalSecrets CAN
# resolve once seeded. Also cleans up the tempfile from apply_apps_root.
apply_secrets_root() {
  log "Applying secrets root (dep-dlm-${GITOPS_ENV}-secrets)"
  kubectl apply -n "$ARGOCD_NAMESPACE" -f <(yq 'select(.metadata.name == "'"${ASET_NAME}"'-secrets")' "$APPLY_FILE")
}

# Applies the gateway root — rucio-server/fts Services must already exist
# for HealthCheckPolicy/HTTPRoute to resolve meaningfully, so this runs
# after bootstrap_rucio_db, not alongside apply_apps_root/apply_secrets_root.
apply_gateway_root() {
  if [[ "$GITOPS_ENV" == "sandbox" ]]; then
    log "No gateway root for sandbox — skipping (staging/production only)"
    return 0
  fi
  log "Applying gateway root (dep-dlm-${GITOPS_ENV}-gateway)"
  kubectl apply -n "$ARGOCD_NAMESPACE" -f <(yq 'select(.metadata.name == "'"${ASET_NAME}"'-gateway")' "$APPLY_FILE")
  [[ "$APPLY_FILE" != "$APP_OF_APPS" ]] && rm -f "$APPLY_FILE"
}

report() {
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
}

# ── Main Entry Point ────────────────────────────────────────────────────────

main() {
  preflight
  install_argocd
  wait_for_argocd_ready
  apply_apps_root
  provision_cluster_secret_store   # from common.sh
  wait_for_core_tier
  apply_secrets_root
  render_testbed_configmaps        # from common.sh
  seed_vault                       # from common.sh
  bootstrap_rucio_db               # from common.sh
  apply_gateway_root
  report
}

main
