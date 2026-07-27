# environments/production
#
# NOT YET VALIDATED — placeholder mirroring environments/staging's module
# wiring. Per docs/adrs/adr-003-staging-cloud-provider.md, staging must
# converge first; this exists so the environment/module split is visible
# from the start rather than bolted on later, not because production is
# ready to apply.
#
# Known deltas from staging before this is real (non-exhaustive):
#   - deletion_protection should default true
#   - database availability_type should be REGIONAL, not ZONAL
#   - region/project_id are a SEPARATE GCP project, not a var flip on the
#     same one — production and staging must not share a project
#   - secrets module's IAM should almost certainly be tighter than
#     "same service account, same roles" once real access patterns exist

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

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  name_prefix = "dep-dlm-${var.environment}"
}

module "networking" {
  source = "../../modules/networking"

  project_id  = var.project_id
  region      = var.region
  name_prefix = local.name_prefix
}

module "kubernetes" {
  source = "../../modules/kubernetes"

  project_id           = var.project_id
  region                = var.region
  name_prefix           = local.name_prefix
  network_id            = module.networking.network_id
  subnet_id             = module.networking.subnet_id
  pods_range_name       = module.networking.pods_range_name
  services_range_name   = module.networking.services_range_name
  deletion_protection   = var.deletion_protection
}

module "secrets" {
  source = "../../modules/secrets"

  project_id                = var.project_id
  name_prefix                = local.name_prefix
  eso_service_account_email  = module.kubernetes.eso_service_account_email
}

module "database" {
  source = "../../modules/database"

  project_id              = var.project_id
  region                  = var.region
  name_prefix             = local.name_prefix
  network_id              = module.networking.network_id
  private_vpc_connection  = module.networking.private_vpc_connection
  deletion_protection     = var.deletion_protection
  availability_type       = "REGIONAL" # production: HA over cost, unlike staging
}
