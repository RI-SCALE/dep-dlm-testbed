#!/usr/bin/env bash
# Compare CI step durations between the latest successful run of a workflow
# on a base branch (main) and on another branch, aggregated per step over all
# matrix jobs. Needs the GitHub CLI (gh auth login).
#
#   scripts/ci-durations.sh [workflow] [branch] [base]
#   defaults:                local.yml  current   main
set -euo pipefail

REPO="${REPO:-RI-SCALE/dep-dlm-testbed}"
WORKFLOW="${1:-local.yml}"
BRANCH="${2:-$(git rev-parse --abbrev-ref HEAD)}"
BASE="${3:-main}"

command -v gh >/dev/null || { echo "gh not found: install the GitHub CLI and run 'gh auth login'" >&2; exit 1; }

latest_success() {
    gh run list -R "$REPO" --workflow "$WORKFLOW" --branch "$1" --status success -L 1 \
        --json databaseId --jq '.[0].databaseId // empty'
}

# One line per step name: avg/min/max seconds over all jobs that ran it,
# slowest first. GitHub's own setup/teardown steps are left out.
report() {
    local label=$1 run=$2
    gh run view "$run" -R "$REPO" --json startedAt,updatedAt,jobs --jq '
        def secs: (.completedAt | fromdate) - (.startedAt | fromdate);
        def pad(n): tostring | if length < n then (" " * (n - length)) + . else . end;
        "wall time: \(((.updatedAt | fromdate) - (.startedAt | fromdate)) / 60 | floor) min, \(.jobs | length) jobs",
        "  avg    min    max  jobs  step",
        ( [ .jobs[].steps[]
            | select(.conclusion == "success" or .conclusion == "failure")
            | select(.name | test("^(Set up job|Complete job|Post )") | not)
            | {name, s: secs} ]
          | group_by(.name)
          | map({name: .[0].name, n: length,
                 avg: ((map(.s) | add) / length | floor),
                 min: (map(.s) | min), max: (map(.s) | max)})
          | sort_by(-.avg)[]
          | "\(.avg | pad(5))s \(.min | pad(5))s \(.max | pad(5))s \(.n | pad(5))  \(.name)" )' \
    | sed "1s|^|== $label (run $run), |"
}

for branch in "$BASE" "$BRANCH"; do
    run=$(latest_success "$branch")
    if [ -z "$run" ]; then
        echo "== $branch: no successful $WORKFLOW run found"
    else
        report "$branch" "$run"
    fi
    echo
done
