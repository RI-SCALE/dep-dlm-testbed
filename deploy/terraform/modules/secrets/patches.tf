# TODO: patches exceeds Secret Manager's 65536-byte per-version limit
# (rucio--fts3.py and rucio--oidc.py individually exceed it) — needs
# GCS instead, not Secret Manager. Disabled for now.
# resource "google_secret_manager_secret_version" "patches" { ... }

# locals {
#   patches_dir = "${path.module}/../../../../shared/patches" # adjust to wherever these actually live in-repo
# }

# resource "google_secret_manager_secret_version" "patches" {
#   secret = google_secret_manager_secret.this["patches"].id
#   secret_data = jsonencode({
#     "fts--JobBuilder.py"     = file("${local.patches_dir}/fts/JobBuilder.py")
#     "fts--cloud.py"          = file("${local.patches_dir}/fts/cloud.py")
#     "fts--cloudStorage.py"   = file("${local.patches_dir}/fts/cloudStorage.py")
#     "fts--middleware.py"     = file("${local.patches_dir}/fts/middleware.py")
#     "fts--openidconnect.py"  = file("${local.patches_dir}/fts/openidconnect.py")
#     "fts--tokenproviders.py" = file("${local.patches_dir}/fts/tokenproviders.py")
#     "rucio--constants.py"    = file("${local.patches_dir}/rucio/constants.py")
#     "rucio--fts3.py"         = file("${local.patches_dir}/rucio/fts3.py")
#     "rucio--oidc.py"         = file("${local.patches_dir}/rucio/oidc.py")
#     "rucio--rse.py"          = file("${local.patches_dir}/rucio/rse.py")
#   })
# }
