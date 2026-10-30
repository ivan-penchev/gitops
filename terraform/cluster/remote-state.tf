# Outputs of terraform/shared: the LAN settings and pg-01.
data "terraform_remote_state" "shared" {
  backend = "s3"
  config = {
    bucket                      = "homelab-tfstate"
    key                         = "homelab/shared.tfstate"
    region                      = "auto"
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}

locals {
  shared = data.terraform_remote_state.shared.outputs
}
