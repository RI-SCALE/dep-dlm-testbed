output "secret_ids" {
  description = "Map of logical secret name -> full Secret Manager secret ID"
  value       = { for k, v in google_secret_manager_secret.this : k => v.secret_id }
}
