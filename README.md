# proxmox-talos-flux

IaC for a Talos-based, HA Kubernetes cluster on a single Proxmox host, managed by
Flux (GitOps). One imperative boundary: `terraform apply`. Everything else is Git.

See [`plan.md`](./plan.md) for the full design, decisions, and rationale.

## Layout

```
terraform/    # Proxmox VMs + Talos bootstrap + Flux bootstrap (bpg/proxmox, siderolabs/talos, fluxcd/flux)
talos/        # Talos machineconfig patches (control-plane / worker)
kubernetes/   # Flux-managed cluster state (infrastructure + apps)
```

This repo (`github.com/ivan-penchev/gitops`) **is** the GitOps source: after
bootstrap, Flux syncs `kubernetes/clusters/homelab` from it over SSH
(`git@github.com`, key `~/.ssh/id_rsa`) and self-manages.

## Cluster at a glance

| Role | ×N | vCPU | RAM | Disk | VMID | IP |
|------|----|------|-----|------|------|-----|
| Control plane | 3 | 2 | 4 GB | 30 GB | 131–133 | .31/.32/.33 |
| Worker | 2 | 4 | 12 GB | 60 GB | 134–135 | .34/.35 |
| API VIP | — | — | — | — | — | .29 |

- Proxmox node `pve` @ `https://192.168.68.2:8006` — VM disks on `tank`, Talos ISO on `local`, bridge `vmbr0`.
- CNI: Cilium (kube-proxy replacement). CSI: Proxmox CSI on `tank`. Exposure: Cloudflare Tunnel.

## Prerequisites (local)

`terraform`, `talosctl`, `kubectl`, `flux`, `helm`, `sops`, `age` — all present on this machine.

## ⚠️ kubeconfig safety

This repo **never** touches your existing kube contexts (AKS clusters, etc.).
Terraform's Kubernetes/Flux providers are wired to the Talos API endpoint via the
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

## Security reminders

- Rotate the Proxmox token once bring-up is verified (it was shared in chat).
- Terraform state contains Talos secrets + kubeconfig → treat `terraform/terraform.tfstate` as a secret (gitignored). Back it up encrypted.
- Commit only SOPS-encrypted `*.sops.yaml` secrets.
