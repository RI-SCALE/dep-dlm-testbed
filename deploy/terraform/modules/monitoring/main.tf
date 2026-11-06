# Cloud Monitoring frontend for staging/production telemetry (design doc 005):
# dashboards converted from the Grafana JSON and PromQL alert policies read
# from alerts.yml (single source). Alerts evaluate in the cloud, so they keep
# working while the cluster is down or being recreated.

data "google_client_config" "this" {}

# Metric names Managed Prometheus has ingested in this project so far.
data "http" "metric_names" {
  url             = "https://monitoring.googleapis.com/v1/projects/${var.project_id}/location/global/prometheus/api/v1/label/__name__/values"
  request_headers = { Authorization = "Bearer ${data.google_client_config.this.access_token}" }
}

locals {
  all_rules = flatten([
    for g in yamldecode(file(var.alerts_file)).groups : [for r in g.rules : merge(r, { group = g.name })]
  ])

  # Recording rules have no cloud-side equivalent; inline them into alerts.
  recordings = { for r in local.all_rules : r.record => trimspace(r.expr) if can(r.record) }

  # Step 1: alerting rules with the recording rules they reference.
  alert_rules = {
    for r in local.all_rules : "${r.group}/${r.alert}" => merge(r, {
      used = [for name, _ in local.recordings : name if strcontains(r.expr, name)]
    }) if can(r.alert)
  }

  # Step 2: Cloud Monitoring policy inputs.
  alerts = {
    for k, r in local.alert_rules : k => {
      name  = r.alert
      group = replace(r.group, "/[^a-zA-Z0-9_:]/", "_")
      used  = r.used
      expr = length(r.used) == 0 ? trimspace(r.expr) : replace(
        trimspace(r.expr), r.used[0], "(${local.recordings[r.used[0]]})"
      )
      # Prometheus duration ("5m") -> seconds; missing `for` means 0.
      for_seconds = try(
        tonumber(regex("^([0-9]+)[smh]$", r["for"])[0]) * { s = 1, m = 60, h = 3600 }[regex("([smh])$", r["for"])[0]],
        0
      )
      labels = { for lk, lv in try(r.labels, {}) : lk => tostring(lv) }
      # Prometheus templating -> Cloud Monitoring documentation variables.
      doc = replace(
        replace(
          trimspace("${try(r.annotations.summary, r.alert)}\n\n${try(r.annotations.description, "")}"),
          "/\\{\\{\\s*\\$labels\\.([A-Za-z_][A-Za-z0-9_]*)\\s*\\}\\}/", "$${metric.label.$1}"
        ),
        "/\\{\\{\\s*\\$value[^}]*\\}\\}/", "the current value"
      )
    }
  }

  # Cloud Monitoring rejects PromQL policies on metrics never written to the
  # project; those are created on a later apply, once the exporters reported.
  available = toset(try(jsondecode(data.http.metric_names.response_body).data, []))
  ready_alerts = {
    for k, a in local.alerts : k => a
    if alltrue([for m in distinct(regexall("(?:rucio|fts)_[a-zA-Z0-9_]+", a.expr)) : contains(local.available, m)])
  }
}

resource "google_monitoring_notification_channel" "email" {
  count = var.notification_email == null ? 0 : 1

  project      = var.project_id
  display_name = "${var.name_prefix} alerts"
  type         = "email"
  labels       = { email_address = var.notification_email }
}

resource "google_monitoring_alert_policy" "this" {
  for_each = local.ready_alerts

  project      = var.project_id
  display_name = "${var.name_prefix} ${each.value.name}"
  combiner     = "OR"

  conditions {
    display_name = each.value.name

    condition_prometheus_query_language {
      query               = each.value.expr
      duration            = "${each.value.for_seconds}s"
      evaluation_interval = var.evaluation_interval
      alert_rule          = each.value.name
      rule_group          = each.value.group
      labels              = each.value.labels
    }
  }

  documentation {
    content   = each.value.doc
    mime_type = "text/markdown"
  }

  notification_channels = google_monitoring_notification_channel.email[*].name

  lifecycle {
    precondition {
      condition     = length(each.value.used) <= 1
      error_message = "Alert ${each.key} uses more than one recording rule; only one is inlined. Split the alert or extend the inlining."
    }
  }
}

resource "google_monitoring_dashboard" "this" {
  for_each = fileset(var.dashboards_dir, "*.json")

  project        = var.project_id
  dashboard_json = file("${var.dashboards_dir}/${each.value}")
}
