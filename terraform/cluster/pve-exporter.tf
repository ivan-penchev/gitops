# ---------------------------------------------------------------------------
# prometheus-pve-exporter credentials (fully IaC, no secrets in Git).
#
# The exporter only reads the Proxmox API: host, guest and storage status. It
# gets its own user with the built-in read-only PVEAuditor role, and a token
# that Terraform writes into the `pve-exporter` Secret as the exporter's
# pve.yml.
#
# Opt-in. Every cluster runs on the same Proxmox host, so only one cluster
# should scrape it. That cluster sets pve_exporter_proxmox_user, and the rest
# leave it empty and create nothing here.
#
# Terraform owns the namespace, like cloudflared. Flux creates `monitoring`
# only after this apply, so a fresh cluster couldn't take the Secret there.
# ---------------------------------------------------------------------------

locals {
  pve_exporter_enabled = var.pve_exporter_proxmox_user != ""
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

resource "kubernetes_namespace_v1" "pve_exporter" {
  count = local.pve_exporter_enabled ? 1 : 0

  metadata {
    name = "pve-exporter"
  }
}

# Mounted by the exporter Deployment as /etc/prometheus/pve.yml.
resource "kubernetes_secret_v1" "pve_exporter" {
  count = local.pve_exporter_enabled ? 1 : 0

  metadata {
    name      = "pve-exporter"
    namespace = kubernetes_namespace_v1.pve_exporter[0].metadata[0].name
  }

  data = {
    "pve.yml" = yamlencode({
      default = {
        user       = var.pve_exporter_proxmox_user
        token_name = var.pve_exporter_token_name
        # The token value is "user@realm!token-name=uuid". pve.yml wants the uuid.
        token_value = split("=", proxmox_user_token.pve_exporter[0].value)[1]
        verify_ssl  = !var.proxmox_insecure
      }
    })
  }

  type = "Opaque"
}
