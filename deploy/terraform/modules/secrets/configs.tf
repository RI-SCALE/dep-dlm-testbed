resource "google_secret_manager_secret_version" "configs" {
  secret = google_secret_manager_secret.this["configs"].id
  secret_data = jsonencode({
    "fts3config" = templatefile("${path.module}/templates/fts3config.tftpl", {
      site_name                = var.site_name
      fts_db_host              = var.fts_db_host
      fts_db_password          = var.fts_db_password
      oidc_issuer              = var.oidc_issuer
      allow_non_managed_tokens = var.token_mode == "unmanaged"
    })
    "fts3restconfig" = templatefile("${path.module}/templates/fts3rest.conf.tftpl", {
      log_level = var.fts3rest_log_level
    })
    "gfal2_http_plugin.conf" = file("${path.module}/../../../../shared/config/fts/gfal2_http_plugin.conf")
  })
}
