#!/usr/bin/env bash
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
CORE_WAIT_TIMEOUT="${CORE_WAIT_TIMEOUT:-600s}"
WAIT=1
SEED=1

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
    -h|--help)        grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

APP_OF_APPS="${GITOPS_DIR}/argocd/entrypoints/app-of-apps-${GITOPS_ENV}.yaml"
ASET_NAME="dep-dlm-${GITOPS_ENV}"   # matches argocd/applicationsets/<env>.yaml metadata.name

# --- Preflight --------------------------------------------------------------
require_cmd kubectl yq timeout
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

# --- 3b. Render + apply the environment's ClusterSecretStore, if templated.
# Sandbox's store is a plain, static file (no .tmpl) — nothing to do here
# for it. staging/production's stores need projectID/region/cluster name,
# which are dynamic (bootstrap-generated), so they're rendered via envsubst
# and applied directly here rather than through ArgoCD's own reconciliation
# — ArgoCD syncs straight from git with no render step, so a .tmpl file
# committed as-is would get applied with literal, unexpanded ${VAR} text.
# Same pattern as seed-vault.sh's own templated manifest: idempotent,
# safe to re-run, not continuously reconciled.
STORE_TMPL="${GITOPS_DIR}/environments/${GITOPS_ENV}/secrets/clustersecretstore.yaml.tmpl"
RENDERED_STORE=""
if [[ -f "$STORE_TMPL" ]]; then
  require_cmd envsubst
  log "Rendering ClusterSecretStore for ${GITOPS_ENV}"
  TF_ENV_DIR="${REPO_ROOT}/deploy/terraform/environments/${GITOPS_ENV}"
  GCP_PROJECT_ID="$(terraform -chdir="$TF_ENV_DIR" output -raw project_id)"
  GCP_REGION="$(terraform -chdir="$TF_ENV_DIR" output -raw region)"
  GCP_CLUSTER_NAME="$(terraform -chdir="$TF_ENV_DIR" output -raw cluster_name)"
  RENDERED_STORE="${GITOPS_DIR}/environments/${GITOPS_ENV}/secrets/clustersecretstore.yaml"
  # shellcheck disable=SC2016
  GCP_PROJECT_ID="$GCP_PROJECT_ID" GCP_REGION="$GCP_REGION" GCP_CLUSTER_NAME="$GCP_CLUSTER_NAME" GITOPS_ENV="$GITOPS_ENV" \
    envsubst '${GCP_PROJECT_ID} ${GCP_REGION} ${GCP_CLUSTER_NAME} ${GITOPS_ENV}' < "$STORE_TMPL" > "$RENDERED_STORE"
fi

# --- 4. Apply the apps root (the ApplicationSet)
log "Applying apps root (dep-dlm-${GITOPS_ENV}-apps)"
kubectl apply -n "$ARGOCD_NAMESPACE" -f <(yq 'select(.metadata.name == "'"${ASET_NAME}"'-apps")' "$APPLY_FILE")

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

# --- 5. Wait for the core tier: vault + external-secrets operator
if [[ "$SEED" -eq 1 && "$GITOPS_ENV" == "sandbox" && "$WAIT" -eq 1 ]]; then
  log "Waiting for the ApplicationSet to generate vault-${GITOPS_ENV} / external-secrets-${GITOPS_ENV} (up to ${CORE_WAIT_TIMEOUT})"
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
fi

# --- 6. Apply the secrets root — Vault + ESO now exist, so ExternalSecrets
# CAN resolve once seeded
log "Applying secrets root (dep-dlm-${GITOPS_ENV}-secrets)"
kubectl apply -n "$ARGOCD_NAMESPACE" -f <(yq 'select(.metadata.name == "'"${ASET_NAME}"'-secrets")' "$APPLY_FILE")
[[ "$APPLY_FILE" != "$APP_OF_APPS" ]] && rm -f "$APPLY_FILE"

# --- 7. Seed Vault (sandbox only) — Vault is reachable (step 5)
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

# --- 8. Bootstrap the rucio DB schema (sandbox only) ------------------------
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
