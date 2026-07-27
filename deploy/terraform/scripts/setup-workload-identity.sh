#!/usr/bin/env bash
# ============================================================================
# setup-workload-identity.sh — bootstrap keyless GCP auth for GitHub Actions
#                                and local dev (via impersonation)
# ============================================================================
# One-time setup, run interactively by a human with IAM admin rights on the
# target project — NOT part of any CI run itself. Creates a service account,
# grants it the roles deploy/terraform's modules need, and wires a Workload
# Identity Federation pool/provider so GitHub Actions can authenticate via
# short-lived OIDC tokens instead of a long-lived service account key. See
# deploy/terraform/README.md for why this replaces `gcloud init`/interactive
# login for CI.
#
# Idempotent: every gcloud call below checks for the resource first and
# skips creation if it already exists, so re-running after a partial
# failure (or to add a second GitHub repo/provider) is safe.
#
# Local dev does NOT get WIF for free — WIF's OIDC exchange only works from
# an actual GitHub Actions runner. Pass --grant-local-impersonation to
# additionally let your own gcloud identity impersonate this service
# account, so local `terraform` runs as the identical principal as CI
# without a persistent credential on disk. (A service-account-key approach
# was considered instead and dropped: most GCP orgs — including this
# project's — enforce `constraints/iam.disableServiceAccountKeyCreation`,
# which blocks key creation outright. Impersonation works regardless of
# that constraint and is the better practice anyway.)
#
# Usage:
#   ./deploy/terraform/scripts/setup-workload-identity.sh \
#     --project-id your-gcp-project-id \
#     --github-repo ri-scale/dep-dlm-testbed \
#     [--grant-local-impersonation] [--impersonator user@example.com]
#
# Env overrides (flags take precedence):
#   PROJECT_ID                required (no default)
#   GITHUB_REPO                required (no default) — format: org/repo
#   SA_NAME                    (default: dep-dlm-terraform-ci)
#   POOL_NAME                  (default: github-actions-pool)
#   PROVIDER_NAME               (default: github-actions-provider)
#   ROLES                       (default: the six roles deploy/terraform's modules
#                                need — see the loop below; space-separated to override)
#   GRANT_LOCAL_IMPERSONATION  (default: false) — same as --grant-local-impersonation
#   IMPERSONATOR                (default: your current `gcloud config get-value account`)
set -euo pipefail

log()  { echo -e "\033[0;34m[setup-wif]\033[0m $*"; }
warn() { echo -e "\033[1;33m[setup-wif] WARN:\033[0m $*" >&2; }
die()  { echo -e "\033[0;31m[setup-wif] ERROR:\033[0m $*" >&2; exit 1; }

PROJECT_ID="${PROJECT_ID:-}"
GITHUB_REPO="${GITHUB_REPO:-}"
SA_NAME="${SA_NAME:-dep-dlm-terraform-ci}"
POOL_NAME="${POOL_NAME:-github-actions-pool}"
PROVIDER_NAME="${PROVIDER_NAME:-github-actions-provider}"
GRANT_LOCAL_IMPERSONATION="${GRANT_LOCAL_IMPERSONATION:-false}"
IMPERSONATOR="${IMPERSONATOR:-}"
# Matches what modules/kubernetes, modules/networking, modules/secrets and
# modules/database actually call, PLUS roles/storage.admin (project-level)
# so CI can create/manage its own Terraform state bucket idempotently
# rather than requiring a human to pre-create it and grant object-level
# access by hand (the manual path this project used the first time). This
# is a real privilege widening — object-level access on one known bucket
# vs. bucket-create/setIamPolicy project-wide — accepted here specifically
# so bucket lifecycle can live in the CI workflow rather than being a
# recurring manual step. Widen further if a module adds a new resource
# type Terraform needs to manage.
ROLES="${ROLES:-roles/container.admin roles/compute.networkAdmin roles/cloudsql.admin roles/secretmanager.admin roles/iam.serviceAccountAdmin roles/servicenetworking.networksAdmin roles/storage.admin}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)                  PROJECT_ID="$2"; shift 2 ;;
    --github-repo)                 GITHUB_REPO="$2"; shift 2 ;;
    --sa-name)                     SA_NAME="$2"; shift 2 ;;
    --pool-name)                   POOL_NAME="$2"; shift 2 ;;
    --provider-name)               PROVIDER_NAME="$2"; shift 2 ;;
    --grant-local-impersonation)   GRANT_LOCAL_IMPERSONATION="true"; shift 1 ;;
    --impersonator)                IMPERSONATOR="$2"; shift 2 ;;
    -h|--help)                     grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$PROJECT_ID" ]]   || die "--project-id (or \$PROJECT_ID) is required"
[[ -n "$GITHUB_REPO" ]]  || die "--github-repo (or \$GITHUB_REPO) is required, format: org/repo"

command -v gcloud >/dev/null 2>&1 || die "gcloud not found — run .devcontainer/setup.sh's install_gcloud() first"

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')" \
  || die "could not resolve project number for ${PROJECT_ID} — check the project ID and your gcloud auth"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# 1. Service account. Skip if it already exists — re-running this script
#    to add roles or a second repo shouldn't fail on a duplicate-create.
if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
  log "Service account ${SA_EMAIL} already exists — skipping create"
else
  log "Creating service account ${SA_EMAIL}"
  gcloud iam service-accounts create "$SA_NAME" \
    --project="$PROJECT_ID" \
    --display-name="Terraform CI (GitHub Actions)"

  # IAM's policy backend lags behind account creation by a few seconds to
  # ~1min — granting roles immediately after create is a known race
  # ("...does not exist" even though describe/list already shows it).
  # Poll describe (fast-consistency read path) as a proxy signal, then add
  # a fixed buffer before touching the (slower-consistency) policy backend.
  log "Waiting for service account to propagate..."
  for _ in $(seq 1 12); do
    gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1 && break
    sleep 5
  done
  sleep 15
fi

# 2. Project-level role grants. add-iam-policy-binding is itself idempotent
#    (re-granting an already-held role is a no-op). Retries on failure to
#    absorb any remaining IAM propagation lag from step 1.
log "Granting roles to ${SA_EMAIL}: ${ROLES}"
for role in $ROLES; do
  attempt=1
  until gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member="serviceAccount:${SA_EMAIL}" \
      --role="$role" \
      --condition=None \
      >/dev/null 2>&1; do
    if [[ $attempt -ge 5 ]]; then
      die "failed to grant ${role} to ${SA_EMAIL} after ${attempt} attempts — check IAM propagation or run this script again"
    fi
    warn "grant of ${role} failed (attempt ${attempt}/5, likely IAM propagation lag) — retrying in 10s"
    sleep 10
    attempt=$((attempt + 1))
  done
done

# 3. Workload Identity pool.
if gcloud iam workload-identity-pools describe "$POOL_NAME" \
    --project="$PROJECT_ID" --location="global" >/dev/null 2>&1; then
  log "Workload identity pool ${POOL_NAME} already exists — skipping create"
else
  log "Creating workload identity pool ${POOL_NAME}"
  gcloud iam workload-identity-pools create "$POOL_NAME" \
    --project="$PROJECT_ID" --location="global" \
    --display-name="GitHub Actions"
fi

# 4. OIDC provider on that pool, scoped to this specific GitHub repo via
#    --attribute-condition — without this, ANY repo in the GitHub org could
#    mint tokens this provider accepts.
if gcloud iam workload-identity-pools providers describe "$PROVIDER_NAME" \
    --project="$PROJECT_ID" --location="global" \
    --workload-identity-pool="$POOL_NAME" >/dev/null 2>&1; then
  log "Provider ${PROVIDER_NAME} already exists — skipping create"
else
  log "Creating OIDC provider ${PROVIDER_NAME} scoped to ${GITHUB_REPO}"
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_NAME" \
    --project="$PROJECT_ID" --location="global" \
    --workload-identity-pool="$POOL_NAME" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
    --attribute-condition="assertion.repository=='${GITHUB_REPO}'"
fi

# 5. Bind the pool (scoped to this repo) to the service account.
log "Binding ${GITHUB_REPO} to ${SA_EMAIL} via workloadIdentityUser"
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_NAME}/attribute.repository/${GITHUB_REPO}" \
  >/dev/null

PROVIDER_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_NAME}/providers/${PROVIDER_NAME}"

log "Done. Add these to your GitHub Actions workflow's google-github-actions/auth step:"
echo
echo "  workload_identity_provider: ${PROVIDER_RESOURCE}"
echo "  service_account: ${SA_EMAIL}"
echo
log "And ensure the workflow/job declares: permissions: { id-token: write, contents: read }"

# 6. OPTIONAL, opt-in only: let your own gcloud identity impersonate this
#    SA for local dev. Off by default. Idempotent (re-granting an
#    already-held role is a no-op). The actual ADC login this enables is
#    left as a manual final step below — it's an interactive consent
#    action by design, not something to script.
if [[ "$GRANT_LOCAL_IMPERSONATION" == "true" ]]; then
  IMPERSONATOR="${IMPERSONATOR:-$(gcloud config get-value account 2>/dev/null)}"
  [[ -n "$IMPERSONATOR" ]] || die "--impersonator (or \$IMPERSONATOR) is required, and 'gcloud config get-value account' returned nothing — run 'gcloud auth login' first"

  echo
  log "Granting ${IMPERSONATOR} permission to impersonate ${SA_EMAIL}"
  gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --project="$PROJECT_ID" \
    --member="user:${IMPERSONATOR}" \
    --role="roles/iam.serviceAccountTokenCreator" \
    >/dev/null

  echo
  log "Grant complete. Run this once yourself to finish local setup (interactive, one browser prompt):"
  echo
  echo "  gcloud auth application-default login \\"
  echo "    --impersonate-service-account=${SA_EMAIL}"
  echo
  log "After that, terraform init/plan/apply need no further interaction — ADC refreshes tokens transparently."
fi
