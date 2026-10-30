# ---------------------------------------------------------------------------
# One Talos cluster and what it needs outside Kubernetes. Shared hosts
# (fileserver, pg-01) come from terraform/shared through local.shared.
# Values live in cluster.auto.tfvars.
# ---------------------------------------------------------------------------

locals {
  repo_root = "${path.root}/../../.."
}

# Talos ISO, the node VMs, Talos config and bootstrap.
module "talos_cluster" {
  source = "../../modules/talos-cluster"

  cluster_name       = var.cluster_name
  cluster_vip        = var.cluster_vip
  control_planes     = var.control_planes
  workers            = var.workers
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
  talos_schematic_id = var.talos_schematic_id
  iso_name_prefix    = var.iso_name_prefix

  talos_patches_dir    = "${local.repo_root}/talos/patches"
  cilium_manifest_path = "${local.repo_root}/talos/cilium/cilium.yaml"

  proxmox_node   = var.proxmox_node
  proxmox_region = var.proxmox_region
  iso_datastore  = var.iso_datastore
  vm_datastore   = var.vm_datastore
  network_bridge = var.network_bridge
  gateway        = local.shared.network.gateway
  cidr_bits      = local.shared.network.cidr_bits
  nameserver     = local.shared.network.nameserver
}

module "cloudflare_tunnel" {
  source = "../../modules/cloudflare-tunnel"

  domain      = var.cloudflare_domain
  tunnel_name = var.cloudflare_tunnel_name
}

data "cloudflare_zone" "extra" {
  for_each = var.extra_zones

  filter = {
    name = each.value
  }
}

# Proxmox user and token for proxmox-csi, and the Secret the chart reads.
module "proxmox_csi" {
  source = "../../modules/proxmox-csi"

  proxmox_node         = var.proxmox_node
  proxmox_region       = var.proxmox_region
  proxmox_csi_endpoint = var.proxmox_csi_endpoint
  proxmox_insecure     = var.proxmox_insecure
  role_id              = var.csi_proxmox_role
  user_id              = var.csi_proxmox_user
}

# Roles, databases and app Secrets on pg-01.
module "postgres_databases" {
  source = "../../modules/postgres-databases"

  host              = local.shared.postgres_fqdn
  ready             = local.shared.postgres_ready
  databases         = var.postgres_databases
  create_namespaces = var.postgres_create_namespaces
}

module "cloudflared" {
  source = "../../modules/cloudflared"

  credentials_json = module.cloudflare_tunnel.tunnel_credentials_json
}

# flux-system namespace, sops-age Secret and cluster-config-tf ConfigMap.
module "flux" {
  source = "../../modules/flux"

  git_url           = var.flux_git_url
  manifests_dir     = "${local.repo_root}/${var.flux_path}/flux-system"
  sops_age_key_file = var.sops_age_key_file
  cluster_config = merge(
    {
      cf_zone_id    = module.cloudflare_tunnel.zone_id
      cf_account_id = module.cloudflare_tunnel.account_id
      tunnel_id     = module.cloudflare_tunnel.tunnel_id
    },
    { for k, z in data.cloudflare_zone.extra : "${k}_cf_zone_id" => z.id },
  )
}

# Installs the Flux Operator and the FluxInstance once. Flux manages both
# from Git afterwards. Bump revision to run the bootstrap again.
module "flux_operator_bootstrap" {
  source  = "controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes"
  version = "0.9.0"

  revision         = 1
  gitops_resources = module.flux.gitops_resources

  depends_on = [module.flux]
}
