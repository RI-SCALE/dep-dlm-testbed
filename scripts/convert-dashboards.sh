#!/usr/bin/env bash
# Converts the Grafana dashboards into Cloud Monitoring dashboard JSON with
# Google's dashboard importer (convert only, no upload), then adapts the
# result to GKE (design doc 005):
#   - recording rules (slo:*) are inlined from alerts.yml, since Managed
#     Prometheus has no rule evaluation in the cloud;
#   - Loki log panels become Cloud Logging logs panels;
#   - the importer's timestamped "Conversion info" tile is dropped, so the
#     output is reproducible.
# The Grafana JSON stays the single source; the output is committed and
# applied by deploy/terraform/modules/monitoring. Needs git, Node.js >= 20.4,
# jq and yq.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OBS_CONFIG="${REPO_ROOT}/configs/observability"
SRC="${OBS_CONFIG}/grafana/dashboards"
ALERTS="${OBS_CONFIG}/prometheus/alerts.yml"
OUT="${OBS_CONFIG}/cloud-monitoring/dashboards"
# Pin to a commit of GoogleCloudPlatform/monitoring-dashboard-samples for
# reproducible output (the CI "generated files up to date" check needs it).
IMPORTER_REF="${IMPORTER_REF:-master}"

# Cloud Logging filters for the converted log panels (all DEP DLM namespaces).
LOGS_FILTER='resource.type="k8s_container" resource.labels.namespace_name=~"^dep-dlm-"'
ERRORS_FILTER="${LOGS_FILTER}"' (severity>=ERROR OR textPayload=~"(?i)error|exception|failed")'

for cmd in node git jq yq; do
  command -v "$cmd" >/dev/null || { echo "$cmd not found" >&2; exit 1; }
done
[[ -d "$SRC" ]] || { echo "no Grafana dashboards in ${SRC}" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git clone --quiet https://github.com/GoogleCloudPlatform/monitoring-dashboard-samples "$work/mds"
git -C "$work/mds" checkout --quiet "$IMPORTER_REF"
cd "$work/mds/scripts/dashboard-importer"
npm install --silent && npm run build --silent

./import.sh "$SRC"   # no project ID: convert only

report_dir="$(find reports -mindepth 2 -maxdepth 2 -type d | sort | tail -1)"
echo "Importer warnings (handled below or accepted):"
jq -r '.results[] | .warnings[] | "  - " + .' "$report_dir/report.json"

# {"slo:...": "<expr>"} from the recording rules in alerts.yml.
recordings="$(yq -o=json '.' "$ALERTS" \
  | jq '[.groups[].rules[] | select(has("record")) | {(.record): .expr}] | add // {}')"

mkdir -p "$OUT"
find "$OUT" -name '*.json' -delete
for f in "$report_dir"/*.json; do
  [[ "$(basename "$f")" == report.json ]] && continue
  jq --argjson rec "$recordings" \
     --arg logs "$LOGS_FILTER" --arg errors "$ERRORS_FILTER" '
    .mosaicLayout.tiles |= map(
      select(.widget.title != "Conversion info")
      | if .widget.title == "Errors across services" then
          .widget = { title: "Errors across services", logsPanel: { filter: $errors } }
        elif (.widget.title // "" | startswith("Logs:")) then
          .widget = { title: "Logs", logsPanel: { filter: $logs } }
        else . end
    )
    | walk(
        if type == "object" and has("prometheusQuery") then
          .prometheusQuery |= reduce ($rec | to_entries[]) as $r
            (.; gsub($r.key; "(" + ($r.value | gsub("^\\s+|\\s+$"; "")) + ")"))
        else . end
      )
  ' "$f" > "$OUT/$(basename "$f")"
done

echo "Converted dashboards written to ${OUT#"$REPO_ROOT"/}"
