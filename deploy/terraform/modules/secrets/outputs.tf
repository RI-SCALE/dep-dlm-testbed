output "secret_ids" {
  description = "Map of logical secret name -> full Secret Manager secret resource name (projects/<project>/secrets/<id>). Uses .id, not .secret_id, so it's directly usable as-is in access_secret_version() calls — same attribute every secret_version resource in this module already references."
  value       = { for k, v in google_secret_manager_secret.this : k => v.id }
}
