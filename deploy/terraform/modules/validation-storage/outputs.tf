output "external_ip" {
  description = "Public IP of the validation-storage VM — point var.hostname's DNS record at this"
  value       = google_compute_address.this.address
}

output "hostname" {
  description = "Configured public hostname for this validation target (echoed back for convenience)"
  value       = var.hostname
}

output "instance_name" {
  description = "GCE instance name, for gcloud compute ssh / logs lookups"
  value       = google_compute_instance.this.name
}

output "instance_self_link" {
  value = google_compute_instance.this.self_link
}

output "service_account_email" {
  value = google_service_account.this.email
}

# Four services, four ports on the same host (matches the compose file's
# xrd3/xrd4/teapot1/teapot2 port mapping) — each needs its own PFN root for
# RSE protocol registration, unlike the earlier single-service-pair design.

output "xrd3_pfn_root" {
  description = "Base PFN (root://...) for registering xrd3 as a Rucio RSE protocol"
  value       = "root://${var.hostname}:1094//rucio"
}

output "xrd4_pfn_root" {
  description = "Base PFN (root://...) for registering xrd4 as a Rucio RSE protocol"
  value       = "root://${var.hostname}:1095//rucio"
}

output "teapot1_pfn_root" {
  description = "Base PFN (https://...) for registering teapot1's WebDAV endpoint as a Rucio RSE protocol"
  value       = "https://${var.hostname}:8081"
}

output "teapot2_pfn_root" {
  description = "Base PFN (https://...) for registering teapot2's WebDAV endpoint as a Rucio RSE protocol"
  value       = "https://${var.hostname}:8082"
}
