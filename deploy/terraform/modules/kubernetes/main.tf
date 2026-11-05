# Zonal GKE Standard cluster with one managed node pool (design doc 008,
# ADR-009). Staging runs a single fixed-size node; production enables the
# node pool autoscaler. Only the node pool variables differ per environment.
resource "google_container_cluster" "this" {
  name     = "${var.name_prefix}-gke"
  project  = var.project_id
  location = var.zone # zonal: one node means one node; covered by the GKE free tier credit

  # Nodes come only from google_container_node_pool.this below. GKE requires
  # an initial default pool at creation, which is removed right after.
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = var.network_id
  subnetwork = var.subnet_id

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  release_channel {
    channel = var.release_channel
  }

  # ESO authenticates to Secret Manager through Workload Identity.
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

resource "google_container_node_pool" "this" {
  name     = "${var.name_prefix}-pool"
  project  = var.project_id
  location = google_container_cluster.this.location
  cluster  = google_container_cluster.this.name

  # Fixed size (staging) or autoscaled (production), never both.
  node_count         = var.autoscaling_enabled ? null : var.node_count
  initial_node_count = var.autoscaling_enabled ? var.min_node_count : null

  dynamic "autoscaling" {
    for_each = var.autoscaling_enabled ? [1] : []
    content {
      min_node_count = var.min_node_count
      max_node_count = var.max_node_count
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true # required with a release channel
  }

  node_config {
    machine_type = var.machine_type
    disk_size_gb = var.disk_size_gb

    # Default compute service account, as with Autopilot before; access is
    # governed by its IAM roles, not by scopes.
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    # Serve the GKE metadata server so pods use Workload Identity (ESO).
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
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
