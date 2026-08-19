# ===========================================================================
# PostgreSQL LXC (pg-01) — shared homelab database server  (Proxmox VE 9)
# ===========================================================================
#
# WHY THIS EXISTS
# ---------------
# Some apps (Immich, Paperless, Authentik, …) need a real PostgreSQL, not the
# SQLite the *arr stack uses. Running ONE Postgres as an LXC (not in-cluster)
# means the databases survive Talos cluster rebuilds — same reasoning as the
# fileserver. Databases and the k8s Secrets that carry their credentials are
# declared once in `var.postgres_databases`; Terraform reconciles the roles,
# the databases, and one `postgres-<db>` Secret per target namespace.
#
# ---------------------------------------------------------------------------
# ⚠️  ONE REQUIRED MANUAL HOST STEP  (same root@pam limitation as fileserver)
# ---------------------------------------------------------------------------
# PGDATA must live on a dedicated ZFS dataset so it survives an LXC rebuild and
# gets its own snapshots. Creating the dataset and bind-mounting it are both
# root@pam-only on PVE 9 (our API token gets HTTP 403), so they're done once by
# hand on the host. `output.postgres_host_mount_command` prints the exact line:
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
#        terraform apply -target=proxmox_virtual_environment_container.postgres
#   2) On the PVE HOST run the printed `zfs create … && pct set … && pct reboot`.
#   3) Set `postgres_data_mounted = true` (tfvars) and re-apply:
#        terraform apply
#      -> provisioner installs PostgreSQL onto the dataset, then the roles,
#         databases and k8s Secrets are created.
# ===========================================================================

locals {
  # Internal DNS name (Cloudflare DNS-only A record), e.g. pg-01.int.home.17072021.xyz.
  postgres_fqdn = "${var.postgres_record_name}.${var.cloudflare_domain}"

  # DB/secret resources only make sense once PostgreSQL is actually reachable on
  # the mounted dataset. Until then these maps are empty, so a first-phase apply
  # (LXC only) never tries to talk to a Postgres that isn't up yet.
  postgres_ready = var.postgres_enabled && var.postgres_data_mounted

  postgres_db_map = local.postgres_ready ? {
    for db in var.postgres_databases : db.name => db
  } : {}

  # One (database, namespace) pair per Secret to inject.
  postgres_secret_pairs = local.postgres_ready ? {
    for pair in flatten([
      for db in var.postgres_databases : [
        for ns in db.namespaces : {
          key = "${db.name}/${ns}"
          db  = db.name
          ns  = ns
        }
      ]
    ]) : pair.key => pair
  } : {}

  # Distinct namespaces to ensure exist (when postgres_create_namespaces = true).
  postgres_namespaces = local.postgres_ready && var.postgres_create_namespaces ? toset(
    flatten([for db in var.postgres_databases : db.namespaces])
  ) : toset([])

  # The single root@pam host command: create the dataset + bind-mount it, reboot.
  postgres_mount_command = join(" ", [
    "zfs create ${trimprefix(var.postgres_host_data_path, "/")}",
    "&& pct set ${var.postgres_vm_id} -mp0 ${var.postgres_host_data_path},mp=${var.postgres_container_data_path}",
    "&& pct reboot ${var.postgres_vm_id}",
  ])

  # PGDATA on the dataset (avoids shadowing /var/lib/postgresql).
  postgres_data_dir = "${var.postgres_container_data_path}/${var.postgres_version}/main"
}

# Generated superuser password — always created so the provider config resolves
# even on a first-phase (LXC-only) apply. Constrained specials keep it safe in
# both a psql string literal and a DSN.
resource "random_password" "postgres_superuser" {
  length           = 28
  special          = true
  override_special = "_-"
}

# Per-database login role passwords.
resource "random_password" "postgres_db" {
  for_each = local.postgres_ready ? { for db in var.postgres_databases : db.name => db } : {}

  length           = 24
  special          = true
  override_special = "_-"
}

# ---------------------------------------------------------------------------
# The LXC. Mirrors the fileserver: privileged, API-token-created, with the data
# bind mount + any features added out-of-band on the host and ignored here.
# ---------------------------------------------------------------------------
resource "proxmox_virtual_environment_container" "postgres" {
  count = var.postgres_enabled ? 1 : 0

  node_name = var.proxmox_node
  vm_id     = var.postgres_vm_id
  tags      = ["terraform", "postgres", "database"]

  # Privileged: keeps host UID/GID semantics on the bind-mounted dataset simple
  # (the postgres user's data is owned consistently). The token CAN create
  # privileged CTs; only the bind mount itself is root@pam-only.
  unprivileged  = false
  start_on_boot = true
  started       = true

  cpu {
    cores = var.postgres_cores
  }

  memory {
    dedicated = var.postgres_memory
    swap      = var.postgres_swap
  }

  # Small rootfs — PGDATA lives on the host bind mount you add manually.
  disk {
    datastore_id = var.vm_datastore
    size         = var.postgres_disk_size
  }

  # NOTE: intentionally NO `mount_point` block. /tank/postgres is bind-mounted at
  # /mnt/pgdata out-of-band on the host (bind mounts are root@pam-only). The
  # `ignore_changes` below stops Terraform stripping it on later applies.

  operating_system {
    template_file_id = var.postgres_template
    type             = "debian"
  }

  initialization {
    hostname = var.postgres_hostname

    dns {
      servers = [var.nameserver]
    }

    ip_config {
      ipv4 {
        address = "${var.postgres_ip}/${var.network_cidr_bits}"
        gateway = var.network_gateway
      }
    }

    user_account {
      keys     = [trimspace(file(pathexpand(var.postgres_ssh_public_key_path)))]
      password = var.postgres_root_password != "" ? var.postgres_root_password : null
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
  count = local.postgres_ready ? 1 : 0

  triggers = {
    container_id = proxmox_virtual_environment_container.postgres[0].id
    version      = var.postgres_version
    data_dir     = local.postgres_data_dir
    client_cidr  = var.postgres_client_cidr
    # Re-run if the superuser password changes so the role stays in sync.
    superuser = random_password.postgres_superuser.result
  }

  connection {
    type        = "ssh"
    host        = var.postgres_ip
    user        = "root"
    private_key = file(pathexpand(var.postgres_ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "export DEBIAN_FRONTEND=noninteractive",
      # Wait for network/DNS before hitting apt.
      "for i in $(seq 1 30); do getent hosts deb.debian.org >/dev/null 2>&1 && break; sleep 2; done",
      # Refuse to initialise on the rootfs: /mnt/pgdata MUST be the bind mount.
      "if ! mountpoint -q ${var.postgres_container_data_path}; then echo 'FATAL: ${var.postgres_container_data_path} is not a mountpoint — run the host zfs/pct step first (see output.postgres_host_mount_command), then re-apply.'; exit 1; fi",
      "apt-get update -qq",
      "apt-get install -y -qq curl ca-certificates gnupg lsb-release",
      # PGDG apt repo (official PostgreSQL packages).
      "install -d /usr/share/postgresql-common/pgdg",
      "curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc",
      "echo \"deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main\" > /etc/apt/sources.list.d/pgdg.list",
      "apt-get update -qq",
      "apt-get install -y -qq postgresql-${var.postgres_version}",
      # Move the auto-created cluster onto the dataset the first time only.
      "if [ ! -f ${local.postgres_data_dir}/PG_VERSION ]; then pg_dropcluster --stop ${var.postgres_version} main || true; install -d -o postgres -g postgres -m 700 ${var.postgres_container_data_path}; pg_createcluster -d ${local.postgres_data_dir} ${var.postgres_version} main; fi",
      # Listen on the LAN, scram password auth.
      "conf=/etc/postgresql/${var.postgres_version}/main/postgresql.conf",
      "hba=/etc/postgresql/${var.postgres_version}/main/pg_hba.conf",
      "sed -i \"s/^#\\?listen_addresses.*/listen_addresses = '*'/\" $conf",
      "sed -i \"s/^#\\?password_encryption.*/password_encryption = scram-sha-256/\" $conf",
      "grep -q '${var.postgres_client_cidr}' $hba || echo 'host all all ${var.postgres_client_cidr} scram-sha-256' >> $hba",
      "pg_ctlcluster ${var.postgres_version} main start || systemctl restart postgresql@${var.postgres_version}-main || true",
      "systemctl enable postgresql >/dev/null 2>&1 || true",
      # Set the superuser password TF's provider will authenticate with.
      "sudo -u postgres psql -v ON_ERROR_STOP=1 -c \"ALTER USER postgres WITH PASSWORD '${random_password.postgres_superuser.result}'\"",
      "systemctl restart postgresql@${var.postgres_version}-main || pg_ctlcluster ${var.postgres_version} main restart || true",
      "echo 'PostgreSQL ${var.postgres_version} ready on ${var.postgres_ip}:5432 (data: ${local.postgres_data_dir})'",
    ]
  }
}

# ---------------------------------------------------------------------------
# Roles + databases (cyrilgdn/postgresql). One login role per database, owner
# == role. Removing an entry from var.postgres_databases will NOT drop the
# database (prevent_destroy) — delete data by hand, deliberately.
# ---------------------------------------------------------------------------
resource "postgresql_role" "db" {
  for_each = local.postgres_db_map

  name     = each.value.name
  login    = true
  password = random_password.postgres_db[each.key].result

  depends_on = [null_resource.postgres_setup]
}

resource "postgresql_database" "db" {
  for_each = local.postgres_db_map

  name              = each.value.name
  owner             = postgresql_role.db[each.key].name
  encoding          = "UTF8"
  lc_collate        = "C"
  lc_ctype          = "C"
  template          = "template0"
  connection_limit  = -1
  allow_connections = true

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [null_resource.postgres_setup]
}

# ---------------------------------------------------------------------------
# k8s Secrets: `postgres-<db>` in every target namespace. Terraform is the
# source of truth for these (the passwords are TF-generated), so they live in
# state, not git.
# ---------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "db" {
  for_each = local.postgres_namespaces

  metadata {
    name = each.value
  }

  depends_on = [talos_cluster_kubeconfig.this]
}

resource "kubernetes_secret_v1" "db" {
  for_each = local.postgres_secret_pairs

  metadata {
    name      = "postgres-${each.value.db}"
    namespace = each.value.ns
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "postgres-credentials"
    }
  }

  data = {
    POSTGRES_HOST     = local.postgres_fqdn
    POSTGRES_PORT     = "5432"
    POSTGRES_DB       = each.value.db
    POSTGRES_USER     = each.value.db
    POSTGRES_PASSWORD = random_password.postgres_db[each.value.db].result
    DATABASE_URL      = "postgresql://${each.value.db}:${random_password.postgres_db[each.value.db].result}@${local.postgres_fqdn}:5432/${each.value.db}?sslmode=disable"
  }

  type = "Opaque"

  depends_on = [
    postgresql_database.db,
    kubernetes_namespace_v1.db,
  ]
}

# ---------------------------------------------------------------------------
# Cloudflare DNS record — DNS-only (grey). Postgres is not internet-safe and the
# CF proxy only handles HTTP(S); this just points the internal name at the LAN IP.
# ---------------------------------------------------------------------------
resource "cloudflare_dns_record" "postgres" {
  count = var.postgres_enabled ? 1 : 0

  zone_id = data.cloudflare_zone.main.id
  name    = var.postgres_record_name
  type    = "A"
  content = var.postgres_ip
  proxied = false
  ttl     = 60
  comment = "Terraform: PostgreSQL LXC (DNS-only, LAN)"
}
