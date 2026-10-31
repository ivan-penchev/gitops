# Testability plan

Written 2026-10-30. The goal is a PR check for every change type before it
reaches the cluster, including Terraform, Talos and Kubernetes upgrades, and
monitoring.

## Where we started

| Change type | Tested in PR on 2026-10-30? | How |
|---|---|---|
| App charts and images from Renovate | Yes | `gitops-live-test` on the live cluster, on the ARC runner |
| Flux Operator and Flux version | Yes | `flux-upgrade-test` on kind, GitHub-hosted |
| Monitoring stack | No | See finding 1 |
| Terraform code, providers and CLI | No | Renovate ignored `terraform/**`, and state was local on the laptop |
| Talos and Kubernetes version | No | Manual. The versions lived in the gitignored `terraform.tfvars` |
| Cilium | No | Manual, through `docs/cilium-upgrade.md` |
| YAML, schemas and formatting | No | No PR ran a static check |

Versions on 2026-10-30:

| | Running | Latest |
|---|---|---|
| Talos | v1.13.7 | v1.13.12, v1.14.5 |
| Kubernetes | 1.36.2 | 1.37.2 |
| Cilium | 1.20.2 | 1.20.4, with 1.21 in pre-release |
| Terraform CLI | The repo needs 1.11 or newer, the laptop had 1.5.7 | 1.17.1 |

## Findings

1. **The live test never applied monitoring PRs.** The five owners,
   `monitoring-namespace`, `-loki`, `-prometheus`, `-alloy` and `-configs`,
   live in `kubernetes/clusters/homelab/` and belong to the root Kustomization.
   The live test suspended the root and reconciled only `infrastructure-*`,
   `apps` and the children of `apps`. A monitoring PR passed without its YAML
   ever reaching the cluster.
2. **Terraform couldn't run in CI.** State was a local file. One root mixed
   five providers that need three networks. Cloudflare needs the internet,
   Proxmox, Talos and pg-01 need the LAN, and Kubernetes needs the cluster API.
3. **Talos and Kubernetes versions weren't in git.** `talos_version` and
   `kubernetes_version` sat in the gitignored `terraform.tfvars`, so neither CI
   nor Renovate could see them.
4. **The Cilium render only worked on this LAN.** `values.yaml` hardcoded
   `k8sServiceHost: 192.168.68.29`. KubePrism listens on `localhost:7445` and
   Talos turns it on by default. With KubePrism the same render boots anywhere,
   CI included.
5. **Cilium blocks Kubernetes 1.37.** Talos 1.14 supports Kubernetes 1.33 to
   1.37, but Cilium 1.20 stops at 1.36. Cilium 1.21 adds 1.37 and is still in
   pre-release. Talos 1.14 can go first, since it runs 1.36 fine.
6. **Nothing cheap ran on every PR.** A typo in a kustomization failed when
   Flux reconciled it, after the merge.

## Should Terraform be split?

Yes, by what it manages. My first cut was three stacks split by API, named
cloudflare, platform and cluster, with remote state between them. Adding a
service meant editing two stacks and keeping their IPs in sync by hand, and
nothing in it allowed a second cluster. So I replaced it.

I tried modules next, one per component, wired together in a shared root and
a copied root per cluster. It worked, but nine single-use modules each needed
a variables file and output plumbing, and every new cluster copied 450 lines
of wiring. Too much for one person to read.

What's here now is two roots with plain resource files:

| Root | Owns | Needs | PR plan runs on | Apply |
|---|---|---|---|---|
| `terraform/shared` | fileserver and pg-01 LXCs, LAN DNS | PVE and Cloudflare APIs | ARC runner | Manual |
| `terraform/cluster` | One cluster's ISO, VMs, Talos, CSI user, tunnel, Flux bootstrap, k8s Secrets, pg roles and DBs | PVE, Talos, Cloudflare and k8s APIs, pg-01 | ARC runner | Manual, laptop only |

Every cluster runs `terraform/cluster` with its own tfvars from
`terraform/clusters/<name>/` and its own state key, which `terraform/tf.sh`
picks. A cluster reads the shared outputs through `terraform_remote_state`,
so a LAN IP lives in `shared.auto.tfvars` and nowhere else. Proxmox and Talos
stay in one root, because Talos applies config to the IPs the VMs report.
Cluster applies stay on the laptop, since the ARC runner lives in the cluster
an apply can reboot. All states share one bucket and token, so any job that
can plan one root can also read the Talos secrets. Separate buckets would fix
that if it ever matters.

## Plan

### P0, quick wins

- **A1 Static gate in `validate.yml`.** It runs on GitHub-hosted runners for
  every PR. `flux-local test` or `kustomize build` for every Flux path, with
  `postBuild` variables stubbed. Render HelmReleases and run `kubeconform`
  with CRD schemas. `terraform fmt -check`, `init -backend=false`, `validate`
  and `tflint`. `alloy validate` on the Alloy config. A check that every
  `*.sops.yaml` is encrypted and no plaintext `kind: Secret` exists. `pluto`
  for deprecated APIs against the next Kubernetes version.
  Status: done. It uses `flate` instead of `flux-local`, which is deprecated.
  The Alloy check validates the rendered ConfigMap, so D1 needs no extraction
  step.
- **A2 Close the monitoring gap in the live test.** Reconcile every
  root-owned Kustomization except `flux-system` in `dependsOn` order, instead
  of the fixed `layers` list. Update `test_gitops_live_test.py` and
  `docs/renovate-live-test.md`.
  Status: done in #78.
- **A3 Pin the toolchain.** A `mise.toml` with terraform, talosctl, kubectl,
  helm and flux, used by the laptop and CI. Renovate bumps it.

### P1, Terraform in CI

- **B1 Remote state** in a private Cloudflare R2 bucket through the S3
  backend with `use_lockfile = true`. Use a scoped API token and keep an
  encrypted offline copy. State holds the Talos CA keys, so the token must not
  leave the CI environment. I rejected a `pg` backend on pg-01, because
  Terraform manages pg-01.
  Status: done in #85. B2 later split the state into `homelab/shared.tfstate`
  and `homelab/clusters/<name>.tfstate`.
- **B2 Split into a shared root and one cluster root, as above.**
  Status: done in #86. I merged the three stack states into
  `homelab/shared.tfstate` and `homelab/clusters/homelab-prd.tfstate`, then
  used `moved` blocks to take the module prefixes off. Every resource kept its
  ID, and I deleted the old keys from R2. A throwaway single-node cluster then
  found three bugs that would hit any second cluster. #87 fixed them.
- **B3 `terraform test` with `mock_provider`.** Runs on GitHub-hosted with no
  credentials. Cover the logic that broke before. `postgres_databases` should
  give one Secret per namespace, the machine config should contain the Cilium
  inline manifest, and the fileserver mount command should render. Mocks use
  the real provider schemas, so a provider bump that renames an attribute
  fails here.
  Status: done. `terraform/shared/tests` and `terraform/cluster/tests` hold
  plan-only runs, and CI runs them after `validate`. The cluster tests use a
  made-up cluster and a mocked `terraform_remote_state`. They also cover the
  #87 fixes. Cilium gets the cluster VIP, and a cluster without workers
  schedules on its control planes.
- **B4 Plan on PR.** Matrix over changed roots, `-detailed-exitcode`, plan
  summary as a PR comment. A provider or CLI bump must plan "No changes".
  Then drop `terraform/**` from Renovate's `ignorePaths` and group provider
  bumps per root.
  Status: done. `.github/workflows/terraform-plan.yml` plans shared and every
  cluster on the ARC runner with `-lock=false`, and keeps one PR comment up to
  date. With two roots, planning all of them is simpler than a matrix over the
  changed ones. It uses the same tokens as a laptop. The age key sits in the
  `terraform-plan` environment and decrypts `secrets.sops.env`. Renovate now
  opens one PR per root for provider and module bumps.

### P1, Talos and Kubernetes

- **C1 Versions in git.** Move `talos_version`, `kubernetes_version` and the
  schematic ID to a committed tfvars file. Add a Renovate regex manager that
  uses `github-releases` for `siderolabs/talos` and `kubernetes/kubernetes`.
  Status: done. After B2 each cluster has
  `terraform/clusters/<name>/talos-versions.tfvars`. The schematic ID stays as
  the variable default. The upgrade steps are in `docs/talos-k8s-versions.md`.
- **C2 Cilium on KubePrism.** Set `k8sServiceHost: localhost` and
  `k8sServicePort: 7445`, and ship it with Cilium 1.20.4 through the upgrade
  guide.
  Status: done. homelab-prd runs 1.20.4 on KubePrism, applied by hand through
  the guide. The render no longer holds a cluster address, so I removed the
  `__K8S_SERVICE_HOST__` placeholder and its `replace()`. Merging pushes the
  render into the cp-1 machine config. The run caught a guide bug. The
  pre-flight cleanup deleted the Hubble certgen objects.
- **C3 Talos-in-Docker job.** Run `talosctl cluster create` with the docker
  provisioner at the version from C1, with `talos/patches/*` and the Cilium
  inline manifest. Check that nodes are Ready, `cilium status` and DNS. Then
  run `talosctl upgrade-k8s --to <next>` and check again. This rehearses
  Kubernetes and Cilium bumps on every C1 Renovate PR. It can't test Talos OS
  upgrades, the ISO install or Proxmox.
  Status: done in #94. `.github/workflows/talos-docker-test.yml` runs
  `.github/scripts/talos-docker-test.sh` once per cluster on a GitHub-hosted
  runner. It takes about 2.5 minutes, or 8 with an upgrade. A talosctl of the
  contract's minor renders the configs, and a second one that matches
  `talos_version` runs `upgrade-k8s`, because the 1.13 talosctl refuses 1.36
  to 1.37. `cilium-dbg status`, rollouts and a cross-node DNS and service
  request replace `cilium status`. A trial run took homelab-prd's setup from
  1.36.2 to 1.37.1 with Cilium 1.20.4 and passed. That says Cilium works on
  1.37 in Docker, not that upstream supports it. Since #95 it runs on PRs
  only, and skips a cluster whose versions, `talos/` and test script match the
  base branch.
- **C4 Staging cluster on Proxmox for OS upgrades.** Dropped. Talos OS
  upgrades follow the runbook in `docs/talos-k8s-versions.md`, which starts
  with an etcd snapshot.
- **C5 Extend `docs/talos-k8s-versions.md`** and run it.
  1. Talos 1.13.7 to 1.13.12, workers first, then cp-1. With one control
     plane the API is down while cp-1 reboots.
     Status: done. cp-1 took about two minutes. Afterwards the proxmox-csi
     controller sat in crash-loop back-off with `no route to host` to
     `10.96.0.1`, which blocked the Flux chain. Deleting the pod fixed it. The
     runbook now covers the etcd snapshot, the ISO eject and the post-checks.
  2. Talos 1.13.12 to 1.14.5, after reading the 1.14 notes. Update the C1
     version and apply so the machine config matches.
     Status: done in #93. Each node took 83 to 96 seconds, and etcd moved to
     3.7.3. The CSI controller recovered on its own this time. The new
     `talos_config_contract` variable keeps the machine configs on the `v1.13`
     contract. A `v1.14` contract with provider 0.12 would switch to the
     multi-document format and turn on workload isolation.
  3. Cilium 1.20.4 now, 1.21.x once it is GA.
  4. Kubernetes 1.36.2 to 1.37.x with `talosctl upgrade-k8s`. That command
     re-syncs inline manifests from the machine config, so the machine config
     must carry the current Cilium first.
  5. Before step 4, confirm 1.37 support for proxmox-csi, Traefik,
     Flux, kube-prometheus-stack and ARC. `pluto` from A1 catches removed APIs.

### P2, Monitoring

- **D1 Move the Alloy config out of the HelmRelease** into `config.alloy`
  with a `configMapGenerator`, and point the chart at it with
  `alloy.configMap.create: false`. A1 can then validate it.
- **D2 Monitoring e2e on kind.** A `kubernetes/clusters/ci` overlay with the
  monitor stack, patched for kind with the `standard` StorageClass, no ingress
  and small resources. Checks:
  - `up == 1` for each ServiceMonitor and PodMonitor target that exists in CI.
  - A canary pod's logs come back from Loki through Alloy.
  - Grafana's datasource health API reports OK for Prometheus and Loki.

  This would have caught the missing `pods/log` RBAC for Alloy. It runs on
  changes to `kubernetes/apps/monitor/**` and `monitoring-*.yaml`, and reuses
  the kind tooling from `flux-upgrade-test`.
- **D3 Selector cross-check.** A script over the A1 render that fails when a
  ServiceMonitor or PodMonitor selector matches no Service or Pod in the repo.
- **D4 Rule tests.** There are no custom `PrometheusRule`s yet. The first one
  ships with a `promtool test rules` file, run by A1.

### P3, later

- Grow the `clusters/ci` overlay to everything that isn't tied to hardware.
  That leaves out proxmox-csi, NFS, cloudflared, external-dns and ARC. Every PR
  then gets a full Flux reconcile on kind, and the live test becomes the last
  gate.

## Action points

| # | Item | Action | Status | Priority | Depends on |
|---|---|---|---|---|---|
| 1 | A2 | Live test reconciles root-owned monitoring Kustomizations | Done | P0 | |
| 2 | A1 | `validate.yml` static gate | Done | P0 | |
| 3 | A3 | `mise.toml` toolchain pin | Open | P0 | |
| 4 | C1 | Talos and Kubernetes versions in a committed tfvars, with Renovate | Done | P1 | |
| 5 | C2 | Cilium 1.20.4 on KubePrism through the upgrade guide | Done | P1 | |
| 6 | C5 steps 1 and 2 | Talos 1.13.7 to 1.13.12 to 1.14.5 | Done | P1 | 4 |
| 7 | B1 | R2 remote state | Done | P1 | |
| 8 | B2 | Split Terraform into a shared root and one cluster root with per-cluster tfvars | Done | P1 | 7 |
| 9 | B3 | `terraform test` with mock providers | Done | P1 | 2 |
| 10 | B4 | Terraform plan on PR, unignored in Renovate | Done | P1 | 7, 8 |
| 11 | C3 | Talos-in-Docker upgrade rehearsal job | Done | P1 | 4, 5 |
| 12 | D1 | Extract the Alloy config and validate it | Open | P2 | 2 |
| 13 | D2, D3 | Monitoring e2e on kind and selector check | Open | P2 | 2 |
| 14 | C4 | Staging cluster for Talos OS upgrades | Dropped | P2 | 8 |
| 15 | C5 steps 3 to 5 | Kubernetes 1.37 | Open | P2 | Cilium 1.21 GA, 6, 11 |
| 16 | P3 | Full-repo kind reconcile | Open | P3 | 13 |
