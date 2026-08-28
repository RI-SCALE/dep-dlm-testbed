<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.7 |
| <a name="requirement_google"></a> [google](#requirement\_google) | ~> 5.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.6 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_google"></a> [google](#provider\_google) | 5.45.2 |
| <a name="provider_random"></a> [random](#provider\_random) | 3.9.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_networking"></a> [networking](#module\_networking) | ../modules/networking | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [google_compute_project_metadata_item.enable_oslogin](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_project_metadata_item) | resource |
| [google_iam_workload_identity_pool.github](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/iam_workload_identity_pool) | resource |
| [google_iam_workload_identity_pool_provider.github](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/iam_workload_identity_pool_provider) | resource |
| [google_project.env](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project) | resource |
| [google_project_iam_member.os_login_admins](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_iam_member.terraform_ci_roles](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_project_service.apis](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_service) | resource |
| [google_service_account.terraform_ci](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account_iam_member.github_wif_binding](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_service_account_iam_member.terraform_ci_compute_sa_user](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_member) | resource |
| [google_storage_bucket.tf_state](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket) | resource |
| [google_storage_bucket_iam_member.tf_state_ci_access](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket_iam_member) | resource |
| [random_id.suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_billing_account_id"></a> [billing\_account\_id](#input\_billing\_account\_id) | GCP Billing Account ID (format XXXXXX-XXXXXX-XXXXXX) every environment<br/>project is linked to. This is the one value in this whole module that<br/>traces back to a genuine manual commercial precondition — Cloud<br/>Billing account creation/enrollment isn't something google\_project can<br/>bootstrap for itself. Whoever applies this module needs roles/billing.user<br/>on this specific billing account (checked by the provider on every<br/>plan/apply, not just once). | `string` | n/a | yes |
| <a name="input_github_repo"></a> [github\_repo](#input\_github\_repo) | GitHub org/repo the Workload Identity Federation provider trusts (format org/repo). Scoped via attribute\_condition so no other repo can mint tokens these providers accept. | `string` | n/a | yes |
| <a name="input_environments"></a> [environments](#input\_environments) | Environments to bootstrap a GCP Project (and now VPC/subnet/networking)<br/>for. `deletion_policy` maps straight to google\_project's own field:<br/>"DELETE" is fine for a disposable/trial staging project, "PREVENT"<br/>(the safer default) stops `terraform destroy` from silently deleting a<br/>project outright. `region` is now the SINGLE source of truth for that<br/>environment's networking AND its GKE cluster's region — environments/<br/><env> receives it as a required input rather than independently<br/>defaulting it, to remove the drift risk of two places disagreeing. | <pre>list(object({<br/>    name            = string<br/>    deletion_policy = optional(string, "PREVENT")<br/>    region          = optional(string, "europe-west3") # Frankfurt; revisit per ADR-003 Open Points<br/>  }))</pre> | <pre>[<br/>  {<br/>    "deletion_policy": "DELETE",<br/>    "name": "staging"<br/>  },<br/>  {<br/>    "deletion_policy": "PREVENT",<br/>    "name": "production"<br/>  }<br/>]</pre> | no |
| <a name="input_folder_id"></a> [folder\_id](#input\_folder\_id) | Numeric GCP folder ID new environment projects are created under, instead of directly under the organization. Mutually exclusive with org\_id. | `string` | `null` | no |
| <a name="input_org_id"></a> [org\_id](#input\_org\_id) | Numeric GCP organization ID new environment projects are created under. Mutually exclusive with folder\_id — GCP only allows one parent type per project. | `string` | `null` | no |
| <a name="input_os_login_admins"></a> [os\_login\_admins](#input\_os\_login\_admins) | Users granted roles/compute.osAdminLogin (sudo-capable OS Login) on<br/>every environment project — for humans who need to SSH into<br/>validation-storage or other VMs for debugging. Not the same as<br/>terraform\_ci's service account access; this is direct human IAM. | `list(string)` | <pre>[<br/>  "marvin.gajek@cern.ch"<br/>]</pre> | no |
| <a name="input_state_bucket_location"></a> [state\_bucket\_location](#input\_state\_bucket\_location) | GCS location for each environment's Terraform state bucket (the ones this module creates FOR environments/<env> — distinct from this module's own bootstrap-state bucket, which is hand-seeded, see backend.tf). | `string` | `"EU"` | no |
| <a name="input_terraform_ci_roles"></a> [terraform\_ci\_roles](#input\_terraform\_ci\_roles) | Project-level roles granted to each environment's dep-dlm-terraform-ci<br/>service account. Uses roles/compute.networkUser rather than<br/>roles/compute.networkAdmin — a deliberate tightening made possible by<br/>moving VPC/subnet/peering creation into THIS module (bootstrap runs as<br/>a human's own org-level identity, not this service account).<br/>environments/<env>'s CI identity now only ever ATTACHES resources<br/>(GKE cluster, Cloud SQL) to an already-existing network; it never<br/>creates/modifies/deletes network resources itself, so it no longer<br/>needs networkAdmin's broader create/delete rights — networkUser (attach<br/>to an existing network) is the correct minimum. Revert to networkAdmin<br/>only if environments/<env> ever needs to manage networking directly<br/>again. | `list(string)` | <pre>[<br/>  "roles/container.admin",<br/>  "roles/compute.networkUser",<br/>  "roles/compute.viewer",<br/>  "roles/compute.loadBalancerAdmin",<br/>  "roles/cloudsql.admin",<br/>  "roles/secretmanager.admin",<br/>  "roles/iam.serviceAccountAdmin",<br/>  "roles/servicenetworking.networksAdmin",<br/>  "roles/storage.admin",<br/>  "roles/compute.instanceAdmin.v1",<br/>  "roles/compute.securityAdmin",<br/>  "roles/resourcemanager.projectIamAdmin"<br/>]</pre> | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_network_ids"></a> [network\_ids](#output\_network\_ids) | Map of environment name -> VPC network ID. Feed into environments/<env>/terraform.tfvars' network\_id. |
| <a name="output_pods_range_names"></a> [pods\_range\_names](#output\_pods\_range\_names) | Map of environment name -> secondary IP range name for GKE pods. Feed into environments/<env>/terraform.tfvars' pods\_range\_name. |
| <a name="output_project_ids"></a> [project\_ids](#output\_project\_ids) | Map of environment name -> created project\_id. Feed into environments/<env>/terraform.tfvars' project\_id. |
| <a name="output_regions"></a> [regions](#output\_regions) | Map of environment name -> region (single source of truth, also used for that environment's networking). Feed into environments/<env>/terraform.tfvars' region. |
| <a name="output_services_range_names"></a> [services\_range\_names](#output\_services\_range\_names) | Map of environment name -> secondary IP range name for GKE services. Feed into environments/<env>/terraform.tfvars' services\_range\_name. |
| <a name="output_state_buckets"></a> [state\_buckets](#output\_state\_buckets) | Map of environment name -> GCS bucket name for that environment's own Terraform state. Feed into environments/<env>'s `terraform init -backend-config=bucket=...` (and the TF\_STATE\_BUCKET repo variable each environment's CI workflow already reads). |
| <a name="output_subnet_ids"></a> [subnet\_ids](#output\_subnet\_ids) | Map of environment name -> GKE subnet ID. Feed into environments/<env>/terraform.tfvars' subnet\_id. |
| <a name="output_terraform_ci_emails"></a> [terraform\_ci\_emails](#output\_terraform\_ci\_emails) | Map of environment name -> dep-dlm-terraform-ci service account email. Feed into each GitHub Actions workflow's google-github-actions/auth step (`service_account:`). |
| <a name="output_workload_identity_providers"></a> [workload\_identity\_providers](#output\_workload\_identity\_providers) | Map of environment name -> full Workload Identity Federation provider resource name. Feed into each GitHub Actions workflow's google-github-actions/auth step (`workload_identity_provider:`). |
<!-- END_TF_DOCS -->
