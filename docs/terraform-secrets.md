# Terraform provider secrets (SOPS)

Terraform's `bpg/proxmox` and `cloudflare` providers read their credentials from
**environment variables** (see `terraform/platform/providers.tf`). The Proxmox credentials
live encrypted in the repo root at [`secrets.sops.env`](../secrets.sops.env),
encrypted with the same age key as the Kubernetes SOPS secrets
(recipient in [`.sops.yaml`](../.sops.yaml)).

- Format: **dotenv** — SOPS encrypts every value, keys stay in cleartext (so the
  file diffs cleanly). Rule: `path_regex: (^|/)secrets\.sops\.env$` in `.sops.yaml`.
- Contains: `PROXMOX_VE_ENDPOINT`, `PROXMOX_VE_API_TOKEN`, `PROXMOX_VE_INSECURE`,
  `CLOUDFLARE_API_TOKEN` — everything both providers need.
- R2 state backend: `R2_ACCOUNT_ID`, `R2_API_TOKEN` (Object Read & Write on the
  `homelab-tfstate` bucket only), and the S3 keys derived from it.
  `AWS_ACCESS_KEY_ID` is the token ID and `AWS_SECRET_ACCESS_KEY` is the SHA-256
  of the token value. Rotating the token means updating all three.
  `AWS_ENDPOINT_URL_S3` is the account's R2 endpoint. It lives here and not in
  the `backend.tf` files because the repo is public.

## Terraform state

Each stack has its own state in R2: `homelab-tfstate/homelab/<stack>.tfstate`
for `cloudflare`, `platform` and `cluster`, configured in each stack's
`backend.tf`. Terraform takes a lock by writing a `.tflock` object next to the
state, so two runs can't apply the same stack at once. The cluster stack reads
the other two through `terraform_remote_state`. It needs Terraform 1.10 or newer;
Homebrew's `terraform` is stuck at 1.5.7, so install it from
`hashicorp/tap/terraform` or the release zip.

The platform state holds the Talos machine secrets and the cluster state
holds the age key. R2 has no object versioning, so keep an age-encrypted copy
offline after big changes:

```bash
for s in cloudflare platform cluster; do
  terraform/tf.sh $s state pull \
    | age -r "$(age-keygen -y age.key)" \
    > ~/tfstate-backups/$s.tfstate.$(date +%F).age
done
```

If the lock gets stuck after a crashed run, use `terraform force-unlock <id>`
with the ID from the error.

> The Cloudflare API token is also stored (independently) inside
> `kubernetes/infrastructure/controllers/cloudflare.sops.yaml` for the in-cluster
> `cloudflared`/`external-dns` secret. If you rotate it, update **both** files.

## Prerequisite

The age **private** key must be available (it is gitignored):

```bash
export SOPS_AGE_KEY_FILE=$PWD/age.key   # run from the repo root
```

## Decode / inspect

```bash
# Print the decrypted Proxmox env (values in cleartext):
sops -d secrets.sops.env
```

## Load into your shell for a Terraform run

`terraform/tf.sh` wraps `sops exec-env`, so the credentials exist only for that
one command. It uses `age.key` in the repo root unless `SOPS_AGE_KEY_FILE` is
set:

```bash
terraform/tf.sh platform plan
terraform/tf.sh all apply
```

To export them into your shell instead (they stay until you close it):

```bash
set -a; eval "$(sops -d secrets.sops.env)"; set +a
terraform -chdir=terraform/platform plan
```

## Edit the secrets

```bash
sops secrets.sops.env          # opens $EDITOR on the decrypted content, re-encrypts on save
```

## Rotate a token

The `terraform-prov@pve!mytoken` Proxmox token should be rotated periodically.
After issuing a new secret in Proxmox (Datacenter → Permissions → API Tokens),
or after rotating the Cloudflare token, update this file in place:

```bash
sops secrets.sops.env          # edit PROXMOX_VE_API_TOKEN / CLOUDFLARE_API_TOKEN, save
```

If you rotate the Cloudflare token, also update
`kubernetes/infrastructure/controllers/cloudflare.sops.yaml` (the in-cluster copy).

## Flux bootstrap credentials

Flux reads this public repository over HTTPS without Git credentials.
Bootstrap does not push generated files to Git.

The `sops-age` Secret comes from `sops_age_key_file`. Keep the age private key
outside Git and preserve it when migrating Flux. Terraform state contains
secrets, so encrypt backups and restrict access to plan files.

## Safety

- **Never** commit a plaintext `.env` — `.gitignore` ignores `*.env` and only
  un-ignores `*.sops.env`, so only the encrypted file can be committed.
- `age.key` is gitignored; without it the file cannot be decrypted.
