# What Flux needs before the operator starts: the flux-system namespace, the
# sops-age Secret and the cluster-config-tf ConfigMap. The cluster root calls
# the upstream flux-operator-bootstrap module with output.gitops_resources.

locals {
  flux_manifest_path    = var.manifests_dir
  flux_instance         = yamldecode(file("${local.flux_manifest_path}/flux-instance.yaml"))
  flux_operator_source  = yamldecode(file("${local.flux_manifest_path}/flux-operator-source.yaml"))
  flux_operator_release = yamldecode(file("${local.flux_manifest_path}/flux-operator.yaml"))
}

resource "kubernetes_namespace_v1" "flux_system" {
  metadata {
    name = "flux-system"
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [metadata[0].labels, metadata[0].annotations]

    precondition {
      condition     = local.flux_instance.spec.sync.url == var.git_url
      error_message = "flux_git_url must match spec.sync.url in flux-instance.yaml."
    }
  }
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

  depends_on = [kubernetes_namespace_v1.flux_system]
}

# Values Flux substitutes into manifests (postBuild.substituteFrom).
resource "kubernetes_config_map_v1" "cluster_config_tf" {
  metadata {
    name      = "cluster-config-tf"
    namespace = "flux-system"
  }

  data = var.cluster_config

  depends_on = [kubernetes_namespace_v1.flux_system]
}
