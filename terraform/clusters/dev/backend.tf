terraform {
  backend "s3" {
    bucket       = "dataflarelabs-tfstate"
    key          = "gearhawk-lab/dev/terraform.tfstate"
    region       = "auto"
    profile      = "dataflarelabs-tfstate"
    use_lockfile = true

    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}
