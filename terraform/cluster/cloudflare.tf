# A Cloudflare Tunnel for one cluster, in credentials-file mode.
# Auth: CLOUDFLARE_API_TOKEN (Zone:Read, Cloudflare Tunnel:Edit).

# Zone id + account id derived from the domain (no hand-copied ids).
# provider v5: lookup wrapped in a `filter` block; account id is read back as the
# nested `.account.id` (was flat `.account_id` in v4).
data "cloudflare_zone" "main" {
  filter = {
    name = var.cloudflare_zone
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
resource "cloudflare_zero_trust_tunnel_cloudflared" "tunnel" {
  account_id    = data.cloudflare_zone.main.account.id
  name          = var.cloudflare_tunnel_name
  tunnel_secret = random_id.tunnel_secret.b64_std
  config_src    = "local"
}


locals {
  # credentials.json consumed by cloudflared (credentials-file mode).
  cloudflared_credentials = jsonencode({
    AccountTag   = data.cloudflare_zone.main.account.id
    TunnelID     = cloudflare_zero_trust_tunnel_cloudflared.tunnel.id
    TunnelSecret = random_id.tunnel_secret.b64_std
  })
}

# Zones outside cloudflare_zone whose ids Flux needs, keyed by a short name.
data "cloudflare_zone" "extra" {
  for_each = var.extra_zones

  filter = {
    name = each.value
  }
}

locals {
  # Read by Flux postBuild substitution through the cluster-config-tf ConfigMap.
  cluster_config = merge(
    {
      cf_zone_id    = data.cloudflare_zone.main.id
      cf_account_id = data.cloudflare_zone.main.account.id
      tunnel_id     = cloudflare_zero_trust_tunnel_cloudflared.tunnel.id
      public_domain = var.public_domain
      lan_domain    = var.lan_domain
      dns_owner_id  = var.dns_owner_id
      # Old name for lan_domain. Remove once main no longer uses it.
      internal_domain = var.lan_domain
    },
    { for k, z in data.cloudflare_zone.extra : "${k}_cf_zone_id" => z.id },
  )
}
