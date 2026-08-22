resource "google_secret_manager_secret_version" "secrets" {
  secret = google_secret_manager_secret.this["secrets"].id
  secret_data = jsonencode({
    "server.cfg" = templatefile("${path.module}/templates/rucio.cfg.tftpl", {
      rucio_db_host          = var.rucio_db_host
      rucio_db_password      = var.rucio_db_password
      rucio_host             = var.rucio_host
      rucio_internal_host    = "http://localhost"
      bootstrap_userpass_pwd = var.bootstrap_userpass_pwd
      oidc_issuer            = var.oidc_issuer
      oidc_token_strategy    = var.token_mode == "managed" ? "exchange" : "client_credentials"
      oidc_expected_scope    = var.oidc_expected_scope
    })
    "alembic.ini" = templatefile("${path.module}/templates/alembic.ini.tftpl", {
      rucio_db_host     = var.rucio_db_host
      rucio_db_password = var.rucio_db_password
    })
    "idpsecrets.json" = templatefile("${path.module}/templates/idpsecrets.json.tftpl", {
      oidc_issuer           = var.oidc_issuer
      oidc_client_id        = var.oidc_client_id
      oidc_client_secret    = var.oidc_client_secret
      rucio_public_hostname = var.rucio_host
    })
    "oidc-client.cfg" = templatefile("${path.module}/templates/oidc-client.cfg.tftpl", {
      rucio_host          = var.rucio_host
      oidc_issuer         = var.oidc_issuer
      oidc_expected_scope = var.oidc_expected_scope
      oidc_client_account = var.oidc_client_account
    })
    "userpass-client.cfg" = templatefile("${path.module}/templates/userpass-client.cfg.tftpl", {
      rucio_host        = var.rucio_host
      userpass_username = var.userpass_username
      userpass_password = var.userpass_password
      userpass_account  = var.userpass_account
    })
    "fts3restconfig" = templatefile("${path.module}/templates/fts3restconfig.tftpl", {
      site_name                = var.site_name
      fts_db_host              = var.fts_db_host
      fts_db_password          = var.fts_db_password
      oidc_issuer              = var.oidc_issuer
      allow_non_managed_tokens = var.token_mode == "unmanaged"
    })
    "fts3config" = templatefile("${path.module}/templates/fts3config.tftpl", {
      site_name       = var.site_name
      fts_db_host     = var.fts_db_host
      fts_db_password = var.fts_db_password
    })
    "docker-entrypoint.sh" = templatefile("${path.module}/templates/fts3-docker-entrypoint.sh.tftpl", {
      fts_db_host = var.fts_db_host
    })
  })
}
