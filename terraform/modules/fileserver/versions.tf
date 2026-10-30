terraform {
  required_version = ">= 1.11"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.66"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2"
    }
  }
}
