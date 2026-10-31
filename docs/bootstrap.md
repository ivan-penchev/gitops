# Bootstrap a new environment

This runbook builds everything on a fresh Proxmox host. Terraform does almost
all of it. The exception is the LXCs: PVE 9 refuses bind mounts, ZFS datasets
and privileged feature flags for API tokens, so you run one command per LXC on
the host as `root@pam`. Terraform prints each command as an output. Copy it,
don't retype it.

Run Terraform through `terraform/tf.sh <shared|all|CLUSTER> <args>`. It
decrypts `secrets.sops.env` with `age.key` and passes the credentials only to
that command. `shared` owns the LXCs and their DNS records. Each directory in
`terraform/clusters/` holds one cluster's settings for `terraform/cluster`.
This runbook uses `homelab-prd`. A cluster reads the shared outputs, so `all`
applies shared first.

| Phase | What | Command | Host step |
|---|---|---|---|
| 0 | Prerequisites | | |
| 1 | LXCs, then the cluster: VMs, Talos, Flux | `tf.sh all apply` | No |
| 2 | Fileserver LXC, NFS | `pct set 110 ...` | Yes |
| 3 | PostgreSQL LXC | `zfs create` and `pct set 111 ...`, then apply | Yes |
| 4 | More databases | `tf.sh homelab-prd apply` | No |

## Phase 0, prerequisites

- On your PATH: Terraform 1.11 or newer, `talosctl`, `kubectl`, `flux`,
  `helm`, `sops` and `age`.
- `age.key` in the repo root, or `SOPS_AGE_KEY_FILE` pointing at it.
- Credentials in `secrets.sops.env`, see
  [terraform-secrets.md](terraform-secrets.md).
- A private R2 bucket for state, with a token scoped to it in
  `secrets.sops.env`. `terraform init` fails without it.
- `~/.ssh/id_rsa` and `id_rsa.pub`. Terraform uses them to provision the LXCs.
  Flux doesn't need an SSH key.
- Your settings in `terraform/shared/shared.auto.tfvars` and in the cluster's
  `cluster.tfvars` and `talos-versions.tfvars`. On a fresh host, set
  `postgres_data_mounted = false` in `shared.auto.tfvars` until phase 3.

## Phase 1, cluster

Talos installs Cilium from its inline manifests, so nodes go Ready with no
help.

```bash
terraform/tf.sh all init
terraform/tf.sh all apply
export KUBECONFIG=$PWD/kubeconfig TALOSCONFIG=$PWD/talosconfig
kubectl get nodes        # all Ready
```

Before it installs Flux, the cluster root creates the `flux-system` namespace,
the `sops-age` Secret, the `cluster-config-tf` ConfigMap and the
`cluster-secrets-tf` Secret. Flux needs the last two to render the CSI,
cloudflared and pve-exporter Secrets.

Terraform then installs the Flux Operator and creates the FluxInstance from the
manifests in `kubernetes/clusters/<name>/flux-system`. Once Flux adopts them,
Git owns their versions and settings. `flux_git_url` must match `spec.sync.url`
in `flux-instance.yaml`, and the plan fails if it doesn't. Flux reads the
public repo without credentials.

Check the handoff:

```bash
kubectl -n flux-system wait fluxinstance/flux --for=condition=Ready --timeout=10m
flux get sources all
flux get kustomizations
flux get helmreleases -A
```

The shared apply also creates the fileserver LXC and an empty pg-01 LXC.
Terraform doesn't link them to the cluster. Pods that mount NFS stay `Pending`
until phase 2 is done, then start on their own.

## Phase 2, fileserver LXC

```bash
terraform/tf.sh shared output -raw fileserver_dataset_command
terraform/tf.sh shared output -raw fileserver_host_mount_command
```

On the host as `root@pam`, run the dataset commands first. They create one
dataset per media type and are safe to run again. Then run the printed
`pct set 110 ... && pct reboot 110`. Each ZFS child dataset in
`fileserver.child_datasets` gets its own `-mpN`.

Check it with `showmount -e <fileserver ip>`.

If nfsd won't start, the provisioner prints an AppArmor fix. Add
`lxc.apparmor.profile: unconfined` to `/etc/pve/lxc/110.conf` and reboot the LXC.

For browsing the USB backup drive from the fileserver, also add the
`/mnt/backup-browse` mount entry from the header of
`terraform/shared/fileserver.tf`.

## Phase 3, PostgreSQL LXC

Phase 1 created the LXC without its data mount. Print the host step and run it
as `root@pam`:

```bash
terraform/tf.sh shared output -raw postgres_host_mount_command
# zfs create tank/postgres && pct set 111 -mp0 /tank/postgres,mp=/mnt/pgdata && pct reboot 111
pct exec 111 -- mountpoint /mnt/pgdata
```

Then set `postgres_data_mounted = true` in `shared.auto.tfvars` and apply:

```bash
terraform/tf.sh shared apply        # installs PostgreSQL on the dataset
terraform/tf.sh homelab-prd apply   # roles, databases, Kubernetes Secrets
```

The mount is `/mnt/pgdata`, because a mount on `/var/lib/postgresql` would
hide the cluster the apt package creates. PGDATA ends up in
`/mnt/pgdata/<version>/main`.

Check that a pod in `db-landing-zone` can connect with the
`postgres-landingzone` Secret.

## Phase 4, more databases

Add an entry to `postgres_databases` in the cluster's `cluster.tfvars` and run
`terraform/tf.sh homelab-prd apply`:

```hcl
postgres_databases = [
  { name = "landingzone", namespaces = ["db-landing-zone"] },
  { name = "immich",      namespaces = ["immich"] },
]
```

Terraform creates the role, the database and a `postgres-<db>` Secret in each
namespace. The Secret has `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_DB`,
`POSTGRES_USER`, `POSTGRES_PASSWORD` and `DATABASE_URL`.

Removing an entry doesn't drop the database. `prevent_destroy` blocks it, so
dropping one is a manual job.

## Why the host steps exist

An API token gets HTTP 403 when it sets bind mounts, privileged feature flags
or raw `lxc.*` keys. Terraform creates each LXC without them, and
`lifecycle.ignore_changes` keeps later applies from undoing what you added by
hand. LXC data lives on host ZFS datasets, so it survives a cluster rebuild.
You only repeat the host steps after rebuilding the host.
