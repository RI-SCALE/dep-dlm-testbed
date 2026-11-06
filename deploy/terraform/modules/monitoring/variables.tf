variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "name_prefix" {
  description = "Prefix for display names (e.g. dep-dlm-staging)"
  type        = string
}

variable "alerts_file" {
  description = "Path to the Prometheus alerts.yml (rule_files format); its alerting rules become PromQL alert policies"
  type        = string
}

variable "dashboards_dir" {
  description = "Directory with Cloud Monitoring dashboard JSON, converted from the Grafana dashboards (scripts/convert-dashboards.sh)"
  type        = string
}

variable "notification_email" {
  description = "E-mail address for alert notifications; null creates the policies without a channel (visible in the console only)"
  type        = string
  default     = null
}

variable "evaluation_interval" {
  description = "How often Cloud Monitoring evaluates each PromQL alert"
  type        = string
  default     = "60s"
}
