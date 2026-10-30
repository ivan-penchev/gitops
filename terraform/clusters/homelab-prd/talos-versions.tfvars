# Talos and Kubernetes versions for the cluster. Renovate opens a PR when a new
# release comes out. Merging it upgrades nothing by itself, see
# docs/talos-k8s-versions.md. Check the Talos support matrix before bumping
# Kubernetes: https://www.talos.dev/latest/introduction/support-matrix/

# renovate: datasource=github-releases depName=siderolabs/talos
talos_version = "v1.14.5"

# Config format the provider generates. Keep the version the cluster was
# created with. Raising it is a separate change, see docs/talos-k8s-versions.md.
talos_config_contract = "v1.13"

# renovate: datasource=github-releases depName=kubernetes/kubernetes
kubernetes_version = "1.37.1"
