# DNS-only A records for hosts on the LAN.
#
# NFS and PostgreSQL are not internet-safe and the Cloudflare proxy only
# handles HTTP(S), so these are never proxied. external-dns leaves them alone:
# it only deletes records that carry its TXT ownership entry.

data "cloudflare_zone" "this" {
  filter = {
    name = var.domain
  }
}

resource "cloudflare_dns_record" "this" {
  for_each = var.records

  zone_id = data.cloudflare_zone.this.id
  name    = each.value.name
  type    = "A"
  content = each.value.ip
  proxied = false
  ttl     = 60
  comment = each.value.comment
}
