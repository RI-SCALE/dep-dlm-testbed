variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for the subnet"
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to all networking resource names (e.g. dep-dlm-staging)"
  type        = string
}

variable "subnet_cidr" {
  description = "Primary CIDR range for the GKE node subnet"
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary CIDR range for GKE pod IPs"
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "Secondary CIDR range for GKE service IPs"
  type        = string
  default     = "10.30.0.0/20"
}
