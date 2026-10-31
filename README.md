# proxmox-talos-flux

Terraform and Flux for a Talos Kubernetes cluster on a single Proxmox host.
`terraform/tf.sh all apply` builds the VMs, Talos, the Cloudflare tunnel and
the Flux bootstrap. After that, Flux applies everything in `kubernetes/` from
this repo.

This is my homelab, so the tfvars and the `cluster-config` ConfigMap hold my
domains and IPs. Change those and the rest should work for you.

## Docs

| Doc | Read it when |
|---|---|
| [architecture.md](docs/architecture.md) | You want to know what runs where and why |
| [bootstrap.md](docs/bootstrap.md) | You're building from zero |
| [terraform-secrets.md](docs/terraform-secrets.md) | You need Terraform credentials, state or token rotation |
| [talos-k8s-versions.md](docs/talos-k8s-versions.md) | You're upgrading Talos or Kubernetes |
| [cilium-upgrade.md](docs/cilium-upgrade.md) | You're upgrading Cilium |
| [renovate-live-test.md](docs/renovate-live-test.md) | A Renovate PR runs against the live cluster |
| [flux-upgrade-test.md](docs/flux-upgrade-test.md) | You're bumping Flux or the Flux Operator |

## Layout

```
terraform/
  shared/          fileserver and pg-01 LXCs, their LAN DNS records
  cluster/         one cluster: VMs, Talos, tunnel, Flux bootstrap, Terraform-made Secrets, pg databases
  clusters/<name>/ cluster.tfvars and talos-versions.tfvars for each cluster
  tf.sh            runs a root with the credentials from secrets.sops.env
talos/             machine config patches and the Cilium render
kubernetes/
  clusters/<name>/ Flux entry point for a cluster
  infrastructure/  controllers (CSI, Traefik, cert-manager, external-dns, cloudflared, ARC) and their config
  apps/            workloads, one folder per namespace
  components/      shared Kustomize components
```

## Prerequisites

Terraform 1.11 or newer, `talosctl`, `kubectl`, `flux`, `helm`, `sops`, `age`
and `yq`. You also need:

- A Proxmox API token for Terraform.
- A Cloudflare account with a zone and an API token that can edit DNS and
  tunnels.
- An age key. Put it in `age.key` at the repo root, which is gitignored.
- An R2 bucket, or another S3 backend, for Terraform state.

[bootstrap.md](docs/bootstrap.md) walks through the rest.

## Kubeconfig

Terraform never reads `~/.kube/config`. It talks to the cluster through the
Talos provider and writes `kubeconfig` and `talosconfig` into the repo root,
both gitignored. Point your tools at them so you don't hit another cluster by
accident:

```bash
export KUBECONFIG=$PWD/kubeconfig
export TALOSCONFIG=$PWD/talosconfig
```

## Terraform

| Root | Owns | State key |
|---|---|---|
| `terraform/shared` | fileserver and pg-01 LXCs, their LAN DNS records | `homelab/shared.tfstate` |
| `terraform/cluster` | One cluster | `homelab/clusters/<name>.tfstate` |

Every cluster runs the same `terraform/cluster` code with its own files from
`terraform/clusters/<name>/`. A cluster reads LAN settings and the pg-01
password from the shared state, so a LAN IP lives only in
`terraform/shared/shared.auto.tfvars`.

Use `terraform/tf.sh`, not plain `terraform`. It decrypts the credentials,
passes the cluster's tfvars and state key, and re-inits when you switch
clusters. `all` runs shared first, then every cluster.

```bash
terraform/tf.sh all init
terraform/tf.sh all plan
terraform/tf.sh homelab-prd apply
```

Each root has plan-only tests with mocked providers. They need no credentials:

```bash
terraform -chdir=terraform/cluster test
```

PRs that touch `terraform/`, `talos/` or a `flux-system` folder get a plan
comment for every root. CI never applies.

The only cluster today is `homelab-prd`. Its Talos cluster name is still
`homelab`, because renaming it renames every node.

## Add a cluster

1. Copy `terraform/clusters/homelab-prd` to `terraform/clusters/<name>`.
2. In `cluster.tfvars`, change everything that names or addresses the
   cluster: `cluster_name`, VM IDs, node IPs, `cluster_vip`,
   `cloudflare_tunnel_name`, `dns_owner_id`, `flux_path`, `iso_name_prefix`,
   `kubeconfig_file` and `talosconfig_file`.
3. Give the CSI user and role new names, such as `<name>-csi@pve`, or both
   clusters share one Proxmox token.
4. Remove `pve_exporter_proxmox_user` and `extra_zones` unless this cluster
   should own them. Only one cluster should scrape the Proxmox host.
5. With `workers = {}`, workloads run on the control planes.
6. Copy `kubernetes/clusters/homelab` to `flux_path` and set the LB IPs in its
   `cluster-config.yaml`. Drop `monitoring-pve-exporter.yaml` if you removed the
   pve-exporter user.
7. Run `terraform/tf.sh <name> apply`.

If one cluster needs something the others don't, add a variable to
`terraform/cluster` whose default keeps the existing clusters unchanged.

## Secrets

- Secrets you write by hand are `*.sops.yaml` files encrypted with age. CI
  fails on an unencrypted one.
- Terraform writes the credentials it creates, such as the CSI token, into the
  `flux-system/cluster-secrets-tf` Secret. Git holds a Secret template with
  `${var}` placeholders, and Flux fills it in.
- Terraform's own credentials are in `secrets.sops.env`.

Terraform state holds the Talos CA keys and the age key. Keep the bucket
private and an encrypted offline copy, see
[terraform-secrets.md](docs/terraform-secrets.md).

## Add an app

1. Create `kubernetes/apps/<namespace>/<app>/ks.yaml` and the manifests under
   `app/`. Copy an existing app such as `downloads/radarr`.
2. Add `<app>/ks.yaml` to `kubernetes/apps/<namespace>/kustomization.yaml`.
3. For a LAN-only app, use an Ingress host of `<app>.${lan_domain}`.
   For a public one, use `<app>.${public_domain}`. external-dns creates the
   record either way.

Check how the app authenticates before you make it public. Wattbill has no
login and is public on purpose.

For a hostname under penchev.com, which stays on Azure DNS, the Azure
external-dns runs `upsert-only`. Delete its Azure CNAME by hand when you retire
an app.
