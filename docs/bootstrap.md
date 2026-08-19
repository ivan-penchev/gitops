# Bootstrap a new environment

Ordered runbook for a fresh Proxmox host. Almost everything is one
`terraform apply`; the only manual steps are the `root@pam` host commands for
the LXCs (bind mounts, ZFS datasets and privileged feature flags are refused for
API tokens on PVE 9). Every such command is printed as a Terraform **output** —
copy-paste, never guess.

All Terraform runs are wrapped so credentials exist only for that command:

```bash
export SOPS_AGE_KEY_FILE=$PWD/age.key
sops exec-env secrets.sops.env 'cd terraform && terraform <cmd>'
```

| # | Phase | Command | Manual host step |
|---|-------|---------|------------------|
| 0 | Prereqs | — | — |
| 1 | Cluster (VMs → Talos → Flux) | `terraform apply` | no |
| 2 | Fileserver LXC (NFS) | apply + `pct set 110 …` | **yes** |
| 3 | PostgreSQL LXC | phased apply + `zfs create` / `pct set 111 …` | **yes** |
| 4 | More databases | `terraform apply` | no |

## Phase 0 — Prereqs (local)
- Tools on PATH: `terraform >= 1.10`, `talosctl`, `kubectl`, `flux`, `helm`, `sops`, `age`.
- `age.key` (SOPS private key) present; `SOPS_AGE_KEY_FILE` exported.
- Credentials in `secrets.sops.env` (see [terraform-secrets.md](./terraform-secrets.md)).
- `~/.ssh/id_rsa[.pub]` (Flux→GitHub + LXC root key).
- `terraform/terraform.tfvars` filled in (versions, Flux URL, SOPS pubkey, per-LXC gates).

## Phase 1 — Cluster *(no manual step)*
Cilium comes up via Talos inlineManifests, so nodes reach Ready on their own.
```bash
sops exec-env secrets.sops.env 'cd terraform && terraform init && terraform apply'
export KUBECONFIG=$PWD/kubeconfig TALOSCONFIG=$PWD/talosconfig
kubectl get nodes        # all Ready
```
Skip the LXCs entirely with `fileserver_enabled=false` / `postgres_enabled=false`.
The LXCs are independent of the cluster (no Terraform dependency); NFS-consuming pods (radarr, audiobookshelf, prowlarr) just stay `Pending` until Phase 2's export is up, then reconcile.

## Phase 2 — Fileserver LXC (CT 110, .11) *(1 host step)*
```bash
sops exec-env secrets.sops.env 'cd terraform && terraform output -raw fileserver_host_mount_command'
```
Run the printed command on the PVE host as `root@pam` (`pct set 110 -mp0 … --features nesting=1 && pct reboot 110`). Child ZFS datasets (movies, torrent-download) each get their own `-mpN`; plain folders ride the parent.
Verify: `showmount -e 192.168.68.11`.
If nfsd won't start, the provisioner prints an apparmor fix (`lxc.apparmor.profile: unconfined` in `/etc/pve/lxc/110.conf`, then reboot).

## Phase 3 — PostgreSQL LXC (CT 111, .12) *(1 host step, phased)*
```bash
# 3a — create empty LXC
sops exec-env secrets.sops.env 'cd terraform && terraform apply -target=proxmox_virtual_environment_container.postgres'
# 3b — host step (root@pam), from the output:
sops exec-env secrets.sops.env 'cd terraform && terraform output -raw postgres_host_mount_command'
#   zfs create tank/postgres && pct set 111 -mp0 /tank/postgres,mp=/mnt/pgdata && pct reboot 111
#   verify: pct exec 111 -- mountpoint /mnt/pgdata
# 3c — set postgres_data_mounted = true in terraform.tfvars, then:
sops exec-env secrets.sops.env 'cd terraform && terraform apply'
```
Mount is `/mnt/pgdata` (not `/var/lib/postgresql`, which would shadow the apt cluster); PGDATA lands at `/mnt/pgdata/<ver>/main`.
Verify: a pod in `db-landing-zone` connects via the injected `postgres-landingzone` secret.

## Phase 4 — More databases *(no host step)*
Add to `postgres_databases` in `terraform.tfvars` and apply:
```hcl
postgres_databases = [
  { name = "landingzone", namespaces = ["db-landing-zone"] },
  { name = "immich",      namespaces = ["immich"] },
]
```
Terraform makes the role, database, and a `postgres-<db>` secret
(`POSTGRES_HOST/PORT/DB/USER/PASSWORD` + `DATABASE_URL`) in each namespace.
Removing an entry does **not** drop the DB (`prevent_destroy`).

## Why the manual steps
On PVE 9, bind mounts, privileged feature flags and raw `lxc.*` keys are
`root@pam`-only (API token → HTTP 403). So each LXC is created without them and
`lifecycle.ignore_changes` stops later applies from reverting the hand-added
mounts. LXC data lives on host ZFS (`tank/media`, `tank/postgres`), so it
survives cluster rebuilds; re-run the host steps only after a full host rebuild.
