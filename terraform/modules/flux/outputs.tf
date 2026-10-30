output "gitops_resources" {
  description = "Input for the flux-operator-bootstrap module, read from manifests_dir."
  value = {
    instance_yaml = file("${local.flux_manifest_path}/flux-instance.yaml")
    operator_chart = {
      repository  = trimprefix(local.flux_operator_source.spec.url, "oci://")
      version     = local.flux_operator_source.spec.ref.tag
      values_yaml = yamlencode(local.flux_operator_release.spec.values)
    }
  }
}
