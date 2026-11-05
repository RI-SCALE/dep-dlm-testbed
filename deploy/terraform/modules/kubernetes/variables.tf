variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "zone" {
  description = "GCP zone for the zonal GKE cluster and its node pool (e.g. europe-west3-b)"
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

# Node pool (defaults suit staging: one fixed node)

variable "machine_type" {
  description = "Machine type of the node pool"
  type        = string
  default     = "e2-standard-4"
}

variable "disk_size_gb" {
  description = "Boot disk size per node in GB"
  type        = number
  default     = 50
}

variable "autoscaling_enabled" {
  description = "Enable the node pool autoscaler (production). When false, the pool has exactly node_count nodes (staging)."
  type        = bool
  default     = false
}

variable "node_count" {
  description = "Fixed number of nodes when autoscaling is disabled"
  type        = number
  default     = 1
}

variable "min_node_count" {
  description = "Minimum nodes when autoscaling is enabled; also the initial size"
  type        = number
  default     = 2
}

variable "max_node_count" {
  description = "Maximum nodes when autoscaling is enabled"
  type        = number
  default     = 4

  validation {
    condition     = var.max_node_count >= var.min_node_count
    error_message = "max_node_count must be >= min_node_count."
  }
}
