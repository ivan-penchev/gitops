terraform {
  # >= 1.10: cross-type `moved` blocks (cloudflare v4->v5 renames migrate state
  # via the provider's MoveState upgrader) need >= 1.8, and the state is now
  # written by TF 1.10.x (older CLIs refuse newer state). The plugin-framework
  # cloudflare v5 provider also requires a modern Terraform.
  required_version = ">= 1.10"

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
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5"
    }
  }

  # Local state (homelab choice). Contains Talos secrets + kubeconfig — gitignored.
  # Back it up encrypted. See plan.md "Risks / follow-ups".
}
