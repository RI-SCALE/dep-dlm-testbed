# modules/kubernetes
#
# GKE Autopilot cluster with Workload Identity enabled — matches the
# "GKE Autopilot" + "Workload Identity Federation" nodes in
# docs/diagrams/staging-gcp.py. Node provisioning/scaling/patching is
# Google-managed (Autopilot); this module only declares the cluster
# shell and the workload identity binding External Secrets Operator
# uses to reach Secret Manager (see modules/secrets).

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

  # Autopilot manages release channel by default; pin explicitly so
  # upgrades are deliberate rather than whatever GKE's default is today.
  release_channel {
    channel = var.release_channel
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  deletion_protection = var.deletion_protection

  # Autopilot clusters manage their own node pools; nothing further to
  # declare here. Standard-mode node pools would go in this module if
  # a future environment needs Standard instead of Autopilot.
}

# GCP service account that External Secrets Operator's k8s ServiceAccount
# impersonates via Workload Identity Federation — see the "federated
# credential" edge in docs/diagrams/staging-gcp.py.
resource "google_service_account" "eso" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-eso"
  display_name = "External Secrets Operator (${var.name_prefix})"
}

resource "google_service_account_iam_member" "eso_workload_identity" {
  service_account_id = google_service_account.eso.name
  role                = "roles/iam.workloadIdentityUser"
  # Reference the cluster's own computed workload_pool output, not a
  # reconstructed "${var.project_id}.svc.id.goog" string. The identity
  # pool only exists once the cluster provisions with Workload Identity
  # enabled — building the string from a plain input variable creates no
  # dependency edge, so Terraform can (and did) apply this binding in
  # parallel with cluster creation and fail with "Identity Pool does not
  # exist" before the cluster had finished.
  member = "serviceAccount:${google_container_cluster.this.workload_identity_config[0].workload_pool}[${var.eso_namespace}/${var.eso_k8s_service_account}]"
}
