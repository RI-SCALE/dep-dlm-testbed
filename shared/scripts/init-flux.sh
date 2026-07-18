#!/usr/bin/env bash
# ============================================================================
# init-flux.sh — install Flux and bootstrap the DEP DLM stack (env-aware)
# ============================================================================
# Installs the Flux controllers, applies the GitRepository source, then
# bootstraps in three explicit stages, mirroring the actual dependency graph
# (and init-argocd.sh's structure, now validated end-to-end on the Argo path)
# rather than one flat entrypoint apply:
#
#   1. CORE stage (flux/core/<env>/kustomization.yaml) — vault + postgresql
#      (+ the GitRepository/HelmRepository sources it needs). Applied and
#      waited on FIRST: this is what seed-vault.sh and every ExternalSecret
#      actually need to exist.
#   2. ESO + per-env SECRETS Kustomizations — applied once core is Ready,
#      but NOT waited on. Same lesson learned on the Argo path: that wait
#      isn't the real gate (seed-vault.sh only needs the Vault pod Ready,
#      already confirmed in step 1) and "Ready" here would require the
#      ExternalSecrets to have actually resolved data, which can't happen
#      until step 4 seeds Vault — waiting on it just risks the same class
#      of stall the Argo script hit polling Application health/sync status.
#   3. seed-vault.sh, then force an immediate ExternalSecret refresh (their
#      default 1h refresh interval is far too slow to wait out) — pods with
#      FailedMount self-heal automatically once the target Secret exists,
#      no restart needed.
#   4. full environment entrypoint (remaining components: rucio-server, fts,
#      keycloak, xrd3/4, teapot1/2, rucio-daemons, rucio-client) — applied.
#      NOT waited on before bootstrap: rucio-daemons crash-loops on a
#      missing "heartbeats" table until bootstrap creates it, so waiting
#      for this Kustomization to go Ready first would be a hard deadlock,
#      confirmed on the Argo path's equivalent per-Application health wait.
#   5. run-bootstrap-db.sh — has its own correct, non-circular precondition
#      (Service/ruciodb exists, then an in-Job DB-reachability retry loop).
#
# Unlike Argo's ApplicationSet-generated Applications (which have NO
# built-in cross-Application ordering — confirmed empirically: sync-wave
# annotations there had no effect at all), Flux Kustomizations natively
# support dependsOn + healthChecks. If flux/entrypoints/<env>.yaml already
# declares that chain correctly, a single `kubectl apply -f "$ENTRYPOINT"`
# would in principle sequence itself. This script still splits the apply
# explicitly because seeding is an imperative step Flux can't trigger on
# its own — we need an actual pause point in bash to call seed-vault.sh
# between "core is up" and "components can converge".
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
# --no-seed skips both the seed-vault.sh AND run-bootstrap-db.sh steps, and
# the core-stage wait — use for staging/production, which don't run vault
# this way (see environments/<env>/secrets/README.md).
#
# ASSUMPTION FLAGGED (please verify against the real
# flux/entrypoints/<env>.yaml, which I have not seen — this path hasn't
# been run yet, unlike the Argo path, where two prior label/wait
# assumptions in this script's sibling both turned out wrong in practice):
# this script assumes Kustomization names "dep-dlm-<env>-core" (→
# flux/core/<env>/), "dep-dlm-<env>-eso", and "dep-dlm-<env>-secrets" for
# the first two stages, and "dep-dlm-<env>" for the final components
# Kustomization (this last one matches the name already used elsewhere in
# this repo, e.g. the "Next steps" reconcile command and flux-uninstall in
# the Makefile). Given the Argo path's track record, verify these names
# against the actual entrypoint before trusting this end-to-end — adjust
# CORE_KS/COMPONENTS_KS below if they differ.
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

# ASSUMPTION: see header note.
CORE_KS="dep-dlm-${GITOPS_ENV}-core"
COMPONENTS_KS="dep-dlm-${GITOPS_ENV}"

require_cmd kubectl yq
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

# --- 4. Apply the CORE stage (vault + postgresql) first, wait for Ready ----
# This one IS the real gate — seed-vault.sh needs the Vault pod up.
if [[ "$SEED" -eq 1 && "$GITOPS_ENV" == "sandbox" ]]; then
  log "Applying core stage (${CORE_KS})"
  kubectl apply -f <(yq 'select(.kind == "Kustomization" and .metadata.name == "'"${CORE_KS}"'")' "$ENTRYPOINT")

  if [[ "$WAIT" -eq 1 ]]; then
    log "Waiting for Kustomization/${CORE_KS} to be Ready (up to 5m)"
    kubectl -n "$FLUX_NAMESPACE" wait --for=condition=Ready "kustomization/${CORE_KS}" --timeout=300s \
      || warn "${CORE_KS} not Ready within timeout — seeding will likely fail; check 'flux get kustomization ${CORE_KS}'"
  fi
fi

# --- 5. Apply ESO + per-env secrets Kustomizations — NOT waited on. See
# header: this isn't the real gate, and waiting on it risks the same class
# of stall the Argo script hit polling for something that can't be true yet.
if [[ "$SEED" -eq 1 && "$GITOPS_ENV" == "sandbox" ]]; then
  log "Applying secrets-layer Kustomizations (eso + ${GITOPS_ENV}-secrets)"
  kubectl apply -f <(yq 'select(.kind == "Kustomization" and (.metadata.name | test("eso|secrets")))' "$ENTRYPOINT")

  # --- 6. Seed Vault — Vault is reachable (step 4).
  "${SCRIPT_DIR}/seed-vault.sh" \
    --namespace "$APP_NS" \
    --repo-url "${REPO_URL:-https://github.com/ri-scale/dep-dlm-testbed.git}" \
    --revision "${REVISION:-main}" \
    --flow "$FLOW" \
    --scope-profile "$SCOPE_PROFILE"

  # ExternalSecrets have a slow default refresh interval (1h per this
  # repo's config). Force an immediate refresh instead of waiting on
  # anything — dependent pods' FailedMount errors self-heal automatically
  # via kubelet's own mount retries once the target Secret exists.
  log "Forcing ExternalSecrets in ${APP_NS} to re-sync now that Vault is seeded"
  for es in $(kubectl -n "$APP_NS" get externalsecret -o name 2>/dev/null); do
    kubectl -n "$APP_NS" annotate "$es" force-sync="$(date +%s)" --overwrite >/dev/null
  done
elif [[ "$SEED" -eq 0 ]]; then
  log "Skipping Vault seeding (--no-seed)"
fi

# --- 7. Apply the full environment entrypoint (remaining components) -------
log "Applying ${GITOPS_ENV} entrypoint (remaining components Kustomizations)"
kubectl apply -f "$ENTRYPOINT"

# --- 8. Bootstrap the rucio DB schema (sandbox only) ------------------------
# NOTE: this used to wait for Kustomization/${COMPONENTS_KS} to be Ready
# before bootstrapping. That's a hard deadlock, not just flaky: this
# Kustomization bundles rucio-daemons, which crash-loops on a missing
# "heartbeats" table until run-bootstrap-db.sh creates it — so the
# Kustomization can NEVER go Ready before bootstrap runs. Confirmed on the
# Argo path, where the equivalent per-Application health wait hit exactly
# this. run-bootstrap-db.sh already has its own correct, non-circular
# precondition (waits for Service/ruciodb, then an in-Job DB-reachability
# retry loop), so call it directly instead.
if [[ "$SEED" -eq 1 && "$GITOPS_ENV" == "sandbox" ]]; then
  "${SCRIPT_DIR}/run-bootstrap-db.sh" --namespace "$APP_NS"
fi

# --- 9. Report --------------------------------------------------------------
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
