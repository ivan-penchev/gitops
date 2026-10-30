# Homelab infrastructure every cluster uses: the fileserver and pg-01 LXCs
# and their LAN DNS records. Cluster roots read the outputs through
# terraform_remote_state.

locals {
  lan_records = {
    fileserver = {
      name    = var.fileserver.dns_name
      ip      = var.fileserver.ip
      comment = "Terraform: fileserver LXC NFS (DNS-only, LAN)"
    }
    postgres = {
      name    = var.postgres.dns_name
      ip      = var.postgres.ip
      comment = "Terraform: PostgreSQL LXC (DNS-only, LAN)"
    }
  }
  lxc_common = {
    proxmox_node   = var.proxmox_node
    vm_datastore   = var.vm_datastore
    network_bridge = var.network_bridge
    gateway        = var.network.gateway
    cidr_bits      = var.network.cidr_bits
    nameserver     = var.network.nameserver
  }
}

