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
| [google_compute_global_address.private_service_range](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_global_address) | resource |
| [google_compute_network.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_network) | resource |
| [google_compute_subnetwork.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_subnetwork) | resource |
| [google_service_networking_connection.private_service_connection](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_networking_connection) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix applied to all networking resource names (e.g. dep-dlm-staging) | `string` | n/a | yes |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | GCP project ID | `string` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | GCP region for the subnet | `string` | n/a | yes |
| <a name="input_pods_cidr"></a> [pods\_cidr](#input\_pods\_cidr) | Secondary CIDR range for GKE pod IPs | `string` | `"10.20.0.0/16"` | no |
| <a name="input_services_cidr"></a> [services\_cidr](#input\_services\_cidr) | Secondary CIDR range for GKE service IPs | `string` | `"10.30.0.0/20"` | no |
| <a name="input_subnet_cidr"></a> [subnet\_cidr](#input\_subnet\_cidr) | Primary CIDR range for the GKE node subnet | `string` | `"10.10.0.0/20"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_network_id"></a> [network\_id](#output\_network\_id) | Self link / ID of the VPC network |
| <a name="output_network_name"></a> [network\_name](#output\_network\_name) | Name of the VPC network |
| <a name="output_pods_range_name"></a> [pods\_range\_name](#output\_pods\_range\_name) | Name of the secondary IP range used for GKE pods |
| <a name="output_private_vpc_connection"></a> [private\_vpc\_connection](#output\_private\_vpc\_connection) | The private services access peering connection. Not consumed cross-state any longer (see modules/database's variables.tf) but kept as an output — still useful for anyone inspecting bootstrap's own state/plan output directly. |
| <a name="output_services_range_name"></a> [services\_range\_name](#output\_services\_range\_name) | Name of the secondary IP range used for GKE services |
| <a name="output_subnet_id"></a> [subnet\_id](#output\_subnet\_id) | Self link / ID of the GKE subnet |
| <a name="output_subnet_name"></a> [subnet\_name](#output\_subnet\_name) | Name of the GKE subnet |
<!-- END_TF_DOCS -->
