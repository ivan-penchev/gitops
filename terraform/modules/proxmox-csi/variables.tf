variable "proxmox_node" {
  description = "Proxmox node name. Also used as the CSI topology zone (must match the real node name)."
  type        = string
}

variable "proxmox_region" {
  description = "CSI topology region label. Must match the `region` field in the proxmox-csi cloud-config secret."
  type        = string
}

variable "proxmox_csi_endpoint" {
  description = "Proxmox API URL used by proxmox-csi-plugin (must include /api2/json)."
  type        = string
}

variable "proxmox_insecure" {
  description = "Skip TLS verification for the self-signed Proxmox cert."
  type        = bool
  default     = true
}

variable "role_id" {
  description = "Proxmox role for the CSI user. Roles are global on the PVE host, so make it unique per cluster."
  type        = string
}

variable "user_id" {
  description = "Proxmox user for the CSI plugin, e.g. <cluster>-csi@pve. Unique per cluster."
  type        = string
}

variable "token_name" {
  description = "Name of the API token on user_id."
  type        = string
  default     = "csi"
}
