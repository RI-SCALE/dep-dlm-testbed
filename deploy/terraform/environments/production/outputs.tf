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

output "database_connection_name" {
  value = module.database.connection_name
}

output "database_private_ip" {
  value = module.database.private_ip_address
}
