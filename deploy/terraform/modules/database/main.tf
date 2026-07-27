# modules/database
#
# Cloud SQL for PostgreSQL, private-IP only, holding both Rucio's and
# FTS's metadata — mirrors the sandbox's single in-cluster `ruciodb`/
# `ftsdb` pattern but as one managed instance with two databases, per
# the "Cloud SQL for PostgreSQL (rucio + fts metadata)" node in
# docs/diagrams/staging-gcp.py. Requires the private services access
# peering from modules/networking to exist first (see
# private_vpc_connection in that module's outputs).

resource "google_sql_database_instance" "this" {
  name             = "${var.name_prefix}-pg"
  project          = var.project_id
  region           = var.region
  database_version = var.postgres_version

  settings {
    tier              = var.tier
    availability_type = var.availability_type

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network_id
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = var.point_in_time_recovery
    }
  }

  deletion_protection = var.deletion_protection

  depends_on = [var.private_vpc_connection]
}

resource "google_sql_database" "rucio" {
  name     = "rucio"
  project  = var.project_id
  instance = google_sql_database_instance.this.name
}

resource "google_sql_database" "fts" {
  name     = "fts"
  project  = var.project_id
  instance = google_sql_database_instance.this.name
}

# Passwords are generated here (not literal-committed) but still land in
# Terraform state — treat state as sensitive (see environments/*/backend.tf
# for remote-state handling) and consider rotating out of Secret Manager
# post-creation for anything longer-lived than a test environment.
resource "random_password" "rucio_db" {
  length  = 32
  special = false
}

resource "random_password" "fts_db" {
  length  = 32
  special = false
}

resource "google_sql_user" "rucio" {
  name     = "rucio"
  project  = var.project_id
  instance = google_sql_database_instance.this.name
  password = random_password.rucio_db.result
}

resource "google_sql_user" "fts" {
  name     = "fts"
  project  = var.project_id
  instance = google_sql_database_instance.this.name
  password = random_password.fts_db.result
}
