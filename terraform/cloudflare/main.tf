# ---------------------------------------------------------------------------
# Cloudflare stack: the tunnel and the DNS-only LAN records.
#
#   * data.cloudflare_zone  -> derives zone id + account id from the domain.
#   * cloudflare_zero_trust_tunnel_cloudflared -> CREATES a named tunnel (local
#                               config mode) and a random tunnel secret.
#   * cloudflare_dns_record.lan -> A records for the LXCs (var.lan_records).
#
# This stack needs only the Cloudflare API. The cluster stack reads its
# outputs and writes the cloudflared Secret and the `cluster-config-tf`
# ConfigMap. Public app records are made in-cluster by external-dns.
#
# Auth: CLOUDFLARE_API_TOKEN in the environment (Zone:Read, DNS:Edit and
# Cloudflare Tunnel:Edit).
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


locals {
  # credentials.json consumed by cloudflared (credentials-file mode).
  cloudflared_credentials = jsonencode({
    AccountTag   = data.cloudflare_zone.main.account.id
    TunnelID     = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
    TunnelSecret = random_id.tunnel_secret.b64_std
  })
}

# Azure remains authoritative for penchev.com. Look up its active Cloudflare
# partial zone only to let the opt-in ExternalDNS release target that zone.
# Terraform does not create or change blog, mail, or Azure DNS records.
data "cloudflare_zone" "penchev" {
  filter = {
    name = "penchev.com"
  }
}

# DNS-only (grey) A records pointing internal names at LAN IPs. NFS and
# Postgres are not internet-safe and the CF proxy only handles HTTP(S), so
# these must not be proxied. external-dns leaves them alone: it only deletes
# records that carry its TXT ownership entry.
resource "cloudflare_dns_record" "lan" {
  for_each = var.lan_records

  zone_id = data.cloudflare_zone.main.id
  name    = each.value.name
  type    = "A"
  content = each.value.ip
  proxied = false
  ttl     = 60
  comment = each.value.comment
}
