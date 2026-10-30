output "fqdns" {
  description = "FQDN of each record, keyed like records."
  value       = { for k, r in var.records : k => "${r.name}.${var.domain}" }
}
