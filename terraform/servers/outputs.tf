output "ansible_inventory" {
  description = "Infrastructure identity only; null during DHCP bootstrap so no placeholder static target can reach Ansible. App settings and secrets belong to Ansible."
  sensitive   = false
  value = var.bootstrap_dhcp ? null : {
    all = {
      children = {
        pihole = {
          hosts = {
            dns_candidate = {
              ansible_host          = local.candidate_ip
              ansible_user          = "root"
              pihole_dns_bind       = local.candidate_ip
              pihole_trusted_cidr   = var.network.lan_cidr
              pihole_provisioned_by = "terraform/servers"
            }
          }
        }
      }
    }
  }
  depends_on = [proxmox_virtual_environment_container.pihole]
}
