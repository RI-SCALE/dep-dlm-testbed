output "cluster_name" {
  description = "Name of the GKE cluster"
  value       = google_container_cluster.this.name
}

output "cluster_endpoint" {
  description = "API server endpoint (sensitive-adjacent — treat kubeconfig generation with care)"
  value       = google_container_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate"
  value       = google_container_cluster.this.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "workload_pool" {
  description = "Workload Identity pool (<project>.svc.id.goog)"
  value       = google_container_cluster.this.workload_identity_config[0].workload_pool
}

output "eso_service_account_email" {
  description = "GCP service account email ESO's k8s ServiceAccount impersonates"
  value       = google_service_account.eso.email
}
