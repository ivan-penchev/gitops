# Proxmox → Talos → Flux GitOps: IaC Plan

## Goal
Infrastructure-as-Code that provisions a Talos-based, HA Kubernetes cluster on
Proxmox and hands ongoing cluster management to Flux (GitOps). One imperative
boundary only: `terraform apply`. Everything else is Git-driven.

## Locked Decisions
| Area | Choice | Why |
|------|--------|-----|
| Provisioner | Terraform + `bpg/proxmox` provider | Modern, declarative, template-clone support |
| Talos delivery | See "Talos delivery (revised)" below — API-only ISO boot | Superseded the disk-image/template approach (that needs SSH) |
| Talos config/bootstrap | `siderolabs/talos` Terraform provider | Pure IaC: gen-config + apply + bootstrap in one apply |
| Topology | **1 control-plane + 2 workers** (was 3 CP; collapsed 2026-07-31) | Single Proxmox host → multi-CP adds no hardware HA, only cost; see "Single control-plane collapse" below |
| API endpoint (VIP) | Talos built-in L2 VIP in machineconfig | Kept after CP collapse: stable endpoint even if cp-1 is rebuilt / CPs re-added |
| Terraform state | Local, gitignored, manually backed up | Homelab choice (see risk below) |
| GitOps engine | Flux CD | Lightweight, Talos community favorite |
| CNI | Cilium (eBPF, kube-proxy replacement, L2 LB) | Talos favorite; disable kube-proxy + default CNI |
| Cilium+Flux bootstrap | Cilium via Talos `inlineManifests` (helm-templated); Flux via TF `flux` provider same apply; Flux adopts Cilium HelmRelease | Hands-off, single source of truth |
| Secrets in Git | SOPS + age; TF seeds `sops-age` secret at bootstrap | Simple, no extra infra |
| Repo | **This repo IS the monorepo** — `github.com/ivan-penchev/gitops` holding `/terraform` + `/kubernetes` + `/talos` | Single change surface; Flux self-manages the same repo |
| Flux ↔ Git auth | **SSH deploy** — `ssh://git@github.com/ivan-penchev/gitops.git`, key `~/.ssh/id_rsa` (verified GitHub access) | No PAT to rotate; Mac SSH already trusts the profile |
| CSI / PV storage | Proxmox CSI plugin → ZFS zvols on `tank` | Single-host native; revisit Longhorn on 2nd host |
| Internet exposure | Cloudflare Tunnel (`cloudflared` in-cluster) + Cloudflare DNS | No public IP/CGNAT/DDNS needed; hides home IP |
| Ingress split | Internal ingress class (LAN) + public ingress class (via Tunnel) | Control what's public by class, not per-service firewall |
| Talos delivery (revised) | **API-only: download Talos ISO to `local`, boot VM from CD-ROM, install to disk** | No SSH needed (disk-image import wants SSH); machineconfig applied over Talos API |

## Access & toolchain (for building/validating the IaC)
- **Reachability:** build machine is on the LAN; Proxmox API `192.168.68.2:8006`
  reachable (verified). Talos/kube validation needs same-LAN access to VIP `.29`.
- **Auth:** dedicated `terraform-prov@pve` user + API token
  `terraform-prov@pve!mytoken` (privsep off). Broad privs at `/` verified.
  - Present: VM.Allocate/Clone/Config.*/PowerMgmt/Migrate, Datastore.*, Sys.Modify (covers ISO URL download), SDN.Use, Pool.Allocate.
  - Add if guest-agent IP detection misbehaves: `VM.Monitor`, `VM.Console`.
  - **Secret handling:** never committed. Terraform reads `PROXMOX_VE_ENDPOINT`
    + `PROXMOX_VE_API_TOKEN` from env / gitignored `*.auto.tfvars`. **Rotate the
    token after bring-up** (it was shared in chat).
- **SSH to node:** intentionally NOT granted → IaC designed API-only (ISO boot).
- **Authorization level:** full apply (create/destroy real VMs) approved.
- **Confirmed infra literals:** node `pve`; VM disks → `tank` (zfspool);
  ISO → `local` (dir); bridge `vmbr0` (192.168.68.2/24); gateway `.1`.
- **Local tools present:** terraform 1.5.7, kubectl 1.36.1, flux 2.8.6, helm, jq, yq,
  **talosctl, sops, age** (last three in `~/.nix-profile/bin`). Only `cloudflared`
  missing — runs in-cluster, not needed locally. **Nothing to install.**
- **Provisioner = Terraform** (not OpenTofu), per decision.

## Current Proxmox inventory (mapped live)
**No QEMU VMs exist** — everything is LXC. Talos nodes will be the first VMs.
VMIDs `100–107, 200` are taken by LXCs → Talos uses **`131–141`** (vmid maps to
IP last-octet, e.g. 131 = .31). All containers are on `vmbr0`, gw `.1`.

| VMID | Name | IP | Type |
|------|------|-----|------|
| 200 | casaos | 192.168.68.10 | static |
| 106 | audiobooks | 192.168.68.15 | static |
| 100 | pihole | 192.168.68.20 | static (DNS) |
| 101 | nginxproxymanager | 192.168.68.21 | static |
| 102 | jellyfin | 192.168.68.25 | static |
| 103 | qbittorrent | 192.168.68.30 | static |
| 104 | radarr | (≥.50) | **DHCP** |
| 105 | prowlarr | (≥.50) | **DHCP** |
| 107 | turnkey-fileserver | (≥.50) | **DHCP** |

**Collision check — CLEAR:** planned VIP `.29`, CPs `.31/.32/.33`, workers
`.34–.39`, ingress LBs `.40/.41` do not overlap any static LXC IP (.10/.15/.20/
.21/.25/.30) and all sit below the `.50` DHCP floor (no dynamic collision).
Note: static LXC IPs are set in LXC config, NOT as Deco reservations — safe only
because they're below the DHCP start; keep the Talos static block below `.50` too.

## Physical / Proxmox host
- **Single Proxmox host** (Minisforum AI X1 Pro): Ryzen AI 9 HX370 (12C/24T),
  96 GB DDR5, dual 2.5GbE, Radeon 890M iGPU + NPU, Oculink expansion.
  → NOT host-level HA: 3 CP VMs still share one physical box. Fine for
  homelab (survives VM/Talos failure, upgrades, drains), not a datacenter.
- **Disks:** 1 TB (boot/system) + 2×2 TB **ZFS mirror `tank`** (accepts disk
  images + container content). `tank` mirror survives one disk failure.
- **CSI:** Proxmox CSI plugin provisions zvols on `tank`, hot-attaches to Talos
  VMs. Longhorn deferred until a 2nd physical host exists (needs cross-host PV HA).

## Network (flat L2, no VLANs)
- Upstream: ISP cable → **TP-Link Deco X20** (router/gateway, **no VLAN support**).
- **Pi-hole LXC = DNS only** (`192.168.68.20`); Deco remains the gateway.
- Subnet `192.168.68.0/24`; Deco DHCP starts at `.50` → `.3–.49` free static space.
- **No public IP** (dynamic/CGNAT) → outbound-only exposure required.

### IP allocation (all static, below DHCP `.50`)
| Purpose | IP |
|---------|-----|
| Deco (gateway) | .1 |
| Proxmox host | .2 |
| Pi-hole LXC (DNS) | .20 |
| qBittorrent LXC | .30 |
| **Talos API VIP** | **.29** |
| **Control planes** | **.31 / .32 / .33** |
| **Workers** | **.34–.39** |
| **Internal ingress LB** | **.40** (LAN-only; Pi-hole local records point here) |
| **Public ingress LB** | **.41** (optional — Tunnel can target internal ingress) |

- Talos nodes get **static IPs in machineconfig** (not Deco DHCP reservations).
- Cilium L2 announces the LB IP(s) on the flat subnet.

## Per-node sizing (measured against live budget)
Live budget: 91.94 GB RAM (~14.7 GB used idle), 24 threads, `tank` 1474 GB free.
VM RAM is reserved (unlike LXC caps); reserve ~44 GB for host + ZFS ARC + LXC growth.

| Role | Count | vCPU | RAM | Disk | VMIDs | IPs |
|------|-------|------|-----|------|-------|-----|
| Control plane | 3 | 2 | 4 GB | 30 GB | 131/132/133 | .31/.32/.33 |
| Worker | 2 | 4 | 12 GB | 60 GB | 134/135 | .34/.35 |
| **API VIP** | — | — | — | — | — | **.29** |

**Cluster totals:** 14 vCPU (of 24, overcommit-safe), **36 GB reserved RAM** (of 92),
210 GB boot disk on `tank` (of 1474 free). PVs use separate CSI zvols on `tank`.

**VM hardware tuning (accepted profile):**
- CPU type `host` (full perf + feature passthrough; single host = no migration cost)
- Ballooning OFF / fixed RAM (stable memory for kubelet/scheduler)
- Machine `q35` + SeaBIOS, serial console on
- Disk: virtio-scsi-single + iothread, `discard=on` + `ssd=1` (TRIM on ZFS zvol)
- QEMU guest agent ON (Talos `qemu-guest-agent` extension → Proxmox sees node IP)
- Boot: Talos ISO from `local` as CD-ROM → installs to `tank` boot disk

**ARC caveat:** confirm `zfs_arc_max` on the node; if ARC is uncapped and grows,
trim it (e.g. cap at 8–16 GB) before pushing VM RAM higher.

## Internet exposure
- **Cloudflare Tunnel** (`cloudflared` runs in-cluster, outbound-only): no
  port-forward, no DDNS, works behind CGNAT/dynamic IP, home IP hidden, free
  DDoS/WAF at Cloudflare edge.
- **Cloudflare DNS** fronts public hostnames; Tunnel routes to the ingress
  controller. Public ingress LB `.41` becomes optional under this model.
- **Cloudflare Access** (SSO/auth) in front of admin/private tools.

## Machineconfig must-haves
- `cluster.network.cni.name: none`  (Cilium owns networking)
- `cluster.proxy.disabled: true`     (Cilium replaces kube-proxy)
- Control-plane `machine.network.interfaces[].vip.ip: <free IP outside DHCP>`
- `cluster.controlPlaneEndpoint` = VIP
- Image Factory schematic includes `siderolabs/qemu-guest-agent`

## Bootstrap ordering (chicken-and-egg to solve, in order)
1. Import Talos Image Factory disk image as Proxmox template.
2. Terraform clones control-plane + worker VMs from template.
3. Talos provider: gen machineconfigs, apply-config, bootstrap etcd (1 CP node).
4. Cilium present via `inlineManifests` → nodes reach Ready with no manual step.
5. Terraform `flux` provider installs Flux, seeds `sops-age` secret, points at repo.
6. Flux syncs `/kubernetes`, adopts Cilium HelmRelease, manages all apps.

## Risks / follow-ups
- **State loss = identity loss.** Talos `secrets.yaml` is irreplaceable. Generate it
  as a separate SOPS/age-encrypted input committed to Git so the crown jewels are
  versioned even though TF state is local.
- **age private key** lives in TF local state + password manager. Losing it = can't
  decrypt Git secrets.
- Keep bootstrap Cilium values == Flux HelmRelease values to avoid drift/adoption pain.
- Reserve a static VIP + a LB IP range (Cilium L2) outside Proxmox DHCP scope.

## Dependency automation (done)
- **Renovate + live Flux health-test** — `renovate.json` + `.github/workflows/`.
  Renovate opens one PR per dependency (flux charts/OCI tags, container images,
  GH Actions); every `renovate/*` PR triggers a destructive **live** test on the
  in-cluster ARC runner that repoints the `flux-system` GitRepository at the PR
  SHA, reconciles, and uses Flux's `wait:true` Ready as the green/red verdict,
  then reverts to `main` (with an in-cluster watchdog dead-man's-switch).
  Human-merge on green. `RENOVATE_TOKEN` Actions secret is set. See
  [`docs/renovate-live-test.md`](./docs/renovate-live-test.md).

## Single control-plane collapse (done, 2026-07-31)
- **Why:** on one Proxmox host, 3 control planes give no hardware fault tolerance
  (host death kills all three) while costing 6 vCPU / 12 GB + 3× etcd write
  amplification. Collapsed to **1 dedicated CP + 2 workers**.
- **cp-1** resized to 4 vCPU / 8 GB (sole etcd + apiserver, stays tainted).
  **cp-2/cp-3** removed. Workers unchanged. **VIP kept.**
- **Method (non-destructive to PVCs):** pre-migration `talosctl etcd snapshot`
  → `talosctl reset --graceful` cp-3 then cp-2 one-at-a-time (each leaves etcd)
  → `terraform apply` (drop cp-2/cp-3 from `control_planes`, bump cp-1) → delete
  stale node objects. Orphaned DaemonSet pods GC'd automatically.
- **Safety net:** manual `talosctl etcd snapshot` only — **mandatory before every
  Talos/k8s upgrade** (single etcd = upgrades are the top risk). No CronJob.
- **Accepted risk:** a cp-1 loss is *recoverable from snapshot* but not
  *transparent* (API down until restore); host loss still takes everything.
- Terraform provider creds are now SOPS-encrypted at repo root in
  [`secrets.sops.env`](./secrets.sops.env); decode via
  [`docs/terraform-secrets.md`](./docs/terraform-secrets.md).

## Dependency updates (2026-07-31)
- **GitHub Actions:** `actions/checkout@v7`, `actions/github-script@v9`,
  `renovatebot/github-action@v46.2.0` (exact pin; a Renovate `packageRule`
  disables *patch* bumps for the Renovate wrapper so only minor/major open PRs).
- **Terraform `cloudflare` provider v4 → v5** (5.22.0). Breaking renames handled:
  `cloudflare_tunnel` → `cloudflare_zero_trust_tunnel_cloudflared` (`secret` →
  `tunnel_secret`); `cloudflare_record` → `cloudflare_dns_record` (`value` →
  `content`); `data.cloudflare_zone` now uses a `filter{}` block and account id
  reads back as nested `.account.id`. State migrated in place via cross-type
  `moved` blocks (provider MoveState upgrader) — **no destroy/recreate**, tunnel
  id and secret preserved, `terraform plan` clean.
- **`required_version` is now `>= 1.10`** (cross-type `moved` needs ≥1.8 and the
  state was rewritten by TF 1.10.x). Upgrade your local Terraform accordingly.

## Proposed repo layout
```
/
├── terraform/
│   ├── proxmox/        # VM templates, clones, networking
│   ├── talos/          # machine secrets, config, bootstrap (siderolabs/talos)
│   ├── flux/           # flux provider bootstrap + sops-age secret
│   ├── main.tf, variables.tf, versions.tf
│   └── secrets.sops.yaml
├── kubernetes/
│   ├── flux-system/    # Flux sync + Kustomizations
│   ├── infrastructure/ # cilium, cert-manager, storage CSI, etc.
│   └── apps/           # workloads
├── .sops.yaml
└── README.md
```

## Open questions (not yet decided)
- Node counts/sizing (vCPU/RAM/disk per CP and worker) within the 96 GB budget.
- Ingress controller choice (ingress-nginx vs Traefik) + cert-manager (though
  Cloudflare can terminate TLS at the edge via Tunnel).
- Which specific services go public vs internal-only.
- Talos + Kubernetes version pinning and upgrade strategy.
- Backup strategy for PVs on `tank` (snapshots / offsite).
