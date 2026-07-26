# One VM per Talos node (control-plane + workers) via the accepted tuning profile:
# CPU type=host, no ballooning (floating=0), q35+SeaBIOS, virtio-scsi + iothread +
# discard + ssd, guest agent on, boot disk on ZFS `tank`, Talos ISO as CD-ROM.
resource "proxmox_virtual_environment_vm" "this" {
  for_each = local.nodes

  name      = "${var.cluster_name}-${each.key}"
  vm_id     = each.value.vmid
  node_name = var.proxmox_node
  tags      = ["talos", each.value.role, var.cluster_name]

  machine       = "q35"
  bios          = "seabios"
  scsi_hardware = "virtio-scsi-single"

  operating_system {
    type = "l26"
  }

  agent {
    enabled = true # Talos qemu-guest-agent extension reports the node IP
  }

  cpu {
    cores = each.value.cpu
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
    floating  = 0 # balloon=0 => ballooning disabled (fixed RAM for kubelet)
  }

  disk {
    datastore_id = var.vm_datastore
    interface    = "scsi0"
    size         = each.value.disk
    file_format  = "raw" # required for zfspool
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  cdrom {
    file_id   = proxmox_download_file.talos_iso.id
    interface = "ide2"
  }

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  # Serial console for Talos (`qm terminal <vmid>`).
  serial_device {
    device = "socket"
  }
  vga {
    type = "serial0"
  }

  # Disk first; on first boot the empty disk falls through to the ISO
  # (Talos maintenance mode). After install, the disk boots Talos.
  boot_order = ["scsi0", "ide2"]

  # Talos sets its own static IP via machineconfig; no cloud-init here.
  # In maintenance mode the node DHCPs a temporary IP — the guest agent
  # reports it and Talos config-apply targets it (see talos.tf).
  lifecycle {
    ignore_changes = [
      cdrom, # keep ISO attached but don't churn after install
    ]
  }
}
