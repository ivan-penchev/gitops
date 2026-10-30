# kubeconfig and talosconfig go to gitignored files in the repo root and are
# never merged into ~/.kube/config or ~/.talos/config. Use them explicitly:
#   KUBECONFIG=./<kubeconfig_file> kubectl ...
#   talosctl --talosconfig ./<talosconfig_file> ...
resource "local_sensitive_file" "kubeconfig" {
  content         = talos_cluster_kubeconfig.this.kubeconfig_raw
  filename        = "${local.repo_root}/${var.kubeconfig_file}"
  file_permission = "0600"
}

resource "local_sensitive_file" "talosconfig" {
  content         = data.talos_client_configuration.this.talos_config
  filename        = "${local.repo_root}/${var.talosconfig_file}"
  file_permission = "0600"
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint (control-plane VIP)."
  value       = local.cluster_endpoint
}

output "kubeconfig_path" {
  description = "Path to the generated, gitignored kubeconfig."
  value       = local_sensitive_file.kubeconfig.filename
}

output "talosconfig_path" {
  description = "Path to the generated, gitignored talosconfig."
  value       = local_sensitive_file.talosconfig.filename
}

output "node_ips" {
  description = "Static IPs assigned to each Talos node."
  value       = { for k, v in local.nodes : k => v.ip }
}

output "postgres_databases_provisioned" {
  description = "Databases created and the namespaces each credential Secret was injected into."
  value = local.shared.postgres_ready ? {
    for db in var.postgres_databases : db.name => {
      secret_name = "postgres-${db.name}"
      namespaces  = db.namespaces
    }
  } : null
}
