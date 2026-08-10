variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for the regional GKE cluster"
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to all kubernetes resource names (e.g. dep-dlm-staging)"
  type        = string
}

variable "network_id" {
  description = "VPC network ID (from deploy/terraform/bootstrap's networking, as of this revision)"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID (from deploy/terraform/bootstrap's networking, as of this revision)"
  type        = string
}

variable "pods_range_name" {
  description = "Secondary IP range name for pods (from deploy/terraform/bootstrap's networking, as of this revision)"
  type        = string
}

variable "services_range_name" {
  description = "Secondary IP range name for services (from deploy/terraform/bootstrap's networking, as of this revision)"
  type        = string
}

variable "release_channel" {
  description = "GKE release channel"
  type        = string
  default     = "REGULAR"
}

variable "deletion_protection" {
  description = "Set false for ephemeral/test environments so terraform destroy can remove the cluster without a manual override"
  type        = bool
  default     = false
}
