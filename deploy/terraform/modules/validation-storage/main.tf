# ============================================================================
# validation-storage — a testbed-owned, publicly reachable XRootD + Teapot
# (WebDAV) target, registered as a real Rucio RSE. Deliberately NOT on GKE:
# the whole point is to validate the external-storage integration path the
# same way an actual RI-SCALE partner endpoint would be reached — real
# network path, real TLS/WebDAV/XRootD protocol handling, real OIDC token
# flow — not in-cluster plumbing. See BACKLOG.md's "testbed-owned XRootD/
# Teapot validation target" item for the full rationale.
#
# One VM runs both services via docker compose (XRootD :1094, Teapot :8081)
# — a single VM is sufficient for a validation target (not a scale/perf
# target, see BACKLOG.md's explicit "not necessarily representative of
# scale" caveat) and keeps the footprint/cost small.
# ============================================================================

resource "google_compute_address" "this" {
  name         = "${var.name_prefix}-validation-storage-ip"
  project      = var.project_id
  region       = var.region
  address_type = "EXTERNAL"
}

resource "google_service_account" "this" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-valstorage"
  display_name = "${var.name_prefix} validation-storage VM"
}

# Minimal roles: read the certs secret, write its own logs/metrics. NOT
# granted anything broader — this VM is intentionally internet-facing, so
# its service account should have as little blast radius as possible if
# ever compromised.
resource "google_secret_manager_secret_iam_member" "certs_access" {
  project   = var.project_id
  secret_id = var.certs_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.this.email}"
}

resource "google_project_iam_member" "logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.this.email}"
}

resource "google_project_iam_member" "monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.this.email}"
}


# The CI identity creating this VM needs serviceAccountUser ON THIS SPECIFIC
# service account to attach it at instance-creation time — project-level
# roles alone (even iam.serviceAccountAdmin, which only covers managing the
# SA itself, not using/attaching it) don't grant this. Same pattern
# bootstrap/main.tf already uses for GKE Autopilot's compute SA
# (terraform_ci_compute_sa_user).
resource "google_service_account_iam_member" "ci_can_use_valstorage_sa" {
  service_account_id = google_service_account.this.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.terraform_ci_sa_email}"
}

# --- Firewall ----------------------------------------------------------
# Scoped to exactly the two service ports, tagged so it only ever applies
# to this VM (not a blanket network-wide rule).
resource "google_compute_firewall" "validation_storage_ingress" {
  name    = "${var.name_prefix}-validation-storage-ingress"
  project = var.project_id
  network = var.network_id

  allow {
    protocol = "tcp"
    ports    = ["1094", "1095", "8081", "8082"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["${var.name_prefix}-validation-storage"]
}

# SSH via IAP tunneling still requires a firewall rule — IAP proxies the
# connection, it doesn't bypass firewall enforcement. 35.235.240.0/20 is
# Google's fixed, published CIDR block reserved exclusively for IAP's TCP
# forwarding proxy: traffic can only originate from there if it came
# through IAP itself (which independently enforces IAM permissions, e.g.
# roles/iap.tunnelResourceAccessor, before proxying). This is NOT the same
# as opening 22 to 0.0.0.0/0 — kept as a separate rule from the ingress
# rule above specifically so SSH never inherits that rule's public
# source_ranges.
resource "google_compute_firewall" "validation_storage_iap_ssh" {
  name    = "${var.name_prefix}-validation-storage-iap-ssh"
  project = var.project_id
  network = var.network_id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["${var.name_prefix}-validation-storage"]
}

# --- VM ------------------------------------------------------------------

resource "google_compute_instance" "this" {
  name         = "${var.name_prefix}-validation-storage"
  project      = var.project_id
  zone         = var.zone
  machine_type = var.machine_type
  tags         = ["${var.name_prefix}-validation-storage"]
  labels       = var.labels

  boot_disk {
    initialize_params {
      image = "cos-cloud/cos-stable" # Container-Optimized OS — docker preinstalled, minimal attack surface
      size  = 20
    }
  }

  network_interface {
    subnetwork = var.subnet_id
    access_config {
      nat_ip = google_compute_address.this.address
    }
  }

  service_account {
    email  = google_service_account.this.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    # startup-script MUST be an executable shell script — the compose YAML
    # is NOT used as metadata directly, it's embedded as a string and
    # written to disk BY the startup script (which then runs `docker
    # compose up`). Static XRootD/Teapot config is read from this repo's
    # existing shared/config files at plan time via file() and embedded
    # the same way, so this module doesn't need a second file-delivery
    # mechanism for config that's already git-tracked.
    startup-script = templatefile("${path.module}/templates/startup-script.sh.tftpl", {
      certs_secret_id         = var.certs_secret_id
      docker_compose_yml      = file("${path.module}/templates/docker-compose.yml.tftpl")
      xrdrucio_scitokens_cfg  = file("${var.repo_root}/shared/config/xrootd/xrdrucio-scitokens.cfg")
      xrootd_authdb           = file("${var.repo_root}/shared/config/xrootd/authdb")
      xrootd_scitokens_conf   = file("${var.repo_root}/shared/config/xrootd/scitokens.conf")
      xrootd_entrypoint_sh    = file("${var.repo_root}/shared/scripts/xrootd/docker-entrypoint.sh")
      teapot_config_ini       = file("${var.repo_root}/shared/config/teapot/config.ini")
      teapot_application_yml  = file("${var.repo_root}/shared/config/teapot/application.yml")
      teapot_data_properties  = file("${var.repo_root}/shared/config/teapot/data.properties")
      teapot_user_mapping_csv = file("${var.repo_root}/shared/config/teapot/user-mapping.csv")
      teapot_logback_xml      = file("${var.repo_root}/shared/config/teapot/logback.xml")
    })
  }

  # Container-Optimized OS pulls updates on its own schedule; don't fight it
  # by forcing recreation on every apply.
  allow_stopping_for_update = true
}
