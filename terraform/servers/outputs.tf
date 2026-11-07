output "ansible_inventory" {
  description = "Infrastructure identity only; consume with terraform output -json ansible_inventory. App settings and secrets belong to Ansible."
  sensitive   = false
  value = {
    all = {
      children = {
        pihole = {
          hosts = {
            dns_candidate = {
              ansible_host          = local.candidate_ip
              ansible_user          = "operator"
              pihole_dns_bind       = local.candidate_ip
              pihole_trusted_cidr   = var.network.lan_cidr
              pihole_provisioned_by = "terraform/servers"
            }
          }
        }
      }
    }
  }
  depends_on = [proxmox_virtual_environment_vm.pihole]
}
