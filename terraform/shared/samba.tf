# ===========================================================================
# Samba on the fileserver LXC, next to NFS
# ===========================================================================
#
# Windows PCs on the LAN map the media tree as a drive. Each person in
# var.samba_users logs in with their own password, and Samba then does every
# file operation as the `media` user, uid 100000. So files written from
# Windows get the same owner as files the apps write over NFS.
#
# Windows 11 requires SMB signing and refuses guest logins, so there's no
# guest share and signing is mandatory here too.
#
# Shares:
#   media   /srv/media, the whole tree including every child dataset.
#   backup  /srv/backup, read only. Empty unless `backup-browse on` has the
#           USB backup pool mounted on the host (see the header of
#           fileserver.tf). Only users with backup = true see it.
#
# Passwords come from TF_VAR_samba_passwords in secrets.sops.env, a JSON map
# of user to password. Removing a user from var.samba_users deletes their
# Samba login on the next apply.
# ===========================================================================

locals {
  samba_rw_users     = sort([for u, c in var.samba_users : u if !c.read_only])
  samba_ro_users     = sort([for u, c in var.samba_users : u if c.read_only])
  samba_backup_users = sort([for u, c in var.samba_users : u if c.backup])

  samba_media_share = join("\n", compact([
    "[media]",
    "  path = ${var.fileserver.container_media_path}",
    "  valid users = ${join(" ", sort(keys(var.samba_users)))}",
    "  read only = yes",
    length(local.samba_rw_users) > 0 ? "  write list = ${join(" ", local.samba_rw_users)}" : "",
    "  force user = media",
    "  force group = media",
    "  create mask = 0664",
    "  directory mask = 0775",
  ]))

  samba_backup_share = length(local.samba_backup_users) == 0 ? "" : join("\n", [
    "[backup]",
    "  path = /srv/backup",
    "  valid users = ${join(" ", local.samba_backup_users)}",
    "  read only = yes",
    "  force user = media",
    "  force group = media",
  ])

  samba_conf = join("\n\n", compact([
    join("\n", [
      "# Written by Terraform, terraform/shared/samba.tf. Local edits get overwritten.",
      "[global]",
      "  server role = standalone server",
      "  server min protocol = SMB3",
      "  server signing = mandatory",
      "  disable netbios = yes",
      "  smb ports = 445",
      "  hosts allow = ${var.network.cidr} 127.0.0.1",
      "  hosts deny = 0.0.0.0/0",
      "  map to guest = never",
      "  restrict anonymous = 2",
      "  load printers = no",
      "  printing = bsd",
      "  printcap name = /dev/null",
      "  disable spoolss = yes",
    ]),
    local.samba_media_share,
    local.samba_backup_share,
  ]))
}

# Installs Samba, creates the media user and writes smb.conf.
resource "null_resource" "fileserver_samba" {
  count = length(var.samba_users) > 0 ? 1 : 0

  triggers = {
    container_id = proxmox_virtual_environment_container.fileserver.id
    conf         = sha256(local.samba_conf)
    media_owner  = var.fileserver.media_owner
  }

  connection {
    type        = "ssh"
    host        = var.fileserver.ip
    user        = "root"
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "4m"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "export DEBIAN_FRONTEND=noninteractive",
      "apt-get update -qq",
      "apt-get install -y -qq samba",
      "getent group media >/dev/null || groupadd -g ${split(":", var.fileserver.media_owner)[1]} media",
      "getent passwd media >/dev/null || useradd -u ${split(":", var.fileserver.media_owner)[0]} -g media -M -d /nonexistent -s /usr/sbin/nologin media",
      "mkdir -p /srv/backup",
      "echo '${base64encode(local.samba_conf)}' | base64 -d > /etc/samba/smb.conf",
      "testparm -s >/dev/null",
      "systemctl disable --now nmbd >/dev/null 2>&1 || true",
      "systemctl enable smbd >/dev/null 2>&1",
      "systemctl restart smbd",
      "systemctl is-active smbd",
    ]
  }
}

# Creates the login users and sets their Samba passwords. Kept apart from the
# resource above because the passwords make Terraform hide all its output.
resource "null_resource" "fileserver_samba_users" {
  count = length(var.samba_users) > 0 ? 1 : 0

  triggers = {
    samba     = null_resource.fileserver_samba[0].id
    users     = join(" ", sort(keys(var.samba_users)))
    passwords = nonsensitive(sha256(jsonencode(var.samba_passwords)))
  }

  lifecycle {
    precondition {
      condition     = alltrue([for u in keys(var.samba_users) : contains(nonsensitive(keys(var.samba_passwords)), u)])
      error_message = "Every user in samba_users needs a password in TF_VAR_samba_passwords."
    }
  }

  connection {
    type        = "ssh"
    host        = var.fileserver.ip
    user        = "root"
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "4m"
  }

  provisioner "remote-exec" {
    inline = concat(
      ["set -e"],
      flatten([
        for u in sort(keys(var.samba_users)) : [
          "id -u ${u} >/dev/null 2>&1 || useradd -M -d /nonexistent -s /usr/sbin/nologin ${u}",
          "P=$(echo '${base64encode(lookup(var.samba_passwords, u, ""))}' | base64 -d); printf '%s\\n%s\\n' \"$P\" \"$P\" | smbpasswd -s -a ${u} >/dev/null",
        ]
      ]),
      # Drop Samba logins for users no longer in samba_users.
      ["for u in $(pdbedit -L | cut -d: -f1); do case ' ${join(" ", keys(var.samba_users))} ' in *\" $u \"*) ;; *) smbpasswd -x \"$u\" ;; esac; done"],
    )
  }
}
