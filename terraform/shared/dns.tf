# DNS-only A records for hosts on the LAN.
#
# NFS and PostgreSQL are not internet-safe and the Cloudflare proxy only
# handles HTTP(S), so these are never proxied. external-dns leaves them alone:
# it only deletes records that carry its TXT ownership entry.

data "cloudflare_zone" "lan" {
  filter = {
    name = var.cloudflare_domain
  }
}

resource "cloudflare_dns_record" "lan" {
  for_each = local.lan_records

  zone_id = data.cloudflare_zone.lan.id
  name    = each.value.name
  type    = "A"
  content = each.value.ip
  proxied = false
  ttl     = 60
  comment = each.value.comment
}
