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

  # Enables the Kubernetes Gateway API controller — GKE's current
  # recommended path for exposing external traffic, preferred over a
  # classic Ingress here for a more portable API shape across
  # hyperscalers. STANDARD is the GA channel; GKE auto-provisions the
  # gke-l7-* GatewayClasses once this is set (gke-l7-global-external-managed,
  # gke-l7-regional-external-managed, gke-l7-rilb, gke-l7-gxlb) — nothing
  # further to create in Terraform for those.
  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  deletion_protection = var.deletion_protection
}

# Static external IP for the public Gateway — reserved via Terraform so
# the eventual Gateway manifest (deploy/gitops) and the smoke test below
# both reference the same, stable address instead of discovering an
# ephemeral one after each Gateway (re)create. Global, matching the
# gke-l7-global-external-managed GatewayClass this targets.
resource "google_compute_global_address" "gateway" {
  project = var.project_id
  name    = "${var.name_prefix}-gateway-ip"
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

resource "google_service_account_iam_member" "eso_workload_identity_flux" {
  service_account_id = google_service_account.eso.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${google_container_cluster.this.workload_identity_config[0].workload_pool}[external-secrets/external-secrets]"
}
