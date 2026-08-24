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

module "rucio_database" {
  source = "../../modules/database-postgres"

  project_id          = var.project_id
  region              = var.region
  name_prefix         = local.name_prefix
  network_id          = var.network_id
  deletion_protection = var.deletion_protection
  availability_type   = "REGIONAL" # production: HA over cost, unlike staging
}

module "fts_database" {
  source = "../../modules/database-mysql"

  project_id          = var.project_id
  region              = var.region
  name_prefix         = local.name_prefix
  network_id          = var.network_id
  deletion_protection = var.deletion_protection
  availability_type   = "REGIONAL"
}

module "secrets" {
  source = "../../modules/secrets"

  project_id                = var.project_id
  name_prefix               = local.name_prefix
  eso_service_account_email = module.kubernetes.eso_service_account_email

  rucio_db_host     = module.rucio_database.private_ip_address
  rucio_db_password = module.rucio_database.rucio_db_password
  fts_db_host       = module.fts_database.private_ip_address
  fts_db_password   = module.fts_database.fts_db_password

  bootstrap_userpass_pwd = var.bootstrap_userpass_pwd
  userpass_password      = var.userpass_password
  oidc_issuer            = var.oidc_issuer
  oidc_client_id         = var.oidc_client_id
  oidc_client_secret     = var.oidc_client_secret
  oidc_expected_scope    = var.oidc_expected_scope
  token_mode             = var.token_mode
  storage_ip             = module.validation_storage.external_ip

  rucio_host = "http://${module.kubernetes.rucio_public_hostname}"
}
