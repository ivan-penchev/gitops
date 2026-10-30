output "cluster_endpoint" {
  description = "Kubernetes API endpoint (control-plane VIP)."
  value       = local.cluster_endpoint
}

output "node_ips" {
  description = "Static IPs assigned to each Talos node."
  value       = { for k, v in local.nodes : k => v.ip }
}

output "kubeconfig_raw" {
  description = "Admin kubeconfig for the cluster."
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "kubernetes_client_configuration" {
  description = "API host and client certificates for the kubernetes and helm providers."
  value       = talos_cluster_kubeconfig.this.kubernetes_client_configuration
  sensitive   = true
}

output "talosconfig" {
  description = "talosconfig for talosctl."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}
