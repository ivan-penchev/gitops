locals {
  candidate_ip = split("/", var.network.ipv4_cidr)[0]
  cloud_config = {
    hostname         = "dns-candidate"
    manage_etc_hosts = true
    disable_root     = true
    ssh_pwauth       = false
    package_update   = true
    package_upgrade  = false
    packages         = ["python3", "python3-apt", "sudo", "qemu-guest-agent"]
    users = [{
      name                = "operator"
      groups              = ["sudo"]
      shell               = "/bin/bash"
      lock_passwd         = true
      sudo                = ["ALL=(ALL) NOPASSWD:ALL"]
      ssh_authorized_keys = [trimspace(var.ssh_public_key)]
    }]
    runcmd = [["systemctl", "enable", "--now", "qemu-guest-agent"]]
  }
}

resource "proxmox_download_file" "debian" {
  node_name           = var.proxmox_node
  datastore_id        = var.image_datastore
  content_type        = "import"
  url                 = var.debian_image_url
  checksum            = lower(var.debian_image_sha256)
  checksum_algorithm  = "sha256"
  file_name           = "servers-${var.vm_id}-debian13-${lower(var.debian_image_sha256)}.qcow2"
  overwrite           = false
  overwrite_unmanaged = false
  verify              = true
}

resource "proxmox_virtual_environment_file" "cloud_init" {
  node_name    = var.proxmox_node
  datastore_id = var.snippet_datastore
  content_type = "snippets"
  overwrite    = false

  source_raw {
    data      = "#cloud-config\n${yamlencode(local.cloud_config)}"
    file_name = "servers-${var.vm_id}-cloud-init-${substr(sha256(yamlencode(local.cloud_config)), 0, 16)}.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "pihole" {
  name          = "dns-candidate"
  description   = "Fresh non-Kubernetes Pi-hole candidate; infrastructure managed by terraform/servers, application by Ansible."
  node_name     = var.proxmox_node
  vm_id         = var.vm_id
  tags          = ["terraform", "servers", "pihole-candidate"]
  machine       = "q35"
  bios          = "seabios"
  scsi_hardware = "virtio-scsi-single"
  boot_order    = ["scsi0"]
  on_boot       = true
  started       = true
  protection    = true

  cpu {
    cores = 2
    type  = "x86-64-v2-AES"
  }
  memory {
    dedicated = 2048
    floating  = 0
  }
  disk {
    datastore_id = var.vm_datastore
    import_from  = proxmox_download_file.debian.id
    interface    = "scsi0"
    size         = 16
    file_format  = "raw"
    iothread     = true
    discard      = "on"
  }
  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }
  initialization {
    datastore_id      = var.vm_datastore
    interface         = "ide2"
    user_data_file_id = proxmox_virtual_environment_file.cloud_init.id
    ip_config {
      ipv4 {
        address = var.network.ipv4_cidr
        gateway = var.network.gateway
      }
    }
    dns {
      servers = var.network.dns_servers
    }
  }
  operating_system {
    type = "l26"
  }
  agent {
    enabled = true
    timeout = "15m"
    wait_for_ip {
      ipv4 = true
    }
  }
  serial_device {}
  vga {
    type = "serial0"
  }
  lifecycle {
    prevent_destroy = true
  }
}
