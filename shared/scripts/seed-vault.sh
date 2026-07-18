#!/usr/bin/env bash
# ============================================================================
# seed-vault.sh — seed the sandbox dev Vault with certs/configs/patches
# ============================================================================
# Replaces environments/sandbox/secrets/seed-job.yaml as an Argo PreSync
# hook. That manifest hardcoded FLOW/SCOPE_PROFILE, which meant switching
# either required editing the file and committing before Argo/Flux would
# pick it up. This script makes both bootstrap-time flags instead — same
# shape as the --repo-url/--revision overrides init-argocd.sh/init-flux.sh
# already support.
#
# Deliberately NOT a GitOps-synced resource: it's a one-shot imperative step,
# invoked between "secrets infra is up" and "workloads get applied" by
# init-argocd.sh / init-flux.sh. Safe to re-run (deletes any prior
# vault-seed-once Job first).
#
# Usage:
#   shared/scripts/seed-vault.sh --namespace dep-dlm-sandbox \
#     --repo-url https://github.com/ri-scale/dep-dlm-testbed.git \
#     --revision main --flow managed --scope-profile local
#
# Env overrides (flags take precedence):
#   K8S_NAMESPACE   (default: dep-dlm-sandbox)
#   FLOW            (default: managed)     managed|unmanaged
#   SCOPE_PROFILE   (default: local)
#   REPO_URL        required (no default — must match what the cluster clones)
#   REVISION        required
#   SEED_TIMEOUT    (default: 300s)
#   VAULT_POD_LABEL (default: app.kubernetes.io/name=vault,component=server)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh disable=SC1091
source "${SCRIPT_DIR}/common.sh"

K8S_NAMESPACE="${K8S_NAMESPACE:-dep-dlm-sandbox}"
FLOW="${FLOW:-managed}"
SCOPE_PROFILE="${SCOPE_PROFILE:-local}"
REPO_URL="${REPO_URL:-}"
REVISION="${REVISION:-}"
SEED_TIMEOUT="${SEED_TIMEOUT:-300s}"
# HashiCorp's vault Helm chart labels the server pod app.kubernetes.io/name=vault,
# component=server — NOT the bare "app=vault" this used to guess (which matched
# nothing, since the chart doesn't set that label at all). component=server also
# excludes vault-agent-injector, which shares app.kubernetes.io/name=vault.
VAULT_POD_LABEL="${VAULT_POD_LABEL:-app.kubernetes.io/name=vault,component=server}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)      K8S_NAMESPACE="$2"; shift 2 ;;
    --repo-url)       REPO_URL="$2"; shift 2 ;;
    --revision)       REVISION="$2"; shift 2 ;;
    --flow)           FLOW="$2"; shift 2 ;;
    --scope-profile)  SCOPE_PROFILE="$2"; shift 2 ;;
    --timeout)        SEED_TIMEOUT="$2"; shift 2 ;;
    -h|--help)         grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$REPO_URL" ]] || die "--repo-url (or \$REPO_URL) is required"
[[ -n "$REVISION" ]] || die "--revision (or \$REVISION) is required"

case "$FLOW" in managed|unmanaged) ;; *) die "--flow must be 'managed' or 'unmanaged', got '$FLOW'" ;; esac

require_cmd kubectl envsubst
require_cluster

TMPL="${SCRIPT_DIR}/k8s/vault-seed-job.yaml.tmpl"
[[ -f "$TMPL" ]] || die "template not found: $TMPL"

# 1. Vault must actually be reachable before we try to talk to it. This is
#    the synchronization Argo's PreSync-hook ordering used to give for free —
#    made explicit here so the guarantee holds identically for Argo and Flux.
log "Waiting for vault to be Ready in ${K8S_NAMESPACE}"
kubectl -n "$K8S_NAMESPACE" wait --for=condition=Ready pod -l "$VAULT_POD_LABEL" --timeout="$SEED_TIMEOUT" \
  || die "vault pod not Ready within ${SEED_TIMEOUT} (label: ${VAULT_POD_LABEL}) — is the vault component deployed for this environment? Check: kubectl -n ${K8S_NAMESPACE} get pods --show-labels"

# 2. Render + apply the one-shot seed Job. Only these five vars are
#    substituted — everything else in the template (${CFG}, ${PDIR}, and the
#    container-runtime ${FLOW}/${SCOPE_PROFILE} reads) is left untouched for
#    the container's own shell to evaluate.
log "Rendering vault-seed-once (FLOW=${FLOW} SCOPE_PROFILE=${SCOPE_PROFILE})"
kubectl -n "$K8S_NAMESPACE" delete job vault-seed-once --ignore-not-found >/dev/null

# shellcheck disable=SC2016
# envsubst's variable-list arg below must stay literal (single-quoted) — it
# names which vars to substitute, it isn't meant to expand. See the
# template's header comment for the full rationale.
K8S_NAMESPACE="$K8S_NAMESPACE" FLOW="$FLOW" SCOPE_PROFILE="$SCOPE_PROFILE" \
REPO_URL="$REPO_URL" REVISION="$REVISION" \
  envsubst '${K8S_NAMESPACE} ${FLOW} ${SCOPE_PROFILE} ${REPO_URL} ${REVISION}' < "$TMPL" \
  | kubectl -n "$K8S_NAMESPACE" apply -f -

# 3. Block until it's actually done.
log "Waiting for vault-seed-once to complete (up to ${SEED_TIMEOUT})"
if ! kubectl -n "$K8S_NAMESPACE" wait --for=condition=complete job/vault-seed-once --timeout="$SEED_TIMEOUT"; then
  warn "vault-seed-once did not complete in time — logs:"
  kubectl -n "$K8S_NAMESPACE" logs job/vault-seed-once --all-containers --tail=100 || true
  die "vault seeding failed"
fi

# 4. Nothing owns this Job declaratively anymore, so we clean up ourselves.
#    (ttlSecondsAfterFinished on the Job is a backstop, not a substitute —
#    don't rely on it if a caller runs this in a tight retry loop.)
kubectl -n "$K8S_NAMESPACE" delete job vault-seed-once --ignore-not-found >/dev/null
log "Vault seeded."
