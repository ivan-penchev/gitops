# Cluster roots read these through terraform_remote_state.

output "network" {
  description = "Gateway, prefix length and nameserver of the LAN."
  value       = var.network
}

output "proxmox_node" {
  description = "Proxmox node the shared hosts run on."
  value       = var.proxmox_node
}

output "fileserver_nfs_export" {
  description = "NFS export to mount from k8s (csi-driver-nfs server + share)."
  value       = "${var.fileserver.ip}:${var.fileserver.container_media_path}"
}

output "fileserver_host_mount_command" {
  description = "One-time root@pam host command for the fileserver bind mounts."
  value       = local.fileserver_mount_command
}

output "postgres_ip" {
  description = "Static IP of pg-01."
  value       = var.postgres.ip
}

output "postgres_fqdn" {
  description = "DNS name apps use to reach pg-01."
  value       = { for k, r in local.lan_records : k => "${r.name}.${var.cloudflare_domain}" }["postgres"]
}

output "postgres_ready" {
  description = "PostgreSQL runs on its ZFS dataset, so cluster roots can create databases."
  value       = local.postgres_ready
}

output "postgres_superuser_password" {
  description = "Generated `postgres` superuser password. Cluster roots log in with it."
  value       = random_password.postgres_superuser.result
  sensitive   = true
}

output "postgres_host_mount_command" {
  description = "One-time root@pam host step for the pg-01 data dataset."
  value       = local.postgres_mount_command
}

output "lan_fqdns" {
  description = "FQDN of each LAN DNS record."
  value       = { for k, r in local.lan_records : k => "${r.name}.${var.cloudflare_domain}" }
}
