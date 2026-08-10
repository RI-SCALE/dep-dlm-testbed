#!/usr/bin/env bash
set -euo pipefail

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
    -h|--help)        grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

GITREPO="${GITOPS_DIR}/flux/flux-system/gitrepository.yaml"
ENTRYPOINT="${GITOPS_DIR}/flux/entrypoints/${GITOPS_ENV}.yaml"
APP_NS="${APP_NS:-dep-dlm-${GITOPS_ENV}}"
CORE_KS="dep-dlm-${GITOPS_ENV}-core"       # confirmed correct by CI
COMPONENTS_KS="dep-dlm-${GITOPS_ENV}"

require_cmd kubectl
require_cluster
[[ -f "$ENTRYPOINT" ]] || die "entrypoint not found: $ENTRYPOINT"
[[ -f "$GITREPO" ]]    || die "gitrepository not found: $GITREPO"
if [[ "$SEED" -eq 1 && "$GITOPS_ENV" == "sandbox" ]]; then
  require_cmd envsubst
fi

log "Target cluster:"; kubectl config current-context || true

# --- 1. Install Flux --------------------------------------------------------
if kubectl get ns "$FLUX_NAMESPACE" >/dev/null 2>&1 \
   && kubectl -n "$FLUX_NAMESPACE" get deploy source-controller >/dev/null 2>&1; then
  log "Flux already present in '$FLUX_NAMESPACE' — skipping install"
else
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
fi

# --- 2. Wait for Flux controllers -------------------------------------------
if [[ "$WAIT" -eq 1 ]]; then
  log "Waiting for Flux controllers to become Available (up to 5m)"
  wait_for_workload "$FLUX_NAMESPACE" deploy source-controller
  wait_for_workload "$FLUX_NAMESPACE" deploy kustomize-controller
  wait_for_workload "$FLUX_NAMESPACE" deploy helm-controller
fi

# --- 3. Apply GitRepository (with optional URL/revision overrides) ---------
APPLY_GITREPO="$(patch_git_ref "$GITREPO" url branch "$REPO_URL" "$REVISION")"
log "Applying GitRepository source"
kubectl apply -f "$APPLY_GITREPO"
[[ "$APPLY_GITREPO" != "$GITREPO" ]] && rm -f "$APPLY_GITREPO"

# --- 3b. Render + apply the environment's ClusterSecretStore, if templated.
# Sandbox's store is a plain, static file (no .tmpl) — nothing to do here
# for it. staging/production's stores need projectID/region/cluster name,
# which are dynamic (bootstrap-generated), so they're rendered via envsubst
# and applied directly here rather than through Flux's own reconciliation.
# Flux applies the full entrypoint in one shot (step 4) and lets its own
# dependsOn/wait graph handle ordering from there — but nothing in that
# graph can render a templated manifest, so the store needs to already
# exist in the cluster before that apply, not be part of it. Same pattern
# as seed-vault.sh's own templated manifest: idempotent, safe to re-run.
STORE_TMPL="${GITOPS_DIR}/environments/${GITOPS_ENV}/secrets/clustersecretstore.yaml.tmpl"
RENDERED_STORE=""
if [[ -f "$STORE_TMPL" ]]; then
  require_cmd envsubst
  log "Rendering + applying ClusterSecretStore for ${GITOPS_ENV}"
  TF_ENV_DIR="${REPO_ROOT}/deploy/terraform/environments/${GITOPS_ENV}"
  GCP_PROJECT_ID="$(terraform -chdir="$TF_ENV_DIR" output -raw project_id)"
  GCP_REGION="$(terraform -chdir="$TF_ENV_DIR" output -raw region)"
  GCP_CLUSTER_NAME="$(terraform -chdir="$TF_ENV_DIR" output -raw cluster_name)"
  RENDERED_STORE="${GITOPS_DIR}/environments/${GITOPS_ENV}/secrets/clustersecretstore.yaml"
  # shellcheck disable=SC2016
  GCP_PROJECT_ID="$GCP_PROJECT_ID" GCP_REGION="$GCP_REGION" GCP_CLUSTER_NAME="$GCP_CLUSTER_NAME" GITOPS_ENV="$GITOPS_ENV" \
    envsubst '${GCP_PROJECT_ID} ${GCP_REGION} ${GCP_CLUSTER_NAME} ${GITOPS_ENV}' < "$STORE_TMPL" > "$RENDERED_STORE"
fi

# --- 4. Apply the FULL entrypoint in one shot
log "Applying ${GITOPS_ENV} entrypoint (eso + core + secrets + components)"
kubectl apply -f "$ENTRYPOINT"

# --- 4b. APPLY the rendered ClusterSecretStore, gated on the ESO CRD
# actually existing.
if [[ -n "$RENDERED_STORE" ]]; then
  log "Waiting for the ClusterSecretStore CRD to be registered (up to ${CORE_WAIT_TIMEOUT})"
  if ! timeout "$CORE_WAIT_TIMEOUT" bash -c \
    "until kubectl get crd clustersecretstores.external-secrets.io >/dev/null 2>&1; do sleep 5; done"
  then
    die "clustersecretstores.external-secrets.io CRD never appeared within ${CORE_WAIT_TIMEOUT} — check the external-secrets Application/HelmRelease: 'kubectl -n ${ARGOCD_NAMESPACE} get application external-secrets-${GITOPS_ENV}'. Rendered manifest left at ${RENDERED_STORE} for inspection."
  fi
  log "Applying ClusterSecretStore for ${GITOPS_ENV}"
  kubectl apply -n "$APP_NS" -f "$RENDERED_STORE"
fi

# --- 4c. Annotate the environment's external-secrets ServiceAccount
if [[ -n "$RENDERED_STORE" ]]; then
  ESO_SA="external-secrets-${GITOPS_ENV}"
  log "Waiting for ServiceAccount/${ESO_SA} to exist in ${APP_NS} (up to ${CORE_WAIT_TIMEOUT})"
  if ! timeout "$CORE_WAIT_TIMEOUT" bash -c \
    "until kubectl -n '${APP_NS}' get serviceaccount '${ESO_SA}' >/dev/null 2>&1; do sleep 5; done"
  then
    die "ServiceAccount/${ESO_SA} never appeared in ${APP_NS} within ${CORE_WAIT_TIMEOUT}"
  fi
  ESO_GCP_SA_EMAIL="$(terraform -chdir="$TF_ENV_DIR" output -raw eso_service_account_email)"
  log "Annotating ServiceAccount/${ESO_SA} for Workload Identity (${ESO_GCP_SA_EMAIL})"
  kubectl -n "$APP_NS" annotate serviceaccount "$ESO_SA" \
    iam.gke.io/gcp-service-account="$ESO_GCP_SA_EMAIL" --overwrite
fi

# --- 5. Wait for the core Kustomization — the real gate for seeding
if [[ "$SEED" -eq 1 && "$GITOPS_ENV" == "sandbox" && "$WAIT" -eq 1 ]]; then
  log "Waiting for Kustomization/${CORE_KS} to be Ready (up to ${CORE_WAIT_TIMEOUT})"
  kubectl -n "$FLUX_NAMESPACE" wait --for=condition=Ready "kustomization/${CORE_KS}" --timeout="$CORE_WAIT_TIMEOUT" \
    || die "${CORE_KS} not Ready within ${CORE_WAIT_TIMEOUT} — check 'flux get kustomization ${CORE_KS}' and 'flux get kustomization dep-dlm-${GITOPS_ENV}-eso'. Re-run with --timeout to allow more time, or re-run this script once Flux catches up (it's idempotent) — Flux keeps reconciling in the background even after this wait gives up."
fi

# --- 6. Seed Vault (sandbox only) — Vault is reachable (step 5).
if [[ "$SEED" -eq 1 && "$GITOPS_ENV" == "sandbox" ]]; then
  "${SCRIPT_DIR}/seed-vault.sh" \
    --namespace "$APP_NS" \
    --repo-url "${REPO_URL:-https://github.com/ri-scale/dep-dlm-testbed.git}" \
    --revision "${REVISION:-main}" \
    --flow "$FLOW" \
    --scope-profile "$SCOPE_PROFILE" \
    --vault-timeout "$CORE_WAIT_TIMEOUT"
elif [[ "$SEED" -eq 0 ]]; then
  log "Skipping Vault seeding (--no-seed)"
fi

# --- 7. Bootstrap the rucio DB schema (sandbox only) ------------------------
if [[ "$SEED" -eq 1 && "$GITOPS_ENV" == "sandbox" ]]; then
  "${SCRIPT_DIR}/run-bootstrap-db.sh" --namespace "$APP_NS"
fi

# --- 8. Report --------------------------------------------------------------
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
