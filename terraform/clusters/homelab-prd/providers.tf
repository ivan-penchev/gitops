# ---------------------------------------------------------------------------
# Credentials come from secrets.sops.env through terraform/tf.sh:
# PROXMOX_VE_ENDPOINT, PROXMOX_VE_API_TOKEN and CLOUDFLARE_API_TOKEN.
# ---------------------------------------------------------------------------

# API token only, no `ssh {}` block (ISO boot, no snippet upload).
provider "proxmox" {
  endpoint  = var.proxmox_endpoint != "" ? var.proxmox_endpoint : null
  api_token = var.proxmox_api_token != "" ? var.proxmox_api_token : null
  insecure  = var.proxmox_insecure # self-signed cert on the PVE host
}

provider "talos" {}

provider "cloudflare" {}

# Wired to the Talos cluster's own kubeconfig, never ~/.kube/config, so these
# can't reach any other cluster.
locals {
  kube = module.talos_cluster.kubernetes_client_configuration
}

provider "kubernetes" {
  host                   = local.kube.host
  client_certificate     = base64decode(local.kube.client_certificate)
  client_key             = base64decode(local.kube.client_key)
  cluster_ca_certificate = base64decode(local.kube.ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = local.kube.host
    client_certificate     = base64decode(local.kube.client_certificate)
    client_key             = base64decode(local.kube.client_key)
    cluster_ca_certificate = base64decode(local.kube.ca_certificate)
  }
}

# Logs in to pg-01 as `postgres` over the LAN (sslmode=disable). It only
# connects when a postgresql_* resource is read or created, so phase 1 of a
# fresh build works before PostgreSQL exists (see modules/postgres/main.tf). pg-01 itself is in terraform/shared.
provider "postgresql" {
  host            = local.shared.postgres_ip
  port            = 5432
  username        = "postgres"
  password        = local.shared.postgres_superuser_password
  sslmode         = "disable"
  connect_timeout = 15
  superuser       = false
}
