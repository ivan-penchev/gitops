# Homelab-wide settings. Every cluster root reads the outputs of this one.

proxmox_node      = "pve"
vm_datastore      = "tank"
network_bridge    = "vmbr0"
cloudflare_domain = "17072021.xyz"
# Set after the one-time pg-01 host step (zfs create + bind mount). See the
# header of terraform/shared/postgres.tf. Keep false on a fresh rebuild until that is done.
postgres_data_mounted = true

network = {
  cidr       = "192.168.68.0/24"
  gateway    = "192.168.68.1"
  cidr_bits  = 24
  nameserver = "192.168.68.20" # Pi-hole
}

fileserver = {
  vm_id          = 110
  hostname       = "fileserver"
  ip             = "192.168.68.11"
  dns_name       = "fileserver.int.home"
  child_datasets = ["movies", "torrent-download"]
}

postgres = {
  vm_id    = 111
  hostname = "pg-01"
  ip       = "192.168.68.12"
  dns_name = "pg-01.int.home"
}
