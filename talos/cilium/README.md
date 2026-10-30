# Cilium (CNI), bootstrapped via Talos inlineManifests

Cilium is the cluster CNI. It is **owned here**, not by Flux: it must exist
before Flux's own controllers can schedule (they are ordinary pods needing a
CNI). It is embedded into the control-plane machine config as
`cluster.inlineManifests`. See `local.cilium_inline_patch` in
`terraform/cluster/talos.tf`.

`cilium.yaml` is rendered from the Cilium Helm chart with `values.yaml` as the
single source of Talos-specific values. `k8sServiceHost` is the placeholder
`__K8S_SERVICE_HOST__`, and Terraform replaces it with each cluster's VIP.
Regenerate it with:

```sh
./render.sh <VERSION>
```

Hubble TLS uses the certgen CronJob, which creates `cilium-ca` and
`hubble-server-certs` in the cluster. The render holds no key material, and
`render.sh` refuses to write one that does. Talos never updates inline-manifest objects after
they exist, so a new render has to be applied to the cluster by hand. Follow
[`docs/cilium-upgrade.md`](../../docs/cilium-upgrade.md).

The LoadBalancer IP pool + L2 announcement policy CRs live in
`kubernetes/infrastructure/configs/cilium-lb.yaml` and ARE Flux-managed, since
they only need Cilium's CRDs (created at runtime by the Cilium operator).
