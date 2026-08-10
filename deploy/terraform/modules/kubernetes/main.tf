resource "google_container_cluster" "this" {
  name     = "${var.name_prefix}-gke"
  project  = var.project_id
  location = var.region # regional cluster for HA control plane

  enable_autopilot = true

  network    = var.network_id
  subnetwork = var.subnet_id

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  release_channel {
    channel = var.release_channel
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  deletion_protection = var.deletion_protection
}

resource "google_service_account" "eso" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-eso"
  display_name = "External Secrets Operator (${var.name_prefix})"
}

resource "google_service_account_iam_member" "eso_workload_identity" {
  service_account_id = google_service_account.eso.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${google_container_cluster.this.workload_identity_config[0].workload_pool}[${var.name_prefix}/external-secrets-${trimprefix(var.name_prefix, "dep-dlm-")}]"
}
