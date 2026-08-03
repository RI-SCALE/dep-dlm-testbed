variable "org_id" {
  description = "Numeric GCP organization ID new environment projects are created under. Mutually exclusive with folder_id — GCP only allows one parent type per project."
  type        = string
  default     = null
}

variable "folder_id" {
  description = "Numeric GCP folder ID new environment projects are created under, instead of directly under the organization. Mutually exclusive with org_id."
  type        = string
  default     = null
}

variable "billing_account_id" {
  description = <<-EOT
    GCP Billing Account ID (format XXXXXX-XXXXXX-XXXXXX) every environment
    project is linked to. This is the one value in this whole module that
    traces back to a genuine manual commercial precondition — Cloud
    Billing account creation/enrollment isn't something google_project can
    bootstrap for itself, the same way an Azure EA/MCA enrollment isn't
    something azurerm_subscription can bootstrap for itself. Whoever
    applies this module needs roles/billing.user on this specific billing
    account (checked by the provider on every plan/apply, not just once).
  EOT
  type        = string
}

variable "github_repo" {
  description = "GitHub org/repo the Workload Identity Federation provider trusts (format org/repo). Scoped via attribute_condition so no other repo can mint tokens these providers accept."
  type        = string
}

variable "state_bucket_location" {
  description = "GCS location for each environment's Terraform state bucket (the ones this module creates FOR environments/<env> — distinct from this module's own bootstrap-state bucket, which is hand-seeded, see backend.tf)."
  type        = string
  default     = "EU"
}

variable "terraform_ci_roles" {
  description = "Project-level roles granted to each environment's dep-dlm-terraform-ci service account. Mirrors setup-workload-identity.sh's ROLES default — kept in sync manually since that script remains available as a manual fallback (see scripts/setup-workload-identity.sh's updated header)."
  type        = list(string)
  default = [
    "roles/container.admin",
    "roles/compute.networkAdmin",
    "roles/cloudsql.admin",
    "roles/secretmanager.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/servicenetworking.networksAdmin",
    "roles/storage.admin",
  ]
}

variable "environments" {
  description = <<-EOT
    Environments to bootstrap a GCP Project for. `deletion_policy` maps
    straight to google_project's own field: "DELETE" is fine for a
    disposable/trial staging project, "PREVENT" (the safer default) stops
    `terraform destroy` from silently deleting a project outright — use
    the existing per-resource `deletion_protection` variables inside
    environments/<env> for tearing down the resources INSIDE a project
    instead, which is the normal teardown path (see the top-level
    README's Teardown section).
  EOT
  type = list(object({
    name            = string
    deletion_policy = optional(string, "PREVENT")
  }))
  default = [
    { name = "staging", deletion_policy = "DELETE" },
    { name = "production", deletion_policy = "PREVENT" },
  ]
}
