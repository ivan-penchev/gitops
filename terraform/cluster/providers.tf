# ---------------------------------------------------------------------------
# Kubernetes and Helm providers.
#
# SAFETY: these use the client credentials the platform stack got from
# talos_cluster_kubeconfig, NOT ~/.kube/config. They can only ever reach the
# Talos cluster, never your existing AKS/kind contexts.
# ---------------------------------------------------------------------------
locals {
  kube = local.platform.kubernetes_client_configuration
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

# ---------------------------------------------------------------------------
# PostgreSQL (cyrilgdn/postgresql) — manages roles/databases on the pg-01 LXC.
#
# Connects over the LAN to the LXC's static IP as the `postgres` superuser,
# with the password the platform stack generated and set. Plaintext on the
# trusted LAN (sslmode=disable). The provider only opens a connection when a
# postgresql_* resource is read/created, so nothing connects until the
# platform stack reports postgres_ready.
# ---------------------------------------------------------------------------
provider "postgresql" {
  host            = local.platform.postgres_ip
  port            = 5432
  username        = "postgres"
  password        = local.platform.postgres_superuser_password
  sslmode         = "disable"
  connect_timeout = 15
  superuser       = false
}
