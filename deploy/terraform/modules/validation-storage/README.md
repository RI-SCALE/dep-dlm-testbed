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
| [google_compute_address.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_address) | resource |
| [google_compute_firewall.validation_storage_ingress](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_instance.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_instance) | resource |
| [google_project_iam_member.logging](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.monitoring](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_secret_manager_secret_iam_member.certs_access](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_iam_member) | resource |
| [google_service_account.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_certs_secret_id"></a> [certs\_secret\_id](#input\_certs\_secret\_id) | Full resource ID of the Secret Manager secret containing this host's cert/key pair + rucio\_ca.pem (JSON-encoded, same shape as module.secrets' certs secret) | `string` | n/a | yes |
| <a name="input_hostname"></a> [hostname](#input\_hostname) | Public DNS hostname this VM will be reachable at (e.g.<br/>validation-storage.dep-dlm-staging.example.com). Must resolve to the<br/>static IP this module reserves — DNS record creation is NOT handled by<br/>this module (out of scope: depends on the zone/registrar in use), set<br/>it manually or via a separate DNS module once the IP output is known. | `string` | n/a | yes |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix for all resources this module creates (e.g. dep-dlm-staging) | `string` | n/a | yes |
| <a name="input_network_id"></a> [network\_id](#input\_network\_id) | Self-link or ID of the VPC network to attach the VM(s) to | `string` | n/a | yes |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | GCP project ID | `string` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | GCP region for the static IP and any regional resources | `string` | n/a | yes |
| <a name="input_repo_root"></a> [repo\_root](#input\_repo\_root) | Absolute path to the repo root (e.g. path.root's parent, or an<br/>explicit path), used to locate shared/config/{xrootd,teapot} and<br/>shared/scripts/xrootd/docker-entrypoint.sh at plan time — these<br/>static config files are embedded into the VM's startup script via<br/>file(), the same content sandbox's compose stack already mounts. | `string` | n/a | yes |
| <a name="input_subnet_id"></a> [subnet\_id](#input\_subnet\_id) | Self-link or ID of the subnetwork to attach the VM(s) to | `string` | n/a | yes |
| <a name="input_labels"></a> [labels](#input\_labels) | Extra labels applied to all resources this module creates | `map(string)` | `{}` | no |
| <a name="input_machine_type"></a> [machine\_type](#input\_machine\_type) | GCE machine type for the validation-storage VM | `string` | `"e2-small"` | no |
| <a name="input_zone"></a> [zone](#input\_zone) | GCP zone for the VM(s). Defaults to europe-west3-b deliberately —<br/>europe-west3-a has shown repeated GCE scale-up/capacity failures<br/>during this project's own testing (see runbook notes); -b and -c<br/>have not. Override only if you've confirmed capacity in the target<br/>zone. | `string` | `"europe-west3-b"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_external_ip"></a> [external\_ip](#output\_external\_ip) | Public IP of the validation-storage VM — point var.hostname's DNS record at this |
| <a name="output_hostname"></a> [hostname](#output\_hostname) | Configured public hostname for this validation target (echoed back for convenience) |
| <a name="output_instance_name"></a> [instance\_name](#output\_instance\_name) | GCE instance name, for gcloud compute ssh / logs lookups |
| <a name="output_instance_self_link"></a> [instance\_self\_link](#output\_instance\_self\_link) | n/a |
| <a name="output_service_account_email"></a> [service\_account\_email](#output\_service\_account\_email) | n/a |
| <a name="output_teapot1_pfn_root"></a> [teapot1\_pfn\_root](#output\_teapot1\_pfn\_root) | Base PFN (https://...) for registering teapot1's WebDAV endpoint as a Rucio RSE protocol |
| <a name="output_teapot2_pfn_root"></a> [teapot2\_pfn\_root](#output\_teapot2\_pfn\_root) | Base PFN (https://...) for registering teapot2's WebDAV endpoint as a Rucio RSE protocol |
| <a name="output_xrd3_pfn_root"></a> [xrd3\_pfn\_root](#output\_xrd3\_pfn\_root) | Base PFN (root://...) for registering xrd3 as a Rucio RSE protocol |
| <a name="output_xrd4_pfn_root"></a> [xrd4\_pfn\_root](#output\_xrd4\_pfn\_root) | Base PFN (root://...) for registering xrd4 as a Rucio RSE protocol |
<!-- END_TF_DOCS -->
