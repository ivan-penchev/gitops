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

output "cloudflare_tunnel_id" {
  description = "ID of the Terraform-created Cloudflare Tunnel."
  value       = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
}

output "cloudflare_zone_id" {
  description = "Derived Cloudflare zone id for the domain."
  value       = data.cloudflare_zone.main.id
}

output "cloudflare_account_id" {
  description = "Derived Cloudflare account id for the domain."
  value       = data.cloudflare_zone.main.account.id
}

# ---------------------------------------------------------------------------
# Fileserver LXC / NFS
# ---------------------------------------------------------------------------
output "fileserver_ip" {
  description = "Static IP of the fileserver LXC."
  value       = var.fileserver_enabled ? var.fileserver_ip : null
}

output "fileserver_nfs_export" {
  description = "NFS export to mount from k8s (csi-driver-nfs server + share)."
  value       = var.fileserver_enabled ? "${var.fileserver_ip}:${var.fileserver_container_media_path}" : null
}

output "fileserver_fqdn" {
  description = "Cloudflare DNS name for the fileserver (DNS-only)."
  value       = var.fileserver_enabled ? "${var.fileserver_record_name}.${var.cloudflare_domain}" : null
}

output "fileserver_verify_hint" {
  description = "Command to verify the NFS export is reachable."
  value       = var.fileserver_enabled ? "showmount -e ${var.fileserver_ip}" : null
}

output "fileserver_host_mount_command" {
  description = "REQUIRED one-time host command: attach /tank/media as the bind mount + enable nesting (both root@pam-only on a privileged CT, so they can't be done via the API token)."
  value       = var.fileserver_enabled ? "pct set ${var.fileserver_vm_id} -mp0 ${var.fileserver_host_media_path},mp=${var.fileserver_container_media_path} --features nesting=1 && pct reboot ${var.fileserver_vm_id}" : null
}
