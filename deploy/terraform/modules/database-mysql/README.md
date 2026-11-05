<!-- BEGIN_TF_DOCS -->
## Requirements

No requirements.

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_google"></a> [google](#provider\_google) | n/a |
| <a name="provider_random"></a> [random](#provider\_random) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [google_sql_database.fts](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/sql_database) | resource |
| [google_sql_database_instance.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/sql_database_instance) | resource |
| [google_sql_user.fts](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/sql_user) | resource |
| [random_password.fts_db](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix applied to the instance name (e.g. dep-dlm-staging) | `string` | n/a | yes |
| <a name="input_network_id"></a> [network\_id](#input\_network\_id) | VPC network ID (from deploy/terraform/bootstrap's networking, as of this revision), for private IP | `string` | n/a | yes |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | GCP project ID | `string` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | GCP region for the Cloud SQL instance | `string` | n/a | yes |
| <a name="input_availability_type"></a> [availability\_type](#input\_availability\_type) | ZONAL for cost-efficient staging; REGIONAL for production HA | `string` | `"ZONAL"` | no |
| <a name="input_deletion_protection"></a> [deletion\_protection](#input\_deletion\_protection) | Set false for ephemeral/test environments so terraform destroy can remove the instance without a manual override | `bool` | `false` | no |
| <a name="input_mysql_version"></a> [mysql\_version](#input\_mysql\_version) | Cloud SQL MySQL version | `string` | `"MYSQL_8_4"` | no |
| <a name="input_point_in_time_recovery"></a> [point\_in\_time\_recovery](#input\_point\_in\_time\_recovery) | Enable binary logging for MySQL point-in-time recovery, when availability\_type = ZONAL. Ignored when availability\_type = REGIONAL — binary logging is forced on there regardless, since GCP requires it for MySQL HA and rejects instance creation without it. | `bool` | `false` | no |
| <a name="input_tier"></a> [tier](#input\_tier) | Cloud SQL machine tier. Small default suits a staging/test-cadence workload; size up for anything closer to production load. | `string` | `"db-custom-2-7680"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_connection_name"></a> [connection\_name](#output\_connection\_name) | Cloud SQL connection name (project:region:instance), useful for the Cloud SQL Auth Proxy if ever needed |
| <a name="output_fts_db_name"></a> [fts\_db\_name](#output\_fts\_db\_name) | n/a |
| <a name="output_fts_db_password"></a> [fts\_db\_password](#output\_fts\_db\_password) | n/a |
| <a name="output_instance_name"></a> [instance\_name](#output\_instance\_name) | Name of the Cloud SQL instance |
| <a name="output_private_ip_address"></a> [private\_ip\_address](#output\_private\_ip\_address) | Private IP address of the Cloud SQL instance |
<!-- END_TF_DOCS -->
