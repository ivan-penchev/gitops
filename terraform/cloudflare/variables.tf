variable "cloudflare_domain" {
  description = "Apex domain / Cloudflare zone name (used to derive zone id + account id)."
  type        = string
  default     = "17072021.xyz"
}

variable "cloudflare_tunnel_name" {
  description = "Name of the Cloudflare Tunnel Terraform creates for the cluster."
  type        = string
  default     = "homelab-k8s"
}

variable "lan_records" {
  description = <<-EOT
    DNS-only A records for the LXCs the platform stack runs. The IPs must match
    the platform stack's fileserver_ip and postgres_ip. The cluster stack looks
    up the `postgres` key.
  EOT
  type = map(object({
    name    = string
    ip      = string
    comment = string
  }))
  default = {
    fileserver = {
      name    = "fileserver.int.home"
      ip      = "192.168.68.11"
      comment = "Terraform: fileserver LXC NFS (DNS-only, LAN)"
    }
    postgres = {
      name    = "pg-01.int.home"
      ip      = "192.168.68.12"
      comment = "Terraform: PostgreSQL LXC (DNS-only, LAN)"
    }
  }
}
