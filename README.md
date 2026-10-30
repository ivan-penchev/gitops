# proxmox-talos-flux

IaC for a Talos-based, HA Kubernetes cluster on a single Proxmox host, managed by
Flux (GitOps). One imperative boundary: `terraform/tf.sh all apply`. Everything else is Git.

See [`plan.md`](./plan.md) for the full design, decisions, and rationale.
For standing a fresh host up step-by-step, see [`docs/bootstrap.md`](./docs/bootstrap.md).

## Layout

```
terraform/    # shared/ for the LXCs and LAN DNS, cluster/ for every cluster, clusters/<name>/ for its settings
talos/        # Talos machineconfig patches (control-plane / worker)
kubernetes/   # Flux-managed cluster state (infrastructure + apps)
```

This repo (`github.com/ivan-penchev/gitops`) **is** the GitOps source: after
bootstrap, Flux syncs `kubernetes/clusters/homelab` over public HTTPS without
Git credentials. The FluxInstance in
`kubernetes/clusters/homelab/flux-system` owns the controller configuration.
Flux manages the operator Helm release from the same directory. Terraform
bootstraps these resources but does not overwrite them after Git adopts them.

## Application layout

Prowlarr and Radarr share `downloads`. Audiobookshelf uses `media`.
Each has a Flux `ks.yaml` in `kubernetes/apps/<namespace>/<app>/`, with its
workloads under `app/`. FlareSolverr stays with Prowlarr. Wattbill keeps its
existing folder, namespace, and direct reconciliation by `apps`.

The per-app Flux objects live in `flux-system` so they can use the existing
SOPS key and substitution ConfigMaps. Their `targetNamespace` selects the
workload namespace. They wait for infrastructure and check their own workloads;
Radarr does not depend on Prowlarr. The parent `apps` checks child readiness.

Homepage runs in its own namespace at `https://homepage.${internal_domain}`
(`homepage.int.home.17072021.xyz` with the current cluster configuration).
It uses ingress-nginx's internal wildcard DNS and default TLS certificate; no
public DNS record, tunnel hostname, or public Ingress is configured. Its
`kubernetes/apps/homepage/app/config/` supplies the dark, grouped dashboard,
search, date, and cluster CPU/memory widgets. Homepage discovers seven LAN-only
services from their internal Ingress annotations. Each Ingress has a
`gethomepage.dev/pod-selector` matching its workload, so the card can display
pod status even when the Ingress name differs from the pod labels. The dashboard
uses a dedicated service account that can read nodes, pods, namespaces,
node/pod metrics, and Ingresses; it does not discover public Ingresses without
the Homepage annotation.
Discovered cards may appear in a different order within each group. Homepage
needs metrics-server for cluster resource data. Kustomize hashes the generated
ConfigMap name into the HelmRelease, so an edit to its `subPath`-mounted files
rolls the pod when Flux reconciles the HelmRelease.

The apps now run in their target namespaces using their original retained volumes.
Child, parent, root and operator reconciliation are restored; parent pruning and
readiness checks are enabled and verified live. DNS, HTTPS and the configured
Prowlarr-to-Radarr connection passed final checks. The live-test and Renovate
workflows were manually re-enabled and their active states verified through the
GitHub API. See [the migration runbook](docs/app-namespace-migration.md).
Keep the old namespaces, stopped workloads and backups for rollback; a Git revert
alone does not move their data back.

## Cluster at a glance

| Role | ×N | vCPU | RAM | Disk | VMID | IP |
|------|----|------|-----|------|------|-----|
| Control plane | 3 | 2 | 4 GB | 30 GB | 131–133 | .31/.32/.33 |
| Worker | 2 | 4 | 12 GB | 60 GB | 134–135 | .34/.35 |
| API VIP | — | — | — | — | — | .29 |

- Proxmox node `pve` @ `https://192.168.68.2:8006` — VM disks on `tank`, Talos ISO on `local`, bridge `vmbr0`.
- CNI: Cilium (kube-proxy replacement). CSI: Proxmox CSI on `tank`. Exposure: Cloudflare Tunnel.

## Prerequisites (local)

Terraform >= 1.11, `talosctl`, `kubectl`, `flux`, `helm`, `sops`, and `age`.

## ⚠️ kubeconfig safety

This repo **never** touches your existing kube contexts (AKS clusters, etc.).
Terraform's Kubernetes and Helm providers are wired to the Talos API endpoint via the
`talos` data sources — not `~/.kube/config`. The generated kubeconfig/talosconfig are
written to gitignored files in this repo. Always target them explicitly:

```bash
export KUBECONFIG=$PWD/kubeconfig          # Talos cluster only
export TALOSCONFIG=$PWD/talosconfig
```

## Usage

Terraform has two roots. Neither uses local modules, so each `.tf` file
holds the resources it's named after.

| Root | Owns | State key |
|---|---|---|
| `terraform/shared` | fileserver and pg-01 LXCs, their LAN DNS records | `homelab/shared.tfstate` |
| `terraform/cluster` | one cluster: Talos ISO, VMs, Talos config and bootstrap, CSI Proxmox user, Cloudflare tunnel, Flux bootstrap, Terraform-made k8s Secrets, pg roles and databases | `homelab/clusters/<name>.tfstate` |

Every cluster runs the same `terraform/cluster` code. What makes clusters
differ is `terraform/clusters/<name>/`, which holds only `cluster.tfvars` and
`talos-versions.tfvars`. A cluster reads the LAN settings and the pg-01
address and password from the shared state through `terraform_remote_state`.
You set a LAN IP once, in `terraform/shared/shared.auto.tfvars`.

The only cluster is `homelab-prd`. Its Talos cluster name is still `homelab`,
because changing it renames every node.

`terraform/tf.sh` runs Terraform with the credentials from
`secrets.sops.env`. For a cluster it also passes that cluster's tfvars and
state key, and runs `init -reconfigure` when the last run used a different
cluster. Don't run plain `terraform` in `terraform/cluster`, since it won't
know which cluster you mean. `all` runs shared first, then every cluster.

```bash
terraform/tf.sh all init
terraform/tf.sh all plan
terraform/tf.sh homelab-prd apply
```

### Add a cluster

1. Copy `terraform/clusters/homelab-prd` to `terraform/clusters/<name>`.
2. In `cluster.tfvars`, change everything that names or addresses the
   cluster: `cluster_name`, VM IDs, node IPs, `cluster_vip`,
   `cloudflare_tunnel_name`, `flux_path`, `iso_name_prefix`,
   `kubeconfig_file` and `talosconfig_file`. Give the CSI user and role new
   names such as `<name>-csi@pve`, or two clusters share one Proxmox token.
   With `workers = {}`, workloads run on the control planes.
3. Create the Flux tree at `flux_path`, starting from a copy of
   `kubernetes/clusters/homelab`.
4. Run `terraform/tf.sh <name> apply`.

If a cluster needs something the others don't, add a variable to
`terraform/cluster` with a default that keeps the current clusters as they
are.

Settings live in tracked tfvars files. There is no local
`terraform.tfvars`. See [docs/bootstrap.md](docs/bootstrap.md) for a
rebuild from zero.

After apply, Flux reconciles `kubernetes/` into the cluster.

## Public apps on penchev.com

Azure DNS remains authoritative; Cloudflare handles public TLS and forwards
application subdomains through the tunnel. The two ExternalDNS releases manage
CNAMEs on each side of this partial-zone setup. Neither manages the blog at
`penchev.com` or `www.penchev.com`.

To expose an app, add a public nginx Ingress for its subdomain with
`external-dns.kubernetes.io/target: <hostname>.cdn.cloudflare.net`. Review its
authentication first: **Wattbill has no login and is publicly accessible.**
Cloudflare's edge certificate for a new hostname may take time to become active;
HTTP working does not mean HTTPS is ready.

Azure ExternalDNS is `upsert-only`, so retiring an app requires manually
removing its Azure CNAME. After removing the check app, delete the stale
`check.penchev.com` Azure CNAME once it is no longer needed. The Azure service
principal currently has zone-wide DNS Zone Contributor; consider narrowing it
to the intended record sets. Keep credentials SOPS-encrypted.

## Security reminders

- Rotate the Proxmox token once bring-up is verified (it was shared in chat).
- Terraform state contains Talos secrets + kubeconfig. It lives in the private R2 bucket `homelab-tfstate`; keep an age-encrypted offline copy (see docs/terraform-secrets.md).
- Commit only SOPS-encrypted `*.sops.yaml` secrets.
