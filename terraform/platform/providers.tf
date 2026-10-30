# ---------------------------------------------------------------------------
# Proxmox (bpg/proxmox)
# Reads PROXMOX_VE_ENDPOINT and PROXMOX_VE_API_TOKEN from the environment by
# default; the vars below are optional overrides. API-token-only (no SSH).
# ---------------------------------------------------------------------------
provider "proxmox" {
  endpoint  = var.proxmox_endpoint != "" ? var.proxmox_endpoint : null
  api_token = var.proxmox_api_token != "" ? var.proxmox_api_token : null
  insecure  = var.proxmox_insecure # self-signed cert on the PVE host

  # No `ssh {}` block on purpose: design is API-only (ISO boot, no snippet upload).
}

# ---------------------------------------------------------------------------
# Talos (siderolabs/talos) — no provider config required.
# ---------------------------------------------------------------------------
provider "talos" {}
