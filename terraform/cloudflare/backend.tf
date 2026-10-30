# State lives in the private Cloudflare R2 bucket `homelab-tfstate`, through
# R2's S3 API. Credentials and the endpoint come from secrets.sops.env
# (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_ENDPOINT_URL_S3). Run
# Terraform through terraform/tf.sh. See docs/terraform-secrets.md.
#
# This state holds the tunnel secret.
terraform {
  backend "s3" {
    bucket = "homelab-tfstate"
    key    = "homelab/cloudflare.tfstate"
    region = "auto"

    # R2 is not AWS. Skip the AWS-only lookups and checksums.
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true

    # Lock with a .tflock object next to the state (conditional writes).
    use_lockfile = true
  }
}
