variable "proxmox_node" {
  description = "Proxmox node name. Also used as the CSI topology zone (must match the real node name)."
  type        = string
}

variable "proxmox_region" {
  description = "CSI topology region label. Must match the `region` field in the proxmox-csi cloud-config secret."
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

variable "cluster_name" {
  description = "Cluster name."
  type        = string
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

variable "cluster_vip" {
  description = "Talos built-in L2 VIP for the Kubernetes API."
  type        = string
}

variable "talos_patches_dir" {
  description = "Directory with cluster.yaml.tmpl and node.yaml.tmpl."
  type        = string
}

variable "cilium_manifest_path" {
  description = "Rendered Cilium manifest, applied as a Talos inline manifest on control planes."
  type        = string
}

variable "iso_name_prefix" {
  description = "Prefix of the Talos ISO file name on the ISO datastore. Clusters on the same Proxmox node with different schematics need different prefixes."
  type        = string
}
