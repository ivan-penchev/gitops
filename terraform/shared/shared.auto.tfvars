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
  vm_id    = 110
  hostname = "fileserver"
  ip       = "192.168.68.11"
  dns_name = "fileserver.int.home"
  # The table in docs/architecture.md says what each one is for.
  child_datasets = [
    { name = "movies" },
    # Torrents write small random pieces. The quota keeps a stuck download
    # from filling the pool that also holds pg-01 and every PVC.
    { name = "torrent-download", properties = { recordsize = "128K", quota = "300G" } },
    { name = "tv" },
    { name = "audiobooks" },
    { name = "ebooks" },
    { name = "photos", properties = { quota = "500G" } },
    { name = "home-videos" },
    { name = "documents", properties = { recordsize = "128K", compression = "zstd", quota = "50G" } },
  ]
}

postgres = {
  vm_id    = 111
  hostname = "pg-01"
  ip       = "192.168.68.12"
  dns_name = "pg-01.int.home"
}

# Samba logins for Windows. Passwords live in secrets.sops.env.
# A second person: add `name = {}`, or `name = { read_only = true }`.
samba_users = {
  ivan = { backup = true }
}
