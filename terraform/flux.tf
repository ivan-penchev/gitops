# ---------------------------------------------------------------------------
# Flux bootstrap (GitOps). Installs Flux into the Talos cluster and points it at
# this same monorepo (path = var.flux_path) over SSH. Flux then self-manages.
# ---------------------------------------------------------------------------
resource "flux_bootstrap_git" "this" {
  path = var.flux_path

  # Flux reaches the cluster via the provider's kubernetes block, which is wired
  # to the Talos kubeconfig — so this can only touch the new cluster.
  depends_on = [talos_cluster_kubeconfig.this]
}

# sops-age secret so Flux can decrypt SOPS-encrypted manifests in Git.
# Created only when an age private key is supplied.
resource "kubernetes_secret_v1" "sops_age" {
  count = var.sops_age_key_file != "" ? 1 : 0

  metadata {
    name      = "sops-age"
    namespace = "flux-system"
  }

  data = {
    "age.agekey" = file(pathexpand(var.sops_age_key_file))
  }

  type = "Opaque"

  depends_on = [flux_bootstrap_git.this]
}
