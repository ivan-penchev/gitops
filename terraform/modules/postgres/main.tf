# ===========================================================================
# PostgreSQL LXC (pg-01) — shared homelab database server  (Proxmox VE 9)
# ===========================================================================
#
# WHY THIS EXISTS
# ---------------
# Some apps (Immich, Paperless, Authentik, …) need a real PostgreSQL, not the
# SQLite the *arr stack uses. Running ONE Postgres as an LXC (not in-cluster)
# means the databases survive Talos cluster rebuilds — same reasoning as the
# fileserver. This module owns the LXC, the PostgreSQL install and the superuser
# password. terraform/shared calls it. Each cluster root creates its own
# databases, roles and k8s Secrets with modules/postgres-databases.
#
# ---------------------------------------------------------------------------
# ⚠️  ONE REQUIRED MANUAL HOST STEP  (same root@pam limitation as fileserver)
# ---------------------------------------------------------------------------
# PGDATA must live on a dedicated ZFS dataset so it survives an LXC rebuild and
# gets its own snapshots. Creating the dataset and bind-mounting it are both
# root@pam-only on PVE 9 (our API token gets HTTP 403), so they're done once by
# hand on the host. the shared root's `postgres_host_mount_command` output prints the exact line:
#
#     zfs create tank/postgres \
#       && pct set 111 -mp0 /tank/postgres,mp=/mnt/pgdata \
#       && pct reboot 111
#
# The mount target is /mnt/pgdata (NOT /var/lib/postgresql) on purpose: a bind
# mount over /var/lib/postgresql would shadow the apt-installed cluster dir. We
# instead place PGDATA at /mnt/pgdata/<ver>/main via pg_createcluster.
#
# ---------------------------------------------------------------------------
# APPLY (phased — the DB provider can't connect until Postgres is up):
#   1) Create just the LXC:
#        terraform/tf.sh shared apply   (with postgres_data_mounted = false)
#   2) On the PVE HOST run the printed `zfs create … && pct set … && pct reboot`.
#   3) Set `postgres_data_mounted = true` (shared/shared.auto.tfvars) and re-apply:
#        terraform/tf.sh shared apply
#      -> provisioner installs PostgreSQL onto the dataset.
#   4) terraform/tf.sh homelab-prd apply
#      -> roles, databases and k8s Secrets.
# ===========================================================================

locals {
  # Cluster roots create databases only once PostgreSQL runs on the mounted
  # dataset (output.ready).
  ready = var.data_mounted

  # The single root@pam host command: create the dataset + bind-mount it, reboot.
  mount_command = join(" ", [
    "zfs create ${trimprefix(var.host_data_path, "/")}",
    "&& pct set ${var.vm_id} -mp0 ${var.host_data_path},mp=${var.container_data_path}",
    "&& pct reboot ${var.vm_id}",
  ])

  # PGDATA on the dataset (avoids shadowing /var/lib/postgresql).
  data_dir = "${var.container_data_path}/${var.pg_version}/main"
}

# Generated superuser password. Cluster roots' postgresql providers log
# in with it. Constrained specials keep it safe in
# both a psql string literal and a DSN.
resource "random_password" "postgres_superuser" {
  length           = 28
  special          = true
  override_special = "_-"
}

# ---------------------------------------------------------------------------
# The LXC. Mirrors the fileserver: privileged, API-token-created, with the data
# bind mount + any features added out-of-band on the host and ignored here.
# ---------------------------------------------------------------------------
resource "proxmox_virtual_environment_container" "postgres" {
  node_name = var.proxmox_node
  vm_id     = var.vm_id
  tags      = ["terraform", "postgres", "database"]

  # Privileged: keeps host UID/GID semantics on the bind-mounted dataset simple
  # (the postgres user's data is owned consistently). The token CAN create
  # privileged CTs; only the bind mount itself is root@pam-only.
  unprivileged  = false
  start_on_boot = true
  started       = true

  cpu {
    cores = var.cores
  }

  memory {
    dedicated = var.memory
    swap      = var.swap
  }

  # Small rootfs — PGDATA lives on the host bind mount you add manually.
  disk {
    datastore_id = var.vm_datastore
    size         = var.disk_size
  }

  # NOTE: intentionally NO `mount_point` block. /tank/postgres is bind-mounted at
  # /mnt/pgdata out-of-band on the host (bind mounts are root@pam-only). The
  # `ignore_changes` below stops Terraform stripping it on later applies.

  operating_system {
    template_file_id = var.template
    type             = "debian"
  }

  initialization {
    hostname = var.hostname

    dns {
      servers = [var.nameserver]
    }

    ip_config {
      ipv4 {
        address = "${var.ip}/${var.cidr_bits}"
        gateway = var.gateway
      }
    }

    user_account {
      keys     = [trimspace(file(pathexpand(var.ssh_public_key_path)))]
      password = var.root_password != "" ? var.root_password : null
    }
  }

  network_interface {
    name   = "eth0"
    bridge = var.network_bridge
  }

  lifecycle {
    ignore_changes = [
      mount_point,
      features,
      initialization[0].user_account,
    ]
  }
}

# ---------------------------------------------------------------------------
# PostgreSQL provisioning over container SSH. Gated on `postgres_data_mounted`
# so PGDATA is only ever initialised on the bind-mounted dataset — never on the
# ephemeral rootfs. Idempotent: safe to re-run.
# ---------------------------------------------------------------------------
resource "null_resource" "postgres_setup" {
  count = local.ready ? 1 : 0

  triggers = {
    container_id = proxmox_virtual_environment_container.postgres.id
    version      = var.pg_version
    data_dir     = local.data_dir
    client_cidr  = var.client_cidr
    # Re-run if the superuser password changes so the role stays in sync.
    superuser = random_password.postgres_superuser.result
  }

  connection {
    type        = "ssh"
    host        = var.ip
    user        = "root"
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "export DEBIAN_FRONTEND=noninteractive",
      # Wait for network/DNS before hitting apt.
      "for i in $(seq 1 30); do getent hosts deb.debian.org >/dev/null 2>&1 && break; sleep 2; done",
      # Refuse to initialise on the rootfs: /mnt/pgdata MUST be the bind mount.
      "if ! mountpoint -q ${var.container_data_path}; then echo 'FATAL: ${var.container_data_path} is not a mountpoint — run the host zfs/pct step first (see output.postgres_host_mount_command), then re-apply.'; exit 1; fi",
      "apt-get update -qq",
      "apt-get install -y -qq curl ca-certificates gnupg lsb-release",
      # PGDG apt repo (official PostgreSQL packages).
      "install -d /usr/share/postgresql-common/pgdg",
      "curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc",
      "echo \"deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main\" > /etc/apt/sources.list.d/pgdg.list",
      "apt-get update -qq",
      "apt-get install -y -qq postgresql-${var.pg_version}",
      # Move the auto-created cluster onto the dataset the first time only.
      "if [ ! -f ${local.data_dir}/PG_VERSION ]; then pg_dropcluster --stop ${var.pg_version} main || true; install -d -o postgres -g postgres -m 700 ${var.container_data_path}; pg_createcluster -d ${local.data_dir} ${var.pg_version} main; fi",
      # Listen on the LAN, scram password auth.
      "conf=/etc/postgresql/${var.pg_version}/main/postgresql.conf",
      "hba=/etc/postgresql/${var.pg_version}/main/pg_hba.conf",
      "sed -i \"s/^#\\?listen_addresses.*/listen_addresses = '*'/\" $conf",
      "sed -i \"s/^#\\?password_encryption.*/password_encryption = scram-sha-256/\" $conf",
      "grep -q '${var.client_cidr}' $hba || echo 'host all all ${var.client_cidr} scram-sha-256' >> $hba",
      "pg_ctlcluster ${var.pg_version} main start || systemctl restart postgresql@${var.pg_version}-main || true",
      "systemctl enable postgresql >/dev/null 2>&1 || true",
      # Set the superuser password TF's provider will authenticate with.
      "runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c \"ALTER USER postgres WITH PASSWORD '${random_password.postgres_superuser.result}'\"",
      "systemctl restart postgresql@${var.pg_version}-main || pg_ctlcluster ${var.pg_version} main restart || true",
      "echo 'PostgreSQL ${var.pg_version} ready on ${var.ip}:5432 (data: ${local.data_dir})'",
    ]
  }
}
