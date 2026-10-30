# ---------------------------------------------------------------------------
# Cloudflare Tunnel objects in the cluster. The tunnel itself is in the
# cloudflare stack.
#
#   * kubernetes_secret     -> credentials.json in the cloudflared namespace.
#   * kubernetes_config_map -> `cluster-config-tf` in flux-system carries the
#                              derived ids (cf_zone_id, cf_account_id,
#                              penchev_cf_zone_id, tunnel_id) into Flux
#                              postBuild substitution.
#
# Terraform owns the `cloudflared` namespace (dropped from Flux
# namespaces.yaml) so the creds secret has a home before Flux reconciles.
# ---------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "cloudflared" {
  metadata {
    name = "cloudflared"
  }
}

# Same name + key as the old SOPS `cloudflared-token`, so cloudflared.yaml's
# volume mount is unchanged.
resource "kubernetes_secret_v1" "cloudflared_token" {
  metadata {
    name      = "cloudflared-token"
    namespace = kubernetes_namespace_v1.cloudflared.metadata[0].name
  }

  data = {
    "credentials.json" = local.cloudflare.tunnel_credentials_json
  }

  type = "Opaque"
}

# Terraform-managed half of the Flux substitution config. Static values
# (domains, LB IPs) stay in Git at kubernetes/clusters/homelab/cluster-config.yaml.
resource "kubernetes_config_map_v1" "cluster_config_tf" {
  metadata {
    name      = "cluster-config-tf"
    namespace = "flux-system"
  }

  data = {
    cf_zone_id         = local.cloudflare.zone_id
    cf_account_id      = local.cloudflare.account_id
    penchev_cf_zone_id = local.cloudflare.penchev_zone_id
    tunnel_id          = local.cloudflare.tunnel_id
  }

  depends_on = [kubernetes_namespace_v1.flux_system]
}
