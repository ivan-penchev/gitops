locals {
  candidate_ip = split("/", var.network.ipv4_cidr)[0]
}

resource "proxmox_download_file" "debian" {
  node_name           = var.proxmox_node
  datastore_id        = var.template_datastore
  content_type        = "vztmpl"
  url                 = var.debian_template_url
  checksum            = lower(var.debian_template_sha256)
  checksum_algorithm  = "sha256"
  file_name           = "servers-${var.vm_id}-debian13-${lower(var.debian_template_sha256)}.tar.zst"
  overwrite           = false
  overwrite_unmanaged = false
  verify              = true
}

resource "proxmox_virtual_environment_container" "pihole" {
  description   = "Fresh unprivileged Pi-hole candidate; infrastructure managed by terraform/servers, native application by Ansible."
  node_name     = var.proxmox_node
  vm_id         = var.vm_id
  tags          = ["terraform", "servers", "pihole-candidate"]
  unprivileged  = true
  started       = var.container_started
  start_on_boot = var.container_started && !var.network_link_down && !var.bootstrap_dhcp
  protection    = true

  features {
    nesting = false
    keyctl  = false
    fuse    = false
    mknod   = false
  }
  cpu {
    cores        = 2
    architecture = "amd64"
  }
  memory {
    dedicated = 1024
    swap      = 0
  }
  disk {
    datastore_id = var.rootfs_datastore
    size         = 8
  }
  dynamic "network_interface" {
    for_each = var.network_link_down ? [] : [1]
    content {
      name    = "eth0"
      bridge  = var.network_bridge
      enabled = true
    }
  }
  initialization {
    hostname = "dns-candidate"
    user_account {
      keys = [trimspace(var.ssh_public_key)]
    }
    dynamic "ip_config" {
      for_each = var.network_link_down ? [] : [1]
      content {
        ipv4 {
          address = var.bootstrap_dhcp ? "dhcp" : var.network.ipv4_cidr
          gateway = var.bootstrap_dhcp ? null : var.network.gateway
        }
      }
    }
    dns {
      servers = var.network.dns_servers
    }
  }
  operating_system {
    template_file_id = proxmox_download_file.debian.id
    type             = "debian"
  }
  console {
    enabled = true
    type    = "shell"
  }
  lifecycle {
    prevent_destroy = true
  }
}
