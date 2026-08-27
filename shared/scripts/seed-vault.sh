#!/usr/bin/env bash
set -euo pipefail

# ── Global Config ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh disable=SC1091
source "${SCRIPT_DIR}/common.sh"

K8S_NAMESPACE="${K8S_NAMESPACE:-dep-dlm-sandbox}"
FLOW="${FLOW:-managed}"
SCOPE_PROFILE="${SCOPE_PROFILE:-local}"
REPO_URL="${REPO_URL:-}"
REVISION="${REVISION:-}"
# Only required when SCOPE_PROFILE != local — validate_args enforces this.
# Substituted straight into the rendered Job YAML by apply_seed_job's
# envsubst call, same trust level already accepted for these values in
# e2e.yml — this Job is applied imperatively, never committed.
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-}"
OIDC_CLIENT_SECRET="${OIDC_CLIENT_SECRET:-}"
VAULT_WAIT_TIMEOUT="${VAULT_WAIT_TIMEOUT:-600s}"
JOB_WAIT_TIMEOUT="${JOB_WAIT_TIMEOUT:-300s}"
# HashiCorp's vault Helm chart labels the server pod app.kubernetes.io/name=vault,
# component=server — NOT the bare "app=vault" this used to guess (which matched
# nothing, since the chart doesn't set that label at all). component=server also
# excludes vault-agent-injector, which shares app.kubernetes.io/name=vault.
VAULT_POD_LABEL="${VAULT_POD_LABEL:-app.kubernetes.io/name=vault,component=server}"
TMPL="${SCRIPT_DIR}/k8s/vault-seed-job.yaml.tmpl"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)          K8S_NAMESPACE="$2"; shift 2 ;;
    --repo-url)           REPO_URL="$2"; shift 2 ;;
    --revision)            REVISION="$2"; shift 2 ;;
    --flow)                FLOW="$2"; shift 2 ;;
    --scope-profile)       SCOPE_PROFILE="$2"; shift 2 ;;
    --oidc-client-id)      OIDC_CLIENT_ID="$2"; shift 2 ;;
    --oidc-client-secret)  OIDC_CLIENT_SECRET="$2"; shift 2 ;;
    --timeout)             VAULT_WAIT_TIMEOUT="$2"; JOB_WAIT_TIMEOUT="$2"; shift 2 ;;
    --vault-timeout)       VAULT_WAIT_TIMEOUT="$2"; shift 2 ;;
    --job-timeout)         JOB_WAIT_TIMEOUT="$2"; shift 2 ;;
    -h|--help)              grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ── Logic Blocks ────────────────────────────────────────────────────────────

validate_args() {
  [[ -n "$REPO_URL" ]] || die "--repo-url (or \$REPO_URL) is required"
  [[ -n "$REVISION" ]] || die "--revision (or \$REVISION) is required"
  case "$FLOW" in managed|unmanaged) ;; *) die "--flow must be 'managed' or 'unmanaged', got '$FLOW'" ;; esac
  if [[ "$SCOPE_PROFILE" != "local" ]]; then
    [[ -n "$OIDC_CLIENT_ID" && -n "$OIDC_CLIENT_SECRET" ]] \
      || die "--oidc-client-id/--oidc-client-secret (or \$OIDC_CLIENT_ID/\$OIDC_CLIENT_SECRET) are required for SCOPE_PROFILE=${SCOPE_PROFILE} — only 'local' ships committed, non-secret idpsecrets.json values."
  fi
}

preflight() {
  require_cmd kubectl envsubst timeout
  require_cluster
  [[ -f "$TMPL" ]] || die "template not found: $TMPL"
}

# Vault must actually be reachable before we try to talk to it. This is the
# synchronization Argo's PreSync-hook ordering used to give for free — made
# explicit here so the guarantee holds identically for Argo and Flux.
#
# Two-phase on purpose: `kubectl wait --for=condition=Ready` errors
# IMMEDIATELY with "no matching resources found" if the label selector
# currently matches zero objects — it does not poll waiting for a match to
# appear, only for an existing object's condition to change. On a
# freshly-reconciled "core" Kustomization, the Helm-installed vault Pod may
# not exist yet at all (chart still installing / image still pulling), so
# calling `wait` directly here fails in milliseconds, not after the timeout
# — confirmed: this is exactly what produced an instant failure on a cold
# cluster, not a genuine 300s timeout. Poll for existence first, then wait
# for Ready.
wait_for_vault_ready() {
  log "Waiting for a vault pod to exist in ${K8S_NAMESPACE} (label: ${VAULT_POD_LABEL}, up to ${VAULT_WAIT_TIMEOUT})"
  if ! timeout "$VAULT_WAIT_TIMEOUT" bash -c \
    "until kubectl -n '${K8S_NAMESPACE}' get pod -l '${VAULT_POD_LABEL}' --no-headers 2>/dev/null | grep -q .; do sleep 5; done"
  then
    die "no vault pod appeared within ${VAULT_WAIT_TIMEOUT} (label: ${VAULT_POD_LABEL}) — is the vault component deployed for this environment? Check: kubectl -n ${K8S_NAMESPACE} get pods --show-labels; flux get kustomizations -A"
  fi
  log "Vault pod exists — waiting for it to become Ready"
  kubectl -n "$K8S_NAMESPACE" wait --for=condition=Ready pod -l "$VAULT_POD_LABEL" --timeout="$VAULT_WAIT_TIMEOUT" \
    || die "vault pod not Ready within ${VAULT_WAIT_TIMEOUT} (label: ${VAULT_POD_LABEL}) — check: kubectl -n ${K8S_NAMESPACE} describe pod -l ${VAULT_POD_LABEL}"
}

# Renders + applies the one-shot seed Job. Only these seven vars are
# substituted — everything else in the template (${CFG}, ${PDIR}, and the
# container-runtime ${FLOW}/${SCOPE_PROFILE} reads) is left untouched for
# the container's own shell to evaluate.
apply_seed_job() {
  log "Rendering vault-seed-once (FLOW=${FLOW} SCOPE_PROFILE=${SCOPE_PROFILE})"
  kubectl -n "$K8S_NAMESPACE" delete job vault-seed-once --ignore-not-found >/dev/null

  # shellcheck disable=SC2016
  # envsubst's variable-list arg below must stay literal (single-quoted) — it
  # names which vars to substitute, it isn't meant to expand. See the
  # template's header comment for the full rationale.
  K8S_NAMESPACE="$K8S_NAMESPACE" FLOW="$FLOW" SCOPE_PROFILE="$SCOPE_PROFILE" \
  REPO_URL="$REPO_URL" REVISION="$REVISION" \
  OIDC_CLIENT_ID="$OIDC_CLIENT_ID" OIDC_CLIENT_SECRET="$OIDC_CLIENT_SECRET" \
    envsubst '${K8S_NAMESPACE} ${FLOW} ${SCOPE_PROFILE} ${REPO_URL} ${REVISION} ${OIDC_CLIENT_ID} ${OIDC_CLIENT_SECRET}' < "$TMPL" \
    | kubectl -n "$K8S_NAMESPACE" apply -f -
}

# Nothing owns this Job declaratively anymore, so we clean up ourselves.
# (ttlSecondsAfterFinished on the Job is a backstop, not a substitute —
# don't rely on it if a caller runs this in a tight retry loop.)
cleanup_seed_job() {
  kubectl -n "$K8S_NAMESPACE" delete job vault-seed-once --ignore-not-found >/dev/null
}

# ── Main Entry Point ────────────────────────────────────────────────────────

main() {
  validate_args
  preflight
  wait_for_vault_ready
  apply_seed_job
  wait_for_job "$K8S_NAMESPACE" vault-seed-once "$JOB_WAIT_TIMEOUT" "vault seeding failed"
  cleanup_seed_job
  log "Vault seeded."
}

main
