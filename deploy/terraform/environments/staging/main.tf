# environments/staging
#
# Root module for the staging environment. Wires networking -> kubernetes
# -> secrets -> database per docs/diagrams/staging-gcp.py and
# docs/adrs/adr-003-staging-cloud-provider.md.
#
# This module intentionally does NOT deploy Rucio/FTS/ESO themselves —
# that remains GitOps-managed (Argo CD/Flux), out of Terraform's scope,
# matching the ADR's stated boundary: Terraform provisions the resource
# group's infrastructure, GitOps converges the workload layer inside it.

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
  availability_type       = "ZONAL" # staging: cost over HA, per ADR-003's low-overhead driver
}
