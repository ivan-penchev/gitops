# ---------------------------------------------------------------------------
# Proxmox (bpg/proxmox)
# Reads PROXMOX_VE_ENDPOINT and PROXMOX_VE_API_TOKEN from the environment by
# default; the vars below are optional overrides. API-token-only (no SSH).
# ---------------------------------------------------------------------------
provider "proxmox" {
  endpoint  = var.proxmox_endpoint != "" ? var.proxmox_endpoint : null
  api_token = var.proxmox_api_token != "" ? var.proxmox_api_token : null
  insecure  = var.proxmox_insecure # self-signed cert on the PVE host

  # No `ssh {}` block on purpose: design is API-only (ISO boot, no snippet upload).
}

# ---------------------------------------------------------------------------
# Talos (siderolabs/talos) — no provider config required.
# ---------------------------------------------------------------------------
provider "talos" {}

# ---------------------------------------------------------------------------
# Kubernetes + Flux providers.
#
# SAFETY: these are wired to the Talos cluster via the talos_cluster_kubeconfig
# data source below — NOT to ~/.kube/config. They can only ever reach the new
# Talos cluster, never your existing AKS/kind contexts.
# ---------------------------------------------------------------------------
provider "kubernetes" {
  host                   = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
  client_certificate     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
  client_key             = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
  cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
}

provider "flux" {
  kubernetes = {
    host                   = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
    client_certificate     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
    client_key             = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
    cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
  }

  git = {
    url = var.flux_git_url
    ssh = {
      username    = "git"
      private_key = file(pathexpand(var.flux_git_private_key_path))
    }
  }
}

# ---------------------------------------------------------------------------
# PostgreSQL (cyrilgdn/postgresql) — manages roles/databases on the pg-01 LXC.
#
# Connects over the LAN to the LXC's static IP as the `postgres` superuser using
# the generated password (set once by the DB provisioner). Plaintext on the
# trusted LAN (sslmode=disable). The provider only opens a connection when a
# postgresql_* resource is read/created, so a first `-target` apply of just the
# LXC works before PostgreSQL is reachable (see postgres.tf header for phases).
# ---------------------------------------------------------------------------
provider "postgresql" {
  host            = var.postgres_ip
  port            = 5432
  username        = "postgres"
  password        = random_password.postgres_superuser.result
  sslmode         = "disable"
  connect_timeout = 15
  superuser       = false
}
