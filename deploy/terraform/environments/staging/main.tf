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

module "kubernetes" {
  source = "../../modules/kubernetes"

  project_id          = var.project_id
  region              = var.region
  name_prefix         = local.name_prefix
  network_id          = var.network_id
  subnet_id           = var.subnet_id
  pods_range_name     = var.pods_range_name
  services_range_name = var.services_range_name
  deletion_protection = var.deletion_protection
}

module "secrets" {
  source = "../../modules/secrets"

  project_id                = var.project_id
  name_prefix               = local.name_prefix
  eso_service_account_email = module.kubernetes.eso_service_account_email
}

module "rucio_database" {
  source = "../../modules/database-postgres"

  project_id          = var.project_id
  region              = var.region
  name_prefix         = local.name_prefix
  network_id          = var.network_id
  deletion_protection = var.deletion_protection
  availability_type   = "ZONAL" # staging: cost over HA, per ADR-003's low-overhead driver
}

module "fts_database" {
  source = "../../modules/database-mysql"

  project_id          = var.project_id
  region              = var.region
  name_prefix         = local.name_prefix
  network_id          = var.network_id
  deletion_protection = var.deletion_protection
  availability_type   = "ZONAL"
}
