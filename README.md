# proxmox-talos-flux

IaC for a Talos-based, HA Kubernetes cluster on a single Proxmox host, managed by
Flux (GitOps). One imperative boundary: `terraform apply`. Everything else is Git.

See [`plan.md`](./plan.md) for the full design, decisions, and rationale.
For standing a fresh host up step-by-step, see [`docs/bootstrap.md`](./docs/bootstrap.md).

## Layout

```
terraform/    # Proxmox VMs, Talos and one-time Flux Operator bootstrap
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

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in — DO NOT COMMIT
export PROXMOX_VE_ENDPOINT='https://192.168.68.2:8006/'
export PROXMOX_VE_API_TOKEN='terraform-prov@pve!mytoken=<secret>'   # rotate after bring-up

terraform init
terraform fmt -check
terraform validate
terraform plan      # review — creates real VMs on apply
# terraform apply   # provisions VMs, bootstraps Talos + Flux
```

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

### Wattbill deployment hardening

Wattbill intentionally allows anonymous public use. Its Pod runs non-root with
seccomp, a read-only root filesystem, no Linux capabilities and no privilege
escalation. Kubernetes service-account token mounting is disabled; the image-pull
secret remains available to the kubelet. The existing version tag is unchanged
and is deliberately not pinned to an immutable digest.

Wattbill opts into the reusable `kubernetes/components/ingress-nginx-only`
Kustomize Component. The consuming Kustomization sets `namespace: wattbill` and
includes it via `components: [../../components/ingress-nginx-only]`. It permits
inbound TCP on the named Pod port `http` (8080 for Wattbill) only from ingress-nginx
controller Pods in the `ingress-nginx` namespace. Both the public tunnel route and
the LAN hostname continue through that controller. Other ordinary Pods, including
Pods in Wattbill's own namespace, are not allowed to connect directly. This is
not protection against a compromised node or ingress controller, and additional
allow policies would be additive. Kubelet probes are not ordinary Pod traffic.

For another application, include the component once in its namespace's resource
assembly, set that assembly's namespace, add the Pod-template label
`networking.penchev.com/allow-ingress-nginx: "true"`, and declare a TCP container
port named `http`. Include it only once per shared namespace; multiple inclusions
would generate the same policy. Unlabelled Pods are unaffected by this component.
Review direct API clients and monitoring before opting in: they will need separate
allow rules. Only Wattbill currently adopts it.

Egress remains unchanged so DNS and upstream billing APIs keep working. This
policy is not an egress/SSRF firewall or an authentication gate. Cloudflare WAF,
HTTPS-only enforcement, and trusted client-IP handling need separate verification;
shared ingress settings are not changed by this hardening.

After GitOps rollout, verify the Pod has no projected API-token volume, readiness
and both HTTPS hostnames pass, ingress controller Pods can reach TCP 8080, and an
unrelated Pod cannot. API schema validation alone does not prove network policy
enforcement. Do not rely on this policy until those live checks pass.

## Security reminders

- Rotate the Proxmox token once bring-up is verified (it was shared in chat).
- Terraform state contains Talos secrets + kubeconfig → treat `terraform/terraform.tfstate` as a secret (gitignored). Back it up encrypted.
- Commit only SOPS-encrypted `*.sops.yaml` secrets.
