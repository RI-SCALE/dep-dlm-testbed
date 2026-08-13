variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to all secret IDs (e.g. dep-dlm-staging)"
  type        = string
}

variable "secret_names" {
  description = "Logical secret names to create empty containers for (values provisioned out-of-band)."
  type        = list(string)
  default = [
    "certs",
    "secrets",
  ]
}

variable "eso_service_account_email" {
  description = "Email of the GCP service account (from modules/kubernetes) that External Secrets Operator impersonates"
  type        = string
}

# --- Inputs for rendered secret content (rucio.cfg, fts3config, etc.) ----
# Wire these from environments/<env>/main.tf using the OTHER modules'
# outputs already available in that scope:
#   rucio_db_host        = module.rucio_database.private_ip_address
#   rucio_db_password    = module.rucio_database.rucio_db_password
#   fts_db_host           = module.fts_database.private_ip_address
#   fts_db_password        = module.fts_database.fts_db_password
#   token_mode             = var.token_mode (new var on environments/<env> —
#                             mirrors the sandbox's existing TOKEN_MODE
#                             concept; add with a default of "managed")

variable "rucio_db_host" {
  description = "Private IP of the rucio Cloud SQL instance (module.rucio_database.private_ip_address)"
  type        = string
}

variable "rucio_db_password" {
  description = "rucio DB user password (module.rucio_database.rucio_db_password) — sensitive, lands in this module's plan/state same as the password itself already does upstream"
  type        = string
  sensitive   = true
}

variable "rucio_host" {
  description = "Base URL the rucio client/auth host point at"
  type        = string
  default     = "http://rucio-server"
}

variable "bootstrap_userpass_pwd" {
  description = "Bootstrap ddmlab userpass password baked into rucio.cfg's [client]/[bootstrap] sections"
  type        = string
  sensitive   = true
}

variable "oidc_issuer" {
  description = "OIDC issuer URL shared by rucio.cfg, fts3config and idpsecrets.json"
  type        = string
}

variable "oidc_client_id" {
  description = "OIDC client ID owned by idpsecrets.json"
  type        = string
}

variable "oidc_client_secret" {
  description = "OIDC client secret owned by idpsecrets.json"
  type        = string
  sensitive   = true
}

variable "token_mode" {
  description = "managed (exchange, FTS manages token lifecycle) | unmanaged (client_credentials, AllowNonManagedTokens=True) — mirrors the sandbox's TOKEN_MODE"
  type        = string
  default     = "managed"
  validation {
    condition     = contains(["managed", "unmanaged"], var.token_mode)
    error_message = "token_mode must be 'managed' or 'unmanaged'."
  }
}

variable "site_name" {
  description = "FTS SiteName / rucio SiteName-equivalent"
  type        = string
  default     = "DOCKER"
}

variable "fts_db_host" {
  description = "Private IP of the fts Cloud SQL (MySQL) instance (module.fts_database.private_ip_address)"
  type        = string
}

variable "fts_db_password" {
  description = "fts DB user password (module.fts_database.fts_db_password) — sensitive"
  type        = string
  sensitive   = true
}

variable "fts3rest_log_level" {
  description = "Apache LogLevel for the fts3rest vhost (fts3restconfig). Defaults to the sandbox's current 'debug' — tighten for production once past validation."
  type        = string
  default     = "debug"
}
