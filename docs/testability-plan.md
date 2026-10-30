# Testability plan

Written 2026-10-30. Goal: every change type gets a PR check before it reaches
the cluster, including Terraform, Talos/Kubernetes upgrades and monitoring.

## Where we are

| Change type | Tested in PR today? | How |
|---|---|---|
| App charts and images (Renovate) | Yes | `gitops-live-test` on the live cluster (ARC runner) |
| Flux Operator / Flux version | Yes | `flux-upgrade-test` on kind (GitHub-hosted) |
| Monitoring stack | No | see finding 1 |
| Terraform (code, providers, CLI) | No | Renovate ignores `terraform/**`; state is local on the laptop |
| Talos / Kubernetes version | No | manual, versions live in gitignored `terraform.tfvars` |
| Cilium | No | manual, `docs/cilium-upgrade.md` |
| YAML/schema/fmt | No | there is no static check on any PR |

Versions on 2026-10-30:

| | Running | Latest |
|---|---|---|
| Talos | v1.13.7 | v1.13.12, v1.14.5 |
| Kubernetes | 1.36.2 | 1.37.2 |
| Cilium | 1.20.2 | 1.20.4 (1.21 is pre-release) |
| Terraform CLI | repo needs >= 1.11, laptop has 1.5.7 | 1.17.1 |

## Findings

1. **Monitoring PRs are never applied by the live test.** The five owners
   (`monitoring-namespace`, `-loki`, `-prometheus`, `-alloy`, `-configs`) live in
   `kubernetes/clusters/homelab/` and belong to the root Kustomization. The live
   test suspends the root and only reconciles `infrastructure-*`, `apps` and the
   children of `apps`. A monitoring PR passes without its YAML ever reaching
   the cluster.
2. **Terraform can't run in CI.** State is a local file. One root mixes five
   providers that need three different networks: Cloudflare (internet),
   Proxmox/Talos/pg-01 (LAN), Kubernetes (cluster API).
3. **Talos and Kubernetes versions aren't in git.** `talos_version` and
   `kubernetes_version` sit in the gitignored `terraform.tfvars`, so neither CI
   nor Renovate can see them.
4. **The Cilium render only works on this LAN.** `values.yaml` hardcodes
   `k8sServiceHost: 192.168.68.29`. With KubePrism (`localhost:7445`, on by
   default in Talos) the same render boots anywhere, including CI.
5. **Kubernetes 1.37 is blocked by Cilium.** Talos 1.14 supports 1.33 to 1.37,
   but Cilium 1.20 stops at 1.36. 1.37 support is in Cilium 1.21, which is still
   pre-release. Talos 1.14 can go first, it runs 1.36 fine.
6. **Nothing cheap runs on every PR.** A typo in a kustomization fails at Flux
   reconcile time, after merge.

## Should Terraform be split?

Yes, by what it manages. My first cut was three stacks split by API,
named cloudflare, platform and cluster, with remote state between them. Adding a
service meant editing two stacks and keeping their IPs in sync by hand, and
nothing in it allowed a second cluster. So I replaced it.

I tried modules next: one per component, wired together in a shared root and
a copied root per cluster. It worked, but nine single-use modules meant a
variables file and output plumbing for each, and every new cluster copied
450 lines of wiring. Too much for one person to read.

What's here now is two roots with plain resource files:

| Root | Owns | Needs | PR plan runs on | Apply |
|---|---|---|---|---|
| `terraform/shared` | fileserver and pg-01 LXCs, LAN DNS | PVE and Cloudflare APIs | ARC runner | manual |
| `terraform/cluster` | one cluster: ISO, VMs, Talos, CSI user, tunnel, Flux bootstrap, k8s Secrets, pg roles/DBs | PVE, Talos, Cloudflare and k8s APIs, pg-01 | ARC runner | manual, laptop only |

Every cluster runs `terraform/cluster` with its own tfvars from
`terraform/clusters/<name>/` and its own state key, which `terraform/tf.sh`
picks. A cluster reads the shared outputs through `terraform_remote_state`,
so a LAN IP lives in `shared.auto.tfvars` and nowhere else. Proxmox and
Talos stay in one root, because Talos config apply targets the IPs the VMs
report. Cluster applies stay laptop-only, since the ARC runner lives in the
cluster an apply can reboot. All states share one bucket and token, so any
job that can plan one root can also read the Talos secrets. Separate buckets
fix that if it ever matters.

## Plan

### P0, quick wins

- **A1 Static gate (`validate.yml`, GitHub-hosted, every PR).**
  `flux-local test` or `kustomize build` for every Flux path, with
  `postBuild` variables stubbed. Render HelmReleases and run `kubeconform`
  with CRD schemas. `terraform fmt -check`, `init -backend=false`, `validate`,
  `tflint`. `alloy validate` on the Alloy config. A check that every
  `*.sops.yaml` is encrypted and no plaintext `kind: Secret` exists. `pluto`
  for deprecated APIs against the next Kubernetes version.
  Status: PR open. It uses `flate` instead of `flux-local`, which is
  deprecated. The Alloy check validates the rendered ConfigMap, so D1 needs
  no extraction step.
- **A2 Close the monitoring gap in the live test.** Reconcile every
  root-owned Kustomization except `flux-system`, in `dependsOn` order, instead
  of the fixed `layers` list. Update `test_gitops_live_test.py` and
  `docs/renovate-live-test.md`.
- **A3 Pin the toolchain.** A `mise.toml` with terraform, talosctl, kubectl,
  helm, flux, used by the laptop and CI. Renovate bumps it.

### P1, Terraform in CI

- **B1 Remote state** in a private Cloudflare R2 bucket via the S3 backend with
  `use_lockfile = true`. Scoped API token, keep an encrypted offline copy.
  State holds the Talos CA keys, so the token must not leave the CI
  environment. A `pg` backend on pg-01 was rejected because Terraform manages
  pg-01.
  Status: PR open. State moved to `homelab-tfstate/homelab/terraform.tfstate`
  and plans clean. Merged in #85.
- **B2 Split into a shared root and one cluster root, as above.** Status:
  done in #86. I merged the three stack states into `homelab/shared.tfstate`
  and `homelab/clusters/homelab-prd.tfstate`, then used `moved` blocks to
  take the module prefixes off. Every resource kept its ID, and the old keys
  are gone from R2. A throwaway single-node cluster then found three bugs
  that would hit any second cluster, fixed in #87.
- **B3 `terraform test` with `mock_provider`.** Runs on GitHub-hosted with no
  credentials. Cover the logic that broke before: `postgres_databases` to one
  Secret per namespace, machine config contains the Cilium inline manifest,
  fileserver mount command. Mocks use the real provider schemas, so a provider
  bump that renames an attribute fails here.
  Status: PR open. `terraform/shared/tests` and `terraform/cluster/tests`
  hold plan-only runs, and CI runs them after `validate`. The cluster tests
  use a made-up cluster and a mocked `terraform_remote_state`, and also cover
  the #87 fixes: Cilium gets the cluster VIP, and a cluster without workers
  schedules on its control planes.
- **B4 Plan on PR.** Matrix over changed roots, `-detailed-exitcode`, plan
  summary as a PR comment. A provider or CLI bump must plan "No changes".
  Then drop `terraform/**` from Renovate's `ignorePaths` and group provider
  bumps per root.

### P1, Talos and Kubernetes

- **C1 Versions in git.** Move `talos_version`, `kubernetes_version` and the
  schematic ID to a committed `terraform/talos/versions.auto.tfvars`. Add a
  Renovate regex manager (`github-releases` for `siderolabs/talos` and
  `kubernetes/kubernetes`).
  Status: PR open. The file is `terraform/talos-versions.auto.tfvars` because
  the stacks don't exist yet. The schematic ID stays as the variable default.
  The upgrade steps are in `docs/talos-k8s-versions.md`.
- **C2 Cilium on KubePrism** (`k8sServiceHost: localhost`,
  `k8sServicePort: 7445`), shipped with Cilium 1.20.4 through the upgrade guide.
  Status: PR open. homelab-prd runs 1.20.4 on KubePrism, applied by hand
  through the guide. The render no longer holds a cluster address, so the
  `__K8S_SERVICE_HOST__` placeholder and its `replace()` are gone. Merging
  pushes the render into the cp-1 machine config. The run caught a guide bug:
  the pre-flight cleanup deleted the Hubble certgen objects.
- **C3 Talos-in-Docker job.** `talosctl cluster create` (docker provisioner)
  at the version from C1, with `talos/patches/*` and the Cilium inline
  manifest. Check nodes Ready, `cilium status`, DNS. Then
  `talosctl upgrade-k8s --to <next>` and check again. This rehearses
  Kubernetes and Cilium bumps on every C1 Renovate PR. It can't test Talos OS
  upgrades, ISO install or Proxmox.
- **C4 Staging cluster on Proxmox for OS upgrades.** A second cluster
  under `terraform/clusters/` with 1 small CP and 1 small worker. Create it, run
  `talosctl upgrade`, destroy it. Needs two reserved IPs below `.50`.
- **C5 Write `docs/talos-upgrade.md`** and run it:
  1. Talos 1.13.7 to 1.13.12, workers first, then cp-1. With one CP the API is
     down while cp-1 reboots.
  2. Talos 1.13.12 to 1.14.5, after reading the 1.14 notes. Update the C1
     version and apply so the machine config matches.
  3. Cilium 1.20.4 now, 1.21.x once it is GA.
  4. Kubernetes 1.36.2 to 1.37.x with `talosctl upgrade-k8s`. That command
     re-syncs inline manifests from the machine config, so the machine config
     must carry the current Cilium first.
  5. Before step 4, confirm 1.37 support for proxmox-csi, ingress-nginx,
     Flux, kube-prometheus-stack and ARC. `pluto` from A1 catches removed APIs.

### P2, Monitoring

- **D1 Move the Alloy config out of the HelmRelease** into `config.alloy`
  with a `configMapGenerator`, and point the chart at it
  (`alloy.configMap.create: false`). A1 can then validate it.
- **D2 Monitoring e2e on kind.** A `kubernetes/clusters/ci` overlay with the
  monitor stack, patched for kind (`standard` StorageClass, no ingress, small
  resources). Checks: `up == 1` for each ServiceMonitor/PodMonitor target that
  exists in CI, a canary pod's logs come back from Loki through Alloy, and
  Grafana's datasource health API reports OK for Prometheus and Loki. This
  would have caught the missing `pods/log` RBAC for Alloy. Runs on changes to
  `kubernetes/apps/monitor/**` and `monitoring-*.yaml`, and reuses the kind
  tooling from `flux-upgrade-test`.
- **D3 Selector cross-check.** A script over the A1 render that fails when a
  ServiceMonitor/PodMonitor selector matches no Service or Pod in the repo.
- **D4 Rule tests.** There are no custom `PrometheusRule`s yet. The first one
  ships with a `promtool test rules` file, run by A1.

### P3, later

- Grow the `clusters/ci` overlay to everything that isn't hardware-bound
  (skip proxmox-csi, NFS, cloudflared, external-dns, ARC). Every PR then gets a
  full Flux reconcile on kind, and the live test becomes the last gate.

## Action points

| # | Action | Priority | Depends on |
|---|---|---|---|
| 1 | Live test reconciles root-owned monitoring Kustomizations (A2), PR open | P0 | |
| 2 | `validate.yml` static gate (A1) | P0 | |
| 3 | `mise.toml` toolchain pin (A3) | P0 | |
| 4 | Talos/k8s versions into a committed tfvars + Renovate (C1) | P1 | |
| 5 | Cilium 1.20.4 + KubePrism via the upgrade guide (C2), PR open | P1 | |
| 6 | Talos 1.13.7 to 1.13.12 to 1.14.5 (C5 steps 1, 2) | P1 | 4 |
| 7 | R2 remote state (B1), done | P1 | |
| 8 | Split Terraform into a shared root and one cluster root with per-cluster tfvars (B2), done | P1 | 7 |
| 9 | `terraform test` with mock providers (B3), PR open | P1 | 2 |
| 10 | Terraform plan on PR, unignore in Renovate (B4) | P1 | 7, 8 |
| 11 | Talos-in-Docker upgrade rehearsal job (C3) | P1 | 4, 5 |
| 12 | Extract Alloy config + validate (D1) | P2 | 2 |
| 13 | Monitoring e2e on kind (D2) and selector check (D3) | P2 | 2 |
| 14 | Staging cluster for Talos OS upgrades (C4) | P2 | 8 |
| 15 | Kubernetes 1.37 (C5 steps 3 to 5) | P2 | Cilium 1.21 GA, 6, 11 |
| 16 | Full-repo kind reconcile (P3) | P3 | 13 |
