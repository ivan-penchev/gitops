variable "domain" {
  description = "Apex domain / Cloudflare zone name (used to derive zone id + account id)."
  type        = string
}

variable "tunnel_name" {
  description = "Name of the Cloudflare Tunnel Terraform creates for the cluster."
  type        = string
}
