# Architecture

This page covers what runs where and why. The values below come from the
homelab-prd cluster. Yours live in `terraform/clusters/<name>/cluster.tfvars`,
`terraform/shared/shared.auto.tfvars` and
`kubernetes/clusters/<name>/cluster-config.yaml`.

## Hardware and network

One Proxmox host, a Minisforum AI X1 Pro with 12 cores, 96 GB RAM, a 1 TB
system disk and a ZFS mirror called `tank` on two 2 TB disks. Everything
below shares that one box, so nothing here survives losing the host.

The LAN is flat, `192.168.68.0/24`, with no VLANs. The router hands out DHCP
from `.50` up, so every static address sits below `.50`:

| Address | Use |
|---|---|
| .1 | Router |
| .2 | Proxmox host |
| .11 | Fileserver LXC, NFS for media |
| .12 | pg-01, PostgreSQL LXC |
| .20 | Pi-hole, LAN DNS |
| .29 | Kubernetes API VIP |
| .31 | Control plane cp-1 |
| .34, .35 | Workers |
| .40 to .49 | Cilium LoadBalancer pool. Traefik takes .41 |

There's no public IP. Everything public goes out through a Cloudflare Tunnel.

## Cluster

Talos Linux VMs, one control plane and two workers. I started with three
control planes and dropped to one: on a single host they add etcd write load
and use 6 vCPU and 12 GB, but they don't protect against the failure that
matters, which is the host itself. The cost is that the API is down while cp-1
reboots, so take an etcd snapshot before every Talos or Kubernetes upgrade.
The VIP stayed, so control planes can come back without changing the endpoint.

Terraform downloads the Talos ISO from Image Factory into Proxmox, boots each
VM from it and pushes the machine config over the Talos API. Nothing needs SSH
to the host. The schematic adds `qemu-guest-agent` so Proxmox sees node IPs.

VMs use CPU type `host`, fixed memory with ballooning off, virtio-scsi-single
with iothread, and `discard=on`.

## Networking inside the cluster

Cilium replaces kube-proxy and announces LoadBalancer IPs over L2. Talos
installs it from `talos/cilium/cilium.yaml` as an inline manifest, so nodes go
Ready without Flux. Flux doesn't manage Cilium afterwards. Upgrades are manual,
see [cilium-upgrade.md](cilium-upgrade.md).

Traefik is the only ingress controller. Apps use plain `Ingress` objects with
`ingressClassName: traefik`.

## DNS and exposure

The hostname decides whether an app is public. There's no separate ingress
class.

- `<app>.${lan_domain}` is LAN only. `external-dns-internal` writes a DNS-only
  A record in Cloudflare that points at the Traefik LB IP. cert-manager issues
  a wildcard certificate for it through a Cloudflare DNS-01 challenge.
- `<app>.${public_domain}` is public. `external-dns-public` writes a proxied
  CNAME to the tunnel. Cloudflare terminates TLS, and `cloudflared` forwards
  every request to Traefik over plain HTTP.

Both external-dns releases use `policy: sync` with their own TXT owner, so they
only delete records they created. Two clusters that share a zone need
different `dns_owner_id` values.

A second domain, penchev.com, stays on Azure DNS. A Cloudflare partial zone
handles its app subdomains. This is opt-in per cluster through `extra_zones`
and the `external-dns-penchev*` releases, and you can delete it if you don't
need it.

`terraform/shared/dns.tf` writes DNS-only records for the LXCs, such as
`pg-01.int.home`. external-dns never touches them.

## Storage

- Proxmox CSI creates ZFS zvols on `tank` and attaches them to the VMs. The
  StorageClass is `proxmox-tank`. Use it for app config and databases.
- The fileserver LXC exports `/tank/media` and its child datasets over NFS.
  Apps mount them through static PVs from `csi-driver-nfs`. Each ZFS child
  dataset needs its own bind mount and export, which
  `fileserver.child_datasets` drives.
- pg-01 runs PostgreSQL 17 with data on `tank/postgres`. It sits outside the
  cluster so databases survive a cluster rebuild. `postgres_databases` in the
  cluster tfvars creates a role, a database and a `postgres-<db>` Secret in
  each listed namespace.

Media files belong to uid 100000, because the unprivileged fileserver LXC maps
its root to that uid. The NFS export ignores supplemental groups, so apps that
write media run as uid 100000. They skip `fsGroup`, which would make kubelet
chown the whole NFS mount, and use a root init container to chown only their
config volume.

## GitOps

The Flux Operator runs Flux. Terraform installs the operator and a
FluxInstance once, then Flux manages both from
`kubernetes/clusters/<name>/flux-system`. Flux reads this public repo over
HTTPS with no credentials.

The root Kustomization applies `kubernetes/clusters/<name>`, which holds these
Kustomizations:

| Kustomization | Path | Depends on |
|---|---|---|
| `infrastructure-controllers` | `kubernetes/infrastructure/controllers` | |
| `infrastructure-configs` | `kubernetes/infrastructure/configs` | controllers |
| `apps` | `kubernetes/apps` | configs |
| `monitoring-*` | `kubernetes/apps/monitor/...` | configs |

`apps` creates one Flux Kustomization per app from `kubernetes/apps/<namespace>/<app>/ks.yaml`.
Those live in `flux-system` and set `targetNamespace`, so they can read the
SOPS key and the substitution ConfigMaps.

## Configuration and secrets

Manifests use `${var}` placeholders. Flux fills them from three sources:

| Source | Written by | Holds |
|---|---|---|
| `cluster-config` ConfigMap | Git | LB IPs and other static values |
| `cluster-config-tf` ConfigMap | Terraform | Domains, zone and tunnel IDs, Proxmox URL |
| `cluster-secrets-tf` Secret | Terraform | Tokens Terraform creates: CSI, pve-exporter, tunnel secret |

`cluster-secrets-tf` goes only to the Kustomizations that need it, and only
into Secret manifests that hold nothing but `${var}` placeholders. CI checks
that rule.

Secrets you write by hand are SOPS files encrypted with age. Terraform seeds
the `sops-age` Secret at bootstrap. Terraform's own credentials sit in
`secrets.sops.env`, see [terraform-secrets.md](terraform-secrets.md).

## Monitoring

kube-prometheus-stack, Loki and Alloy run in `monitoring`, each with its own
Flux Kustomization. Grafana, Prometheus and Alertmanager are LAN only at
`<name>.${lan_domain}`. Grafana allows anonymous admin on the LAN, and a SOPS
Secret holds the break-glass password.

- Talos doesn't expose the scheduler, controller-manager or etcd metrics, and
  Cilium replaces kube-proxy, so those scrape jobs are off.
- Alloy ships pod logs through the Kubernetes API. Talos system logs aren't
  collected.
- pve-exporter scrapes the Proxmox host. Set `pve_exporter_proxmox_user` on
  one cluster only, or every cluster scrapes the same host.
- Alertmanager has no receiver yet.
- The namespace runs Pod Security `privileged` because node-exporter needs
  host access.

## Terraform

Two roots, no local modules:

- `terraform/shared` owns the fileserver and pg-01 LXCs and their DNS records.
- `terraform/cluster` owns one cluster. It runs once per directory in
  `terraform/clusters/`, each with its own state.

State lives in a private Cloudflare R2 bucket. Proxmox API tokens can't set LXC
bind mounts on PVE 9, so the LXCs need a one-time host command each, see
[bootstrap.md](bootstrap.md).

## CI

| Workflow | Runs on | Checks |
|---|---|---|
| `validate.yml` | GitHub-hosted | flate render and kubeconform, Alloy config, Terraform fmt, validate and tests, SOPS rules, pluto |
| `terraform-plan.yml` | In-cluster ARC runner | Plans every root and comments on the PR |
| `talos-docker-test.yml` | GitHub-hosted | Boots the Talos and Kubernetes versions in Docker and tries the next Kubernetes upgrade |
| `gitops-live-test.yml` | In-cluster ARC runner | Points Flux at a Renovate PR and checks it reconciles, see [renovate-live-test.md](renovate-live-test.md) |
| `flux-upgrade-test.yml` | GitHub-hosted | Flux Operator and Flux upgrades on kind, see [flux-upgrade-test.md](flux-upgrade-test.md) |
| `arc-upgrade-test.yml` | GitHub-hosted | ARC chart upgrades on kind |

Nothing applies Terraform from CI. Cluster applies run from a laptop, because
the ARC runner lives in the cluster an apply can reboot.

## Known risks

- The Proxmox host is a single point of failure.
- With one etcd member, a lost cp-1 means restoring from a snapshot.
- Losing the age key means losing every SOPS secret. Keep it in a password
  manager.
- Terraform state holds the Talos CA keys. Keep the R2 token private and an
  encrypted offline copy of the state.
- No backups yet for PVs or PostgreSQL beyond ZFS on the mirror.
