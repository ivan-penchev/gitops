# ---------------------------------------------------------------------------
# One Talos cluster and what it needs outside Kubernetes: VMs, Talos, the
# Cloudflare tunnel, the proxmox-csi user, Flux bootstrap and pg databases.
# Every cluster uses this root. Its values live in
# terraform/clusters/<name>/*.tfvars and terraform/tf.sh picks them, plus
# the state key. Shared hosts (fileserver, pg-01) come from terraform/shared
# through local.shared.
# ---------------------------------------------------------------------------

locals {
  repo_root            = "${path.root}/../.."
  talos_patches_dir    = "${local.repo_root}/talos/patches"
  cilium_manifest_path = "${local.repo_root}/talos/cilium/cilium.yaml"
  flux_manifests_dir   = "${local.repo_root}/${var.flux_path}/flux-system"
}
