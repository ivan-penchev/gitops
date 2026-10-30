
output "zone_id" {
  description = "Zone id of domain."
  value       = data.cloudflare_zone.main.id
}

output "account_id" {
  description = "Account id that owns domain."
  value       = data.cloudflare_zone.main.account.id
}

output "tunnel_id" {
  description = "ID of the Terraform-created Cloudflare Tunnel."
  value       = cloudflare_zero_trust_tunnel_cloudflared.this.id
}

output "tunnel_credentials_json" {
  description = "credentials.json for cloudflared (credentials-file mode)."
  value       = local.cloudflared_credentials
  sensitive   = true
}
