# Remote state in a GCS bucket. Create the bucket out-of-band once
# (it can't provision the backend that stores its own state):
#
#   gcloud storage buckets create gs://dep-dlm-tfstate-staging \
#     --project=<project_id> --location=EU --uniform-bucket-level-access
#
# Then uncomment and fill in:
#
# terraform {
#   backend "gcs" {
#     bucket = "dep-dlm-tfstate-staging"
#     prefix = "staging"
#   }
# }
#
# Left commented so `terraform init` doesn't fail out of the box before
# the bucket exists — this file is the placeholder the README points to.
