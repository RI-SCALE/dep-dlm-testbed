# Secret Manager entries for the values External Secrets Operator syncs
# into the cluster — the same set the sandbox's Vault seed job populates
# today (see shared/scripts/seed-vault.sh in the testbed repo).

resource "google_secret_manager_secret" "this" {
  for_each  = toset(var.secret_names)
  project   = var.project_id
  secret_id = "${var.name_prefix}-${each.value}"

  replication {
    auto {}
  }
}

# Grants ESO's GCP service account (from modules/kubernetes) read access
# to every secret this module manages. Actual version creation/rotation
# is out of Terraform's scope by design (see module docstring above).
resource "google_secret_manager_secret_iam_member" "eso_access" {
  for_each  = google_secret_manager_secret.this
  project   = var.project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.eso_service_account_email}"
}
