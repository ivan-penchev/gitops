# proxmox-csi-plugin credentials. The platform stack creates the
# least-privilege Proxmox user/token and renders the cloud-config; this writes
# it as the secret the HelmRelease expects (`existingConfigSecret:
# proxmox-csi-plugin`).
resource "kubernetes_secret_v1" "proxmox_csi" {
  metadata {
    name      = "proxmox-csi-plugin"
    namespace = "kube-system"
  }

  data = {
    "config.yaml" = local.platform.csi_cloud_config
  }

  type = "Opaque"
}
