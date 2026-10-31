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

variable "postgres_data_mounted" {
  description = <<-EOT
    Flip to true AFTER you have run the one-time root@pam host step that creates
    the ZFS dataset and bind-mounts it (printed by output.postgres_host_mount_command),
    then re-apply. This gates the DB provisioner so PGDATA is initialised on the
    dataset (survives LXC rebuild), never on the ephemeral rootfs.
  EOT
  type        = bool
}

variable "network" {
  description = "The flat LAN all hosts sit on."
  type = object({
    cidr       = string
    gateway    = string
    cidr_bits  = number
    nameserver = string
  })
}

variable "fileserver" {
  description = "Identity of the fileserver LXC. dns_name is relative to cloudflare_domain."
  type = object({
    vm_id    = number
    hostname = string
    ip       = string
    dns_name = string
    # ZFS child datasets under host_media_path, one per media type. Each is a
    # separate filesystem, so the parent bind mount doesn't include it and it
    # gets its own mpN and export line. Order sets the mp index, so append new
    # ones at the end. properties are ZFS properties set on that dataset only.
    child_datasets = list(object({
      name       = string
      properties = optional(map(string), {})
    }))
    # Set on the parent dataset. Children inherit them unless they override.
    media_properties = optional(map(string), {
      recordsize  = "1M"
      compression = "lz4"
      atime       = "off"
      xattr       = "sa"
    })
    # Owner of every media dataset. The apps write as this uid.
    media_owner          = optional(string, "100000:100000")
    host_media_path      = optional(string, "/tank/media")
    container_media_path = optional(string, "/srv/media")
    cores                = optional(number, 2)
    memory               = optional(number, 2048)
    swap                 = optional(number, 512)
    disk_size            = optional(number, 8)
    template             = optional(string, "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst")
  })
}

variable "postgres" {
  description = "Identity of the PostgreSQL LXC. dns_name is relative to cloudflare_domain."
  type = object({
    vm_id    = number
    hostname = string
    ip       = string
    dns_name = string
    # Mount at /mnt/pgdata, not /var/lib/postgresql, which would hide the
    # apt-created cluster.
    pg_version          = optional(string, "17")
    host_data_path      = optional(string, "/tank/postgres")
    container_data_path = optional(string, "/mnt/pgdata")
    cores               = optional(number, 2)
    memory              = optional(number, 2048)
    swap                = optional(number, 512)
    disk_size           = optional(number, 8)
    template            = optional(string, "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst")
  })
}

variable "lxc_root_password" {
  description = "Root password for the LXCs. Empty means SSH key only."
  type        = string
  default     = ""
  sensitive   = true
}

variable "ssh_public_key_path" {
  description = "Public key installed in the LXCs."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "ssh_private_key_path" {
  description = "Private key the provisioners use to reach the LXCs."
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "samba_users" {
  description = "Samba logins on the fileserver. read_only users can't write to media. backup users see the read-only backup share."
  type = map(object({
    read_only = optional(bool, false)
    backup    = optional(bool, false)
  }))
  default = {}
}

variable "samba_passwords" {
  description = "Samba password per user in samba_users. Set as TF_VAR_samba_passwords in secrets.sops.env."
  type        = map(string)
  default     = {}
  sensitive   = true
}
