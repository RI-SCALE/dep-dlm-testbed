output "project_ids" {
  description = "Map of environment name -> created project_id. Feed into environments/<env>/terraform.tfvars' project_id."
  value       = { for k, v in google_project.env : k => v.project_id }
}

output "terraform_ci_emails" {
  description = "Map of environment name -> dep-dlm-terraform-ci service account email. Feed into each GitHub Actions workflow's google-github-actions/auth step (`service_account:`)."
  value       = { for k, v in google_service_account.terraform_ci : k => v.email }
}

output "workload_identity_providers" {
  description = "Map of environment name -> full Workload Identity Federation provider resource name. Feed into each GitHub Actions workflow's google-github-actions/auth step (`workload_identity_provider:`)."
  value       = { for k, v in google_iam_workload_identity_pool_provider.github : k => v.name }
}

output "state_buckets" {
  description = "Map of environment name -> GCS bucket name for that environment's own Terraform state. Feed into environments/<env>'s `terraform init -backend-config=bucket=...` (and the TF_STATE_BUCKET repo variable each environment's CI workflow already reads)."
  value       = { for k, v in google_storage_bucket.tf_state : k => v.name }
}
