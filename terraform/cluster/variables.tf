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

variable "postgres_create_namespaces" {
  description = "If true, Terraform ensures every namespace referenced in postgres_databases exists (kubernetes_namespace_v1). Set false when the namespace is already Flux-managed to avoid double ownership."
  type        = bool
  default     = true
}

variable "talos_version" {
  description = "Talos version tag, e.g. 'v1.13.7'. Set in terraform/clusters/<name>/talos-versions.tfvars."
  type        = string
}

variable "talos_config_contract" {
  description = "Talos version contract for the machine configs and secrets, e.g. 'v1.13'. Keep the version the cluster was created with. Bumping it makes the provider generate the newer config format, which can turn on features such as workload isolation. Set in terraform/clusters/<name>/talos-versions.tfvars."
  type        = string

  validation {
    condition     = can(regex("^v\\d+\\.\\d+$", var.talos_config_contract))
    error_message = "talos_config_contract must look like v1.13."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes version for Talos to install, e.g. '1.36.2'. Set in terraform/clusters/<name>/talos-versions.tfvars."
  type        = string
}

variable "sops_age_key_file" {
  description = "Path to the age PRIVATE key file used to create the in-cluster sops-age secret for Flux decryption. Relative to this directory. Empty skips the secret (and deletes it if it exists)."
  type        = string
  default     = "../../age.key"
}

variable "cluster_name" {
  description = "Cluster name."
  type        = string
}

variable "talos_schematic_id" {
  description = <<-EOT
    Talos Image Factory schematic ID for the metal ISO. Must include the
    siderolabs/qemu-guest-agent extension. Generate at https://factory.talos.dev
    or via the factory API.
  EOT
  type        = string
}

variable "control_planes" {
  description = "Control-plane node definitions."
  type = map(object({
    vmid   = number
    ip     = string
    cpu    = number
    memory = number # MiB
    disk   = number # GiB
  }))
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
}

variable "proxmox_region" {
  description = "CSI topology region label. Must match the `region` field in the proxmox-csi cloud-config secret."
  type        = string
}

variable "proxmox_csi_endpoint" {
  description = "Proxmox API URL used by proxmox-csi-plugin (must include /api2/json)."
  type        = string
}

variable "iso_datastore" {
  description = "Datastore that accepts ISO content."
  type        = string
}

variable "vm_datastore" {
  description = "Datastore for VM boot disks (ZFS)."
  type        = string
}

variable "network_bridge" {
  description = "Linux bridge for VM NICs."
  type        = string
}

variable "cloudflare_domain" {
  description = "Apex domain / Cloudflare zone name (used to derive zone id + account id)."
  type        = string
}

variable "internal_domain" {
  description = "LAN-only domain for this cluster's internal ingresses, for example int.home.example.com. It must sit inside cloudflare_domain, because ExternalDNS writes its records to that zone."
  type        = string

  validation {
    condition     = endswith(var.internal_domain, ".${var.cloudflare_domain}")
    error_message = "internal_domain must be a subdomain of cloudflare_domain."
  }
}

variable "cloudflare_tunnel_name" {
  description = "Name of the Cloudflare Tunnel Terraform creates for the cluster."
  type        = string
}

variable "flux_git_url" {
  description = "Public HTTPS Git URL Flux syncs from. Must match the FluxInstance sync URL."
  type        = string
}

variable "flux_path" {
  description = "Path in the monorepo Flux reconciles for this cluster."
  type        = string
}

variable "postgres_databases" {
  description = <<-EOT
    Databases to provision. For each entry Terraform creates a login role
    (owner == db name) with a generated password, the database, and an Opaque
    Secret `postgres-<name>` in every listed namespace carrying discrete
    connection keys plus a DATABASE_URL. Removing an entry does NOT drop the
    database (prevent_destroy) — you delete data manually.
  EOT
  type = list(object({
    name       = string
    namespaces = list(string)
  }))
}

variable "cluster_vip" {
  description = "Talos built-in L2 VIP for the Kubernetes API."
  type        = string
}

variable "csi_proxmox_role" {
  description = "Proxmox role for this cluster's CSI user. Global on the PVE host."
  type        = string
}

variable "csi_proxmox_user" {
  description = "Proxmox user for this cluster's CSI plugin. Global on the PVE host."
  type        = string
}

variable "extra_zones" {
  description = "Other Cloudflare zones whose ids Flux gets in cluster-config-tf, as <key> = <zone name>. The key becomes <key>_cf_zone_id."
  type        = map(string)
  default     = {}
}

variable "proxmox_node" {
  description = "Proxmox node the cluster VMs run on. Also the topology zone label."
  type        = string
}

variable "iso_name_prefix" {
  description = "Prefix of the Talos ISO file on iso_datastore. Must differ per cluster, since each cluster owns its ISO file."
  type        = string
}

variable "kubeconfig_file" {
  description = "File name in the repo root for the generated kubeconfig."
  type        = string
}

variable "talosconfig_file" {
  description = "File name in the repo root for the generated talosconfig."
  type        = string
}

variable "csi_token_name" {
  description = "Name of the Proxmox API token for proxmox-csi."
  type        = string
  default     = "csi"
}
