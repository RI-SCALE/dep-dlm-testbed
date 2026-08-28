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
    "5fca1cb1.0"              = file("${local.certs_dir}/rucio_ca.pem")
    "5fca1cb1.signing_policy" = file("${local.certs_dir}/5fca1cb1.signing_policy")
    "b96dc756.0"              = file("${local.certs_dir}/b96dc756.0")
    "b96dc756.signing_policy" = file("${local.certs_dir}/b96dc756.signing_policy")

    "storm-webdav-localhostcert.pem" = file("${local.certs_dir}/storm-webdav-localhostcert.pem")
    "storm-webdav-localhostkey.pem"  = file("${local.certs_dir}/storm-webdav-localhostkey.pem")

    "xrd3cert.pem"    = file("${local.certs_dir}/xrd3cert.pem")
    "xrd3key.pem"     = file("${local.certs_dir}/xrd3key.pem")
    "xrd4cert.pem"    = file("${local.certs_dir}/xrd4cert.pem")
    "xrd4key.pem"     = file("${local.certs_dir}/xrd4key.pem")
    "teapot1cert.pem" = file("${local.certs_dir}/teapot1cert.pem")
    "teapot1key.pem"  = file("${local.certs_dir}/teapot1key.pem")
    "teapot2cert.pem" = file("${local.certs_dir}/teapot2cert.pem")
    "teapot2key.pem"  = file("${local.certs_dir}/teapot2key.pem")
  })
}
