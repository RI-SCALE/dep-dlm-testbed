variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to all secret IDs (e.g. dep-dlm-staging)"
  type        = string
}

variable "secret_names" {
  description = "Logical secret names to create empty containers for (values provisioned out-of-band). Mirrors the sandbox's Vault seed categories: idpsecrets, certs, configs, patches, rucio, scripts."
  type        = list(string)
  default = [
    "idpsecrets",
    "certs",
    "configs",
    "patches",
    "rucio",
    "scripts",
  ]
}

variable "eso_service_account_email" {
  description = "Email of the GCP service account (from modules/kubernetes) that External Secrets Operator impersonates"
  type        = string
}
