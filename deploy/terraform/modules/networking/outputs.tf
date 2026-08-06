output "network_id" {
  description = "Self link / ID of the VPC network"
  value       = google_compute_network.this.id
}

output "network_name" {
  description = "Name of the VPC network"
  value       = google_compute_network.this.name
}

output "subnet_id" {
  description = "Self link / ID of the GKE subnet"
  value       = google_compute_subnetwork.this.id
}

output "subnet_name" {
  description = "Name of the GKE subnet"
  value       = google_compute_subnetwork.this.name
}

output "pods_range_name" {
  description = "Name of the secondary IP range used for GKE pods"
  value       = google_compute_subnetwork.this.secondary_ip_range[0].range_name
}

output "services_range_name" {
  description = "Name of the secondary IP range used for GKE services"
  value       = google_compute_subnetwork.this.secondary_ip_range[1].range_name
}

output "private_vpc_connection" {
  description = "The private services access peering connection. Not consumed cross-state any longer (see modules/database's variables.tf) but kept as an output — still useful for anyone inspecting bootstrap's own state/plan output directly."
  value       = google_service_networking_connection.private_service_connection
}
