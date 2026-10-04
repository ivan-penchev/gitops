removed {
  from = flux_bootstrap_git.this

  lifecycle {
    destroy = false
  }
}

locals {
  flux_manifest_path    = "${path.module}/../${var.flux_path}/flux-system"
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
      condition     = local.flux_instance.spec.sync.url == var.flux_git_url
      error_message = "flux_git_url must match spec.sync.url in flux-instance.yaml."
    }
  }

  depends_on = [talos_cluster_kubeconfig.this]
}

resource "kubernetes_secret_v1" "flux_git" {
  metadata {
    name      = "flux-system"
    namespace = kubernetes_namespace_v1.flux_system.metadata[0].name
  }

  data = {
    identity       = file(pathexpand(var.flux_git_private_key_path))
    "identity.pub" = format("%s\n", join(" ", slice(regexall("\\S+", file(pathexpand("${var.flux_git_private_key_path}.pub"))), 0, 2)))
    known_hosts    = file("${path.module}/github_known_hosts")
  }

  type                           = "Opaque"
  wait_for_service_account_token = false

  lifecycle {
    prevent_destroy = true
  }
}

module "flux_operator_bootstrap" {
  source  = "controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes"
  version = "0.9.0"

  revision = 1
  gitops_resources = {
    instance_yaml = file("${local.flux_manifest_path}/flux-instance.yaml")
    operator_chart = {
      repository  = trimprefix(local.flux_operator_source.spec.url, "oci://")
      version     = local.flux_operator_source.spec.ref.tag
      values_yaml = yamlencode(local.flux_operator_release.spec.values)
    }
  }

  depends_on = [
    kubernetes_secret_v1.flux_git,
    kubernetes_secret_v1.sops_age,
    kubernetes_config_map_v1.cluster_config_tf,
  ]
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
