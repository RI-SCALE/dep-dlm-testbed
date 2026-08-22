variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for the static IP and any regional resources"
  type        = string
}

variable "zone" {
  description = <<-EOT
    GCP zone for the VM(s). Defaults to europe-west3-b deliberately —
    europe-west3-a has shown repeated GCE scale-up/capacity failures
    during this project's own testing (see runbook notes); -b and -c
    have not. Override only if you've confirmed capacity in the target
    zone.
  EOT
  type        = string
  default     = "europe-west3-b"
}

variable "network_id" {
  description = "Self-link or ID of the VPC network to attach the VM(s) to"
  type        = string
}

variable "subnet_id" {
  description = "Self-link or ID of the subnetwork to attach the VM(s) to"
  type        = string
}

variable "name_prefix" {
  description = "Prefix for all resources this module creates (e.g. dep-dlm-staging)"
  type        = string
}

variable "machine_type" {
  description = "GCE machine type for the validation-storage VM"
  type        = string
  default     = "e2-small"
}

# --- Container images ------------------------------------------------------
# The compose template (templates/docker-compose.yml.tftpl) pins the same
# prebuilt images sandbox's own docker-compose.yml already uses
# (rucio/test-xrootd@sha256:..., mgajekcern/teapot:latest) — no on-VM build,
# no Artifact Registry step needed. If those images ever need to diverge
# from sandbox's, edit the compose template directly rather than
# reintroducing image variables here.

variable "repo_root" {
  description = <<-EOT
    Absolute path to the repo root (e.g. path.root's parent, or an
    explicit path), used to locate shared/config/{xrootd,teapot} and
    shared/scripts/xrootd/docker-entrypoint.sh at plan time — these
    static config files are embedded into the VM's startup script via
    file(), the same content sandbox's compose stack already mounts.
  EOT
  type        = string
}

# --- Certs / trust -----------------------------------------------------
# Pulled from the SAME Secret Manager secret the rest of the testbed's certs
# live in (module.secrets), so this validation target is trusted by the same
# rucio_ca.pem every other RSE/FTS endpoint already trusts — no second trust
# root to manage. Requires the secrets module's "certs" secret to already
# contain keys for this host (see module.secrets README for the item-list
# pattern used by fts/rucio-server/etc).

variable "certs_secret_id" {
  description = "Full resource ID of the Secret Manager secret containing this host's cert/key pair + rucio_ca.pem (JSON-encoded, same shape as module.secrets' certs secret)"
  type        = string
}

variable "hostname" {
  description = <<-EOT
    Public DNS hostname this VM will be reachable at (e.g.
    validation-storage.dep-dlm-staging.example.com). Must resolve to the
    static IP this module reserves — DNS record creation is NOT handled by
    this module (out of scope: depends on the zone/registrar in use), set
    it manually or via a separate DNS module once the IP output is known.
  EOT
  type        = string
}

variable "labels" {
  description = "Extra labels applied to all resources this module creates"
  type        = map(string)
  default     = {}
}

variable "terraform_ci_sa_email" {
  description = "Email of the Terraform CI service account that will create this module's VM — granted iam.serviceAccountUser on this module's own service account, required to attach it at instance-creation time."
  type        = string
}

variable "oidc_issuer" {
  description = "External OIDC issuer URL trusted by Teapot/XRootD alongside the internal Keycloak issuer — must match var.oidc_issuer passed to module.secrets."
  type        = string
}

variable "oidc_issuer_name" {
  description = "Short label for this issuer, used as the YAML/section key in Teapot's application.yml and XRootD's scitokens.conf (e.g. 'keycloak-rucio', 'egi-checkin-dev', 'lsaai-dev'). No spaces — used as a bracketed section header in scitokens.conf."
  type        = string
}

variable "teapot_idp_name" {
  description = "IdP_name_1 value in Teapot's STORAGE_AREA_1 config."
  type        = string
  default     = "rucio"
}

variable "teapot_audiences" {
  description = "Optional list of audience URIs Teapot restricts this issuer's tokens to (LS AAI profile only — EGI/Keycloak leave this empty)."
  type        = list(string)
  default     = []
}

variable "teapot_extra_subs" {
  description = "Additional 'sub' claims (beyond the two fixed teapot client UUIDs) mapped to the local 'teapot' user in user-mapping.csv — profile-specific client/human subs."
  type        = list(string)
  default     = []
}
