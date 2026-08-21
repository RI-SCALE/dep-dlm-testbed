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
| [google_secret_manager_secret_version.certs](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_version) | resource |
| [google_secret_manager_secret_version.secrets](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/secret_manager_secret_version) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_bootstrap_userpass_pwd"></a> [bootstrap\_userpass\_pwd](#input\_bootstrap\_userpass\_pwd) | Bootstrap ddmlab userpass password baked into rucio.cfg's [client]/[bootstrap] sections | `string` | n/a | yes |
| <a name="input_eso_service_account_email"></a> [eso\_service\_account\_email](#input\_eso\_service\_account\_email) | Email of the GCP service account (from modules/kubernetes) that External Secrets Operator impersonates | `string` | n/a | yes |
| <a name="input_fts_db_host"></a> [fts\_db\_host](#input\_fts\_db\_host) | Private IP of the fts Cloud SQL (MySQL) instance (module.fts\_database.private\_ip\_address) | `string` | n/a | yes |
| <a name="input_fts_db_password"></a> [fts\_db\_password](#input\_fts\_db\_password) | fts DB user password (module.fts\_database.fts\_db\_password) — sensitive | `string` | n/a | yes |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix applied to all secret IDs (e.g. dep-dlm-staging) | `string` | n/a | yes |
| <a name="input_oidc_client_id"></a> [oidc\_client\_id](#input\_oidc\_client\_id) | OIDC client ID owned by idpsecrets.json | `string` | n/a | yes |
| <a name="input_oidc_client_secret"></a> [oidc\_client\_secret](#input\_oidc\_client\_secret) | OIDC client secret owned by idpsecrets.json | `string` | n/a | yes |
| <a name="input_oidc_issuer"></a> [oidc\_issuer](#input\_oidc\_issuer) | OIDC issuer URL shared by rucio.cfg, fts3config and idpsecrets.json | `string` | n/a | yes |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | GCP project ID | `string` | n/a | yes |
| <a name="input_rucio_db_host"></a> [rucio\_db\_host](#input\_rucio\_db\_host) | Private IP of the rucio Cloud SQL instance (module.rucio\_database.private\_ip\_address) | `string` | n/a | yes |
| <a name="input_rucio_db_password"></a> [rucio\_db\_password](#input\_rucio\_db\_password) | rucio DB user password (module.rucio\_database.rucio\_db\_password) — sensitive, lands in this module's plan/state same as the password itself already does upstream | `string` | n/a | yes |
| <a name="input_oidc_client_account"></a> [oidc\_client\_account](#input\_oidc\_client\_account) | Rucio account oidc-client.cfg authenticates as for interactive CLI use (rucio whoami/upload/download). Distinct from rucio.cfg's [client] account (root, used for internal bootstrap/admin calls). | `string` | `"randomaccount"` | no |
| <a name="input_oidc_expected_scope"></a> [oidc\_expected\_scope](#input\_oidc\_expected\_scope) | Space-separated scope string rucio.cfg's [oidc] expected\_scope validates incoming tokens against. Must match what idpsecrets.json's capabilities.scope\_map actually produces for this issuer (e.g. EGI: 'storage.read:/ storage.modify:/' if scope\_map keys are used as-is, or 'read:/ write:/' if scope\_map remaps them — check the issuer's idpsecrets.json before overriding). Differs per OIDC profile the same way oidc\_issuer does. | `string` | `"openid offline_access storage.read:/ storage.modify:/"` | no |
| <a name="input_rucio_host"></a> [rucio\_host](#input\_rucio\_host) | Base URL the rucio client/auth host point at | `string` | `"http://rucio-server"` | no |
| <a name="input_secret_names"></a> [secret\_names](#input\_secret\_names) | Logical secret names to create empty containers for (values provisioned out-of-band). | `list(string)` | <pre>[<br/>  "certs",<br/>  "secrets"<br/>]</pre> | no |
| <a name="input_site_name"></a> [site\_name](#input\_site\_name) | FTS SiteName / rucio SiteName-equivalent | `string` | `"DOCKER"` | no |
| <a name="input_token_mode"></a> [token\_mode](#input\_token\_mode) | managed (exchange, FTS manages token lifecycle) \| unmanaged (client\_credentials, AllowNonManagedTokens=True) — mirrors the sandbox's TOKEN\_MODE | `string` | `"managed"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_secret_ids"></a> [secret\_ids](#output\_secret\_ids) | Map of logical secret name -> full Secret Manager secret resource name (projects/<project>/secrets/<id>). Uses .id, not .secret\_id, so it's directly usable as-is in access\_secret\_version() calls — same attribute every secret\_version resource in this module already references. |
<!-- END_TF_DOCS -->
