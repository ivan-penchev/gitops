output "ip" {
  description = "Static IP of the fileserver LXC."
  value       = var.ip
}

output "nfs_export" {
  description = "NFS export to mount from k8s (csi-driver-nfs server + share)."
  value       = "${var.ip}:${var.container_media_path}"
}

output "host_mount_command" {
  description = "One-time root@pam host command: bind-mount /tank/media (mp0) and each child dataset (mp1...) and enable nesting. The API token can't do this on a privileged CT."
  value       = local.mount_command
}
