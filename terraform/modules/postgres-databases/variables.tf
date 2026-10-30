variable "host" {
  description = "DNS name apps use to reach PostgreSQL, e.g. pg-01.int.home.<domain>."
  type        = string
}

variable "ready" {
  description = "Create databases only when true (PostgreSQL is up on its dataset)."
  type        = bool
}

variable "databases" {
  description = <<-EOT
    Databases to provision. For each entry Terraform creates a login role
    (owner == db name) with a generated password, the database, and an Opaque
    Secret `postgres-<name>` in every listed namespace carrying discrete
    connection keys plus a DATABASE_URL. Removing an entry does NOT drop the
    database (prevent_destroy) — you delete data manually.
  EOT
  type = list(object({
    name       = string
    namespaces = list(string)
  }))
}

variable "create_namespaces" {
  description = "If true, Terraform ensures every namespace referenced in postgres_databases exists (kubernetes_namespace_v1). Set false when the namespace is already Flux-managed to avoid double ownership."
  type        = bool
  default     = true
}
