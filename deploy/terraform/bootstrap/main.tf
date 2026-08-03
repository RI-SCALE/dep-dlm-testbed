terraform {
  required_version = ">= 1.7"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "google" {}

locals {
  environments = { for e in var.environments : e.name => e }

  required_apis = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "secretmanager.googleapis.com",
    "sqladmin.googleapis.com",
    "servicenetworking.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "sts.googleapis.com",
  ]
}

# --- Projects ----------------------------------------------------------

resource "random_id" "suffix" {
  for_each    = local.environments
  byte_length = 4
}

resource "google_project" "env" {
  for_each = local.environments

  name            = "dep-dlm-${each.key}"
  project_id      = "dep-dlm-${each.key}-${random_id.suffix[each.key].hex}"
  org_id          = var.org_id
  folder_id       = var.folder_id
  billing_account = var.billing_account_id

  deletion_policy = each.value.deletion_policy
}

# --- API activation ------------------------------------------------------
resource "google_project_service" "apis" {
  for_each = {
    for pair in setproduct(keys(local.environments), local.required_apis) :
    "${pair[0]}.${pair[1]}" => { env = pair[0], api = pair[1] }
  }

  project = google_project.env[each.value.env].project_id
  service = each.value.api

  disable_dependent_services = false
  disable_on_destroy         = false # never turn off APIs on `terraform destroy` — see top-level README's Teardown section on why bucket/API deletion stay out of the routine path
}

# --- Per-environment Terraform CI service account -----------------------
resource "google_service_account" "terraform_ci" {
  for_each = local.environments

  project      = google_project.env[each.key].project_id
  account_id   = "dep-dlm-terraform-ci"
  display_name = "Terraform CI (GitHub Actions) - ${each.key}"

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "terraform_ci_roles" {
  for_each = {
    for pair in setproduct(keys(local.environments), var.terraform_ci_roles) :
    "${pair[0]}.${pair[1]}" => { env = pair[0], role = pair[1] }
  }

  project = google_project.env[each.value.env].project_id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.terraform_ci[each.value.env].email}"
}

# GKE Autopilot node VMs run under the project's default compute SA — the
# CI identity needs iam.serviceAccountUser ON THAT SPECIFIC SA, a
# per-service-account binding distinct from the project-level roles above
# (mirrors setup-workload-identity.sh's own comment on why this is a
# separate gcloud subcommand there, and a separate resource type here).
resource "google_service_account_iam_member" "terraform_ci_compute_sa_user" {
  for_each = local.environments

  service_account_id = "projects/${google_project.env[each.key].project_id}/serviceAccounts/${google_project.env[each.key].number}-compute@developer.gserviceaccount.com"
  role                = "roles/iam.serviceAccountUser"
  member              = "serviceAccount:${google_service_account.terraform_ci[each.key].email}"

  depends_on = [google_project_service.apis]
}

# --- Workload Identity Federation (GitHub Actions -> GCP, no stored key) -

resource "google_iam_workload_identity_pool" "github" {
  for_each = local.environments

  project                   = google_project.env[each.key].project_id
  workload_identity_pool_id = "github-actions-pool"
  display_name              = "GitHub Actions"

  depends_on = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  for_each = local.environments

  project                            = google_project.env[each.key].project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github[each.key].workload_identity_pool_id
  workload_identity_pool_provider_id = "github-actions-provider"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }
  # Scoped to this specific repo — without this, any repo in the GitHub
  # org could mint tokens this provider accepts.
  attribute_condition = "assertion.repository=='${var.github_repo}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "github_wif_binding" {
  for_each = local.environments

  service_account_id = google_service_account.terraform_ci[each.key].name
  role                = "roles/iam.workloadIdentityUser"
  member              = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github[each.key].name}/attribute.repository/${var.github_repo}"
}

# --- Per-environment remote-state bucket ---------------------------------
# The bucket environments/<env>'s OWN backend.tf points at. Distinct from
# THIS module's bootstrap-state bucket (hand-seeded once, see backend.tf) —
# this one is real Terraform-managed infrastructure like everything else
# above, so environments/<env> never has to self-provision the bucket it's
# about to store its own state in (previously a manual `gcloud storage
# buckets create` step in the top-level README's Prerequisites).
resource "google_storage_bucket" "tf_state" {
  for_each = local.environments

  project                     = google_project.env[each.key].project_id
  name                        = "dep-dlm-tfstate-${each.key}-${google_project.env[each.key].project_id}"
  location                    = var.state_bucket_location
  uniform_bucket_level_access = true
  force_destroy               = false # state history should survive a careless destroy of other resources

  versioning {
    enabled = true
  }

  depends_on = [google_project_service.apis]
}

resource "google_storage_bucket_iam_member" "tf_state_ci_access" {
  for_each = local.environments

  bucket = google_storage_bucket.tf_state[each.key].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.terraform_ci[each.key].email}"
}
