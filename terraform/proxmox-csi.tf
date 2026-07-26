# ---------------------------------------------------------------------------
# proxmox-csi-plugin credentials (fully IaC — no secrets in Git).
#
# The CSI controller provisions/attaches/detaches VM disks on Proxmox, so it
# needs its own least-privilege API token. We create a dedicated role, user and
# token here, then inject the rendered cloud-config straight into a Kubernetes
# secret (same pattern as the sops-age secret). The HelmRelease consumes it via
# `existingConfigSecret: proxmox-csi-plugin`.
#
# region MUST match the topology.kubernetes.io/region node label (var.proxmox_region)
# and the Proxmox node name is used as the topology zone (var.proxmox_node).
# ---------------------------------------------------------------------------

# Least-privilege role: disk lifecycle + audit only.
resource "proxmox_virtual_environment_role" "csi" {
  role_id = "CSI"
  privileges = [
    "VM.Audit",
    "VM.Config.Disk",
    "Datastore.Allocate",
    "Datastore.AllocateSpace",
    "Datastore.Audit",
  ]
}

resource "proxmox_virtual_environment_user" "csi" {
  user_id = "kubernetes-csi@pve"
  comment = "proxmox-csi-plugin (managed by Terraform)"
  enabled = true
}

# Grant the role to the user at the root path (propagates to all VMs/datastores).
resource "proxmox_virtual_environment_acl" "csi" {
  user_id   = proxmox_virtual_environment_user.csi.user_id
  role_id   = proxmox_virtual_environment_role.csi.role_id
  path      = "/"
  propagate = true
}

# API token that inherits the user's privileges (privileges_separation = false).
resource "proxmox_virtual_environment_user_token" "csi" {
  user_id               = proxmox_virtual_environment_user.csi.user_id
  token_name            = "csi"
  comment               = "proxmox-csi-plugin (managed by Terraform)"
  privileges_separation = false

  depends_on = [proxmox_virtual_environment_acl.csi]
}

locals {
  # token_value is "user@realm!token-name=uuid"; split into id + secret.
  csi_token_parts  = split("=", proxmox_virtual_environment_user_token.csi.value)
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

# Inject the cloud-config directly as the secret the HelmRelease expects.
resource "kubernetes_secret_v1" "proxmox_csi" {
  metadata {
    name      = "proxmox-csi-plugin"
    namespace = "kube-system"
  }

  data = {
    "config.yaml" = local.csi_cloud_config
  }

  type = "Opaque"

  depends_on = [talos_cluster_kubeconfig.this]
}
