variable "proxmox_endpoint" {
  description = "API endpoint; empty uses PROXMOX_VE_ENDPOINT. Use an IP or independent resolver, not the existing Pi-hole."
  type        = string
  default     = ""
}

variable "proxmox_api_token" {
  description = "API token; empty uses PROXMOX_VE_API_TOKEN. Keep credentials out of tfvars."
  type        = string
  default     = ""
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Explicit opt-in for a self-signed Proxmox API certificate."
  type        = bool
  default     = false
}

variable "proxmox_node" {
  description = "Existing Proxmox node on which to create the fresh VM."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]*$", var.proxmox_node))
    error_message = "Specify a non-empty Proxmox node name."
  }
}

variable "proxmox_ssh_address" {
  description = "Explicit PVE host IPv4 address for snippet upload, independent of Pi-hole DNS."
  type        = string
  validation {
    condition     = can(cidrnetmask("${var.proxmox_ssh_address}/32")) && var.proxmox_ssh_address != "192.168.68.20"
    error_message = "Specify the Proxmox host IPv4 address, never the existing Pi-hole 192.168.68.20."
  }
}

variable "proxmox_ssh_username" {
  description = "PVE SSH user with permission to write snippets (root, or a properly configured sudo account). Authentication uses SSH_AUTH_SOCK."
  type        = string
  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]*$", var.proxmox_ssh_username))
    error_message = "Specify an explicit PVE SSH username."
  }
}

variable "vm_datastore" {
  description = "Existing storage for VM and cloud-init disks."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]*$", var.vm_datastore))
    error_message = "Specify a VM datastore ID."
  }
}

variable "image_datastore" {
  description = "Existing file storage with Import content enabled (PVE 8.4+)."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]*$", var.image_datastore))
    error_message = "Specify an image datastore ID."
  }
}

variable "snippet_datastore" {
  description = "Existing file storage with Snippets content enabled."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]*$", var.snippet_datastore))
    error_message = "Specify a snippet datastore ID."
  }
}

variable "network_bridge" {
  description = "Existing Linux bridge attached to the intended LAN."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]*$", var.network_bridge))
    error_message = "Specify a network bridge."
  }
}

variable "vm_id" {
  description = "Operator-reserved, unused VMID. No auto-allocation, existing VM import, or reuse. Verify availability outside Terraform."
  type        = number
  validation {
    condition     = var.vm_id >= 100 && var.vm_id <= 999999999 && var.vm_id == floor(var.vm_id)
    error_message = "Supply an explicit integer Proxmox VMID from 100 through 999999999."
  }
}

variable "network" {
  description = "Explicit unused RFC1918 IPv4/CIDR, canonical LAN CIDR, gateway and independent bootstrap DNS. Never target or depend on existing Pi-hole .20."
  type = object({
    ipv4_cidr   = string
    lan_cidr    = string
    gateway     = string
    dns_servers = list(string)
  })
  validation {
    condition = try(
      can(cidrnetmask(var.network.ipv4_cidr)) &&
      can(cidrnetmask(var.network.lan_cidr)) &&
      tonumber(split("/", var.network.lan_cidr)[1]) >= 8 &&
      tonumber(split("/", var.network.lan_cidr)[1]) <= 30 &&
      var.network.lan_cidr == "${cidrhost(var.network.lan_cidr, 0)}/${split("/", var.network.lan_cidr)[1]}" &&
      split("/", var.network.ipv4_cidr)[1] == split("/", var.network.lan_cidr)[1] &&
      cidrhost(var.network.ipv4_cidr, 0) == cidrhost(var.network.lan_cidr, 0) &&
      can(regex("^(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.)", split("/", var.network.ipv4_cidr)[0])) &&
      tonumber(split("/", var.network.lan_cidr)[1]) >= (startswith(var.network.ipv4_cidr, "192.168.") ? 16 : startswith(var.network.ipv4_cidr, "172.") ? 12 : 8) &&
      !contains([cidrhost(var.network.lan_cidr, 0), cidrhost(var.network.lan_cidr, -1), var.network.gateway], split("/", var.network.ipv4_cidr)[0]) &&
      !endswith(split("/", var.network.ipv4_cidr)[0], ".20") &&
      split("/", var.network.ipv4_cidr)[0] != var.proxmox_ssh_address &&
      can(cidrnetmask("${var.network.gateway}/32")) &&
      cidrhost("${var.network.gateway}/${split("/", var.network.lan_cidr)[1]}", 0) == cidrhost(var.network.lan_cidr, 0) &&
      !contains([cidrhost(var.network.lan_cidr, 0), cidrhost(var.network.lan_cidr, -1), "192.168.68.20"], var.network.gateway),
    false)
    error_message = "Use a fresh RFC1918 host (never .20, PVE, gateway, network or broadcast), canonical private LAN /8../30, matching host prefix, and a usable gateway in that LAN."
  }
  validation {
    condition = try(length(var.network.dns_servers) > 0 && alltrue([
      for ip in var.network.dns_servers : can(cidrnetmask("${ip}/32")) &&
      !contains(["192.168.68.20", split("/", var.network.ipv4_cidr)[0], "0.0.0.0", "255.255.255.255"], ip) &&
      !startswith(ip, "127.")
    ]), false)
    error_message = "Supply independent bootstrap DNS IPv4 servers; existing Pi-hole .20, the candidate itself and loopback are forbidden."
  }
}

variable "ssh_public_key" {
  description = "Operator's public OpenSSH key as text, never a private key or a path."
  type        = string
  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]+={0,2}( [^\\r\\n]+)?$", trimspace(var.ssh_public_key)))
    error_message = "Supply a single OpenSSH public key (ed25519, RSA or ECDSA); private keys and file paths are rejected."
  }
}

variable "debian_image_url" {
  description = "Immutable official Debian 13 amd64 genericcloud QCOW2 release URL. No latest/current aliases. Verify its publisher signature before selecting the SHA256."
  type        = string
  validation {
    condition     = can(regex("^https://cloud\\.debian\\.org/images/cloud/trixie/[0-9]{8}-[0-9]+/debian-13-genericcloud-amd64-[0-9]{8}-[0-9]+\\.qcow2$", var.debian_image_url))
    error_message = "Supply a dated official Debian 13 trixie genericcloud amd64 QCOW2 URL, not latest, HTTP, or a different OS."
  }
}

variable "debian_image_sha256" {
  description = "Operator-verified SHA256 for the exact downloaded image; required and intentionally has no default."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F]{64}$", var.debian_image_sha256)) && length(distinct(split("", lower(var.debian_image_sha256)))) > 1
    error_message = "Supply the image's verified 64-hex SHA256, not an empty value or repeated-character placeholder."
  }
}
