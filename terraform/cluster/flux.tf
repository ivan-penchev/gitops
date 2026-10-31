# Flux bootstrap. Terraform creates what Flux needs before it starts (the
# flux-system namespace, the sops-age Secret, the cluster-config-tf ConfigMap
# and the cluster-secrets-tf Secret), then installs the Flux Operator once.

locals {
  flux_instance         = yamldecode(file("${local.flux_manifests_dir}/flux-instance.yaml"))
  flux_operator_source  = yamldecode(file("${local.flux_manifests_dir}/flux-operator-source.yaml"))
  flux_operator_release = yamldecode(file("${local.flux_manifests_dir}/flux-operator.yaml"))
}

resource "kubernetes_namespace_v1" "flux_system" {
  metadata {
    name = "flux-system"
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [metadata[0].labels, metadata[0].annotations]

    precondition {
      condition     = local.flux_instance.spec.sync.url == var.flux_git_url
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

  data = local.cluster_config

  depends_on = [kubernetes_namespace_v1.flux_system]
}

# Credentials Terraform generates, for Flux to substitute into Secret manifests.
# Only the Kustomizations that need a value list this Secret in substituteFrom.
# SOPS secrets written by hand stay in Git and never pass through here.
resource "kubernetes_secret_v1" "cluster_secrets_tf" {
  metadata {
    name      = "cluster-secrets-tf"
    namespace = "flux-system"
  }

  data = merge(local.cloudflared_secrets, local.csi_secrets, local.pve_exporter_secrets)

  type = "Opaque"

  depends_on = [kubernetes_namespace_v1.flux_system]
}

# Installs the Flux Operator and the FluxInstance once. Flux manages both
# from Git afterwards. Bump revision to run the bootstrap again.
module "flux_operator_bootstrap" {
  source  = "controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes"
  version = "0.9.0"

  revision = 1
  gitops_resources = {
    instance_yaml = file("${local.flux_manifests_dir}/flux-instance.yaml")
    operator_chart = {
      repository  = trimprefix(local.flux_operator_source.spec.url, "oci://")
      version     = local.flux_operator_source.spec.ref.tag
      values_yaml = yamlencode(local.flux_operator_release.spec.values)
    }
  }

  depends_on = [
    kubernetes_namespace_v1.flux_system,
    kubernetes_secret_v1.sops_age,
    kubernetes_config_map_v1.cluster_config_tf,
    kubernetes_secret_v1.cluster_secrets_tf,
  ]
}
