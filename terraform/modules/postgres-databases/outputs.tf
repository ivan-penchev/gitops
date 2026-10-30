output "provisioned" {
  description = "Databases created and the namespaces each credential Secret was injected into."
  value = var.ready ? {
    for db in var.databases : db.name => {
      secret_name = "postgres-${db.name}"
      namespaces  = db.namespaces
    }
  } : null
}
