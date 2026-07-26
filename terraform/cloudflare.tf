# ---------------------------------------------------------------------------
# Cloudflare DNS for the homelab cluster.
#
# Provider auth: the Cloudflare API token is read from the CLOUDFLARE_API_TOKEN
# environment variable (same env-based pattern as Proxmox). The token only
# needs Zone:Read + DNS:Edit on the 17072021.xyz zone. It intentionally does
# NOT need Zero Trust "Tunnel: Edit" — the tunnel is configured locally in the
# cloudflared ConfigMap, not via the API.
#
# Two record classes:
#   * Internal (*.int.home) — a grey-cloud (DNS-only) wildcard A record to the
#     ingress-nginx LoadBalancer IP. Resolvable/reachable only on the LAN.
#   * Public (<app>) — one orange-cloud (proxied) CNAME per exposed app,
#     pointing at this cluster's dedicated tunnel. Coexists with the existing
#     tunnel records already in the zone; we never touch those.
# ---------------------------------------------------------------------------

provider "cloudflare" {
  # api_token comes from CLOUDFLARE_API_TOKEN in the environment.
}

# Internal wildcard: *.int.home.17072021.xyz -> ingress LB (LAN only, DNS-only).
resource "cloudflare_record" "internal_wildcard" {
  zone_id = var.cloudflare_zone_id
  name    = "*.int.home"
  type    = "A"
  content = var.internal_ingress_ip
  proxied = false
  ttl     = 1 # auto (required when not proxied)
  comment = "homelab k8s: internal apps via ingress-nginx (LAN only)"
}

# Public app (demo): whoami.17072021.xyz -> cluster tunnel (edge TLS via CF).
# Add one of these per exposed app; ingress-nginx routes by Host header.
resource "cloudflare_record" "whoami_pub" {
  zone_id = var.cloudflare_zone_id
  name    = "whoami"
  type    = "CNAME"
  content = "${var.cloudflare_tunnel_id}.cfargotunnel.com"
  proxied = true
  comment = "homelab k8s: public app via Cloudflare tunnel"
}
