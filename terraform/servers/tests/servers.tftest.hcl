# Synthetic offline fixtures only; no address, VMID, key or checksum here is deployable.
mock_provider "proxmox" {}

variables {
  proxmox_node           = "fixture-pve"
  proxmox_host_ipv4      = "192.168.68.2"
  rootfs_datastore       = "fixture-disks"
  template_datastore     = "fixture-images"
  network_bridge         = "vmbr0"
  vm_id                  = 999999
  ssh_public_key         = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestFixtureOnlyNotARealPublicKey"
  debian_template_url    = "https://download.proxmox.com/images/system/debian-13-standard_13.99-999_amd64.tar.zst"
  debian_template_sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  network = {
    ipv4_cidr   = "192.168.68.250/24"
    lan_cidr    = "192.168.68.0/24"
    gateway     = "192.168.68.1"
    dns_servers = ["1.1.1.1", "9.9.9.9"]
  }
}

run "fresh_container_contract" {
  command = plan
  assert {
    condition = (proxmox_virtual_environment_container.pihole.vm_id == var.vm_id &&
      proxmox_virtual_environment_container.pihole.node_name == var.proxmox_node &&
      proxmox_virtual_environment_container.pihole.protection &&
      proxmox_virtual_environment_container.pihole.unprivileged &&
      !proxmox_virtual_environment_container.pihole.start_on_boot &&
      !proxmox_virtual_environment_container.pihole.started &&
      proxmox_virtual_environment_container.pihole.operating_system[0].type == "debian" &&
      proxmox_virtual_environment_container.pihole.disk[0].datastore_id == var.rootfs_datastore &&
      proxmox_virtual_environment_container.pihole.disk[0].size == 8 &&
      proxmox_virtual_environment_container.pihole.initialization[0].ip_config[0].ipv4[0].address == var.network.ipv4_cidr &&
      proxmox_virtual_environment_container.pihole.network_interface[0].enabled &&
    proxmox_virtual_environment_container.pihole.network_interface[0].bridge == var.network_bridge)
    error_message = "Exactly the explicitly selected protected unprivileged Debian CT must be staged stopped."
  }
  assert {
    condition = (proxmox_download_file.debian.checksum == var.debian_template_sha256 &&
      proxmox_download_file.debian.checksum_algorithm == "sha256" &&
      proxmox_download_file.debian.url == var.debian_template_url &&
      proxmox_download_file.debian.datastore_id == var.template_datastore &&
      proxmox_download_file.debian.verify &&
      !proxmox_download_file.debian.overwrite &&
      !proxmox_download_file.debian.overwrite_unmanaged &&
    proxmox_download_file.debian.content_type == "vztmpl")
    error_message = "Template download must verify the explicit SHA256 and never overwrite unmanaged artifacts."
  }
  assert {
    condition = output.ansible_inventory == {
      all = { children = { pihole = { hosts = { dns_candidate = {
        ansible_host          = "192.168.68.250"
        ansible_user          = "root"
        pihole_dns_bind       = "192.168.68.250"
        pihole_trusted_cidr   = "192.168.68.0/24"
        pihole_provisioned_by = "terraform/servers"
      } } } } }
    }
    error_message = "Inventory must expose only infrastructure identity at the stable dns_candidate alias."
  }
  assert {
    condition = (!issensitive(output.ansible_inventory) &&
      proxmox_virtual_environment_container.pihole.initialization[0].user_account[0].keys == tolist([var.ssh_public_key]) &&
      (proxmox_virtual_environment_container.pihole.initialization[0].user_account[0].password == null ||
      proxmox_virtual_environment_container.pihole.initialization[0].user_account[0].password == "") &&
      !proxmox_virtual_environment_container.pihole.features[0].nesting &&
      !proxmox_virtual_environment_container.pihole.features[0].keyctl &&
      !proxmox_virtual_environment_container.pihole.features[0].fuse &&
      !proxmox_virtual_environment_container.pihole.features[0].mknod &&
      proxmox_virtual_environment_container.pihole.initialization[0].dns[0].servers == var.network.dns_servers &&
      proxmox_virtual_environment_container.pihole.initialization[0].ip_config[0].ipv4[0].gateway == var.network.gateway &&
      proxmox_virtual_environment_container.pihole.console[0].enabled &&
    proxmox_virtual_environment_container.pihole.console[0].type == "shell")
    error_message = "API root keys, guest-only console and explicit networking must not enable privileged/nested features."
  }
}

run "explicit_connected_boot" {
  command = plan
  variables { container_started = true }
  assert {
    condition = (proxmox_virtual_environment_container.pihole.started &&
    proxmox_virtual_environment_container.pihole.start_on_boot)
    error_message = "Connected boot and automatic startup require the explicit start switch."
  }
}

run "isolated_guest_boot" {
  command = plan
  variables {
    container_started = true
    network_link_down = true
  }
  assert {
    condition = (proxmox_virtual_environment_container.pihole.started &&
      !proxmox_virtual_environment_container.pihole.start_on_boot &&
      length(proxmox_virtual_environment_container.pihole.network_interface) == 0 &&
    length(proxmox_virtual_environment_container.pihole.initialization[0].ip_config) == 0)
    error_message = "Isolated staging must omit all guest NICs/IPs and prohibit host autostart."
  }
}

run "dhcp_bootstrap_without_static_identity" {
  command = plan
  variables {
    container_started = true
    bootstrap_dhcp    = true
  }
  assert {
    condition = (proxmox_virtual_environment_container.pihole.started &&
      !proxmox_virtual_environment_container.pihole.start_on_boot &&
      proxmox_virtual_environment_container.pihole.network_interface[0].enabled &&
      proxmox_virtual_environment_container.pihole.initialization[0].ip_config[0].ipv4[0].address == "dhcp" &&
      (proxmox_virtual_environment_container.pihole.initialization[0].ip_config[0].ipv4[0].gateway == null ||
    proxmox_virtual_environment_container.pihole.initialization[0].ip_config[0].ipv4[0].gateway == ""))
    error_message = "DHCP staging must request a lease with no static gateway and no host autostart."
  }
  assert {
    condition     = output.ansible_inventory == null
    error_message = "DHCP must never expose the placeholder static address to the integrated runner."
  }
}

run "dhcp_stopped_without_inventory" {
  command = plan
  variables { bootstrap_dhcp = true }
  assert {
    condition = (!proxmox_virtual_environment_container.pihole.started &&
      !proxmox_virtual_environment_container.pihole.start_on_boot &&
    output.ansible_inventory == null)
    error_message = "A stopped DHCP test guest must retain its DHCP flag and suppress inventory."
  }
}

run "dhcp_cannot_override_network_isolation" {
  command = plan
  variables {
    container_started = true
    bootstrap_dhcp    = true
    network_link_down = true
  }
  assert {
    condition = (length(proxmox_virtual_environment_container.pihole.network_interface) == 0 &&
      length(proxmox_virtual_environment_container.pihole.initialization[0].ip_config) == 0 &&
      !proxmox_virtual_environment_container.pihole.start_on_boot &&
    output.ansible_inventory == null)
    error_message = "Network isolation takes precedence over DHCP and inventory remains suppressed."
  }
}

run "dhcp_still_rejects_existing_ct100" {
  command = plan
  variables {
    bootstrap_dhcp = true
    vm_id          = 100
  }
  expect_failures = [var.vm_id]
}

run "dhcp_still_rejects_existing_pihole_input" {
  command = plan
  variables {
    bootstrap_dhcp = true
    network        = { ipv4_cidr = "192.168.68.20/24", lan_cidr = "192.168.68.0/24", gateway = "192.168.68.1", dns_servers = ["1.1.1.1"] }
  }
  expect_failures = [var.network]
}

run "existing_ct100_rejected" {
  command = plan
  variables { vm_id = 100 }
  expect_failures = [var.vm_id]
}

run "checksum_empty" {
  command = plan
  variables { debian_template_sha256 = "" }
  expect_failures = [var.debian_template_sha256]
}
run "checksum_short" {
  command = plan
  variables { debian_template_sha256 = "abc123" }
  expect_failures = [var.debian_template_sha256]
}
run "checksum_nonhex" {
  command = plan
  variables { debian_template_sha256 = "z123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }
  expect_failures = [var.debian_template_sha256]
}
run "checksum_placeholder" {
  command = plan
  variables { debian_template_sha256 = "0000000000000000000000000000000000000000000000000000000000000000" }
  expect_failures = [var.debian_template_sha256]
}
run "unpinned_template" {
  command = plan
  variables { debian_template_url = "https://download.proxmox.com/images/system/debian-13-standard_latest_amd64.tar.zst" }
  expect_failures = [var.debian_template_url]
}
run "non_debian13_template" {
  command = plan
  variables { debian_template_url = "https://download.proxmox.com/images/system/debian-12-standard_12.99-999_amd64.tar.zst" }
  expect_failures = [var.debian_template_url]
}
run "untrusted_template_host" {
  command = plan
  variables { debian_template_url = "http://untrusted.example/images/system/debian-13-standard_13.99-999_amd64.tar.zst" }
  expect_failures = [var.debian_template_url]
}
run "private_key_rejected" {
  command = plan
  variables { ssh_public_key = "-----BEGIN OPENSSH PRIVATE KEY-----" }
  expect_failures = [var.ssh_public_key]
}
run "empty_key_rejected" {
  command = plan
  variables { ssh_public_key = "" }
  expect_failures = [var.ssh_public_key]
}
run "auto_vmid_rejected" {
  command = plan
  variables { vm_id = -1 }
  expect_failures = [var.vm_id]
}
run "fractional_vmid_rejected" {
  command = plan
  variables { vm_id = 123.5 }
  expect_failures = [var.vm_id]
}
run "low_vmid_rejected" {
  command = plan
  variables { vm_id = 99 }
  expect_failures = [var.vm_id]
}
run "oversize_vmid_rejected" {
  command = plan
  variables { vm_id = 1000000000 }
  expect_failures = [var.vm_id]
}
run "existing_pihole_rejected" {
  command = plan
  variables {
    network = { ipv4_cidr = "192.168.68.20/24", lan_cidr = "192.168.68.0/24", gateway = "192.168.68.1", dns_servers = ["1.1.1.1"] }
  }
  expect_failures = [var.network]
}
run "proxmox_host_collision_rejected" {
  command = plan
  variables {
    network = { ipv4_cidr = "192.168.68.2/24", lan_cidr = "192.168.68.0/24", gateway = "192.168.68.1", dns_servers = ["1.1.1.1"] }
  }
  expect_failures = [var.network]
}
run "network_address_rejected" {
  command = plan
  variables {
    network = { ipv4_cidr = "192.168.68.0/24", lan_cidr = "192.168.68.0/24", gateway = "192.168.68.1", dns_servers = ["1.1.1.1"] }
  }
  expect_failures = [var.network]
}
run "broadcast_rejected" {
  command = plan
  variables {
    network = { ipv4_cidr = "192.168.68.255/24", lan_cidr = "192.168.68.0/24", gateway = "192.168.68.1", dns_servers = ["1.1.1.1"] }
  }
  expect_failures = [var.network]
}
run "gateway_collision_rejected" {
  command = plan
  variables {
    network = { ipv4_cidr = "192.168.68.1/24", lan_cidr = "192.168.68.0/24", gateway = "192.168.68.1", dns_servers = ["1.1.1.1"] }
  }
  expect_failures = [var.network]
}
run "different_lan_rejected" {
  command = plan
  variables {
    network = { ipv4_cidr = "192.168.69.250/24", lan_cidr = "192.168.68.0/24", gateway = "192.168.68.1", dns_servers = ["1.1.1.1"] }
  }
  expect_failures = [var.network]
}
run "different_gateway_lan_rejected" {
  command = plan
  variables {
    network = { ipv4_cidr = "192.168.68.250/24", lan_cidr = "192.168.68.0/24", gateway = "192.168.69.1", dns_servers = ["1.1.1.1"] }
  }
  expect_failures = [var.network]
}
run "public_target_rejected" {
  command = plan
  variables {
    network = { ipv4_cidr = "8.8.8.8/24", lan_cidr = "8.8.8.0/24", gateway = "8.8.8.1", dns_servers = ["1.1.1.1"] }
  }
  expect_failures = [var.network]
}
run "overbroad_private_lan_rejected" {
  command = plan
  variables {
    network = { ipv4_cidr = "192.168.68.250/8", lan_cidr = "192.0.0.0/8", gateway = "192.168.68.1", dns_servers = ["1.1.1.1"] }
  }
  expect_failures = [var.network]
}
run "ipv6_rejected" {
  command = plan
  variables {
    network = { ipv4_cidr = "fd00::2/64", lan_cidr = "fd00::/64", gateway = "fd00::1", dns_servers = ["1.1.1.1"] }
  }
  expect_failures = [var.network]
}
run "malformed_target_rejected" {
  command = plan
  variables {
    network = { ipv4_cidr = "not-an-ip", lan_cidr = "192.168.68.0/24", gateway = "192.168.68.1", dns_servers = ["1.1.1.1"] }
  }
  expect_failures = [var.network]
}
run "missing_prefix_rejected" {
  command = plan
  variables {
    network = { ipv4_cidr = "192.168.68.250", lan_cidr = "192.168.68.0/24", gateway = "192.168.68.1", dns_servers = ["1.1.1.1"] }
  }
  expect_failures = [var.network]
}
run "mismatched_prefix_rejected" {
  command = plan
  variables {
    network = { ipv4_cidr = "192.168.68.250/25", lan_cidr = "192.168.68.0/24", gateway = "192.168.68.1", dns_servers = ["1.1.1.1"] }
  }
  expect_failures = [var.network]
}
run "host_as_lan_rejected" {
  command = plan
  variables {
    network = { ipv4_cidr = "192.168.68.250/24", lan_cidr = "192.168.68.5/24", gateway = "192.168.68.1", dns_servers = ["1.1.1.1"] }
  }
  expect_failures = [var.network]
}
run "existing_dns_dependency_rejected" {
  command = plan
  variables {
    network = { ipv4_cidr = "192.168.68.250/24", lan_cidr = "192.168.68.0/24", gateway = "192.168.68.1", dns_servers = ["192.168.68.20"] }
  }
  expect_failures = [var.network]
}
run "self_dns_dependency_rejected" {
  command = plan
  variables {
    network = { ipv4_cidr = "192.168.68.250/24", lan_cidr = "192.168.68.0/24", gateway = "192.168.68.1", dns_servers = ["192.168.68.250"] }
  }
  expect_failures = [var.network]
}
run "no_dns_rejected" {
  command = plan
  variables {
    network = { ipv4_cidr = "192.168.68.250/24", lan_cidr = "192.168.68.0/24", gateway = "192.168.68.1", dns_servers = [] }
  }
  expect_failures = [var.network]
}
run "existing_pihole_host_rejected" {
  command = plan
  variables { proxmox_host_ipv4 = "192.168.68.20" }
  expect_failures = [var.proxmox_host_ipv4]
}
run "empty_node_rejected" {
  command = plan
  variables { proxmox_node = "" }
  expect_failures = [var.proxmox_node]
}
run "empty_storage_rejected" {
  command = plan
  variables { rootfs_datastore = "" }
  expect_failures = [var.rootfs_datastore]
}

run "wrong_architecture_rejected" {
  command = plan
  variables { debian_template_url = "https://download.proxmox.com/images/system/debian-13-standard_13.99-999_arm64.tar.zst" }
  expect_failures = [var.debian_template_url]
}

run "official_http_with_pinned_digest" {
  command = plan
  variables { debian_template_url = "http://download.proxmox.com/images/system/debian-13-standard_13.99-999_amd64.tar.zst" }
  assert {
    condition     = proxmox_download_file.debian.checksum == var.debian_template_sha256
    error_message = "Official HTTP archives still require the separately authenticated pinned digest."
  }
}
