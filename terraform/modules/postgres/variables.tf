variable "ip" {
  description = "Static IPv4 address (no CIDR suffix)."
  type        = string
}

variable "vm_id" {
  description = "Proxmox CT ID for the PostgreSQL LXC."
  type        = number
}

variable "hostname" {
  description = "Hostname of the PostgreSQL container (also the internal DNS label)."
  type        = string
}

variable "cores" {
  description = "vCPU cores for the PostgreSQL LXC."
  type        = number
  default     = 2
}

variable "memory" {
  description = "RAM (MiB) for the PostgreSQL LXC."
  type        = number
  default     = 2048
}

variable "swap" {
  description = "Swap (MiB) for the PostgreSQL LXC."
  type        = number
  default     = 512
}

variable "disk_size" {
  description = "Root filesystem size (GiB) for the PostgreSQL LXC. Data lives on the bind-mounted ZFS dataset, not here."
  type        = number
  default     = 8
}

variable "template" {
  description = "Proxmox CT template volume id (already present on the node)."
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "pg_version" {
  description = "PostgreSQL major version to install from the PGDG apt repo."
  type        = string
  default     = "17"
}

variable "host_data_path" {
  description = "Host ZFS dataset bind-mounted into the container to hold PGDATA (created on the host: `zfs create tank/postgres`)."
  type        = string
  default     = "/tank/postgres"
}

variable "container_data_path" {
  description = "Path inside the container where the data dataset is mounted. Deliberately NON-shadowing (not /var/lib/postgresql) so the apt cluster dir is never hidden; PGDATA is placed under here."
  type        = string
  default     = "/mnt/pgdata"
}

variable "data_mounted" {
  description = <<-EOT
    Flip to true AFTER you have run the one-time root@pam host step that creates
    the ZFS dataset and bind-mounts it (printed by output.postgres_host_mount_command),
    then re-apply. This gates the DB provisioner so PGDATA is initialised on the
    dataset (survives LXC rebuild), never on the ephemeral rootfs.
  EOT
  type        = bool
  default     = false
}

variable "client_cidr" {
  description = "CIDR allowed to connect to PostgreSQL (pg_hba scram-sha-256)."
  type        = string
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
  description = "Private key used to SSH into the container for provisioning."
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
