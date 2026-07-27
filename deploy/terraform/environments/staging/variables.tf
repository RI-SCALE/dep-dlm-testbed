variable "project_id" {
  description = "GCP project ID for the staging environment"
  type        = string
}

variable "region" {
  description = "GCP region — pick per adr-003's still-open region-selection follow-on before this is anything but a placeholder default"
  type        = string
  default     = "europe-west3" # Frankfurt; revisit per ADR-003 Open Points
}

variable "environment" {
  description = "Environment name, used to derive resource name prefixes"
  type        = string
  default     = "staging"
}

variable "deletion_protection" {
  description = "Keep false for staging so environments can be torn down freely; override per the low-maintenance, ephemeral-environment driver in ADR-003"
  type        = bool
  default     = false
}
