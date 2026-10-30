terraform {
  required_version = ">= 1.11"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.66"
    }
    talos = {
      source  = "siderolabs/talos"
      version = ">= 0.7"
    }
  }
}
