# ===========================================================================
# Fileserver LXC — shared media over NFS  (Proxmox VE 9)
# ===========================================================================
#
# WHY THIS EXISTS
# ---------------
# A media center constantly MOVES files between folders (torrent client writes
# to a download dir; an *arr app hardlinks/moves it into the library) and then
# several apps (Jellyfin, Audiobookshelf, *arr) READ the same tree at once.
# Per-app RWO PVCs can't do that: they can't be shared, and a cross-PVC "move"
# becomes a full copy that also breaks hardlinks. The fix is ONE shared media
# tree exported over NFS (RWX) that every pod mounts (via csi-driver-nfs).
#
# This file builds that NFS server as a small Debian 12 LXC that bind-mounts the
# host's existing media dir (/tank/media) and re-exports it to the LAN.
#
# ---------------------------------------------------------------------------
# ⚠️  ONE REQUIRED MANUAL HOST STEP  (this is the "Option B" model)
# ---------------------------------------------------------------------------
# Proxmox hardcodes a rule (verified live on THIS PVE 9 host): a container mount
# point that points at a host path (a "bind mount") is refused for every account
# except the literal root@pam login:
#
#     HTTP 403: "mount point type bind is only allowed for root@pam"
#
# This is NOT an ACL/permission you can grant — our scoped API token
# (terraform-prov@pve, privsep=0/admin) still gets the 403. Everything else the
# token CAN do: it successfully creates the privileged container, nesting, IP,
# etc. Only the single bind-mount line is off-limits.
#
# So to keep using the normal token (no root@pam password stored in Terraform),
# Terraform creates the container WITHOUT the bind mount OR the nesting feature
# flag, and you add BOTH once by hand on the Proxmox host (root@pam on the host
# shell is allowed):
#
#     pct set 110 -mp0 /tank/media,mp=/srv/media --features nesting=1 && pct reboot 110
#
# (`nesting=1` is likewise root@pam-only for a privileged CT on PVE 9 — verified
# HTTP 403 — and nfsd needs it to mount nfsd/rpc_pipefs.)
#
# `output.fileserver_host_mount_command` prints this exact command after apply.
# Terraform then IGNORES the mount + features (see `lifecycle.ignore_changes`
# below) so a future `plan` will not try to strip them back off.
#
# ---------------------------------------------------------------------------
# NFS-in-LXC apparmor caveat (a possible SECOND host command)
# ---------------------------------------------------------------------------
# Privileged + nesting is usually enough to run nfsd, but on some kernels nfsd
# also needs `lxc.apparmor.profile: unconfined`, which is a raw lxc.* key NOT
# settable via the Proxmox API / bpg. The NFS provisioner below detects this and
# prints the remediation if nfsd won't start:
#
#     echo 'lxc.apparmor.profile: unconfined' >> /etc/pve/lxc/110.conf && pct reboot 110
#
# ---------------------------------------------------------------------------
# APPLY (nothing special — your normal token/env works as-is):
#     cd terraform
#     export PROXMOX_VE_ENDPOINT=... PROXMOX_VE_API_TOKEN=...   # your usual vars
#     export CLOUDFLARE_API_TOKEN=...
#     terraform apply -target=proxmox_virtual_environment_container.fileserver \
#                     -target=null_resource.fileserver_nfs \
#                     -target=cloudflare_record.fileserver
#     # then run the printed `pct set ... && pct reboot ...` on the PVE host
#     # verify:  showmount -e 192.168.68.11
# ===========================================================================

resource "proxmox_virtual_environment_container" "fileserver" {
  count = var.fileserver_enabled ? 1 : 0
  # Default provider = your normal scoped token. No root@pam needed: the token
  # can create a privileged container fine; only the bind mount (added by hand
  # on the host, above) is root@pam-only.

  node_name = var.proxmox_node
  vm_id     = var.fileserver_vm_id
  tags      = ["terraform", "nfs", "fileserver"]

  # Privileged so nfsd can run and host UIDs/GIDs on the media are preserved
  # 1:1 (no idmap shift). The token IS allowed to create privileged CTs on PVE 9.
  unprivileged  = false
  start_on_boot = true
  started       = true

  # NOTE: intentionally NO `features { nesting = true }` block. On PVE 9, setting
  # a feature flag on a PRIVILEGED container is root@pam-only (verified: HTTP 403
  # "changing feature flags for privileged container is only allowed for
  # root@pam"). So `nesting=1` — which nfsd needs to mount nfsd/rpc_pipefs — is
  # added by the same one-time host command as the bind mount (see header), and
  # ignored by `lifecycle.ignore_changes` below.

  cpu {
    cores = var.fileserver_cores
  }

  memory {
    dedicated = var.fileserver_memory
    swap      = var.fileserver_swap
  }

  # Small rootfs on the ZFS datastore — the media itself lives on the host bind
  # mount you add manually, NOT on this disk.
  disk {
    datastore_id = var.vm_datastore
    size         = var.fileserver_disk_size
  }

  # NOTE: intentionally NO `mount_point` block here. The /tank/media bind mount
  # is added out-of-band on the host (`pct set 110 -mp0 ...`) because Proxmox
  # forbids bind mounts for API tokens. `ignore_changes` below stops Terraform
  # from removing that manually-added mount on later applies.

  operating_system {
    template_file_id = var.fileserver_template
    type             = "debian"
  }

  initialization {
    hostname = var.fileserver_hostname

    dns {
      servers = [var.nameserver]
    }

    ip_config {
      ipv4 {
        address = "${var.fileserver_ip}/${var.network_cidr_bits}"
        gateway = var.network_gateway
      }
    }

    user_account {
      keys     = [trimspace(file(pathexpand(var.fileserver_ssh_public_key_path)))]
      password = var.fileserver_root_password != "" ? var.fileserver_root_password : null
    }
  }

  network_interface {
    name   = "eth0"
    bridge = var.network_bridge
  }

  lifecycle {
    # `mount_point` + `features`: the /tank/media bind mount and nesting=1 are
    #   added on the host by hand (root@pam-only for a privileged CT) and MUST
    #   NOT be reverted by Terraform.
    # `initialization[0].user_account`: password/keys are write-only in the API
    #   and re-read as null, which would otherwise show false drift.
    ignore_changes = [
      mount_point,
      features,
      initialization[0].user_account,
    ]
  }
}

# ---------------------------------------------------------------------------
# NFS provisioning over container SSH (the PROXMOX HOST is never SSH'd into —
# only this container is, at its static IP).
#
# Installs nfs-kernel-server, writes /etc/exports and enables + starts nfsd. The
# service is ENABLED so it re-exports automatically after you add the bind mount
# and reboot the CT. Start is tolerant so the first apply still succeeds even if
# the apparmor host tweak turns out to be needed; the final echo tells you what
# to check / run next.
# ---------------------------------------------------------------------------
resource "null_resource" "fileserver_nfs" {
  count = var.fileserver_enabled ? 1 : 0

  triggers = {
    container_id = proxmox_virtual_environment_container.fileserver[0].id
    export_line  = "${var.fileserver_container_media_path} ${var.fileserver_export_cidr}(rw,sync,no_subtree_check,no_root_squash)"
  }

  connection {
    type        = "ssh"
    host        = var.fileserver_ip
    user        = "root"
    private_key = file(pathexpand(var.fileserver_ssh_private_key_path))
    timeout     = "4m"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "export DEBIAN_FRONTEND=noninteractive",
      # Wait for the container's network/DNS to settle before hitting apt.
      "for i in $(seq 1 30); do getent hosts deb.debian.org >/dev/null 2>&1 && break; sleep 2; done",
      "apt-get update -qq",
      "apt-get install -y -qq nfs-kernel-server",
      # Ensure the export dir exists even before the host bind mount is attached
      # (empty for now; becomes /tank/media after `pct set ... && pct reboot`).
      "mkdir -p ${var.fileserver_container_media_path}",
      "echo '${var.fileserver_container_media_path} ${var.fileserver_export_cidr}(rw,sync,no_subtree_check,no_root_squash)' > /etc/exports",
      "exportfs -ra || true",
      "systemctl enable nfs-server >/dev/null 2>&1 || true",
      "systemctl restart nfs-server || true",
      "sleep 2",
      "echo '----------------------------------------------------------------'",
      "if systemctl is-active --quiet nfs-server; then echo 'NFS server: ACTIVE'; exportfs -v; else echo 'NFS server: FAILED to start. On the PVE HOST run then re-apply:'; echo \"  echo 'lxc.apparmor.profile: unconfined' >> /etc/pve/lxc/${var.fileserver_vm_id}.conf && pct reboot ${var.fileserver_vm_id}\"; fi",
      "echo 'NEXT (required) — on the PVE HOST attach the media bind mount + nesting, then reboot:'",
      "echo \"  pct set ${var.fileserver_vm_id} -mp0 ${var.fileserver_host_media_path},mp=${var.fileserver_container_media_path} --features nesting=1 && pct reboot ${var.fileserver_vm_id}\"",
      "echo '----------------------------------------------------------------'",
    ]
  }
}

# ---------------------------------------------------------------------------
# Cloudflare DNS record — DNS-only (grey). NFS is not internet-safe and the CF
# proxy only handles HTTP(S), so this MUST NOT be proxied. It just points a
# friendly name at the LAN IP; k8s csi-driver-nfs uses the IP directly.
#
# external-dns won't fight this: it only deletes records carrying its ownership
# TXT registry entry, and nothing in-cluster owns this name.
# ---------------------------------------------------------------------------
resource "cloudflare_record" "fileserver" {
  count = var.fileserver_enabled ? 1 : 0

  zone_id = data.cloudflare_zone.main.id
  name    = var.fileserver_record_name
  type    = "A"
  value   = var.fileserver_ip
  proxied = false
  ttl     = 60
  comment = "Terraform: fileserver LXC NFS (DNS-only, LAN)"
}
