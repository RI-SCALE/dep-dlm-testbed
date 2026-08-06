#!/usr/bin/env bash
set -euo pipefail

TF_ENV="${1:?Usage: resolve-tf-env.sh <environment>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VARS="GCP_PROJECT_ID GCP_REGION TF_STATE_BUCKET TF_NETWORK_ID TF_SUBNET_ID TF_PODS_RANGE_NAME TF_SERVICES_RANGE_NAME"

# --- CI: hard-require everything pre-set, never touch bootstrap's state --
if [[ "${TF_IN_AUTOMATION:-}" == "true" || -n "${CI:-}" ]]; then
  missing=()
  for var in $VARS; do
    [[ -n "${!var:-}" ]] || missing+=("$var")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "{ echo 'ERROR: running in CI (TF_IN_AUTOMATION/CI set) but these are not set: ${missing[*]} — CI never reads deploy/terraform/bootstrap state directly (dep-dlm-terraform-ci has no IAM grant on it, by design). Set them as GitHub Environment variables instead; see deploy/terraform/README.md Bootstrap section for the values (terraform -chdir=deploy/terraform/bootstrap output -json <name>).' >&2; exit 1; }"
    exit 1
  fi
  for var in $VARS; do
    printf 'export %s=%q\n' "$var" "${!var}"
  done
  exit 0
fi

# --- Local dev: resolve from deploy/terraform/bootstrap's own outputs ----
# BOOTSTRAP_DIR is resolved here, not above — CI's branch exits before this
# point and should never need this path to even exist, let alone resolve.
BOOTSTRAP_DIR="$(cd "${SCRIPT_DIR}/../bootstrap" && pwd)"

TF_OUTPUT_ERR="$(mktemp)"
trap 'rm -f "$TF_OUTPUT_ERR"' EXIT

if ! ALL_OUTPUTS="$(terraform -chdir="$BOOTSTRAP_DIR" output -json 2>"$TF_OUTPUT_ERR")"; then
  echo "{ echo 'ERROR: terraform -chdir=${BOOTSTRAP_DIR} output -json failed:' >&2; cat >&2 <<'TF_ERR_EOF'"
  cat "$TF_OUTPUT_ERR"
  echo "TF_ERR_EOF"
  echo "exit 1; }"
  exit 1
fi

resolve() {
  local var="$1" output_name="$2" current value
  current="${!var:-}"
  if [[ -n "$current" ]]; then
    echo "WARNING: \$${var} is already set in this shell to '${current}' — using it as-is, NOT looking it up from bootstrap for TF_ENV=${TF_ENV}. If that's stale (e.g. left over from earlier manual testing), run 'unset ${var}' and try again." >&2
    printf 'export %s=%q\n' "$var" "$current"
    return
  fi
  value="$(jq -r --arg env "$TF_ENV" --arg key "$output_name" \
    '(.[$key].value[$env]) // empty' <<<"$ALL_OUTPUTS")"
  if [[ -z "$value" ]]; then
    echo "{ echo 'ERROR: could not resolve \$${var} for TF_ENV=${TF_ENV} — deploy/terraform/bootstrap output has no ${output_name}.${TF_ENV}. Is bootstrap applied for this environment? (terraform -chdir=${BOOTSTRAP_DIR} apply)' >&2; exit 1; }"
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
