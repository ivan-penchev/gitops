# Static LAN addressing shared by the platform and cloudflare stacks.
# This module has no resources and no providers. Change an IP here and both
# stacks pick it up on their next plan: platform moves the host, cloudflare
# moves the DNS record. Run platform first so DNS never points at an empty IP.

locals {
  lan_hosts = {
    fileserver = {
      ip      = "192.168.68.11"
      dns     = "fileserver.int.home"
      comment = "Terraform: fileserver LXC NFS (DNS-only, LAN)"
    }
    postgres = {
      ip      = "192.168.68.12"
      dns     = "pg-01.int.home"
      comment = "Terraform: PostgreSQL LXC (DNS-only, LAN)"
    }
  }
}

output "gateway" {
  description = "Default gateway for the flat LAN."
  value       = "192.168.68.1"
}

output "cidr_bits" {
  description = "Prefix length of the LAN subnet."
  value       = 24
}

output "nameserver" {
  description = "DNS server for nodes and LXCs (Pi-hole)."
  value       = "192.168.68.20"
}

output "cluster_vip" {
  description = "Talos built-in L2 VIP for the Kubernetes API."
  value       = "192.168.68.29"
}

output "lan_hosts" {
  description = "LXCs with a static IP and a DNS-only record, keyed by role."
  value       = local.lan_hosts
}
