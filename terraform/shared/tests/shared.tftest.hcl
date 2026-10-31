# Plan-only tests with mocked providers. They need no credentials and run in CI.
# Values come from shared.auto.tfvars unless a run overrides them.

mock_provider "proxmox" {}
mock_provider "cloudflare" {}
mock_provider "null" {}
mock_provider "random" {}

variables {
  ssh_public_key_path  = "tests/fake-ssh-key"
  ssh_private_key_path = "tests/fake-ssh-key"
  samba_passwords      = { ivan = "test" }
}

run "fileserver_mounts_every_child_dataset" {
  command = plan

  assert {
    condition     = output.fileserver_host_mount_command == "pct set 110 -mp0 /tank/media,mp=/srv/media -mp1 /tank/media/movies,mp=/srv/media/movies -mp2 /tank/media/torrent-download,mp=/srv/media/torrent-download -mp3 /tank/media/tv,mp=/srv/media/tv -mp4 /tank/media/audiobooks,mp=/srv/media/audiobooks -mp5 /tank/media/ebooks,mp=/srv/media/ebooks -mp6 /tank/media/photos,mp=/srv/media/photos -mp7 /tank/media/home-videos,mp=/srv/media/home-videos -mp8 /tank/media/documents,mp=/srv/media/documents --features nesting=1 && pct reboot 110"
    error_message = "Unexpected fileserver mount command: ${output.fileserver_host_mount_command}"
  }

  assert {
    condition     = local.fileserver_export_lines == ["/srv/media 192.168.68.0/24(rw,sync,no_subtree_check,no_root_squash)", "/srv/media/movies 192.168.68.0/24(rw,sync,no_subtree_check,no_root_squash)", "/srv/media/torrent-download 192.168.68.0/24(rw,sync,no_subtree_check,no_root_squash)", "/srv/media/tv 192.168.68.0/24(rw,sync,no_subtree_check,no_root_squash)", "/srv/media/audiobooks 192.168.68.0/24(rw,sync,no_subtree_check,no_root_squash)", "/srv/media/ebooks 192.168.68.0/24(rw,sync,no_subtree_check,no_root_squash)", "/srv/media/photos 192.168.68.0/24(rw,sync,no_subtree_check,no_root_squash)", "/srv/media/home-videos 192.168.68.0/24(rw,sync,no_subtree_check,no_root_squash)", "/srv/media/documents 192.168.68.0/24(rw,sync,no_subtree_check,no_root_squash)"]
    error_message = "/etc/exports must list the parent and each child dataset for the LAN CIDR."
  }
}

run "fileserver_dataset_command" {
  command = plan

  variables {
    fileserver = {
      vm_id    = 110
      hostname = "fileserver"
      ip       = "192.168.68.11"
      dns_name = "fileserver.int.home"
      child_datasets = [
        { name = "movies" },
        { name = "documents", properties = { quota = "50G", recordsize = "128K" } },
      ]
    }
  }

  assert {
    condition = output.fileserver_dataset_command == join("\n", [
      "zfs set atime=off compression=lz4 recordsize=1M xattr=sa tank/media",
      "zfs list -H -o name tank/media/movies >/dev/null 2>&1 || zfs create tank/media/movies",
      "zfs list -H -o name tank/media/documents >/dev/null 2>&1 || zfs create tank/media/documents",
      "zfs set quota=50G recordsize=128K tank/media/documents",
      "chown 100000:100000 /tank/media/movies /tank/media/documents",
    ])
    error_message = "Unexpected dataset command: ${output.fileserver_dataset_command}"
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

run "samba_shares_per_user" {
  command = plan

  variables {
    samba_users = {
      ivan = { backup = true }
      gf   = { read_only = true }
    }
    samba_passwords = { ivan = "a", gf = "b" }
  }

  assert {
    condition     = strcontains(local.samba_conf, "  valid users = gf ivan\n  read only = yes\n  write list = ivan\n")
    error_message = "media share must list both users and let only ivan write:\n${local.samba_conf}"
  }

  assert {
    condition     = strcontains(local.samba_conf, "[backup]\n  path = /srv/backup\n  valid users = ivan\n")
    error_message = "backup share must be ivan only:\n${local.samba_conf}"
  }
}

run "samba_needs_a_password_per_user" {
  command = plan

  variables {
    samba_users     = { ivan = {}, gf = {} }
    samba_passwords = { ivan = "a" }
  }

  expect_failures = [null_resource.fileserver_samba_users]
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
