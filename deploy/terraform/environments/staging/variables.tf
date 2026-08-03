variable "project_id" {
  description = "GCP project ID for the staging environment (from deploy/terraform/bootstrap output project_ids.staging)"
  type        = string
}

variable "region" {
  description = "GCP region — must match deploy/terraform/bootstrap output regions.staging exactly (that's now the single source of truth for this environment's region, since networking and the GKE cluster must agree). No default, deliberately — an independent default here was a latent drift risk against bootstrap's own default."
  type        = string
}

variable "network_id" {
  description = "VPC network ID from deploy/terraform/bootstrap output network_ids.staging"
  type        = string
}

variable "subnet_id" {
  description = "GKE subnet ID from deploy/terraform/bootstrap output subnet_ids.staging"
  type        = string
}

variable "pods_range_name" {
  description = "Secondary IP range name for GKE pods, from deploy/terraform/bootstrap output pods_range_names.staging"
  type        = string
}

variable "services_range_name" {
  description = "Secondary IP range name for GKE services, from deploy/terraform/bootstrap output services_range_names.staging"
  type        = string
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
