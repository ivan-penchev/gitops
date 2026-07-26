# Cilium (CNI) — bootstrapped via Talos inlineManifests

Cilium is the cluster CNI. It is **owned here**, not by Flux: it must exist
before Flux's own controllers can schedule (they are ordinary pods needing a
CNI). It is embedded into the control-plane machine config as
`cluster.inlineManifests` (see `terraform/talos.tf` -> `local.cilium_inline_patch`).

`cilium.yaml` is rendered from the Cilium Helm chart. To regenerate (e.g. to
bump the version), keep `values.yaml` as the single source of Talos-specific
values and run:

```sh
helm repo add cilium https://helm.cilium.io/
helm repo update cilium
helm template cilium cilium/cilium \
  --version <VERSION> \
  --namespace kube-system \
  -f values.yaml > cilium.yaml
```

Then `terraform apply` (control-plane config change) and roll the nodes.

The LoadBalancer IP pool + L2 announcement policy CRs live in
`kubernetes/infrastructure/configs/cilium-lb.yaml` and ARE Flux-managed, since
they only need Cilium's CRDs (created at runtime by the Cilium operator).
