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
bootstrap, Flux syncs `kubernetes/clusters/homelab` from it over SSH
(`git@github.com`, key `~/.ssh/id_rsa`). The FluxInstance in
`kubernetes/clusters/homelab/flux-system` owns the controller configuration.
Flux manages the operator Helm release from the same directory. Terraform
bootstraps these resources but does not overwrite them after Git adopts them.

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

## Security reminders

- Rotate the Proxmox token once bring-up is verified (it was shared in chat).
- Terraform state contains Talos secrets + kubeconfig → treat `terraform/terraform.tfstate` as a secret (gitignored). Back it up encrypted.
- Commit only SOPS-encrypted `*.sops.yaml` secrets.
