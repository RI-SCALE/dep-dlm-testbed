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
  description = "VPC network ID (from deploy/terraform/bootstrap's networking, as of this revision), for private IP"
  type        = string
}

variable "mysql_version" {
  description = "Cloud SQL MySQL version"
  type        = string
  default     = "MYSQL_8_4"
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
  description = "Enable binary logging for MySQL point-in-time recovery, when availability_type = ZONAL. Ignored when availability_type = REGIONAL — binary logging is forced on there regardless, since GCP requires it for MySQL HA and rejects instance creation without it."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Set false for ephemeral/test environments so terraform destroy can remove the instance without a manual override"
  type        = bool
  default     = false
}
