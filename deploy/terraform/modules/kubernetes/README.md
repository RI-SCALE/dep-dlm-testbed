<!-- BEGIN_TF_DOCS -->
## Requirements

No requirements.

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_google"></a> [google](#provider\_google) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [google_container_cluster.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/container_cluster) | resource |
| [google_service_account.eso](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account_iam_member.eso_workload_identity](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix applied to all kubernetes resource names (e.g. dep-dlm-staging) | `string` | n/a | yes |
| <a name="input_network_id"></a> [network\_id](#input\_network\_id) | VPC network ID (from deploy/terraform/bootstrap's networking, as of this revision) | `string` | n/a | yes |
| <a name="input_pods_range_name"></a> [pods\_range\_name](#input\_pods\_range\_name) | Secondary IP range name for pods (from deploy/terraform/bootstrap's networking, as of this revision) | `string` | n/a | yes |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | GCP project ID | `string` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | GCP region for the regional GKE cluster | `string` | n/a | yes |
| <a name="input_services_range_name"></a> [services\_range\_name](#input\_services\_range\_name) | Secondary IP range name for services (from deploy/terraform/bootstrap's networking, as of this revision) | `string` | n/a | yes |
| <a name="input_subnet_id"></a> [subnet\_id](#input\_subnet\_id) | Subnet ID (from deploy/terraform/bootstrap's networking, as of this revision) | `string` | n/a | yes |
| <a name="input_deletion_protection"></a> [deletion\_protection](#input\_deletion\_protection) | Set false for ephemeral/test environments so terraform destroy can remove the cluster without a manual override | `bool` | `false` | no |
| <a name="input_release_channel"></a> [release\_channel](#input\_release\_channel) | GKE release channel | `string` | `"REGULAR"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_cluster_ca_certificate"></a> [cluster\_ca\_certificate](#output\_cluster\_ca\_certificate) | Base64-encoded cluster CA certificate |
| <a name="output_cluster_endpoint"></a> [cluster\_endpoint](#output\_cluster\_endpoint) | API server endpoint (sensitive-adjacent — treat kubeconfig generation with care) |
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | Name of the GKE cluster |
| <a name="output_eso_service_account_email"></a> [eso\_service\_account\_email](#output\_eso\_service\_account\_email) | GCP service account email ESO's k8s ServiceAccount impersonates |
| <a name="output_workload_pool"></a> [workload\_pool](#output\_workload\_pool) | Workload Identity pool (<project>.svc.id.goog) |
<!-- END_TF_DOCS -->
