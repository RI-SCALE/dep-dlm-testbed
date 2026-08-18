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

output "gateway_static_ip" {
  description = "Reserved external IP for the public Gateway (rucio-server/fts). Referenced by the Gateway manifest's spec.addresses (NamedAddress) and by the reachability smoke test."
  value       = google_compute_global_address.gateway.address
}

output "rucio_public_hostname" {
  description = "Host header the public Gateway uses to route to rucio-server. Not a real, DNS-registered domain — .example.com is RFC 2606-reserved for exactly this use, since no DNS record or registered RSE is required for this reachability check."
  value       = "rucio.${var.name_prefix}.example.com"
}

output "fts_public_hostname" {
  description = "Host header the public Gateway uses to route to fts. See rucio_public_hostname for the .example.com rationale."
  value       = "fts.${var.name_prefix}.example.com"
}

output "workload_pool" {
  description = "Workload Identity pool (<project>.svc.id.goog)"
  value       = google_container_cluster.this.workload_identity_config[0].workload_pool
}

output "eso_service_account_email" {
  description = "GCP service account email ESO's k8s ServiceAccount impersonates"
  value       = google_service_account.eso.email
}
