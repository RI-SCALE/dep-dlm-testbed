#!/usr/bin/env bash
# ============================================================================
# seed-bootstrap-state.sh — one-time creation of the GCS bucket that holds
# deploy/terraform/bootstrap's OWN Terraform state.
# ============================================================================
# This is the one genuinely manual infrastructure step in the whole IaC
# stack (see deploy/terraform/bootstrap/backend.tf and README.md). Run this
# exactly once, ever — by a human with billing/project access on whatever
# project you're using to host it. That project can be any existing
# project with billing already linked; it does NOT need to be, and at this
# point cannot be, one of the dep-dlm-staging/dep-dlm-production projects,
# since bootstrap hasn't created those yet.
#
# After this, deploy/terraform/bootstrap is applied normally
# (terraform init -backend-config="bucket=<this bucket>" ...), and IT
# creates the dep-dlm-staging/dep-dlm-production projects, their own state
# buckets, their CI service accounts, and their WIF bindings — nothing
# past this point is a manual gcloud step.
#
# Idempotent: safe to re-run (skips bucket creation if it already exists).
#
# Usage:
#   ./deploy/terraform/scripts/seed-bootstrap-state.sh \
#     --project-id <existing-project-with-billing> \
#     [--bucket-name dep-dlm-tfstate-bootstrap-<suffix>] [--location EU]
#
# Env overrides (flags take precedence):
#   PROJECT_ID   required (no default)
#   BUCKET_NAME  (default: dep-dlm-tfstate-bootstrap-<project-id>)
#   LOCATION     (default: EU)
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-}"
BUCKET_NAME="${BUCKET_NAME:-}"
LOCATION="${LOCATION:-EU}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)   PROJECT_ID="$2"; shift 2 ;;
    --bucket-name)  BUCKET_NAME="$2"; shift 2 ;;
    --location)     LOCATION="$2"; shift 2 ;;
    -h|--help)      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$PROJECT_ID" ]] || { echo "ERROR: --project-id (or \$PROJECT_ID) is required" >&2; exit 1; }

# Bucket names are global across ALL of GCP, not project-scoped — same
# gotcha the top-level README's Troubleshooting table already documents
# for the per-environment state buckets. Default to a project-suffixed
# name so a first run doesn't collide with someone else's bucket.
BUCKET_NAME="${BUCKET_NAME:-dep-dlm-tfstate-bootstrap-${PROJECT_ID}}"

if gcloud storage buckets describe "gs://${BUCKET_NAME}" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "Bucket gs://${BUCKET_NAME} already exists — skipping create"
else
  echo "Creating gs://${BUCKET_NAME} in ${PROJECT_ID} (${LOCATION})"
  gcloud storage buckets create "gs://${BUCKET_NAME}" \
    --project="$PROJECT_ID" --location="$LOCATION" --uniform-bucket-level-access
fi

echo "Enabling versioning (state file history)"
gcloud storage buckets update "gs://${BUCKET_NAME}" --versioning

cat <<EOF

Done. Initialize the bootstrap module with:

  cd deploy/terraform/bootstrap
  terraform init -backend-config="bucket=${BUCKET_NAME}" -backend-config="prefix=bootstrap"

This is a one-time step for the lifetime of this org/billing account's use
of the repo — re-run this script only if you're seeding a second,
independent bootstrap lineage (e.g. a separate org or billing account).
EOF
