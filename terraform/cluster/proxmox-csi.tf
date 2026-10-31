# ---------------------------------------------------------------------------
# proxmox-csi-plugin credentials (fully IaC, no secrets in Git).
#
# The CSI controller provisions/attaches/detaches VM disks on Proxmox, so it
# needs its own least-privilege API token. We create a dedicated role, user and
# token here. Terraform writes the token to cluster-secrets-tf and the URL and
# region to cluster-config-tf. Flux fills them into the `proxmox-csi-plugin`
# Secret template in kubernetes/infrastructure/controllers. Role and user names
# are global on the PVE host, so each cluster passes its own.
#
# region MUST match the topology.kubernetes.io/region node label (var.proxmox_region)
# and the Proxmox node name is used as the topology zone (var.proxmox_node).
# ---------------------------------------------------------------------------

# Least-privilege role: disk lifecycle + audit only.
resource "proxmox_virtual_environment_role" "csi" {
  role_id = var.csi_proxmox_role
  privileges = [
    "VM.Audit",
    "VM.Config.Disk",
    "Datastore.Allocate",
    "Datastore.AllocateSpace",
    "Datastore.Audit",
  ]
}

resource "proxmox_virtual_environment_user" "csi" {
  user_id = var.csi_proxmox_user
  comment = "proxmox-csi-plugin (managed by Terraform)"
  enabled = true
}

# Grant the role to the user at the root path (propagates to all VMs/datastores).
resource "proxmox_acl" "csi" {
  user_id   = proxmox_virtual_environment_user.csi.user_id
  role_id   = proxmox_virtual_environment_role.csi.role_id
  path      = "/"
  propagate = true
}

# API token that inherits the user's privileges (privileges_separation = false).
resource "proxmox_user_token" "csi" {
  user_id               = proxmox_virtual_environment_user.csi.user_id
  token_name            = var.csi_token_name
  comment               = "proxmox-csi-plugin (managed by Terraform)"
  privileges_separation = false

  depends_on = [proxmox_acl.csi]
}

locals {
  # Plain values for cluster-config-tf.
  csi_config = {
    proxmox_csi_url  = var.proxmox_csi_endpoint
    proxmox_insecure = tostring(var.proxmox_insecure)
    proxmox_region   = var.proxmox_region
  }

  # token value is "user@realm!token-name=uuid". Split it into id and secret.
  csi_secrets = {
    proxmox_csi_token_id     = split("=", proxmox_user_token.csi.value)[0]
    proxmox_csi_token_secret = split("=", proxmox_user_token.csi.value)[1]
  }
}

# Flux owns the Secret now. Forget it without deleting it from the cluster.
removed {
  from = kubernetes_secret_v1.proxmox_csi

  lifecycle {
    destroy = false
  }
}

# bpg/proxmox renamed these types. Keep the moves until every cluster has applied.
moved {
  from = proxmox_virtual_environment_acl.csi
  to   = proxmox_acl.csi
}

moved {
  from = proxmox_virtual_environment_user_token.csi
  to   = proxmox_user_token.csi
}
