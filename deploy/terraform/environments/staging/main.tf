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

# Declared after rucio_database/fts_database — not load-bearing for
# Terraform's own dependency graph (that's built from the module.*
# references below regardless of block order in this file), but reads
# more naturally now that secrets genuinely depends on both databases'
# outputs, not just kubernetes'.
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

  rucio_host = "http://${module.kubernetes.rucio_public_hostname}"
}

module "validation_storage" {
  source = "../../modules/validation-storage"

  project_id            = var.project_id
  region                = var.region
  zone                  = "europe-west3-b"
  network_id            = var.network_id
  subnet_id             = var.subnet_id
  name_prefix           = "dep-dlm-staging"
  terraform_ci_sa_email = "dep-dlm-terraform-ci@${var.project_id}.iam.gserviceaccount.com"

  hostname        = "valstorage.dep-dlm-staging.example.com"
  certs_secret_id = module.secrets.secret_ids["certs"]

  oidc_issuer       = var.oidc_issuer
  oidc_issuer_name  = var.oidc_issuer_name
  teapot_idp_name   = var.teapot_idp_name
  teapot_audiences  = var.teapot_audiences
  teapot_extra_subs = var.teapot_extra_subs

  repo_root = abspath("${path.module}/../../../..")

  labels = {
    environment = "staging"
    component   = "validation-storage"
  }
}
