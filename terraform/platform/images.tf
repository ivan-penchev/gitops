# Download the Talos Image Factory "metal" ISO (with qemu-guest-agent) to `local`.
# API-only: no SSH needed for downloads.
resource "proxmox_download_file" "talos_iso" {
  content_type = "iso"
  datastore_id = var.iso_datastore
  node_name    = var.proxmox_node

  url       = local.talos_iso_url
  file_name = "talos-${var.talos_version}-metal-amd64.iso"
  overwrite = false
}
