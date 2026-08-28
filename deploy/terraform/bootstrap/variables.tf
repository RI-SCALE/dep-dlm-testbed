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
    bootstrap for itself. Whoever applies this module needs roles/billing.user
    on this specific billing account (checked by the provider on every
    plan/apply, not just once).
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
  description = <<-EOT
    Project-level roles granted to each environment's dep-dlm-terraform-ci
    service account. Uses roles/compute.networkUser rather than
    roles/compute.networkAdmin — a deliberate tightening made possible by
    moving VPC/subnet/peering creation into THIS module (bootstrap runs as
    a human's own org-level identity, not this service account).
    environments/<env>'s CI identity now only ever ATTACHES resources
    (GKE cluster, Cloud SQL) to an already-existing network; it never
    creates/modifies/deletes network resources itself, so it no longer
    needs networkAdmin's broader create/delete rights — networkUser (attach
    to an existing network) is the correct minimum. Revert to networkAdmin
    only if environments/<env> ever needs to manage networking directly
    again.
  EOT
  type        = list(string)
  default = [
    "roles/container.admin",
    "roles/compute.networkUser",
    "roles/compute.viewer",
    "roles/compute.loadBalancerAdmin",
    "roles/cloudsql.admin",
    "roles/secretmanager.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/servicenetworking.networksAdmin",
    "roles/storage.admin",
    "roles/compute.instanceAdmin.v1",
    "roles/compute.securityAdmin",
    "roles/resourcemanager.projectIamAdmin",
  ]
}

variable "environments" {
  description = <<-EOT
    Environments to bootstrap a GCP Project (and now VPC/subnet/networking)
    for. `deletion_policy` maps straight to google_project's own field:
    "DELETE" is fine for a disposable/trial staging project, "PREVENT"
    (the safer default) stops `terraform destroy` from silently deleting a
    project outright. `region` is now the SINGLE source of truth for that
    environment's networking AND its GKE cluster's region — environments/
    <env> receives it as a required input rather than independently
    defaulting it, to remove the drift risk of two places disagreeing.
  EOT
  type = list(object({
    name            = string
    deletion_policy = optional(string, "PREVENT")
    region          = optional(string, "europe-west3") # Frankfurt; revisit per ADR-003 Open Points
  }))
  default = [
    { name = "staging", deletion_policy = "DELETE" },
    { name = "production", deletion_policy = "PREVENT" },
  ]
}

variable "os_login_admins" {
  description = <<-EOT
    Users granted roles/compute.osAdminLogin (sudo-capable OS Login) on
    every environment project — for humans who need to SSH into
    validation-storage or other VMs for debugging. Not the same as
    terraform_ci's service account access; this is direct human IAM.
  EOT
  type        = list(string)
  default     = ["marvin.gajek@cern.ch"]
}
