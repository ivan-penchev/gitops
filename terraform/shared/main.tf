# Homelab infrastructure every cluster uses: the fileserver and pg-01 LXCs
# and their LAN DNS records. Cluster roots read the outputs through
# terraform_remote_state.

locals {
  lxc_common = {
    proxmox_node   = var.proxmox_node
    vm_datastore   = var.vm_datastore
    network_bridge = var.network_bridge
    gateway        = var.network.gateway
    cidr_bits      = var.network.cidr_bits
    nameserver     = var.network.nameserver
  }
}

module "fileserver" {
  source = "../modules/fileserver"

  vm_id          = var.fileserver.vm_id
  hostname       = var.fileserver.hostname
  ip             = var.fileserver.ip
  export_cidr    = var.network.cidr
  child_datasets = var.fileserver.child_datasets
  proxmox_node   = local.lxc_common.proxmox_node
  vm_datastore   = local.lxc_common.vm_datastore
  network_bridge = local.lxc_common.network_bridge
  gateway        = local.lxc_common.gateway
  cidr_bits      = local.lxc_common.cidr_bits
  nameserver     = local.lxc_common.nameserver
}

module "postgres" {
  source = "../modules/postgres"

  vm_id          = var.postgres.vm_id
  hostname       = var.postgres.hostname
  ip             = var.postgres.ip
  data_mounted   = var.postgres_data_mounted
  client_cidr    = var.network.cidr
  proxmox_node   = local.lxc_common.proxmox_node
  vm_datastore   = local.lxc_common.vm_datastore
  network_bridge = local.lxc_common.network_bridge
  gateway        = local.lxc_common.gateway
  cidr_bits      = local.lxc_common.cidr_bits
  nameserver     = local.lxc_common.nameserver
}

module "lan_dns" {
  source = "../modules/lan-dns"

  domain = var.cloudflare_domain
  records = {
    fileserver = {
      name    = var.fileserver.dns_name
      ip      = module.fileserver.ip
      comment = "Terraform: fileserver LXC NFS (DNS-only, LAN)"
    }
    postgres = {
      name    = var.postgres.dns_name
      ip      = module.postgres.ip
      comment = "Terraform: PostgreSQL LXC (DNS-only, LAN)"
    }
  }
}
