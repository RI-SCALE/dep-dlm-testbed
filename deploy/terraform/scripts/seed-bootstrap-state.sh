#!/usr/bin/env bash
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
