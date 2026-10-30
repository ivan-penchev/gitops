# The cluster stack reads these through terraform_remote_state.

output "zone_id" {
  description = "Zone id of cloudflare_domain."
  value       = data.cloudflare_zone.main.id
}

output "account_id" {
  description = "Account id that owns cloudflare_domain."
  value       = data.cloudflare_zone.main.account.id
}

output "penchev_zone_id" {
  description = "Zone id of the penchev.com partial zone (opt-in ExternalDNS target)."
  value       = data.cloudflare_zone.penchev.id
}

output "tunnel_id" {
  description = "ID of the Terraform-created Cloudflare Tunnel."
  value       = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
}

output "tunnel_credentials_json" {
  description = "credentials.json for cloudflared (credentials-file mode)."
  value       = local.cloudflared_credentials
  sensitive   = true
}

output "lan_fqdns" {
  description = "FQDN of each modules/network lan_hosts entry, keyed the same way."
  value       = { for k, r in module.network.lan_hosts : k => "${r.dns}.${var.cloudflare_domain}" }
}
