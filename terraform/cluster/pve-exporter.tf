# ---------------------------------------------------------------------------
# prometheus-pve-exporter credentials (fully IaC, no secrets in Git).
#
# The exporter only reads the Proxmox API: host, guest and storage status. It
# gets its own user with the built-in read-only PVEAuditor role, and a token
# that Terraform writes into the `pve-exporter` Secret as the exporter's
# pve.yml. The user name is global on the PVE host, so each cluster passes
# its own.
#
# Terraform owns the namespace, like cloudflared. Flux creates `monitoring`
# only after this apply, so a fresh cluster couldn't take the Secret there.
# ---------------------------------------------------------------------------

resource "proxmox_virtual_environment_user" "pve_exporter" {
  user_id = var.pve_exporter_proxmox_user
  comment = "prometheus-pve-exporter (managed by Terraform)"
  enabled = true
}

resource "proxmox_acl" "pve_exporter" {
  user_id   = proxmox_virtual_environment_user.pve_exporter.user_id
  role_id   = "PVEAuditor"
  path      = "/"
  propagate = true
}

# Inherits the user's read-only rights (privileges_separation = false).
resource "proxmox_user_token" "pve_exporter" {
  user_id               = proxmox_virtual_environment_user.pve_exporter.user_id
  token_name            = var.pve_exporter_token_name
  comment               = "prometheus-pve-exporter (managed by Terraform)"
  privileges_separation = false

  depends_on = [proxmox_acl.pve_exporter]
}

locals {
  # value is "user@realm!token-name=uuid". The exporter wants the parts apart.
  pve_exporter_token_secret = split("=", proxmox_user_token.pve_exporter.value)[1]

  pve_exporter_config = yamlencode({
    default = {
      user        = proxmox_virtual_environment_user.pve_exporter.user_id
      token_name  = var.pve_exporter_token_name
      token_value = local.pve_exporter_token_secret
      verify_ssl  = !var.proxmox_insecure
    }
  })
}

resource "kubernetes_namespace_v1" "pve_exporter" {
  metadata {
    name = "pve-exporter"
  }
}

# Mounted by the exporter Deployment as /etc/prometheus/pve.yml.
resource "kubernetes_secret_v1" "pve_exporter" {
  metadata {
    name      = "pve-exporter"
    namespace = kubernetes_namespace_v1.pve_exporter.metadata[0].name
  }

  data = {
    "pve.yml" = local.pve_exporter_config
  }

  type = "Opaque"
}
