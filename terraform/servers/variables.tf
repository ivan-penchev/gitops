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
  description = "Existing Proxmox node on which to create the fresh unprivileged container."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]*$", var.proxmox_node))
    error_message = "Specify a non-empty Proxmox node name."
  }
}

variable "proxmox_host_ipv4" {
  description = "PVE host IPv4 used only to reject a colliding guest address; no host SSH connection is made."
  type        = string
  validation {
    condition     = can(cidrnetmask("${var.proxmox_host_ipv4}/32")) && var.proxmox_host_ipv4 != "192.168.68.20"
    error_message = "Specify the Proxmox host IPv4 address, never the existing Pi-hole 192.168.68.20."
  }
}

variable "rootfs_datastore" {
  description = "Existing storage with rootdir support for the container root filesystem."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]*$", var.rootfs_datastore))
    error_message = "Specify a rootfs datastore ID."
  }
}

variable "template_datastore" {
  description = "Existing file storage with vztmpl content enabled. No Import or snippets content is required."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]*$", var.template_datastore))
    error_message = "Specify a container template datastore ID."
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
  description = "Operator-reserved, unused container ID in Proxmox's shared VM/CT ID namespace. Never reuse or import an existing guest; CT100 is forbidden."
  type        = number
  validation {
    condition     = var.vm_id > 100 && var.vm_id <= 999999999 && var.vm_id == floor(var.vm_id)
    error_message = "Supply an explicit integer Proxmox guest ID from 101 through 999999999; existing CT100 is protected."
  }
}

variable "container_started" {
  description = "Explicitly start the container. Defaults stopped; host autostart requires connected static networking, never isolated or DHCP staging."
  type        = bool
  default     = false
  nullable    = false
}

variable "bootstrap_dhcp" {
  description = "Temporary DHCP bootstrap only: suppress Ansible inventory and host autostart. Keep static network inputs for later reserved-address configuration."
  type        = bool
  default     = false
  nullable    = false
}

variable "network_link_down" {
  description = "Isolate the guest by omitting its NIC and IP configuration (not a native link_down flag). Set true before isolated staging; never connect an unreserved address."
  type        = bool
  default     = false
  nullable    = false
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
      split("/", var.network.ipv4_cidr)[0] != var.proxmox_host_ipv4 &&
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

variable "debian_template_url" {
  description = "Version-pinned official Proxmox Debian 13 standard amd64 tar.zst template URL. Authenticate publisher metadata before trusting its checksum; HTTP alone is not authenticated."
  type        = string
  validation {
    condition     = can(regex("^https?://download\\.proxmox\\.com/images/system/debian-13-standard_13\\.[0-9]+-[0-9]+_amd64\\.tar\\.zst$", var.debian_template_url))
    error_message = "Supply an official version-pinned Proxmox Debian 13 standard amd64 tar.zst URL, never latest, a different OS, or an arbitrary host."
  }
}

variable "debian_template_sha256" {
  description = "Operator-authenticated SHA256 for the exact template archive; required with no default. Verify against authenticated publisher metadata before calculating SHA256."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F]{64}$", var.debian_template_sha256)) && length(distinct(split("", lower(var.debian_template_sha256)))) > 1
    error_message = "Supply the template's verified 64-hex SHA256, not an empty value or repeated-character placeholder."
  }
}
