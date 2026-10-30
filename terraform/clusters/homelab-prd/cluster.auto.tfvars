# Settings for the homelab-prd cluster. Copy this directory to add a cluster.

# Talos cluster name. It also prefixes node hostnames and VM names, so
# changing it re-registers every node. Kept from before the homelab-prd rename.
cluster_name = "homelab"

talos_schematic_id = "ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"
control_planes = {
  cp-1 = { vmid = 131, ip = "192.168.68.31", cpu = 4, memory = 8192, disk = 30 }
}
workers = {
  work-1 = { vmid = 134, ip = "192.168.68.34", cpu = 4, memory = 12288, disk = 60 }
  work-2 = { vmid = 135, ip = "192.168.68.35", cpu = 4, memory = 12288, disk = 60 }
}
proxmox_node           = "pve"
proxmox_region         = "homelab"
proxmox_csi_endpoint   = "https://192.168.68.2:8006/api2/json"
iso_datastore          = "local"
vm_datastore           = "tank"
network_bridge         = "vmbr0"
cloudflare_domain      = "17072021.xyz"
cloudflare_tunnel_name = "homelab-prd"
flux_git_url           = "https://github.com/ivan-penchev/gitops.git"
flux_path              = "kubernetes/clusters/homelab"
postgres_databases = [
  {
    name       = "landingzone"
    namespaces = ["db-landing-zone"]
  }
]

cluster_vip = "192.168.68.29"

# Kept from before the multi-cluster layout. A new cluster should use
# "<cluster>-talos", "kubeconfig-<cluster>" and "talosconfig-<cluster>".
iso_name_prefix  = "talos"
kubeconfig_file  = "kubeconfig"
talosconfig_file = "talosconfig"

# Created before the multi-cluster layout. A new cluster should use
# <cluster>-csi names so the users don't collide on the PVE host.
csi_proxmox_role = "CSI"
csi_proxmox_user = "kubernetes-csi@pve"

# penchev.com stays on Azure DNS. Its Cloudflare partial zone id is only
# handed to the opt-in ExternalDNS release.
extra_zones = {
  penchev = "penchev.com"
}
