output "postgres_databases_provisioned" {
  description = "Databases created and the namespaces each credential Secret was injected into."
  value = local.postgres_ready ? {
    for db in var.postgres_databases : db.name => {
      secret_name = "postgres-${db.name}"
      namespaces  = db.namespaces
    }
  } : null
}
