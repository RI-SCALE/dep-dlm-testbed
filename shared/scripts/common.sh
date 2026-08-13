#!/usr/bin/env bash
log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# require_cmd <name> [<name> ...] — die if any is missing from PATH.
require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "$c not found in PATH"
  done
}

# require_cluster — die if kubectl can't reach the current context.
require_cluster() {
  kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach a cluster (check your context)"
}

# patch_git_ref <src_file> <url_field> <rev_field> <REPO_URL> <REVISION>
# Copies src_file to a tempfile with url_field/rev_field patched via sed,
# ONLY if REPO_URL or REVISION is non-empty. Echoes the path to apply
# (either the tempfile, or src_file unchanged if no override was given).
# Caller is responsible for `rm -f` on the result if it differs from
# src_file — see apply_apps_root() in init-argocd.sh / apply_gitrepository()
# in init-flux.sh.
#
#   url_field/rev_field are the literal YAML keys to patch, e.g.:
#     Argo app-of-apps:   patch_git_ref "$f" "repoURL"   "targetRevision" ...
#     Flux GitRepository: patch_git_ref "$f" "url"       "branch"        ...
patch_git_ref() {
  local src="$1" url_field="$2" rev_field="$3" repo_url="$4" revision="$5"
  if [[ -z "$repo_url" && -z "$revision" ]]; then
    echo "$src"
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  cp "$src" "$tmp"
  [[ -n "$repo_url" ]] && { sed -i "s#${url_field}:.*#${url_field}: ${repo_url}#" "$tmp"; log "Overriding ${url_field} -> ${repo_url}"; } >&2
  [[ -n "$revision" ]] && { sed -i "s#${rev_field}:.*#${rev_field}: ${revision}#" "$tmp"; log "Overriding ${rev_field} -> ${revision}"; } >&2
  echo "$tmp"
}

# wait_for_workload <namespace> <deploy|statefulset> <name> [timeout]
# Tries deploy first if kind is ambiguous; used for the Argo-CD/Flux
# controller readiness loops.
wait_for_workload() {
  local ns="$1" kind="$2" name="$3" timeout="${4:-300s}"
  if kubectl -n "$ns" get "$kind" "$name" >/dev/null 2>&1; then
    kubectl -n "$ns" rollout status "${kind}/${name}" --timeout="$timeout" \
      || warn "$name not ready within $timeout"
  fi
}

# provision_cluster_secret_store — render (if templated), apply, and wire up
# the environment's ClusterSecretStore. Was duplicated near-verbatim between
# init-argocd.sh and init-flux.sh (their step 3b/4b/4c blocks).
#
# Sandbox's store is a plain, static file (no .tmpl) — this is a no-op for
# it. staging/production's stores need projectID/region/cluster name, which
# are dynamic (bootstrap-generated), so they're rendered via envsubst here
# rather than through Argo/Flux's own reconciliation — neither tool has a
# render step, so a .tmpl file committed as-is would get applied with
# literal, unexpanded ${VAR} text.
#
# Requires these globals already set by the caller:
#   GITOPS_DIR GITOPS_ENV ESO_SA ESO_SA_NAMESPACE APP_NS CORE_WAIT_TIMEOUT REPO_ROOT
# Sets these globals for later use (e.g. by bootstrap_rucio_db):
#   RENDERED_STORE  — path to the rendered store, or "" if nothing to render
#   TF_ENV_DIR      — only set when RENDERED_STORE is non-empty
provision_cluster_secret_store() {
  local store_tmpl="${GITOPS_DIR}/environments/${GITOPS_ENV}/secrets/clustersecretstore.yaml.tmpl"
  RENDERED_STORE=""
  [[ -f "$store_tmpl" ]] || return 0

  require_cmd envsubst
  log "Rendering ClusterSecretStore for ${GITOPS_ENV}"
  TF_ENV_DIR="${REPO_ROOT}/deploy/terraform/environments/${GITOPS_ENV}"
  local gcp_project_id gcp_region gcp_cluster_name
  gcp_project_id="$(terraform -chdir="$TF_ENV_DIR" output -raw project_id)"
  gcp_region="$(terraform -chdir="$TF_ENV_DIR" output -raw region)"
  gcp_cluster_name="$(terraform -chdir="$TF_ENV_DIR" output -raw cluster_name)"
  RENDERED_STORE="${GITOPS_DIR}/environments/${GITOPS_ENV}/secrets/clustersecretstore.yaml"
  # shellcheck disable=SC2016
  GCP_PROJECT_ID="$gcp_project_id" GCP_REGION="$gcp_region" GCP_CLUSTER_NAME="$gcp_cluster_name" GITOPS_ENV="$GITOPS_ENV" \
    ESO_SA_NAME="$ESO_SA" ESO_SA_NAMESPACE="$ESO_SA_NAMESPACE" \
    envsubst '${GCP_PROJECT_ID} ${GCP_REGION} ${GCP_CLUSTER_NAME} ${GITOPS_ENV} ${ESO_SA_NAME} ${ESO_SA_NAMESPACE}' < "$store_tmpl" > "$RENDERED_STORE"

  local eso_webhook_svc="${ESO_SA}-webhook"
  log "Waiting for ${eso_webhook_svc} webhook endpoints in ${ESO_SA_NAMESPACE} (up to ${CORE_WAIT_TIMEOUT})"
  if ! timeout "$CORE_WAIT_TIMEOUT" bash -c \
    "until kubectl -n '${ESO_SA_NAMESPACE}' get endpoints '${eso_webhook_svc}' -o jsonpath='{.subsets[*].addresses}' 2>/dev/null | grep -q .; do sleep 5; done"
  then
    warn "${eso_webhook_svc} has no ready endpoints within ${CORE_WAIT_TIMEOUT} — ClusterSecretStore apply will likely fail with a webhook error; check 'kubectl -n ${ESO_SA_NAMESPACE} get pods'"
  fi

  log "Applying ClusterSecretStore for ${GITOPS_ENV}"
  kubectl apply -n "$APP_NS" -f "$RENDERED_STORE"

  log "Waiting for ServiceAccount/${ESO_SA} to exist in ${ESO_SA_NAMESPACE} (up to ${CORE_WAIT_TIMEOUT})"
  if ! timeout "$CORE_WAIT_TIMEOUT" bash -c \
    "until kubectl -n '${ESO_SA_NAMESPACE}' get serviceaccount '${ESO_SA}' >/dev/null 2>&1; do sleep 5; done"
  then
    die "ServiceAccount/${ESO_SA} never appeared in ${ESO_SA_NAMESPACE} within ${CORE_WAIT_TIMEOUT}"
  fi
  local eso_gcp_sa_email
  eso_gcp_sa_email="$(terraform -chdir="$TF_ENV_DIR" output -raw eso_service_account_email)"
  log "Annotating ServiceAccount/${ESO_SA} for Workload Identity (${eso_gcp_sa_email})"
  kubectl -n "$ESO_SA_NAMESPACE" annotate serviceaccount "$ESO_SA" \
    iam.gke.io/gcp-service-account="$eso_gcp_sa_email" --overwrite
}

# seed_vault — invoke seed-vault.sh (sandbox only). No-op elsewhere.
# Requires globals: SEED GITOPS_ENV SCRIPT_DIR APP_NS REPO_URL REVISION FLOW
# SCOPE_PROFILE CORE_WAIT_TIMEOUT
seed_vault() {
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
}

# wait_for_job <namespace> <job_name> <timeout> [fail_msg]
# Waits for a Job to reach condition=complete. On timeout/failure, dumps its
# logs and dies with fail_msg (defaults to "<job_name> did not complete").
# Was duplicated near-verbatim in run-bootstrap-db.sh and seed-vault.sh.
wait_for_job() {
  local ns="$1" job="$2" timeout="$3"
  local fail_msg="${4:-${job} did not complete}"
  log "Waiting for ${job} to complete (up to ${timeout})"
  if ! kubectl -n "$ns" wait --for=condition=complete "job/${job}" --timeout="$timeout"; then
    warn "${job} did not complete in time — logs:"
    kubectl -n "$ns" logs "job/${job}" --all-containers --tail=100 || true
    die "$fail_msg"
  fi
}

# bootstrap_rucio_db — bootstrap the rucio DB schema. Sandbox runs it
# directly; other envs first wait for testbed-secrets's ExternalSecret to
# actually sync (the secret object existing isn't the same as ESO having
# finished projecting its content — sandbox gets an equivalent guarantee
# for free via run-bootstrap-db.sh's own Service-existence wait, which
# doesn't apply here), then pass an explicit --db-host.
#
# Requires globals: SEED GITOPS_ENV SCRIPT_DIR APP_NS CORE_WAIT_TIMEOUT
# TF_ENV_DIR (set by provision_cluster_secret_store for non-sandbox envs),
# and SECRETS_READY_HINT — a one-line command suggestion shown on warn,
# set per-caller since Argo and Flux surface secrets-root health differently.
bootstrap_rucio_db() {
  if [[ "$SEED" -eq 0 ]]; then
    log "Skipping rucio DB bootstrap (--no-seed)"
    return 0
  fi

  # Waits for testbed-secrets (rucio-cfg's server.cfg/alembic.ini/
  # idpsecrets.json, mounted via subPath — a missing key here is a hard
  # FailedMount, not a soft runtime failure). testbed-scripts (bootstrap-db.py)
  # used to need this same wait when it was ESO/Vault-backed, but it's a
  # plain git-committed ConfigMap now (shared/scripts/kustomization.yaml) —
  # created synchronously by the same Kustomize apply this function already
  # waited on via Kustomization/dep-dlm-<env>-core being Ready, no async
  # ESO sync to race against, so checking it as an ExternalSecret here would
  # hang forever (that object kind no longer exists for this name).
  local secret_names="testbed-secrets"
  for secret_name in $secret_names; do
    log "Waiting for ExternalSecret/${secret_name} to exist in ${APP_NS} (up to ${CORE_WAIT_TIMEOUT})"
    if ! timeout "$CORE_WAIT_TIMEOUT" bash -c \
      "until kubectl -n '${APP_NS}' get externalsecret ${secret_name} >/dev/null 2>&1; do sleep 5; done"
    then
      warn "ExternalSecret/${secret_name} never appeared in ${APP_NS} within ${CORE_WAIT_TIMEOUT} — bootstrap will likely fail; check '${SECRETS_READY_HINT}'"
      continue
    fi
    log "Waiting for ExternalSecret/${secret_name} to sync (up to ${CORE_WAIT_TIMEOUT})"
    kubectl -n "$APP_NS" wait --for=condition=Ready "externalsecret/${secret_name}" \
      --timeout="$CORE_WAIT_TIMEOUT" \
      || warn "${secret_name} not synced within ${CORE_WAIT_TIMEOUT} — bootstrap will likely fail; check 'kubectl -n ${APP_NS} describe externalsecret ${secret_name}'"
  done

  if [[ "$GITOPS_ENV" == "sandbox" ]]; then
    "${SCRIPT_DIR}/run-bootstrap-db.sh" --namespace "$APP_NS"
    return 0
  fi

  local rucio_db_host
  rucio_db_host="$(terraform -chdir="$TF_ENV_DIR" output -raw rucio_database_private_ip)"
  "${SCRIPT_DIR}/run-bootstrap-db.sh" --namespace "$APP_NS" \
    --db-host "$rucio_db_host" --skip-service-check --generate-scripts-secret
}
