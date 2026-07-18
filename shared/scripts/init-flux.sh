#!/usr/bin/env bash
# ============================================================================
# init-flux.sh — install Flux and bootstrap the DEP DLM stack (env-aware)
# ============================================================================
# Installs the Flux controllers, applies the GitRepository source, then
# applies the FULL environment entrypoint in one shot and lets Flux's own
# dependsOn graph sequence eso → core → secrets → components — NOT a
# hand-staged sequence of separate applies.
#
# CHANGED from an earlier version of this script, which manually applied
# "core" (vault + postgresql) before "eso", on the assumption that vault
# needing to exist before ExternalSecrets meant core had no dependencies of
# its own. Wrong: CI proved flux/entrypoints/sandbox.yaml's own
# "dep-dlm-sandbox-core" Kustomization declares `dependsOn: [dep-dlm-sandbox-
# eso]` — applying core alone, before eso exists, fails immediately with
# "dependency ... not found", because Flux's kustomize-controller can't even
# start reconciling a Kustomization whose dependsOn target doesn't exist yet.
#
# Unlike Argo's ApplicationSet-generated Applications (confirmed to have NO
# cross-Application ordering at all — sync-wave annotations are inert there),
# Flux Kustomizations DO natively enforce dependsOn correctly. So the fix
# isn't to guess a different manual order — it's to stop guessing and apply
# everything at once, then just wait on the ONE Kustomization that's the
# real precondition for seeding (core, since that's what creates the Vault
# pod), trusting Flux to have already sequenced eso before it internally.
#
# Sequence:
#   1. Apply GitRepository.
#   2. Apply the ENTIRE entrypoint (eso + core + secrets + components, in
#      whatever shape flux/entrypoints/<env>.yaml declares) in one apply.
#      Flux's dependsOn graph handles internal sequencing; secrets and
#      components will sit unready until core/seeding catch up, same as the
#      Argo path's components sit unhealthy until their Applications' turn.
#   3. Wait for CORE_KS (the "core" Kustomization) to be Ready — this is
#      the real gate for seeding, and per its own dependsOn it implies eso
#      is already Ready too, so we don't need to wait on eso separately.
#   4. seed-vault.sh.
#   5. run-bootstrap-db.sh — NOT gated behind waiting for the components
#      Kustomization to be Ready first. That Kustomization bundles
#      rucio-daemons, which crash-loops on a missing "heartbeats" table
#      until bootstrap creates it — waiting on its Ready condition first
#      would be a hard deadlock, confirmed on the Argo path's equivalent
#      per-Application health wait. run-bootstrap-db.sh has its own correct,
#      non-circular precondition (Service/ruciodb exists, then an in-Job
#      DB-reachability retry loop).
#
# Idempotent: safe to re-run. Honours an existing Flux install.
#
# Usage:
#   shared/scripts/init-flux.sh [--env sandbox|staging|production]
#                               [--repo-url URL] [--revision REF]
#                               [--flow managed|unmanaged]
#                               [--scope-profile local|<profile>]
#                               [--no-wait] [--no-seed]
#
# Env overrides:
#   FLUX_NAMESPACE   (default: flux-system)
#   GITOPS_ENV       (default: sandbox)
#   REPO_URL         git repo Flux pulls from (default: from gitrepository.yaml)
#   REVISION         git branch Flux tracks   (default: from gitrepository.yaml)
#   FLOW             FTS token mode for vault seeding (default: managed)
#   SCOPE_PROFILE    OIDC scope profile for vault seeding (default: local)
#
# --no-seed skips the core-Kustomization wait, seed-vault.sh, and
# run-bootstrap-db.sh — use for staging/production, which don't run vault
# this way (see environments/<env>/secrets/README.md). The entrypoint is
# still applied in full either way.
#
# ASSUMPTION FLAGGED: this script assumes the "core" Kustomization is named
# "dep-dlm-<env>-core" (→ flux/core/<env>/) — CI confirmed this name is
# correct. It no longer needs to know the eso/secrets/components
# Kustomization names at all, since they're applied as part of the same
# single `kubectl apply -f "$ENTRYPOINT"` — only CORE_KS is still name-
# sensitive, because it's the one Kustomization we wait on individually.
#
# Examples:
#   shared/scripts/init-flux.sh --env sandbox \
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
FLUX_NAMESPACE="${FLUX_NAMESPACE:-flux-system}"
REPO_URL="${REPO_URL:-}"
REVISION="${REVISION:-}"
FLOW="${FLOW:-managed}"
SCOPE_PROFILE="${SCOPE_PROFILE:-local}"
WAIT=1
SEED=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)            GITOPS_ENV="$2"; shift 2 ;;
    --repo-url)       REPO_URL="$2"; shift 2 ;;
    --revision)       REVISION="$2"; shift 2 ;;
    --flow)           FLOW="$2"; shift 2 ;;
    --scope-profile)  SCOPE_PROFILE="$2"; shift 2 ;;
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

# --- 4. Apply the FULL entrypoint in one shot — let Flux's own dependsOn
# graph (eso -> core -> secrets -> components, or whatever it actually
# declares) sequence reconciliation. See header for why this replaced a
# hand-staged apply order that turned out to be backwards.
log "Applying ${GITOPS_ENV} entrypoint (eso + core + secrets + components)"
kubectl apply -f "$ENTRYPOINT"

# --- 5. Wait for the core Kustomization — the real gate for seeding. Its
# own dependsOn on eso means Flux won't mark it Ready until eso is Ready
# too, so we don't need a separate wait for eso.
if [[ "$SEED" -eq 1 && "$GITOPS_ENV" == "sandbox" && "$WAIT" -eq 1 ]]; then
  log "Waiting for Kustomization/${CORE_KS} to be Ready (up to 5m)"
  kubectl -n "$FLUX_NAMESPACE" wait --for=condition=Ready "kustomization/${CORE_KS}" --timeout=300s \
    || warn "${CORE_KS} not Ready within timeout — seeding will likely fail; check 'flux get kustomization ${CORE_KS}' and 'flux get kustomization dep-dlm-${GITOPS_ENV}-eso'"
fi

# --- 6. Seed Vault (sandbox only) — Vault is reachable (step 5).
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

# --- 7. Bootstrap the rucio DB schema (sandbox only) ------------------------
# NOT gated behind waiting for the components Kustomization to be Ready —
# see header for why (rucio-daemons circular dependency on the schema).
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
