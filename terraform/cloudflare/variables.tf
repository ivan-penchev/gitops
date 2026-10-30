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
