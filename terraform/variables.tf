# ---------------------------------------------------------------------------
# Proxmox connection (prefer env: PROXMOX_VE_ENDPOINT / PROXMOX_VE_API_TOKEN)
# ---------------------------------------------------------------------------
variable "proxmox_endpoint" {
  description = "Proxmox API endpoint. Empty = read PROXMOX_VE_ENDPOINT from env."
  type        = string
  default     = ""
}

variable "proxmox_api_token" {
  description = "Proxmox API token 'user@realm!id=secret'. Empty = read PROXMOX_VE_API_TOKEN from env."
  type        = string
  default     = ""
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification for the self-signed Proxmox cert."
  type        = bool
  default     = true
}

variable "proxmox_node" {
  description = "Proxmox node name. Also used as the CSI topology zone (must match the real node name)."
  type        = string
  default     = "pve"
}

variable "proxmox_region" {
  description = "CSI topology region label. Must match the `region` field in the proxmox-csi cloud-config secret."
  type        = string
  default     = "homelab"
}

variable "proxmox_csi_endpoint" {
  description = "Proxmox API URL used by proxmox-csi-plugin (must include /api2/json)."
  type        = string
  default     = "https://192.168.68.2:8006/api2/json"
}

# ---------------------------------------------------------------------------
# Datastores / networking (confirmed live)
# ---------------------------------------------------------------------------
variable "vm_datastore" {
  description = "Datastore for VM boot disks (ZFS)."
  type        = string
  default     = "tank"
}

variable "iso_datastore" {
  description = "Datastore that accepts ISO content."
  type        = string
  default     = "local"
}

variable "network_bridge" {
  description = "Linux bridge for VM NICs."
  type        = string
  default     = "vmbr0"
}

variable "network_gateway" {
  description = "Default gateway for the flat LAN."
  type        = string
  default     = "192.168.68.1"
}

variable "network_cidr_bits" {
  description = "Prefix length of the LAN subnet."
  type        = number
  default     = 24
}

variable "nameserver" {
  description = "DNS server handed to Talos nodes (Pi-hole)."
  type        = string
  default     = "192.168.68.20"
}

# ---------------------------------------------------------------------------
# Talos / Kubernetes versions + image
# ---------------------------------------------------------------------------
variable "cluster_name" {
  description = "Cluster name."
  type        = string
  default     = "homelab"
}

variable "talos_version" {
  description = "Talos version tag, e.g. 'v1.9.0'. Set to a current release."
  type        = string
  # No default on purpose — pin to a real, current Talos release in tfvars.
}

variable "kubernetes_version" {
  description = "Kubernetes version for Talos to install, e.g. 'v1.32.0'."
  type        = string
  # No default on purpose — pin to a version supported by the chosen Talos release.
}

variable "talos_schematic_id" {
  description = <<-EOT
    Talos Image Factory schematic ID for the metal ISO. Must include the
    siderolabs/qemu-guest-agent extension. Generate at https://factory.talos.dev
    or via the factory API. The default below corresponds to a schematic with
    only qemu-guest-agent — VERIFY it against the factory for your Talos version.
  EOT
  type        = string
  default     = "ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"
}

# ---------------------------------------------------------------------------
# Control-plane VIP (shared API endpoint)
# ---------------------------------------------------------------------------
variable "cluster_vip" {
  description = "Talos built-in L2 VIP for the Kubernetes API."
  type        = string
  default     = "192.168.68.29"
}

# ---------------------------------------------------------------------------
# Node topology. IP is the last octet's full address; vmid maps to it.
# ---------------------------------------------------------------------------
variable "control_planes" {
  description = "Control-plane node definitions."
  type = map(object({
    vmid   = number
    ip     = string
    cpu    = number
    memory = number # MiB
    disk   = number # GiB
  }))
  default = {
    cp-1 = { vmid = 131, ip = "192.168.68.31", cpu = 2, memory = 4096, disk = 30 }
    cp-2 = { vmid = 132, ip = "192.168.68.32", cpu = 2, memory = 4096, disk = 30 }
    cp-3 = { vmid = 133, ip = "192.168.68.33", cpu = 2, memory = 4096, disk = 30 }
  }
}

variable "workers" {
  description = "Worker node definitions."
  type = map(object({
    vmid   = number
    ip     = string
    cpu    = number
    memory = number # MiB
    disk   = number # GiB
  }))
  default = {
    work-1 = { vmid = 134, ip = "192.168.68.34", cpu = 4, memory = 12288, disk = 60 }
    work-2 = { vmid = 135, ip = "192.168.68.35", cpu = 4, memory = 12288, disk = 60 }
  }
}

# ---------------------------------------------------------------------------
# Flux / GitOps (monorepo: this same repo, synced over SSH)
# ---------------------------------------------------------------------------
variable "flux_git_url" {
  description = "SSH Git URL Flux syncs from (the monorepo itself)."
  type        = string
  default     = "ssh://git@github.com/ivan-penchev/gitops.git"
}

variable "flux_git_private_key_path" {
  description = "Path to the SSH private key with push access to the gitops repo."
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "flux_path" {
  description = "Path in the monorepo Flux reconciles for this cluster."
  type        = string
  default     = "kubernetes/clusters/homelab"
}

variable "sops_age_public_key" {
  description = "age public key (age1...) matching .sops.yaml. Used to remind operators; the private key seeds the sops-age secret."
  type        = string
  default     = ""
}

variable "sops_age_key_file" {
  description = "Path to the age PRIVATE key file used to create the in-cluster sops-age secret for Flux decryption."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Cloudflare DNS
# ---------------------------------------------------------------------------
variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for 17072021.xyz."
  type        = string
  default     = "efc277581b9a576b31d2f2de7c78cade"
}

variable "cloudflare_tunnel_id" {
  description = "Cloudflare Tunnel ID that the in-cluster cloudflared connects to."
  type        = string
  default     = "d5f7a187-d8ac-4eb3-900f-d2c2a2d8f647"
}

variable "internal_ingress_ip" {
  description = "LAN IP assigned to the ingress-nginx LoadBalancer (Cilium LB pool)."
  type        = string
  default     = "192.168.68.40"
}
