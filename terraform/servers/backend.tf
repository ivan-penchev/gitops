# Independent of shared infrastructure and every Kubernetes cluster.
# R2 credentials: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_ENDPOINT_URL_S3.
terraform {
  backend "s3" {
    bucket = "homelab-tfstate"
    key    = "homelab/servers.tfstate"
    region = "auto"

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
    use_lockfile                = true
  }
}
