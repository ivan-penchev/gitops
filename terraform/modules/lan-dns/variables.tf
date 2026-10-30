variable "domain" {
  description = "Cloudflare zone the records go in."
  type        = string
}

variable "records" {
  description = "A records keyed by role. name is relative to domain."
  type = map(object({
    name    = string
    ip      = string
    comment = string
  }))
}
