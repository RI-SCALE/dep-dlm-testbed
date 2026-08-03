#!/usr/bin/env bash
set -euo pipefail

TF_ENV="${1:?Usage: resolve-tf-env.sh <environment>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "${SCRIPT_DIR}/../bootstrap" && pwd)"

ALL_OUTPUTS="$(terraform -chdir="$BOOTSTRAP_DIR" output -json 2>/dev/null || echo '{}')"

resolve() {
  local var="$1" output_name="$2" current value
  current="${!var:-}"
  if [[ -n "$current" ]]; then
    printf 'export %s=%q\n' "$var" "$current"
    return
  fi
  value="$(jq -r --arg env "$TF_ENV" --arg key "$output_name" \
    '(.[$key].value[$env]) // empty' <<<"$ALL_OUTPUTS")"
  if [[ -z "$value" ]]; then
    echo "{ echo 'ERROR: could not resolve \$${var} for TF_ENV=${TF_ENV} — set \$${var} explicitly, or apply deploy/terraform/bootstrap for this environment first (terraform -chdir=${BOOTSTRAP_DIR} apply)' >&2; exit 1; }"
    exit 1
  fi
  printf 'export %s=%q\n' "$var" "$value"
}

resolve GCP_PROJECT_ID         project_ids
resolve GCP_REGION             regions
resolve TF_STATE_BUCKET        state_buckets
resolve TF_NETWORK_ID          network_ids
resolve TF_SUBNET_ID           subnet_ids
resolve TF_PODS_RANGE_NAME     pods_range_names
resolve TF_SERVICES_RANGE_NAME services_range_names
