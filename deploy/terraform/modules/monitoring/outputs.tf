output "dashboard_ids" {
  description = "Map of dashboard file -> Cloud Monitoring dashboard ID"
  value       = { for f, d in google_monitoring_dashboard.this : f => d.id }
}

output "alert_policy_names" {
  description = "Map of group/alert -> alert policy resource name"
  value       = { for k, p in google_monitoring_alert_policy.this : k => p.name }
}

output "pending_alert_policies" {
  description = "Alerts whose metrics have not been ingested yet; created on a later apply"
  value       = sort(setsubtract(keys(local.alerts), keys(local.ready_alerts)))
}
