variable "project_id" {
  description = "GCP project ID for the production environment — must be a DIFFERENT project than staging, not a var flip on the same one"
  type        = string
}

variable "region" {
  description = "GCP region — pick per adr-003's still-open region-selection follow-on before this is anything but a placeholder default"
  type        = string
  default     = "europe-west3"
}

variable "environment" {
  description = "Environment name, used to derive resource name prefixes"
  type        = string
  default     = "production"
}

variable "deletion_protection" {
  description = "Should default true for production once this environment is actually used — left false here only because this whole environment is an unvalidated placeholder"
  type        = bool
  default     = false
}
