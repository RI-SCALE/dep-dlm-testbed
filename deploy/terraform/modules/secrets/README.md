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
| [google_secret_manager_secret.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret) | resource |
| [google_secret_manager_secret_iam_member.eso_access](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_iam_member) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_eso_service_account_email"></a> [eso\_service\_account\_email](#input\_eso\_service\_account\_email) | Email of the GCP service account (from modules/kubernetes) that External Secrets Operator impersonates | `string` | n/a | yes |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix applied to all secret IDs (e.g. dep-dlm-staging) | `string` | n/a | yes |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | GCP project ID | `string` | n/a | yes |
| <a name="input_secret_names"></a> [secret\_names](#input\_secret\_names) | Logical secret names to create empty containers for (values provisioned out-of-band). Mirrors the sandbox's Vault seed categories: idpsecrets, certs, configs, patches, rucio, scripts. | `list(string)` | <pre>[<br/>  "idpsecrets",<br/>  "certs",<br/>  "configs",<br/>  "patches",<br/>  "rucio",<br/>  "scripts"<br/>]</pre> | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_secret_ids"></a> [secret\_ids](#output\_secret\_ids) | Map of logical secret name -> full Secret Manager secret ID |
<!-- END_TF_DOCS -->
