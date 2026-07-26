terraform {
  required_version = ">= 1.5"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.66"
    }
    talos = {
      source  = "siderolabs/talos"
      version = ">= 0.7"
    }
    flux = {
      source  = "fluxcd/flux"
      version = ">= 1.4"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.30"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4"
    }
  }

  # Local state (homelab choice). Contains Talos secrets + kubeconfig — gitignored.
  # Back it up encrypted. See plan.md "Risks / follow-ups".
}
