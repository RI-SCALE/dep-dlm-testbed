#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=common.sh disable=SC1091
source "${SCRIPT_DIR}/common.sh"

K8S_NAMESPACE="${K8S_NAMESPACE:-dep-dlm-sandbox}"
SCOPE_PROFILE="${SCOPE_PROFILE:-local}"
TOKEN_MODE="${TOKEN_MODE:-managed}"
CHART_DIR="${REPO_ROOT}/deploy/helm-charts/dep-dlm-testbed"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)      K8S_NAMESPACE="$2"; shift 2 ;;
    --scope-profile)  SCOPE_PROFILE="$2"; shift 2 ;;
    --token-mode)     TOKEN_MODE="$2"; shift 2 ;;
    -h|--help)        grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ── Logic Blocks ────────────────────────────────────────────────────────────

preflight() {
  require_cmd kubectl helm
  require_cluster
  [[ -d "$CHART_DIR" ]] || die "umbrella chart not found: $CHART_DIR"

  # helm template validates Chart.yaml's dependencies against charts/
  # before rendering anything, even with --show-only narrowing output to
  # top-level templates that don't touch any subchart.
  log "Ensuring chart dependencies (helm dependency build)"
  helm dependency build "$CHART_DIR"
}

render_and_apply() {
  log "Rendering testbed-configs/patches/scripts/tests (scopeProfile=${SCOPE_PROFILE} tokenMode=${TOKEN_MODE}) into ${K8S_NAMESPACE}"
  helm template testbed "$CHART_DIR" \
    --show-only templates/testbed-configs.yaml \
    --show-only templates/testbed-patches.yaml \
    --show-only templates/testbed-scripts.yaml \
    --show-only templates/testbed-tests.yaml \
    --set global.scopeProfile="$SCOPE_PROFILE" \
    --set global.tokenMode="$TOKEN_MODE" \
    | kubectl apply --server-side --force-conflicts -n "$K8S_NAMESPACE" -f -
  log "testbed-configs/testbed-patches/testbed-scripts/testbed-tests applied."
}

# ── Main Entry Point ────────────────────────────────────────────────────────

main() {
  preflight
  render_and_apply
}

main
