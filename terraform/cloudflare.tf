# ---------------------------------------------------------------------------
# Cloudflare Tunnel + derived cluster config (fully IaC).
#
# Terraform owns the entire ingress-from-internet identity so a from-zero
# `terraform apply` reproduces it with no hand-copied ids:
#
#   * data.cloudflare_zone  -> derives zone id + account id from the domain.
#   * cloudflare_zero_trust_tunnel_cloudflared -> CREATES a named tunnel (local
#                               config mode) and a random tunnel secret.
#   * kubernetes_secret      -> writes credentials.json into the cloudflared ns
#                               (replaces the old SOPS `cloudflared-token`).
#   * kubernetes_config_map  -> `cluster-config-tf` in flux-system carries the
#                               three DERIVED values (cf_zone_id, cf_account_id,
#                               tunnel_id) into Flux postBuild substitution.
#
# Terraform also OWNS the `cloudflared` namespace (dropped from Flux
# namespaces.yaml) so the creds secret has a home before Flux reconciles.
#
# Auth: CLOUDFLARE_API_TOKEN in the environment (Zone:Read + Cloudflare
# Tunnel:Edit). DNS records themselves are still created in-cluster by
# external-dns; Terraform only owns the tunnel + config identifiers.
# ---------------------------------------------------------------------------

provider "cloudflare" {
  # api_token comes from CLOUDFLARE_API_TOKEN in the environment.
}

# Zone id + account id derived from the domain (no hand-copied ids).
# provider v5: lookup wrapped in a `filter` block; account id is read back as the
# nested `.account.id` (was flat `.account_id` in v4).
data "cloudflare_zone" "main" {
  filter = {
    name = var.cloudflare_domain
  }
}

# 32-byte tunnel secret; cloudflared expects the base64 form in credentials.json
# and the tunnel resource takes the same base64 string.
resource "random_id" "tunnel_secret" {
  byte_length = 32
}

# The cluster's Cloudflare Tunnel. config_src = "local" keeps ingress rules in
# the GitOps ConfigMap (cloudflared runs in credentials-file mode).
# provider v5: resource renamed cloudflare_tunnel -> cloudflare_zero_trust_tunnel_cloudflared,
# and `secret` -> `tunnel_secret` (same base64 value).
resource "cloudflare_zero_trust_tunnel_cloudflared" "homelab" {
  account_id    = data.cloudflare_zone.main.account.id
  name          = var.cloudflare_tunnel_name
  tunnel_secret = random_id.tunnel_secret.b64_std
  config_src    = "local"
}

# cloudflare v4->v5 rename. The provider's MoveState upgrader transforms the
# existing state in place (preserving tunnel_secret), so no destroy/recreate.
moved {
  from = cloudflare_tunnel.homelab
  to   = cloudflare_zero_trust_tunnel_cloudflared.homelab
}

locals {
  # credentials.json consumed by cloudflared (credentials-file mode).
  cloudflared_credentials = jsonencode({
    AccountTag   = data.cloudflare_zone.main.account.id
    TunnelID     = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
    TunnelSecret = random_id.tunnel_secret.b64_std
  })
}

# Terraform-owned namespace for cloudflared (removed from Flux namespaces.yaml).
resource "kubernetes_namespace_v1" "cloudflared" {
  metadata {
    name = "cloudflared"
  }

  depends_on = [talos_cluster_kubeconfig.this]
}

# Tunnel credentials — replaces the SOPS `cloudflared-token` secret. Same name +
# key so cloudflared.yaml's volume mount is unchanged.
resource "kubernetes_secret_v1" "cloudflared_token" {
  metadata {
    name      = "cloudflared-token"
    namespace = kubernetes_namespace_v1.cloudflared.metadata[0].name
  }

  data = {
    "credentials.json" = local.cloudflared_credentials
  }

  type = "Opaque"
}

# Derived, Terraform-managed half of the Flux substitution config. Static values
# (domains, LB IPs) stay in Git at kubernetes/clusters/homelab/cluster-config.yaml.
resource "kubernetes_config_map_v1" "cluster_config_tf" {
  metadata {
    name      = "cluster-config-tf"
    namespace = "flux-system"
  }

  data = {
    cf_zone_id    = data.cloudflare_zone.main.id
    cf_account_id = data.cloudflare_zone.main.account.id
    tunnel_id     = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
  }

  depends_on = [flux_bootstrap_git.this]
}
