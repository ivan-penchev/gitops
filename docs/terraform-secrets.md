# Terraform secrets and state

The Proxmox and Cloudflare providers and the R2 state backend read their
credentials from environment variables. Those live in
[`secrets.sops.env`](../secrets.sops.env) at the repo root, encrypted with the
same age key as the Kubernetes SOPS files. The recipient is in
[`.sops.yaml`](../.sops.yaml).

The file is dotenv. SOPS encrypts each value and leaves the keys readable, so
diffs show which key changed. It holds:

- `PROXMOX_VE_ENDPOINT`, `PROXMOX_VE_API_TOKEN` and `PROXMOX_VE_INSECURE`.
- `CLOUDFLARE_API_TOKEN`.
- `R2_ACCOUNT_ID` and `R2_API_TOKEN`, with Object Read & Write on the state
  bucket only.
- `AWS_ACCESS_KEY_ID`, the R2 token ID, and `AWS_SECRET_ACCESS_KEY`, the
  SHA-256 of the token value. Rotating the R2 token means updating all three.
- `AWS_ENDPOINT_URL_S3`, the account's R2 endpoint. It sits here instead of in
  `backend.tf` because the repo is public.

## Use the secrets

Point SOPS at the age key, which is gitignored:

```bash
export SOPS_AGE_KEY_FILE=$PWD/age.key   # from the repo root
```

`terraform/tf.sh` wraps `sops exec-env`, so the credentials exist only for that
one command. It falls back to `age.key` in the repo root when
`SOPS_AGE_KEY_FILE` isn't set.

```bash
terraform/tf.sh homelab-prd plan
terraform/tf.sh all apply
```

To load them into your shell instead, where they stay until you close it:

```bash
set -a; eval "$(sops -d secrets.sops.env)"; set +a
terraform -chdir=terraform/cluster init -reconfigure -backend-config=key=homelab/clusters/homelab-prd.tfstate
terraform -chdir=terraform/cluster plan -var-file=../clusters/homelab-prd/cluster.tfvars -var-file=../clusters/homelab-prd/talos-versions.tfvars
```

Read or edit the file:

```bash
sops -d secrets.sops.env   # print the values
sops secrets.sops.env      # edit in $EDITOR, re-encrypts on save
```

## Rotate a token

Rotate the Proxmox token now and then. Make a new secret for it in Proxmox,
under Datacenter, Permissions, API Tokens, then put it in the file with
`sops secrets.sops.env`.

The Cloudflare token has a second copy in
`kubernetes/infrastructure/controllers/cloudflare.sops.yaml`. That one becomes
the `cloudflare-api-token` Secret, which cert-manager and external-dns use.
Update both files when you rotate it.

## Terraform state

`terraform/shared` keeps its state at `homelab/shared.tfstate`, set in its
`backend.tf`. Each cluster gets `homelab/clusters/<name>.tfstate`. The
`backend.tf` in `terraform/cluster` has no key, because `terraform/tf.sh`
passes it at init.

Terraform locks a state by writing a `.tflock` object next to it, so two runs
can't apply the same state at once. If a crashed run leaves the lock behind,
run `terraform force-unlock <id>` with the ID from the error.

The roots need Terraform 1.11 or newer. Homebrew's `terraform` formula stopped
at 1.5.7, so install from `hashicorp/tap/terraform` or the release zip.

A cluster's state holds its Talos machine secrets and the age key. The shared
state holds the pg-01 superuser password. R2 has no object versioning, so keep
an encrypted copy offline after big changes:

```bash
for s in shared homelab-prd; do
  terraform/tf.sh $s state pull \
    | age -r "$(age-keygen -y age.key)" \
    > ~/tfstate-backups/$s.tfstate.$(date +%F).age
done
```

## Flux bootstrap

Flux reads this public repo over HTTPS without Git credentials, and bootstrap
doesn't push anything to Git.

Terraform creates the `sops-age` Secret from `sops_age_key_file`. Keep the age
key out of Git and in a password manager. Losing it means losing every SOPS
secret.

## Credentials Terraform creates

Some credentials only exist after Terraform makes them: the Proxmox CSI token,
the pve-exporter token and the tunnel secret. Terraform writes them to the
`flux-system/cluster-secrets-tf` Secret. Git holds the Secret manifests with
`${var}` placeholders, and Flux fills them in through `postBuild.substituteFrom`.

To add one:

1. Add a local map in the Terraform file that creates the credential, and
   merge it into `data` of `kubernetes_secret_v1.cluster_secrets_tf` in
   `terraform/cluster/flux.tf`.
2. Write the Secret manifest in Git with only `${var}` values.
   `.github/scripts/check_sops.py` rejects anything else in a plaintext Secret.
3. Add `cluster-secrets-tf` to `substituteFrom` of the Kustomization that
   applies it, and to no other.
4. Add the key with a dummy value to the stub Secret in
   `.github/workflows/validate.yml`.
5. Apply Terraform before you merge. If Flux reconciles first, it substitutes
   empty strings.

If Terraform used to manage that Secret itself, add a `removed` block with
`destroy = false`. Terraform then forgets the Secret and Flux takes it over
without a delete.

## Plans in CI

`.github/workflows/terraform-plan.yml` needs the age key too. It lives in the
`SOPS_AGE_KEY` secret of the `terraform-plan` GitHub environment, and only that
job reads it. The job runs only for PRs from this repo, never forks. When you
rotate the age key, update the secret:

```bash
gh secret set SOPS_AGE_KEY --env terraform-plan < age.key
```

## What keeps plaintext out of Git

- `.gitignore` ignores `*.env` and un-ignores only `*.sops.env`.
- `age.key` is gitignored.
- CI fails on an unencrypted `*.sops.yaml` or a plaintext Secret with real
  values.
