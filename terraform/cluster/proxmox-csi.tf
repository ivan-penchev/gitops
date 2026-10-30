# ---------------------------------------------------------------------------
# proxmox-csi-plugin credentials (fully IaC, no secrets in Git).
#
# The CSI controller provisions/attaches/detaches VM disks on Proxmox, so it
# needs its own least-privilege API token. We create a dedicated role, user and
# token here, render the cloud-config and write it into the
# `proxmox-csi-plugin` Secret that the HelmRelease consumes via
# `existingConfigSecret`. Role and user names are global on the PVE host,
# so each cluster passes its own.
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
  # token_value is "user@realm!token-name=uuid"; split into id + secret.
  csi_token_parts  = split("=", proxmox_user_token.csi.value)
  csi_token_id     = local.csi_token_parts[0]
  csi_token_secret = local.csi_token_parts[1]

  csi_cloud_config = yamlencode({
    clusters = [
      {
        url          = var.proxmox_csi_endpoint
        insecure     = var.proxmox_insecure
        token_id     = local.csi_token_id
        token_secret = local.csi_token_secret
        region       = var.proxmox_region
      }
    ]
  })
}

# The Secret the HelmRelease reads (`existingConfigSecret: proxmox-csi-plugin`).
resource "kubernetes_secret_v1" "proxmox_csi" {
  metadata {
    name      = "proxmox-csi-plugin"
    namespace = "kube-system"
  }

  data = {
    "config.yaml" = local.csi_cloud_config
  }

  type = "Opaque"
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
