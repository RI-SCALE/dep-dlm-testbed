terraform {
  backend "gcs" {
    bucket = "dep-dlm-tfstate-production"
    prefix = "production"
  }
}
