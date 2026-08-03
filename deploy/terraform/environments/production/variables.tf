variable "project_id" {
  description = "GCP project ID for the production environment (from deploy/terraform/bootstrap output project_ids.production) — must be a DIFFERENT project than staging, not a var flip on the same one"
  type        = string
}

variable "region" {
  description = "GCP region — must match deploy/terraform/bootstrap output regions.production exactly. No default, deliberately — see environments/staging/variables.tf's identical note."
  type        = string
}

variable "network_id" {
  description = "VPC network ID from deploy/terraform/bootstrap output network_ids.production"
  type        = string
}

variable "subnet_id" {
  description = "GKE subnet ID from deploy/terraform/bootstrap output subnet_ids.production"
  type        = string
}

variable "pods_range_name" {
  description = "Secondary IP range name for GKE pods, from deploy/terraform/bootstrap output pods_range_names.production"
  type        = string
}

variable "services_range_name" {
  description = "Secondary IP range name for GKE services, from deploy/terraform/bootstrap output services_range_names.production"
  type        = string
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
