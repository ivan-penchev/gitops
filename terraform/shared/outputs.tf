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
  value       = module.fileserver.nfs_export
}

output "fileserver_host_mount_command" {
  description = "One-time root@pam host command for the fileserver bind mounts."
  value       = module.fileserver.host_mount_command
}

output "postgres_ip" {
  description = "Static IP of pg-01."
  value       = module.postgres.ip
}

output "postgres_fqdn" {
  description = "DNS name apps use to reach pg-01."
  value       = module.lan_dns.fqdns["postgres"]
}

output "postgres_ready" {
  description = "PostgreSQL runs on its ZFS dataset, so cluster roots can create databases."
  value       = module.postgres.ready
}

output "postgres_superuser_password" {
  description = "Generated `postgres` superuser password. Cluster roots log in with it."
  value       = module.postgres.superuser_password
  sensitive   = true
}

output "postgres_host_mount_command" {
  description = "One-time root@pam host step for the pg-01 data dataset."
  value       = module.postgres.host_mount_command
}

output "lan_fqdns" {
  description = "FQDN of each LAN DNS record."
  value       = module.lan_dns.fqdns
}
