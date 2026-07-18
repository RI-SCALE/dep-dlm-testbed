#!/usr/bin/env bash
# ============================================================================
# common.sh — shared helpers for init-argocd.sh / init-flux.sh / seed-vault.sh
# ============================================================================
# Sourced, not executed. Every function here was previously duplicated
# (verbatim or near-verbatim) across init-argocd.sh and init-flux.sh.
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=common.sh disable=SC1091
#   source "${SCRIPT_DIR}/common.sh"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# require_cmd <name> [<name> ...] — die if any is missing from PATH.
require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "$c not found in PATH"
  done
}

# require_cluster — die if kubectl can't reach the current context.
require_cluster() {
  kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach a cluster (check your context)"
}

# patch_git_ref <src_file> <url_field> <rev_field> <REPO_URL> <REVISION>
# Copies src_file to a tempfile with url_field/rev_field patched via sed,
# ONLY if REPO_URL or REVISION is non-empty. Echoes the path to apply
# (either the tempfile, or src_file unchanged if no override was given).
# Caller is responsible for `rm -f` on the result if it differs from
# src_file — see APPLY_FILE cleanup in init-argocd.sh / APPLY_GITREPO in
# init-flux.sh.
#
#   url_field/rev_field are the literal YAML keys to patch, e.g.:
#     Argo app-of-apps:   patch_git_ref "$f" "repoURL"   "targetRevision" ...
#     Flux GitRepository: patch_git_ref "$f" "url"       "branch"        ...
patch_git_ref() {
  local src="$1" url_field="$2" rev_field="$3" repo_url="$4" revision="$5"
  if [[ -z "$repo_url" && -z "$revision" ]]; then
    echo "$src"
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  cp "$src" "$tmp"
  [[ -n "$repo_url" ]] && { sed -i "s#${url_field}:.*#${url_field}: ${repo_url}#" "$tmp"; log "Overriding ${url_field} -> ${repo_url}"; } >&2
  [[ -n "$revision" ]] && { sed -i "s#${rev_field}:.*#${rev_field}: ${revision}#" "$tmp"; log "Overriding ${rev_field} -> ${revision}"; } >&2
  echo "$tmp"
}

# wait_for_workload <namespace> <deploy|statefulset> <name> [timeout]
# Tries deploy first if kind is ambiguous; used for the Argo-CD/Flux
# controller readiness loops, which previously duplicated this pattern.
wait_for_workload() {
  local ns="$1" kind="$2" name="$3" timeout="${4:-300s}"
  if kubectl -n "$ns" get "$kind" "$name" >/dev/null 2>&1; then
    kubectl -n "$ns" rollout status "${kind}/${name}" --timeout="$timeout" \
      || warn "$name not ready within $timeout"
  fi
}
