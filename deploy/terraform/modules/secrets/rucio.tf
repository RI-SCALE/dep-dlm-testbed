resource "google_secret_manager_secret_version" "rucio" {
  secret = google_secret_manager_secret.this["rucio"].id
  secret_data = jsonencode({
    "server.cfg" = templatefile("${path.module}/templates/rucio.cfg.tftpl", {
      rucio_db_host          = var.rucio_db_host
      rucio_db_password      = var.rucio_db_password
      rucio_host             = var.rucio_host
      bootstrap_userpass_pwd = var.bootstrap_userpass_pwd
      oidc_issuer            = var.oidc_issuer
      oidc_token_strategy    = var.token_mode == "managed" ? "client_credentials" : "exchange"
    })
    "alembic.ini" = templatefile("${path.module}/templates/alembic.ini.tftpl", {
      rucio_db_host     = var.rucio_db_host
      rucio_db_password = var.rucio_db_password
    })
    "idpsecrets.json" = templatefile("${path.module}/templates/idpsecrets.json.tftpl", {
      oidc_issuer        = var.oidc_issuer
      oidc_client_id     = var.oidc_client_id
      oidc_client_secret = var.oidc_client_secret
    })
  })
}
