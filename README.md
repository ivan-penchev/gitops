# proxmox-talos-flux

IaC for a Talos-based, HA Kubernetes cluster on a single Proxmox host, managed by
Flux (GitOps). One imperative boundary: `terraform apply`. Everything else is Git.

See [`plan.md`](./plan.md) for the full design, decisions, and rationale.
For standing a fresh host up step-by-step, see [`docs/bootstrap.md`](./docs/bootstrap.md).

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

## Public apps on penchev.com (partial Cloudflare zone)

Azure DNS remains authoritative. The separate `external-dns-penchev` release
allows **only `check.penchev.com`** into the Cloudflare partial zone, where it
creates a proxied CNAME to the existing tunnel. The test app returns a fixed
message and has no access to personal data. Wattbill stays LAN-only. The
existing `17072021.xyz` public and internal ExternalDNS releases are unchanged.
The anchored hostname allowlist and distinct TXT registry owner/prefix ensure
this release cannot manage the blog's `penchev.com` or `www.penchev.com` records.

To activate the test hostname:

1. Run `terraform apply` from `terraform/` with the existing credentials; it
   resolves the partial zone ID into `cluster-config-tf`. Review the plan first.
   This change does not migrate DNS or update the Azure zone.
2. After Flux reconciles, verify the **in-cluster** Cloudflare token has
   Zone:Read and DNS:Edit on `penchev.com` and that ExternalDNS created the
   proxied `check.penchev.com` CNAME to `<tunnel-id>.cfargotunnel.com`.
   Access to list a zone alone does not prove DNS-edit permission.
3. At the **authoritative Azure DNS zone**, create **only** a CNAME for
   `check.penchev.com` targeting `check.penchev.com.cdn.cloudflare.net`.
   Verify the target and TLS at Cloudflare before exposing more hosts; this
   repository does not automate or perform that Azure DNS change. Do not
   change the registrar nameservers, apex blog alias, `www` blog CNAME, or mail.
4. Verify `https://check.penchev.com/` returns
   `GitOps public tunnel check OK`. If it does not, inspect the Cloudflare
   record, Azure CNAME, and tunnel/Ingress health before adding apps.

For another public app, first review its authentication and data exposure.
Add its Ingress and explicitly add its **exact hostname** to the anchored
`--regex-domain-filter` allowlist in `external-dns-penchev`; then repeat the
Cloudflare record verification and authoritative Azure CNAME step. Do not
replace the allowlist with a zone-wide suffix filter: that could include the
blog's apex or `www`.

## Security reminders

- Rotate the Proxmox token once bring-up is verified (it was shared in chat).
- Terraform state contains Talos secrets + kubeconfig → treat `terraform/terraform.tfstate` as a secret (gitignored). Back it up encrypted.
- Commit only SOPS-encrypted `*.sops.yaml` secrets.
