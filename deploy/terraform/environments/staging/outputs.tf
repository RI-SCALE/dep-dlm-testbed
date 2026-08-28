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
  description = "Annotate the ESO k8s ServiceAccount with iam.gke.io/gcp-service-account=<this> to complete the Workload Identity binding"
  value       = module.kubernetes.eso_service_account_email
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

output "gateway_static_ip" {
  value = module.kubernetes.gateway_static_ip
}

output "rucio_public_hostname" {
  value = module.kubernetes.rucio_public_hostname
}

output "fts_public_hostname" {
  value = module.kubernetes.fts_public_hostname
}

output "validation_storage_ip" {
  value = module.validation_storage.external_ip
}
output "validation_storage_hostname" {
  value = module.validation_storage.hostname
}
output "validation_storage_xrd3_pfn_root" {
  value = module.validation_storage.xrd3_pfn_root
}
output "validation_storage_xrd4_pfn_root" {
  value = module.validation_storage.xrd4_pfn_root
}
output "validation_storage_teapot1_pfn_root" {
  value = module.validation_storage.teapot1_pfn_root
}
output "validation_storage_teapot2_pfn_root" {
  value = module.validation_storage.teapot2_pfn_root
}
