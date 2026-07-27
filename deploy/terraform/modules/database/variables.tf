variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for the Cloud SQL instance"
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to the instance name (e.g. dep-dlm-staging)"
  type        = string
}

variable "network_id" {
  description = "VPC network ID from modules/networking, for private IP"
  type        = string
}

variable "private_vpc_connection" {
  description = "The private services access connection from modules/networking — passed through purely to create an explicit dependency"
  type        = any
}

variable "postgres_version" {
  description = "Cloud SQL PostgreSQL version"
  type        = string
  default     = "POSTGRES_16"
}

variable "tier" {
  description = "Cloud SQL machine tier. Small default suits a staging/test-cadence workload; size up for anything closer to production load."
  type        = string
  default     = "db-custom-2-7680" # 2 vCPU, 7.5GB RAM
}

variable "availability_type" {
  description = "ZONAL for cost-efficient staging; REGIONAL for production HA"
  type        = string
  default     = "ZONAL"
}

variable "point_in_time_recovery" {
  description = "Enable PITR (requires ZONAL or REGIONAL with binary logging support)"
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Set false for ephemeral/test environments so terraform destroy can remove the instance without a manual override"
  type        = bool
  default     = false
}
