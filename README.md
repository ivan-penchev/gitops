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

Cloudflare ExternalDNS has created the proxied `check.penchev.com` CNAME to
`<tunnel-id>.cfargotunnel.com`. A **separate Azure ExternalDNS release** creates
the authoritative Azure CNAME to `check.penchev.com.cdn.cloudflare.net`. It
uses only the annotated test Ingress,
an exact hostname regex, the `penchev.com` Azure zone-name filter, CNAME-only
record management, and `upsert-only` with no TXT registry. It cannot delete
records when the Ingress disappears; remove the CNAME deliberately if retiring
the test. The app currently has **DNS Zone Contributor on the whole zone**;
that permission is broader than these filters and could allow unintended
changes if they are misconfigured. Narrow it to **Reader** on `rg-prod` and
**DNS Zone Contributor** only on `penchev.com/CNAME/check` as soon as practical.
Record-set-scoped access [is supported by Azure DNS](https://learn.microsoft.com/azure/dns/dns-protect-zones-recordsets#record-set-level-azure-rbac).
Use the *enterprise application/service principal* object ID
`3522d76e-0fef-4c1c-9bb2-908ecaad67a0`, not the app-registration object
ID; verify record-set-scoped creation before removing the current role.

The SOPS-encrypted `azure-dns.sops.yaml` Secret supplies `azure.json` to the
release in the `external-dns` namespace. It is listed alongside the release
in the controllers Kustomization. Never commit a plaintext copy of the client
secret; rotate any copy disclosed outside the encrypted Secret.

After Flux reconciles, check the Azure ExternalDNS logs for a successful
CNAME upsert and query authoritative Azure nameservers for
`check.penchev.com CNAME check.penchev.com.cdn.cloudflare.net`.
Verify `https://check.penchev.com/` returns `GitOps public tunnel check OK`.
Do not change the registrar nameservers, apex blog alias, `www` blog CNAME, or
mail records. The live `cluster-config-tf` already contains the Cloudflare
partial-zone ID, but Terraform state does not; review any Terraform plan for
unrelated Flux bootstrap changes before applying it.

For another public app, first review its authentication and data exposure.
Add its Ingress and explicitly add its **exact hostname** to both anchored
`--regex-domain-filter` allowlists and the Azure annotation filter opt-in.
Also adjust Azure target selection for that hostname (the current forced
`--default-targets` is test-only) and grant only its intended CNAME record-set
permission. Do not replace the allowlists with a zone-wide suffix filter.

## Security reminders

- Rotate the Proxmox token once bring-up is verified (it was shared in chat).
- Terraform state contains Talos secrets + kubeconfig → treat `terraform/terraform.tfstate` as a secret (gitignored). Back it up encrypted.
- Commit only SOPS-encrypted `*.sops.yaml` secrets.
