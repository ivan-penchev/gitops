variable "flux_git_url" {
  description = "Public HTTPS Git URL Flux syncs from. Must match the FluxInstance sync URL."
  type        = string
  default     = "https://github.com/ivan-penchev/gitops.git"
}

variable "flux_path" {
  description = "Path in the monorepo Flux reconciles for this cluster."
  type        = string
  default     = "kubernetes/clusters/homelab"
}

variable "sops_age_key_file" {
  description = "Path to the age PRIVATE key file used to create the in-cluster sops-age secret for Flux decryption. Relative to terraform/cluster. Empty skips the secret (and deletes it if it exists)."
  type        = string
  default     = "../../age.key"
}

variable "postgres_create_namespaces" {
  description = "If true, Terraform ensures every namespace referenced in postgres_databases exists (kubernetes_namespace_v1). Set false when the namespace is already Flux-managed to avoid double ownership."
  type        = bool
  default     = true
}

variable "postgres_databases" {
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
  default = [
    {
      name       = "landingzone"
      namespaces = ["db-landing-zone"]
    }
  ]
}
