output "ip" {
  description = "Static IP of the PostgreSQL LXC."
  value       = var.ip
}

output "superuser_password" {
  description = "Generated `postgres` superuser password."
  value       = random_password.postgres_superuser.result
  sensitive   = true
}

output "ready" {
  description = "PostgreSQL runs on its ZFS dataset, so databases can be created."
  value       = local.ready
}

output "host_mount_command" {
  description = "One-time root@pam host step: create the ZFS data dataset, bind-mount it and reboot. Run it between phase 1 and phase 2 (see main.tf header)."
  value       = local.mount_command
}
