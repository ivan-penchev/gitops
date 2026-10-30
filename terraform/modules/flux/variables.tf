variable "git_url" {
  description = "Public HTTPS Git URL Flux syncs from. Must match the FluxInstance sync URL."
  type        = string
}

variable "manifests_dir" {
  description = "Directory with flux-instance.yaml, flux-operator-source.yaml and flux-operator.yaml."
  type        = string
}

variable "sops_age_key_file" {
  description = "Path to the age PRIVATE key file used to create the in-cluster sops-age secret for Flux decryption. Empty skips the secret (and deletes it if it exists)."
  type        = string
}

variable "cluster_config" {
  description = "Key/values for the cluster-config-tf ConfigMap."
  type        = map(string)
}
