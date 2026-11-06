<!-- BEGIN_TF_DOCS -->
## Requirements

No requirements.

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_google"></a> [google](#provider\_google) | n/a |
| <a name="provider_http"></a> [http](#provider\_http) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [google_monitoring_alert_policy.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/monitoring_alert_policy) | resource |
| [google_monitoring_dashboard.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/monitoring_dashboard) | resource |
| [google_monitoring_notification_channel.email](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/monitoring_notification_channel) | resource |
| [google_client_config.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/client_config) | data source |
| [http_http.metric_names](https://registry.terraform.io/providers/hashicorp/http/latest/docs/data-sources/http) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_alerts_file"></a> [alerts\_file](#input\_alerts\_file) | Path to the Prometheus alerts.yml (rule\_files format); its alerting rules become PromQL alert policies | `string` | n/a | yes |
| <a name="input_dashboards_dir"></a> [dashboards\_dir](#input\_dashboards\_dir) | Directory with Cloud Monitoring dashboard JSON, converted from the Grafana dashboards (scripts/convert-dashboards.sh) | `string` | n/a | yes |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix for display names (e.g. dep-dlm-staging) | `string` | n/a | yes |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | GCP project ID | `string` | n/a | yes |
| <a name="input_evaluation_interval"></a> [evaluation\_interval](#input\_evaluation\_interval) | How often Cloud Monitoring evaluates each PromQL alert | `string` | `"60s"` | no |
| <a name="input_notification_email"></a> [notification\_email](#input\_notification\_email) | E-mail address for alert notifications; null creates the policies without a channel (visible in the console only) | `string` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_alert_policy_names"></a> [alert\_policy\_names](#output\_alert\_policy\_names) | Map of group/alert -> alert policy resource name |
| <a name="output_dashboard_ids"></a> [dashboard\_ids](#output\_dashboard\_ids) | Map of dashboard file -> Cloud Monitoring dashboard ID |
| <a name="output_pending_alert_policies"></a> [pending\_alert\_policies](#output\_pending\_alert\_policies) | Alerts whose metrics have not been ingested yet; created on a later apply |
<!-- END_TF_DOCS -->
