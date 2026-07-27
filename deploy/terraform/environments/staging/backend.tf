terraform {
  backend "gcs" {
    bucket = "dep-dlm-tfstate-staging"
    prefix = "staging"
  }
}
