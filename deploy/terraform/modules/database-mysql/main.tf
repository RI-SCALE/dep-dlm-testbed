resource "google_sql_database_instance" "this" {
  name             = "${var.name_prefix}-mysql"
  project          = var.project_id
  region           = var.region
  database_version = var.mysql_version

  settings {
    tier              = var.tier
    availability_type = var.availability_type

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network_id
    }

    backup_configuration {
      enabled            = true
      binary_log_enabled = var.availability_type == "REGIONAL" ? true : var.point_in_time_recovery
    }
  }

  deletion_protection = var.deletion_protection
}

resource "google_sql_database" "fts" {
  name     = "fts"
  project  = var.project_id
  instance = google_sql_database_instance.this.name
}

resource "random_password" "fts_db" {
  length  = 32
  special = false
}

resource "google_sql_user" "fts" {
  name     = "fts"
  project  = var.project_id
  instance = google_sql_database_instance.this.name
  password = random_password.fts_db.result
}
