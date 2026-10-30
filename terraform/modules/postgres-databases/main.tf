# ---------------------------------------------------------------------------
# Databases on pg-01 and their k8s Secrets. terraform/shared owns the LXC,
# the PostgreSQL install and the superuser password.
#
# Databases are declared once in `var.databases`. Terraform reconciles
# one login role per database, the database, and one `postgres-<db>` Secret per
# target namespace. Nothing here runs until var.ready is true
# (LXC up and PGDATA on the ZFS dataset).
# ---------------------------------------------------------------------------

locals {
  postgres_db_map = var.ready ? {
    for db in var.databases : db.name => db
  } : {}

  # One (database, namespace) pair per Secret to inject.
  postgres_secret_pairs = var.ready ? {
    for pair in flatten([
      for db in var.databases : [
        for ns in db.namespaces : {
          key = "${db.name}/${ns}"
          db  = db.name
          ns  = ns
        }
      ]
    ]) : pair.key => pair
  } : {}

  # Distinct namespaces to ensure exist (when postgres_create_namespaces = true).
  postgres_namespaces = var.ready && var.create_namespaces ? toset(
    flatten([for db in var.databases : db.namespaces])
  ) : toset([])
}

# Per-database login role passwords.
resource "random_password" "postgres_db" {
  for_each = local.postgres_db_map

  length           = 24
  special          = true
  override_special = "_-"
}

# One login role per database, owner == role. Removing an entry from
# var.databases will NOT drop the database (prevent_destroy). Delete
# data by hand, deliberately.
resource "postgresql_role" "db" {
  for_each = local.postgres_db_map

  name     = each.value.name
  login    = true
  password = random_password.postgres_db[each.key].result
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
}

# Terraform is the source of truth for these Secrets (the passwords are
# TF-generated), so they live in state, not Git.
resource "kubernetes_namespace_v1" "db" {
  for_each = local.postgres_namespaces

  metadata {
    name = each.value
  }
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
    POSTGRES_HOST     = var.host
    POSTGRES_PORT     = "5432"
    POSTGRES_DB       = each.value.db
    POSTGRES_USER     = each.value.db
    POSTGRES_PASSWORD = random_password.postgres_db[each.value.db].result
    DATABASE_URL      = "postgresql://${each.value.db}:${random_password.postgres_db[each.value.db].result}@${var.host}:5432/${each.value.db}?sslmode=disable"
  }

  type = "Opaque"

  depends_on = [
    postgresql_database.db,
    kubernetes_namespace_v1.db,
  ]
}
