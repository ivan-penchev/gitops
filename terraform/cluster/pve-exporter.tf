# ---------------------------------------------------------------------------
# prometheus-pve-exporter credentials (no secrets in Git).
#
# The exporter only reads the Proxmox API: host, guest and storage status. It
# gets its own user with the built-in read-only PVEAuditor role, and a token.
# Terraform hands Flux the values below and nothing else. Flux owns the
# exporter, its namespace and its Secret, and fills the token in through
# postBuild substitution from the cluster-secrets-tf Secret.
#
# Opt-in. Every cluster runs on the same Proxmox host, so only one cluster
# should scrape it. That cluster sets pve_exporter_proxmox_user, and the rest
# leave it empty and create nothing here.
# ---------------------------------------------------------------------------

locals {
  pve_exporter_enabled = var.pve_exporter_proxmox_user != ""

  # Plain values for cluster-config-tf.
  pve_exporter_config = local.pve_exporter_enabled ? {
    pve_exporter_user       = var.pve_exporter_proxmox_user
    pve_exporter_token_name = var.pve_exporter_token_name
    pve_exporter_target     = regex("^https?://([^:/]+)", var.proxmox_csi_endpoint)[0]
  } : {}

  # The token value is "user@realm!token-name=uuid". The exporter wants the uuid.
  pve_exporter_secrets = local.pve_exporter_enabled ? {
    pve_exporter_token = split("=", proxmox_user_token.pve_exporter[0].value)[1]
  } : {}
}

resource "proxmox_virtual_environment_user" "pve_exporter" {
  count = local.pve_exporter_enabled ? 1 : 0

  user_id = var.pve_exporter_proxmox_user
  comment = "prometheus-pve-exporter (managed by Terraform)"
  enabled = true
}

resource "proxmox_acl" "pve_exporter" {
  count = local.pve_exporter_enabled ? 1 : 0

  user_id   = proxmox_virtual_environment_user.pve_exporter[0].user_id
  role_id   = "PVEAuditor"
  path      = "/"
  propagate = true
}

# Inherits the user's read-only rights (privileges_separation = false).
resource "proxmox_user_token" "pve_exporter" {
  count = local.pve_exporter_enabled ? 1 : 0

  user_id               = proxmox_virtual_environment_user.pve_exporter[0].user_id
  token_name            = var.pve_exporter_token_name
  comment               = "prometheus-pve-exporter (managed by Terraform)"
  privileges_separation = false

  depends_on = [proxmox_acl.pve_exporter]
}
