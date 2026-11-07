# Synthetic offline fixtures only; no address, VMID, key or checksum here is deployable.
mock_provider "proxmox" {}

variables {
  proxmox_node         = "fixture-pve"
  proxmox_ssh_address  = "192.168.68.2"
  proxmox_ssh_username = "root"
  vm_datastore         = "fixture-disks"
  image_datastore      = "fixture-images"
  snippet_datastore    = "fixture-snippets"
  network_bridge       = "vmbr0"
  vm_id                = 999999
  ssh_public_key       = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestFixtureOnlyNotARealPublicKey"
  debian_image_url     = "https://cloud.debian.org/images/cloud/trixie/20260101-9999/debian-13-genericcloud-amd64-20260101-9999.qcow2"
  debian_image_sha256  = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  network = {
    ipv4_cidr   = "192.168.68.250/24"
    lan_cidr    = "192.168.68.0/24"
    gateway     = "192.168.68.1"
    dns_servers = ["1.1.1.1", "9.9.9.9"]
  }
}

run "fresh_vm_contract" {
  command = plan
  assert {
    condition = (proxmox_virtual_environment_vm.pihole.vm_id == var.vm_id &&
      proxmox_virtual_environment_vm.pihole.node_name == var.proxmox_node &&
      proxmox_virtual_environment_vm.pihole.protection &&
      proxmox_virtual_environment_vm.pihole.on_boot &&
      proxmox_virtual_environment_vm.pihole.started &&
      proxmox_virtual_environment_vm.pihole.operating_system[0].type == "l26" &&
      proxmox_virtual_environment_vm.pihole.disk[0].datastore_id == var.vm_datastore &&
      proxmox_virtual_environment_vm.pihole.initialization[0].ip_config[0].ipv4[0].address == var.network.ipv4_cidr &&
    proxmox_virtual_environment_vm.pihole.network_device[0].bridge == var.network_bridge)
    error_message = "Exactly the explicitly selected protected Linux VM must be bootable on the intended LAN."
  }
  assert {
    condition = (proxmox_download_file.debian.checksum == var.debian_image_sha256 &&
      proxmox_download_file.debian.checksum_algorithm == "sha256" &&
      proxmox_download_file.debian.url == var.debian_image_url &&
      proxmox_download_file.debian.verify &&
      !proxmox_download_file.debian.overwrite &&
      !proxmox_download_file.debian.overwrite_unmanaged &&
    !proxmox_virtual_environment_file.cloud_init.overwrite)
    error_message = "Download must verify the explicit SHA256 and TLS, never overwrite unmanaged artifacts."
  }
  assert {
    condition = output.ansible_inventory == {
      all = { children = { pihole = { hosts = { dns_candidate = {
        ansible_host          = "192.168.68.250"
        ansible_user          = "operator"
        pihole_dns_bind       = "192.168.68.250"
        pihole_trusted_cidr   = "192.168.68.0/24"
        pihole_provisioned_by = "terraform/servers"
      } } } } }
    }
    error_message = "Inventory must expose only infrastructure identity at the stable dns_candidate alias."
  }
  assert {
    condition = (!issensitive(output.ansible_inventory) &&
      startswith(proxmox_virtual_environment_file.cloud_init.source_raw[0].data, "#cloud-config\n") &&
      local.cloud_config.users[0].name == "operator" &&
      local.cloud_config.users[0].sudo == ["ALL=(ALL) NOPASSWD:ALL"] &&
      local.cloud_config.users[0].ssh_authorized_keys == [var.ssh_public_key] &&
      local.cloud_config.users[0].lock_passwd &&
      !local.cloud_config.ssh_pwauth &&
    alltrue([for package in ["python3", "python3-apt", "sudo", "qemu-guest-agent"] : contains(local.cloud_config.packages, package)]))
    error_message = "Bootstrap must prepare SSH key-only operator access, Python3 and passwordless sudo; inventory stays non-sensitive."
  }
}

run "checksum_empty" {
  command = plan
  variables { debian_image_sha256 = "" }
  expect_failures = [var.debian_image_sha256]
}
run "checksum_short" {
  command = plan
  variables { debian_image_sha256 = "abc123" }
  expect_failures = [var.debian_image_sha256]
}
run "checksum_nonhex" {
  command = plan
  variables { debian_image_sha256 = "z123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }
  expect_failures = [var.debian_image_sha256]
}
run "checksum_placeholder" {
  command = plan
  variables { debian_image_sha256 = "0000000000000000000000000000000000000000000000000000000000000000" }
  expect_failures = [var.debian_image_sha256]
}
run "unpinned_image" {
  command = plan
  variables { debian_image_url = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2" }
  expect_failures = [var.debian_image_url]
}
run "non_debian13_image" {
  command = plan
  variables { debian_image_url = "https://cloud.debian.org/images/cloud/bookworm/20260101-9999/debian-12-genericcloud-amd64-20260101-9999.qcow2" }
  expect_failures = [var.debian_image_url]
}
run "http_image" {
  command = plan
  variables { debian_image_url = "http://cloud.debian.org/images/cloud/trixie/20260101-9999/debian-13-genericcloud-amd64-20260101-9999.qcow2" }
  expect_failures = [var.debian_image_url]
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
run "existing_pihole_ssh_rejected" {
  command = plan
  variables { proxmox_ssh_address = "192.168.68.20" }
  expect_failures = [var.proxmox_ssh_address]
}
run "empty_node_rejected" {
  command = plan
  variables { proxmox_node = "" }
  expect_failures = [var.proxmox_node]
}
run "empty_storage_rejected" {
  command = plan
  variables { vm_datastore = "" }
  expect_failures = [var.vm_datastore]
}
