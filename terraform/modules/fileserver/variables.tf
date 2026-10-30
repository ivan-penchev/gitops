variable "ip" {
  description = "Static IPv4 address (no CIDR suffix)."
  type        = string
}

variable "vm_id" {
  description = "Proxmox CT ID for the fileserver LXC."
  type        = number
}

variable "hostname" {
  description = "Hostname of the fileserver container."
  type        = string
}

variable "cores" {
  description = "vCPU cores for the fileserver LXC."
  type        = number
  default     = 2
}

variable "memory" {
  description = "RAM (MiB) for the fileserver LXC."
  type        = number
  default     = 2048
}

variable "swap" {
  description = "Swap (MiB) for the fileserver LXC."
  type        = number
  default     = 512
}

variable "disk_size" {
  description = "Root filesystem size (GiB) for the fileserver LXC."
  type        = number
  default     = 8
}

variable "template" {
  description = "Proxmox CT template volume id (already present on the node)."
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "host_media_path" {
  description = "Host path bind-mounted into the container (the existing media dir)."
  type        = string
  default     = "/tank/media"
}

variable "container_media_path" {
  description = "Path inside the container where the host media dir is mounted + exported."
  type        = string
  default     = "/srv/media"
}

variable "export_cidr" {
  description = "CIDR allowed to mount the NFS export."
  type        = string
}

variable "child_datasets" {
  description = <<-EOT
    Names of ZFS child datasets under `host_media_path` (e.g.
    /tank/media/movies) that are SEPARATE filesystems, not plain folders. Each
    needs its own bind mount (mp1, mp2, …) AND its own NFS export line, because
    the parent bind mount of /tank/media is non-recursive and does NOT include
    nested dataset mounts (a plain folder like `audiobooks` needs nothing here —
    it rides along with the parent export). Order defines the mp index.
  EOT
  type        = list(string)
}

variable "root_password" {
  description = "Optional root password for console/rescue access to the LXC (SSH is key-only). Empty = no password set."
  type        = string
  default     = ""
  sensitive   = true
}

variable "ssh_public_key_path" {
  description = "Public key injected as the container's root authorized_key."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "ssh_private_key_path" {
  description = "Private key used to SSH into the container for NFS provisioning."
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "gateway" {
  description = "Default gateway for the LAN."
  type        = string
}

variable "cidr_bits" {
  description = "Prefix length of the LAN subnet."
  type        = number
}

variable "nameserver" {
  description = "DNS server for the hosts (Pi-hole)."
  type        = string
}

variable "proxmox_node" {
  description = "Proxmox node name."
  type        = string
}

variable "vm_datastore" {
  description = "Datastore for the container root disk."
  type        = string
}

variable "network_bridge" {
  description = "Linux bridge for the container NIC."
  type        = string
}
