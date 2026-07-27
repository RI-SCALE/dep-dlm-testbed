output "instance_name" {
  description = "Name of the Cloud SQL instance"
  value       = google_sql_database_instance.this.name
}

output "private_ip_address" {
  description = "Private IP address of the Cloud SQL instance"
  value       = google_sql_database_instance.this.private_ip_address
}

output "connection_name" {
  description = "Cloud SQL connection name (project:region:instance), useful for the Cloud SQL Auth Proxy if ever needed"
  value       = google_sql_database_instance.this.connection_name
}

output "rucio_db_name" {
  value = google_sql_database.rucio.name
}

output "fts_db_name" {
  value = google_sql_database.fts.name
}

output "rucio_db_password" {
  value     = random_password.rucio_db.result
  sensitive = true
}

output "fts_db_password" {
  value     = random_password.fts_db.result
  sensitive = true
}
