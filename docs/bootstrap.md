# Bootstrap a new environment

Ordered runbook for a fresh Proxmox host. Almost everything is
`terraform/tf.sh all apply`; the only manual steps are the `root@pam` host commands for
the LXCs (bind mounts, ZFS datasets and privileged feature flags are refused for
API tokens on PVE 9). Every such command is printed as a Terraform **output** —
copy-paste, never guess.

All Terraform runs go through `terraform/tf.sh <stack|all> <args>`. It
decrypts `secrets.sops.env` with `age.key` and passes the credentials only to
that command. The stacks are `cloudflare`, `platform` and `cluster`; `all` runs
them in that order. `cluster` reads the outputs of the other two, so it can
only plan once they are applied.

| # | Phase | Command | Manual host step |
|---|-------|---------|------------------|
| 0 | Prereqs | — | — |
| 1 | Cluster (VMs → Talos → Flux) | `tf.sh all apply` | no |
| 2 | Fileserver LXC (NFS) | apply + `pct set 110 …` | **yes** |
| 3 | PostgreSQL LXC | phased apply + `zfs create` / `pct set 111 …` | **yes** |
| 4 | More databases | `tf.sh cluster apply` | no |

## Phase 0 — Prereqs (local)
- Tools on PATH: `terraform >= 1.11`, `talosctl`, `kubectl`, `flux`, `helm`, `sops`, `age`.
- `age.key` (SOPS private key) present; `SOPS_AGE_KEY_FILE` exported.
- Credentials in `secrets.sops.env` (see [terraform-secrets.md](./terraform-secrets.md)).
- The private R2 bucket `homelab-tfstate` exists, with a token scoped to it in
  `secrets.sops.env`. State lives there, so `terraform init` fails without it.
- `~/.ssh/id_rsa[.pub]` for LXC provisioning. Flux does not use an SSH key.
- Settings are tracked: `variables.tf` defaults in each stack, plus
  `terraform/platform/talos-versions.auto.tfvars` and
  `terraform/platform/homelab.auto.tfvars`. On a fresh host set
  `postgres_data_mounted = false` in `homelab.auto.tfvars` until Phase 3.

## Phase 1 — Cluster *(no manual step)*
Cilium comes up via Talos inlineManifests, so nodes reach Ready on their own.
```bash
terraform/tf.sh all init
terraform/tf.sh all apply
export KUBECONFIG=$PWD/kubeconfig TALOSCONFIG=$PWD/talosconfig
kubectl get nodes        # all Ready
```
The cluster stack creates the `flux-system` namespace, SOPS secret, and
`cluster-config-tf` ConfigMap before running the operator bootstrap module.
The module installs `flux-operator` and creates the FluxInstance from Git's
manifests. Once Flux adopts them, Git controls their versions and configuration.
`cluster-config` remains Git-managed. Set `flux_git_url` to the public HTTPS URL
in `flux-instance.yaml`. Flux reads the repository without credentials.

Check the handoff:

```bash
kubectl -n flux-system wait fluxinstance/flux --for=condition=Ready --timeout=10m
flux get sources all
flux get kustomizations
flux get helmreleases -A
```

Skip the LXCs entirely with `fileserver_enabled=false` / `postgres_enabled=false`.
The LXCs are independent of the cluster (no Terraform dependency); NFS-consuming pods (radarr, audiobookshelf, prowlarr) just stay `Pending` until Phase 2's export is up, then reconcile.

## Phase 2 — Fileserver LXC (CT 110, .11) *(1 host step)*
```bash
terraform/tf.sh platform output -raw fileserver_host_mount_command
```
Run the printed command on the PVE host as `root@pam` (`pct set 110 -mp0 … --features nesting=1 && pct reboot 110`). Child ZFS datasets (movies, torrent-download) each get their own `-mpN`; plain folders ride the parent.
Verify: `showmount -e 192.168.68.11`.
If nfsd won't start, the provisioner prints an apparmor fix (`lxc.apparmor.profile: unconfined` in `/etc/pve/lxc/110.conf`, then reboot).

## Phase 3 — PostgreSQL LXC (CT 111, .12) *(1 host step, phased)*
```bash
# 3a — create empty LXC
terraform/tf.sh platform apply -target=proxmox_virtual_environment_container.postgres
# 3b — host step (root@pam), from the output:
terraform/tf.sh platform output -raw postgres_host_mount_command
#   zfs create tank/postgres && pct set 111 -mp0 /tank/postgres,mp=/mnt/pgdata && pct reboot 111
#   verify: pct exec 111 -- mountpoint /mnt/pgdata
# 3c — set postgres_data_mounted = true in terraform/platform/homelab.auto.tfvars, then:
terraform/tf.sh platform apply   # installs PostgreSQL on the dataset
terraform/tf.sh cluster apply    # roles, databases, k8s Secrets
```
Mount is `/mnt/pgdata` (not `/var/lib/postgresql`, which would shadow the apt cluster); PGDATA lands at `/mnt/pgdata/<ver>/main`.
Verify: a pod in `db-landing-zone` connects via the injected `postgres-landingzone` secret.

## Phase 4 — More databases *(no host step)*
Add to the `postgres_databases` default in `terraform/cluster/variables.tf`
and run `terraform/tf.sh cluster apply`:
```hcl
postgres_databases = [
  { name = "landingzone", namespaces = ["db-landing-zone"] },
  { name = "immich",      namespaces = ["immich"] },
]
```
Terraform makes the role, database, and a `postgres-<db>` secret
(`POSTGRES_HOST/PORT/DB/USER/PASSWORD` + `DATABASE_URL`) in each namespace.
Removing an entry does **not** drop the DB (`prevent_destroy`).

## Migrate an existing Flux installation

The move from `flux bootstrap` to the Flux Operator is done. Its runbook, and
the `removed` blocks it relied on, are in Git history up to commit `44ad7c8`.

## Why the manual steps
On PVE 9, bind mounts, privileged feature flags and raw `lxc.*` keys are
`root@pam`-only (API token → HTTP 403). So each LXC is created without them and
`lifecycle.ignore_changes` stops later applies from reverting the hand-added
mounts. LXC data lives on host ZFS (`tank/media`, `tank/postgres`), so it
survives cluster rebuilds; re-run the host steps only after a full host rebuild.
