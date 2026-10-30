# Outputs of the other two stacks. Same bucket and credentials as backend.tf;
# the endpoint comes from AWS_ENDPOINT_URL_S3.
locals {
  r2_state = {
    bucket                      = "homelab-tfstate"
    region                      = "auto"
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}

data "terraform_remote_state" "platform" {
  backend = "s3"
  config  = merge(local.r2_state, { key = "homelab/platform.tfstate" })
}

data "terraform_remote_state" "cloudflare" {
  backend = "s3"
  config  = merge(local.r2_state, { key = "homelab/cloudflare.tfstate" })
}

locals {
  platform   = data.terraform_remote_state.platform.outputs
  cloudflare = data.terraform_remote_state.cloudflare.outputs
}
