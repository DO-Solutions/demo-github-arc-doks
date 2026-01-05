terraform {
  backend "s3" {
    endpoints = {
      s3 = "https://sfo3.digitaloceanspaces.com"
    }
    bucket                      = "jkeegan-solutions-tf-state"
    key                         = "github-runner-doks-demo/terraform.tfstate"
    region                      = "us-east-1" # Required but ignored by DO
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}
