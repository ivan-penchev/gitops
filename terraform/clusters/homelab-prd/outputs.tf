# kubeconfig and talosconfig go to gitignored files in the repo root and are
# never merged into ~/.kube/config or ~/.talos/config. Use them explicitly:
#   KUBECONFIG=./<kubeconfig_file> kubectl ...
#   talosctl --talosconfig ./<talosconfig_file> ...
resource "local_sensitive_file" "kubeconfig" {
  content         = module.talos_cluster.kubeconfig_raw
  filename        = "${local.repo_root}/${var.kubeconfig_file}"
  file_permission = "0600"
}

resource "local_sensitive_file" "talosconfig" {
  content         = module.talos_cluster.talosconfig
  filename        = "${local.repo_root}/${var.talosconfig_file}"
  file_permission = "0600"
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint (control-plane VIP)."
  value       = module.talos_cluster.cluster_endpoint
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
  value       = module.talos_cluster.node_ips
}

output "postgres_databases_provisioned" {
  description = "Databases created and the namespaces each credential Secret was injected into."
  value       = module.postgres_databases.provisioned
}
