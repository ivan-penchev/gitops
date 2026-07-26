# ---------------------------------------------------------------------------
# Outputs + local credential files.
#
# SAFETY: kubeconfig/talosconfig are written to gitignored files in the repo
# root and are NEVER merged into ~/.kube/config or ~/.talos/config. Use them
# explicitly:  KUBECONFIG=./kubeconfig kubectl ...   /   talosctl --talosconfig ./talosconfig ...
# ---------------------------------------------------------------------------

resource "local_sensitive_file" "kubeconfig" {
  content         = talos_cluster_kubeconfig.this.kubeconfig_raw
  filename        = "${path.module}/../kubeconfig"
  file_permission = "0600"
}

resource "local_sensitive_file" "talosconfig" {
  content         = data.talos_client_configuration.this.talos_config
  filename        = "${path.module}/../talosconfig"
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
