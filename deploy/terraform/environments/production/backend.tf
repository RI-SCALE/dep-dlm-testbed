# See environments/staging/backend.tf for the pattern. Production MUST
# use a separate state bucket/prefix (and separate GCP project) from
# staging — never share state between environments.
#
# terraform {
#   backend "gcs" {
#     bucket = "dep-dlm-tfstate-production"
#     prefix = "production"
#   }
# }
