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
| PostgreSQL LXC (pg-01) | .12 |
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

## Observability stack (2026-07-31)
Metrics + logs for the cluster and its K8s nodes, deployed as a dedicated Flux
layer (`kubernetes/monitoring/`, `controllers` → `configs`,
`dependsOn: infrastructure-configs`). Live-verified: all Prometheus targets UP,
Loki ingesting logs from every namespace, Grafana anonymous-admin reachable.
- **kube-prometheus-stack 88.0.1** — Prometheus (30d/40Gi), Alertmanager (1Gi),
  Grafana (2Gi), node-exporter (all 3 nodes, tolerates CP taint),
  kube-state-metrics. CP component scrape jobs (scheduler/controller-manager/
  etcd/kube-proxy) **disabled** (Talos doesn't expose them; Cilium replaces
  kube-proxy) — no down-target noise.
- **Loki 7.2.0** SingleBinary, filesystem PVC 40Gi / 30d retention (no MinIO,
  no caches). **Grafana Alloy 1.11.0** DaemonSet tails container logs via the
  K8s API → Loki (no Talos node/system log shipping).
- **Access:** `grafana` / `prometheus` / `alertmanager`.int.home.17072021.xyz
  on the ingress-nginx default wildcard cert. Grafana runs anonymous-**Admin**
  (login form off) with a SOPS break-glass secret
  (`kubernetes/monitoring/controllers/grafana-admin.sops.yaml`).
- **Extra scrape targets:** ServiceMonitors for ingress-nginx (metrics flag
  flipped on) + cert-manager, PodMonitor for Flux.
- **Alerting:** default rules evaluate in-cluster only, **no external receiver
  yet** (SMTP2GO email is an easy later add — one SOPS Alertmanager-config
  secret). Only `Watchdog` fires (pipeline healthy).
- **Talos gotcha:** the `monitoring` namespace runs at PodSecurity
  `privileged` — node-exporter's hostNetwork/hostPID/hostPath/hostPort is
  rejected by Talos' cluster-wide `baseline` default otherwise.

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

## Audiobookshelf non-root (2026-08-01)
ABS now runs **non-root** (`runAsNonRoot: true`, no `fsGroup`) on port **13378**.
- **uid/gid 100000, `supplementalGroups: [0]`.** 100000 is the owner the
  fileserver assigns to the media tree — the unprivileged fileserver LXC (id 110)
  maps its root to host uid 100000, so files land as `100000:0`.
- **Why not group 0 for media:** the NFS export is `sec=sys`, and that server
  **ignores the client's supplemental group list**, so gid-0 membership grants
  neither read nor write on media (reads only worked via the world `r-x` bits).
  Empirically only the *file owner* uid 100000 (or root, via `no_root_squash`)
  can write. Verified live: uid 1000+grp0 → `Permission denied`; uid 100000 → OK.
- **Block PVCs (config/metadata, proxmox-csi):** owned `0:0`, group-0 `rwx`
  setgid dirs, so `supplementalGroups: [0]` grants RW there (local ext4 honors
  supplemental gids normally).
- **No `fsGroup` on purpose:** it applies pod-wide and `nfs.csi` fsGroupPolicy is
  `File` → kubelet would recursively chown the 1 TiB media mount on every mount.
- New UI uploads land as `100000:0`, matching the existing root-`mv`-populated
  media, so the two population paths stay consistent.

## Prowlarr + FlareSolverr (2026-08-01)
Migrated Prowlarr off the DHCP LXC 105 into k8s (`kubernetes/apps/prowlarr/`),
alongside FlareSolverr so protected indexers can clear Cloudflare/DDoS-GUARD.
- **Prowlarr** `lscr.io/linuxserver/prowlarr:2.5.2.5491-ls155`, **non-root**
  (uid/gid 1000 + `fsGroup: 1000`), config on a 2Gi `proxmox-tank` block PVC,
  port 9696, **internal-only** ingress `prowlarr.int.home.17072021.xyz`. s6 needs
  a writable `/run` and Prowlarr a writable `/tmp` → both `emptyDir`; PUID/PGID
  match runAsUser so s6 skips its chown.
- **FlareSolverr** `ghcr.io/flaresolverr/flaresolverr:v3.5.0`, stateless, non-root,
  ClusterIP-only at `http://flaresolverr:8191` (no ingress). Headless Chromium →
  writable `/tmp` + in-memory `/dev/shm` (256Mi) `emptyDir` (the default 64Mi shm
  crashes tabs), ~256Mi req / 1Gi limit.
- **Migration = cold file-copy.** Stopped LXC 105's `prowlarr` service, tar'd
  `/var/lib/prowlarr/{prowlarr.db,config.xml}`, loaded it into the PVC via a root
  helper pod (overwriting the fresh DB), chown 1000:1000. The **API key is
  preserved** (`config.xml` carried over), and the 2.3.5 DB migrated **forward**
  to 2.5.2 on first start. All 8 indexers + Radarr/Sonarr app links survived.
- **FlareSolverr wiring (lives in the DB/PVC, not git).** Added a FlareSolverr
  indexer proxy (host `http://flaresolverr:8191/`) with a `flaresolverr` tag;
  tagged `kickasstorrents.ws` (was *"blocked by CloudFlare Protection"* → now OK,
  and it returns real search results through the proxy). Only Cloudflare-gated
  indexers get the tag so others aren't needlessly routed through the browser.
- **DHCP drift fixed by the move.** The apps' Prowlarr callback URL was stale
  (`.57`) and Radarr had drifted from `.53` → `.58` (LXC 104). Repointed both
  apps' `prowlarrUrl` at the stable ingress and Radarr's `baseUrl` to `.58`;
  both app tests pass, full ApplicationIndexerSync completed, health clean.
  Prowlarr now behind a stable ingress, so its own IP can never drift again.
- **Out of scope:** `0Magnet` (redirects to a parked craigslist page) and
  `ACG.RIP` (connection-refused / site down) still fail — dead indexers, not a
  Cloudflare problem, so FlareSolverr doesn't help them.
- **Access note:** the build host's SSH key reaches the fileserver (.11) and the
  cluster, but **not** the Proxmox host (.2) or the LXCs — the LXC config was
  pulled over the LAN from the container's own `python3 -m http.server`.
- **Follow-up:** LXC 105 is currently stopped (kept as rollback); decommission it
  once satisfied. Radarr/Sonarr/qBittorrent remain LXCs on the LAN.

## Radarr (2026-08-01)
Migrated Radarr off the DHCP LXC 104 into k8s (`kubernetes/apps/radarr/`),
non-root, behind a stable internal ingress. Same cold-copy pattern as Prowlarr.
- **Radarr** `lscr.io/linuxserver/radarr:6.3.0.10514-ls312`, **fully non-root**
  (uid/gid **100000**), config on a 2Gi `proxmox-tank` block PVC, port 7878,
  **internal-only** ingress `radarr.int.home.17072021.xyz`. `emptyDir` `/run`+`/tmp`,
  `/ping` probes, PUID/PGID 100000.
- **uid 100000 + root initContainer.** The media lives on NFS owned `100000:100000`
  (the unprivileged fileserver LXC maps root→100000) and the `sec=sys` export
  ignores supplemental groups, so Radarr must run **as the owner** to write imports.
  A root `initContainer` chowns only the block config PVC to 100000 (no pod-wide
  `fsGroup`, which would recursively chown the huge NFS mount under nfs.csi
  `fsGroupPolicy=File`).
- **The storage surprise — child datasets weren't exported.** `tank/media/movies`,
  `tank/media/torrent-download`, `tank/media/tv` are **separate ZFS child datasets**,
  not folders. The fileserver LXC 110's bind of `/tank/media` is **non-recursive**,
  so it only ever exported the `audiobooks` *folder* (why ABS worked) and never the
  child datasets — the NFS export showed empty `movies`/`downloads`. Fixed by adding
  explicit bind mounts to LXC 110 (`pct set 110 -mp1 /tank/media/movies,... -mp2
  /tank/media/torrent-download,...`) and NFS export lines for each on the fileserver.
  **These live-infra changes must be folded into the fileserver Terraform** so a
  rebuild keeps them (see follow-up).
- **Two NFS mounts, not one.** Because movies/downloads are distinct filesystems,
  Radarr's import from `/downloads`→`/media/movies` is a **cross-dataset copy, never
  a hardlink** (an early single-mount/subPath design chasing hardlinks was wrong —
  nfs.csi subPath = separate mounts = `EXDEV` anyway). Mapped each dataset to its
  own static NFS PV at the **exact LXC paths** (`/media/movies`, `/downloads`), so
  the migrated `radarr.db` (root folder `/media/movies`, remote path mapping
  `/downloads`→`/downloads`) needed **zero edits**.
- **Migration = cold file-copy.** Stopped LXC 104's `radarr`, tar'd
  `/var/lib/radarr/{radarr.db,config.xml}`, loaded into the PVC via a root helper
  pod, chown 100000. **API key preserved**; schema 242 DB migrated **forward** to
  6.3.0. Verified: **14/14 movies present (0 missing)**, root folder accessible,
  media RW as 100000, qBittorrent (.30) reachable, cross-dir hardlinks work within a
  dataset.
- **DHCP drift fixed.** Repointed Prowlarr's Radarr `baseUrl` from the old LXC
  `.58` to `https://radarr.int.home.17072021.xyz`; app test passes, 5 indexers
  synced (incl. the FlareSolverr-gated `kickasstorrents.ws`).
- **Incident note.** While probing, an early `rmdir`+`mkdir` of the `movies`
  placeholder dir on the fileserver detached the host's `tank/media/movies` mount
  (`mounted no`); remounted with `zfs mount`, **no data lost** (136G intact).
- **Memory / OOMKilled (fixed 2026-08-01).** Radarr crash-looped on `OOMKilled`
  (exit 137) at the initial **512Mi** limit while rescanning the migrated library.
  Root cause: Radarr's **.NET Server GC** (default) reserves one heap per CPU (4 on
  the node) and grows to the cgroup limit, deferring collection — real RSS is only
  ~250–300MB, the rest was GC-reserved + reclaimable NFS page cache. Fix: raised the
  limit **512Mi→1Gi** (request 128→256Mi, matches audiobookshelf) *and* set
  `DOTNET_gcServer=0` (workstation GC). Peak memory dropped **1024MiB→~144MiB**,
  0 restarts. Both in `deployment.yaml`.
- **Fileserver child datasets in IaC (done 2026-08-01).** Folded the LXC 110
  `movies` + `torrent-download` bind mounts and NFS exports into
  `terraform/fileserver.tf` (driven by `var.fileserver_child_datasets`): the
  provisioner now writes all export lines and `output.fileserver_host_mount_command`
  emits the full `pct set -mp0/-mp1/-mp2 … && pct reboot`. Verified byte-identical
  to the live hand-applied state.
- **Follow-ups:** decommission LXC 104 once satisfied (stopped = rollback);
  qBittorrent's Share Ratio Limiting is set to *Remove them* (pre-existing) —
  switch to *Pause them* so torrents aren't deleted before Radarr imports.

## PostgreSQL LXC (pg-01, 2026-08-19)
Shared homelab Postgres as a privileged Debian LXC (CT **111**, `.12`,
`pg-01.int.home.17072021.xyz`), provisioned in `terraform/postgres.tf`. Runs
outside the cluster so databases survive Talos rebuilds (same rationale as the
fileserver).

- **Data on ZFS.** PGDATA lives on a dedicated dataset `tank/postgres`
  bind-mounted at **`/mnt/pgdata`** (non-shadowing — a mount over
  `/var/lib/postgresql` would hide the apt cluster). PGDATA = `/mnt/pgdata/17/main`
  via `pg_createcluster`. Independent ZFS snapshots; survives LXC rebuild.
- **PostgreSQL 17** from the PGDG apt repo. `scram-sha-256`, `listen_addresses='*'`,
  `pg_hba` restricted to `192.168.68.0/24` (LAN-only, plaintext on the trusted LAN).
- **Declarative databases.** `var.postgres_databases = [{ name, namespaces }]`
  drives, via the `cyrilgdn/postgresql` provider (544★, actively maintained): a
  login role (owner == db, generated `random_password`), the database, and an
  Opaque Secret **`postgres-<db>`** injected by the `hashicorp/kubernetes`
  provider into every listed namespace. Default entry = DB `landingzone` →
  ns `db-landing-zone`.
- **Secret keys.** `POSTGRES_HOST/PORT/DB/USER/PASSWORD` + `DATABASE_URL`
  (`postgresql://user:pass@pg-01.int.home.17072021.xyz:5432/<db>?sslmode=disable`,
  host = internal FQDN, not the raw IP). Passwords are TF-generated so these
  Secrets live in TF state, not git.
- **Two root@pam host steps (like fileserver).** Bind mount + dataset create are
  root@pam-only, so `output.postgres_host_mount_command` prints
  `zfs create tank/postgres && pct set 111 -mp0 /tank/postgres,mp=/mnt/pgdata && pct reboot 111`.
  Apply is **phased**: (1) `-target` the LXC, (2) run the host step, (3) flip
  `postgres_data_mounted=true` and re-apply so PGDATA initialises on the dataset,
  then roles/dbs/secrets reconcile.
- **Safety.** `prevent_destroy=true` on `postgresql_database` — removing an array
  entry never drops data; deletion is a deliberate manual act.
- **Follow-ups:** backups (nightly `pg_dumpall` → fileserver + ZFS snapshots) are
  intentionally out of scope for now; TLS on connections could be added later.


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
