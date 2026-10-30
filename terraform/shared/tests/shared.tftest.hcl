# Plan-only tests with mocked providers. They need no credentials and run in CI.
# Values come from shared.auto.tfvars unless a run overrides them.

mock_provider "proxmox" {}
mock_provider "cloudflare" {}
mock_provider "null" {}
mock_provider "random" {}

variables {
  ssh_public_key_path  = "tests/fake-ssh-key"
  ssh_private_key_path = "tests/fake-ssh-key"
}

run "fileserver_mounts_every_child_dataset" {
  command = plan

  assert {
    condition     = output.fileserver_host_mount_command == "pct set 110 -mp0 /tank/media,mp=/srv/media -mp1 /tank/media/movies,mp=/srv/media/movies -mp2 /tank/media/torrent-download,mp=/srv/media/torrent-download --features nesting=1 && pct reboot 110"
    error_message = "Unexpected fileserver mount command: ${output.fileserver_host_mount_command}"
  }

  assert {
    condition     = local.fileserver_export_lines == ["/srv/media 192.168.68.0/24(rw,sync,no_subtree_check,no_root_squash)", "/srv/media/movies 192.168.68.0/24(rw,sync,no_subtree_check,no_root_squash)", "/srv/media/torrent-download 192.168.68.0/24(rw,sync,no_subtree_check,no_root_squash)"]
    error_message = "/etc/exports must list the parent and each child dataset for the LAN CIDR."
  }
}

run "fileserver_without_child_datasets" {
  command = plan

  variables {
    fileserver = {
      vm_id          = 110
      hostname       = "fileserver"
      ip             = "192.168.68.11"
      dns_name       = "fileserver.int.home"
      child_datasets = []
    }
  }

  assert {
    condition     = output.fileserver_host_mount_command == "pct set 110 -mp0 /tank/media,mp=/srv/media --features nesting=1 && pct reboot 110"
    error_message = "Unexpected fileserver mount command: ${output.fileserver_host_mount_command}"
  }
}

run "postgres_mount_command" {
  command = plan

  assert {
    condition     = startswith(output.postgres_host_mount_command, "zfs create ") && strcontains(output.postgres_host_mount_command, "pct set 111 -mp0 ")
    error_message = "Unexpected pg-01 mount command: ${output.postgres_host_mount_command}"
  }
}

run "lan_dns_records_point_at_the_lxcs" {
  command = plan

  assert {
    condition     = cloudflare_dns_record.lan["fileserver"].content == "192.168.68.11" && cloudflare_dns_record.lan["postgres"].content == "192.168.68.12"
    error_message = "LAN records must point at the LXC IPs."
  }

  assert {
    condition     = alltrue([for r in cloudflare_dns_record.lan : r.proxied == false])
    error_message = "LAN records must be DNS-only."
  }

  assert {
    condition     = output.lan_fqdns.postgres == "pg-01.int.home.17072021.xyz"
    error_message = "Unexpected pg-01 FQDN: ${output.lan_fqdns.postgres}"
  }
}
