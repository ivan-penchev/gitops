# Terraform provider secrets (SOPS)

Terraform's `bpg/proxmox` and `cloudflare` providers read their credentials from
**environment variables** (see `terraform/providers.tf`). The Proxmox credentials
live encrypted in the repo root at [`secrets.sops.env`](../secrets.sops.env),
encrypted with the same age key as the Kubernetes SOPS secrets
(recipient in [`.sops.yaml`](../.sops.yaml)).

- Format: **dotenv** — SOPS encrypts every value, keys stay in cleartext (so the
  file diffs cleanly). Rule: `path_regex: (^|/)secrets\.sops\.env$` in `.sops.yaml`.
- Contains: `PROXMOX_VE_ENDPOINT`, `PROXMOX_VE_API_TOKEN`, `PROXMOX_VE_INSECURE`,
  `CLOUDFLARE_API_TOKEN` — everything both providers need.

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

Two equivalent ways — run from the repo root with `SOPS_AGE_KEY_FILE` exported.

**Option A — wrap the command (nothing leaks into your shell):**

```bash
# Runs terraform with Proxmox + Cloudflare env injected, then discards it:
sops exec-env secrets.sops.env 'cd terraform && terraform plan'
sops exec-env secrets.sops.env 'cd terraform && terraform apply'
```

**Option B — export into the current shell:**

```bash
set -a; eval "$(sops -d secrets.sops.env)"; set +a
cd terraform && terraform apply
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

## Safety

- **Never** commit a plaintext `.env` — `.gitignore` ignores `*.env` and only
  un-ignores `*.sops.env`, so only the encrypted file can be committed.
- `age.key` is gitignored; without it the file cannot be decrypted.
