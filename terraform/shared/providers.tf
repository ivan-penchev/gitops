# Credentials come from secrets.sops.env through terraform/tf.sh:
# PROXMOX_VE_ENDPOINT, PROXMOX_VE_API_TOKEN and CLOUDFLARE_API_TOKEN.

provider "proxmox" {
  endpoint  = var.proxmox_endpoint != "" ? var.proxmox_endpoint : null
  api_token = var.proxmox_api_token != "" ? var.proxmox_api_token : null
  insecure  = var.proxmox_insecure # self-signed cert on the PVE host
}

provider "cloudflare" {}
