output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.kubernetes.cluster_name
}

output "cluster_endpoint" {
  value = module.kubernetes.cluster_endpoint
}

output "eso_service_account_email" {
  value = module.kubernetes.eso_service_account_email
}

output "secret_ids" {
  value = module.secrets.secret_ids
}

output "rucio_database_connection_name" {
  value = module.rucio_database.connection_name
}

output "rucio_database_private_ip" {
  value = module.rucio_database.private_ip_address
}

output "rucio_db_password" {
  value     = module.rucio_database.rucio_db_password
  sensitive = true
}

output "fts_database_connection_name" {
  value = module.fts_database.connection_name
}

output "fts_database_private_ip" {
  value = module.fts_database.private_ip_address
}

output "fts_db_password" {
  value     = module.fts_database.fts_db_password
  sensitive = true
}
