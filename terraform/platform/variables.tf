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

# ---------------------------------------------------------------------------
# Talos / Kubernetes versions + image
# ---------------------------------------------------------------------------
variable "cluster_name" {
  description = "Cluster name."
  type        = string
  default     = "homelab"
}

variable "talos_version" {
  description = "Talos version tag, e.g. 'v1.13.7'. Set in talos-versions.auto.tfvars."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for Talos to install, e.g. '1.36.2'. Set in talos-versions.auto.tfvars."
  type        = string
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
    cp-1 = { vmid = 131, ip = "192.168.68.31", cpu = 4, memory = 8192, disk = 30 }
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
# Fileserver LXC (shared media over NFS)
#
# A privileged Debian 12 LXC that bind-mounts the host's ZFS media dir and
# re-exports it over NFS so k8s pods (via csi-driver-nfs) get an RWX shared
# media tree instead of per-app RWO copies. Created via the root@pam provider
# alias; NFS is configured over container-SSH (host stays API-only).
# ---------------------------------------------------------------------------
variable "fileserver_enabled" {
  description = "Create the fileserver LXC. Its IP and DNS name are in modules/network."
  type        = bool
  default     = true
}

variable "fileserver_vm_id" {
  description = "Proxmox CT ID for the fileserver LXC."
  type        = number
  default     = 110
}

variable "fileserver_hostname" {
  description = "Hostname of the fileserver container."
  type        = string
  default     = "fileserver"
}

variable "fileserver_cores" {
  description = "vCPU cores for the fileserver LXC."
  type        = number
  default     = 2
}

variable "fileserver_memory" {
  description = "RAM (MiB) for the fileserver LXC."
  type        = number
  default     = 2048
}

variable "fileserver_swap" {
  description = "Swap (MiB) for the fileserver LXC."
  type        = number
  default     = 512
}

variable "fileserver_disk_size" {
  description = "Root filesystem size (GiB) for the fileserver LXC."
  type        = number
  default     = 8
}

variable "fileserver_template" {
  description = "Proxmox CT template volume id (already present on the node)."
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "fileserver_host_media_path" {
  description = "Host path bind-mounted into the container (the existing media dir)."
  type        = string
  default     = "/tank/media"
}

variable "fileserver_container_media_path" {
  description = "Path inside the container where the host media dir is mounted + exported."
  type        = string
  default     = "/srv/media"
}

variable "fileserver_export_cidr" {
  description = "CIDR allowed to mount the NFS export."
  type        = string
  default     = "192.168.68.0/24"
}

variable "fileserver_child_datasets" {
  description = <<-EOT
    Names of ZFS child datasets under `fileserver_host_media_path` (e.g.
    /tank/media/movies) that are SEPARATE filesystems, not plain folders. Each
    needs its own bind mount (mp1, mp2, …) AND its own NFS export line, because
    the parent bind mount of /tank/media is non-recursive and does NOT include
    nested dataset mounts (a plain folder like `audiobooks` needs nothing here —
    it rides along with the parent export). Order defines the mp index.
  EOT
  type        = list(string)
  default     = ["movies", "torrent-download"]
}

variable "fileserver_root_password" {
  description = "Optional root password for console/rescue access to the LXC (SSH is key-only). Empty = no password set."
  type        = string
  default     = ""
  sensitive   = true
}

variable "fileserver_ssh_public_key_path" {
  description = "Public key injected as the container's root authorized_key."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "fileserver_ssh_private_key_path" {
  description = "Private key used to SSH into the container for NFS provisioning."
  type        = string
  default     = "~/.ssh/id_rsa"
}

# ===========================================================================
# PostgreSQL LXC (pg-01) — shared homelab database server
# ===========================================================================
# A single privileged Debian LXC running PostgreSQL, provisioned like the
# fileserver (API-token create + SSH provisioner; the data-dir bind mount is the
# one root@pam-only host step). Databases and their k8s Secrets are declared in
# the cluster stack (terraform/cluster/variables.tf).
# ===========================================================================

variable "postgres_enabled" {
  description = "Create the PostgreSQL LXC. With it off, the cluster stack creates no databases."
  type        = bool
  default     = true
}

variable "postgres_vm_id" {
  description = "Proxmox CT ID for the PostgreSQL LXC."
  type        = number
  default     = 111
}

variable "postgres_hostname" {
  description = "Hostname of the PostgreSQL container (also the internal DNS label)."
  type        = string
  default     = "pg-01"
}

variable "postgres_cores" {
  description = "vCPU cores for the PostgreSQL LXC."
  type        = number
  default     = 2
}

variable "postgres_memory" {
  description = "RAM (MiB) for the PostgreSQL LXC."
  type        = number
  default     = 2048
}

variable "postgres_swap" {
  description = "Swap (MiB) for the PostgreSQL LXC."
  type        = number
  default     = 512
}

variable "postgres_disk_size" {
  description = "Root filesystem size (GiB) for the PostgreSQL LXC. Data lives on the bind-mounted ZFS dataset, not here."
  type        = number
  default     = 8
}

variable "postgres_template" {
  description = "Proxmox CT template volume id (already present on the node)."
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "postgres_version" {
  description = "PostgreSQL major version to install from the PGDG apt repo."
  type        = string
  default     = "17"
}

variable "postgres_host_data_path" {
  description = "Host ZFS dataset bind-mounted into the container to hold PGDATA (created on the host: `zfs create tank/postgres`)."
  type        = string
  default     = "/tank/postgres"
}

variable "postgres_container_data_path" {
  description = "Path inside the container where the data dataset is mounted. Deliberately NON-shadowing (not /var/lib/postgresql) so the apt cluster dir is never hidden; PGDATA is placed under here."
  type        = string
  default     = "/mnt/pgdata"
}

variable "postgres_data_mounted" {
  description = <<-EOT
    Flip to true AFTER you have run the one-time root@pam host step that creates
    the ZFS dataset and bind-mounts it (printed by output.postgres_host_mount_command),
    then re-apply. This gates the DB provisioner so PGDATA is initialised on the
    dataset (survives LXC rebuild), never on the ephemeral rootfs.
  EOT
  type        = bool
  default     = false
}

variable "postgres_client_cidr" {
  description = "CIDR allowed to connect to PostgreSQL (pg_hba scram-sha-256). LAN-only by default."
  type        = string
  default     = "192.168.68.0/24"
}

variable "postgres_root_password" {
  description = "Optional root password for console/rescue access to the LXC (SSH is key-only). Empty = no password set."
  type        = string
  default     = ""
  sensitive   = true
}

variable "postgres_ssh_public_key_path" {
  description = "Public key injected as the container's root authorized_key."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "postgres_ssh_private_key_path" {
  description = "Private key used to SSH into the container for provisioning."
  type        = string
  default     = "~/.ssh/id_rsa"
}

