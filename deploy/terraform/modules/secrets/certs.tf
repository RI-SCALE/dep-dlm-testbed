locals {
  certs_dir = "${path.module}/../../../../certs" # shared/scripts/generate-certs.sh's output dir
}

resource "google_secret_manager_secret_version" "certs" {
  secret = google_secret_manager_secret.this["certs"].id
  secret_data = jsonencode({
    "hostcert.pem"            = file("${local.certs_dir}/hostcert.pem")
    "hostkey.pem"             = file("${local.certs_dir}/hostkey.pem")
    "hostcert_with_key.pem"   = file("${local.certs_dir}/hostcert_with_key.pem")
    "rucio_ca.pem"            = file("${local.certs_dir}/rucio_ca.pem")
    "tls_ca_bundle.pem"       = file("${local.certs_dir}/tls_ca_bundle.pem")
    "5fca1cb1.0"              = file("${local.certs_dir}/rucio_ca.pem") # same bytes as rucio_ca.pem, hash-named
    "5fca1cb1.signing_policy" = file("${local.certs_dir}/5fca1cb1.signing_policy")
  })
}
