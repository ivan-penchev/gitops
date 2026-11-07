# API credentials use the same environment conventions as terraform/shared.
provider "proxmox" {
  endpoint  = var.proxmox_endpoint != "" ? var.proxmox_endpoint : null
  api_token = var.proxmox_api_token != "" ? var.proxmox_api_token : null
  insecure  = var.proxmox_insecure

  # Snippet uploads need PVE host SSH, not guest SSH or a Terraform provisioner.
  ssh {
    agent    = true
    username = var.proxmox_ssh_username
    node {
      name    = var.proxmox_node
      address = var.proxmox_ssh_address
    }
  }
}
