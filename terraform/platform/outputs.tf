# ---------------------------------------------------------------------------
# Outputs + local credential files.
#
# SAFETY: kubeconfig/talosconfig are written to gitignored files in the repo
# root and are NEVER merged into ~/.kube/config or ~/.talos/config. Use them
# explicitly:  KUBECONFIG=./kubeconfig kubectl ...   /   talosctl --talosconfig ./talosconfig ...
# ---------------------------------------------------------------------------

resource "local_sensitive_file" "kubeconfig" {
  content         = talos_cluster_kubeconfig.this.kubeconfig_raw
  filename        = "${path.module}/../../kubeconfig"
  file_permission = "0600"
}

resource "local_sensitive_file" "talosconfig" {
  content         = data.talos_client_configuration.this.talos_config
  filename        = "${path.module}/../../talosconfig"
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

# ---------------------------------------------------------------------------
# Fileserver LXC / NFS
# ---------------------------------------------------------------------------
output "fileserver_ip" {
  description = "Static IP of the fileserver LXC."
  value       = var.fileserver_enabled ? local.fileserver_ip : null
}

output "fileserver_nfs_export" {
  description = "NFS export to mount from k8s (csi-driver-nfs server + share)."
  value       = var.fileserver_enabled ? "${local.fileserver_ip}:${var.fileserver_container_media_path}" : null
}

output "fileserver_verify_hint" {
  description = "Command to verify the NFS export is reachable."
  value       = var.fileserver_enabled ? "showmount -e ${local.fileserver_ip}" : null
}

output "fileserver_host_mount_command" {
  description = "REQUIRED one-time host command: attach /tank/media (mp0) + each child dataset (mp1…) as bind mounts + enable nesting (all root@pam-only on a privileged CT, so they can't be done via the API token)."
  value       = var.fileserver_enabled ? local.fileserver_mount_command : null
}

# ---------------------------------------------------------------------------
# PostgreSQL LXC (pg-01)
# ---------------------------------------------------------------------------
output "postgres_ip" {
  description = "Static IP of the PostgreSQL LXC."
  value       = var.postgres_enabled ? local.postgres_ip : null
}

output "postgres_host_mount_command" {
  description = "REQUIRED one-time root@pam host step: create the ZFS data dataset + bind-mount it, then reboot (both root@pam-only on a privileged CT). Run this between phase 1 and phase 2 (see postgres.tf header)."
  value       = var.postgres_enabled ? local.postgres_mount_command : null
}

output "postgres_superuser_password" {
  description = "Generated `postgres` superuser password (for manual admin / psql)."
  value       = var.postgres_enabled ? random_password.postgres_superuser.result : null
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Read by the cluster stack through terraform_remote_state.
# ---------------------------------------------------------------------------
output "kubernetes_client_configuration" {
  description = "API host and client certificates for the cluster stack's kubernetes/helm providers."
  value       = talos_cluster_kubeconfig.this.kubernetes_client_configuration
  sensitive   = true
}

output "csi_cloud_config" {
  description = "Rendered proxmox-csi-plugin cloud-config (contains the CSI token)."
  value       = local.csi_cloud_config
  sensitive   = true
}

output "postgres_ready" {
  description = "PostgreSQL is up on its ZFS dataset, so the cluster stack can create databases."
  value       = local.postgres_ready
}
