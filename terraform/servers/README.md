# Independent Pi-hole candidate VM

This root owns **one fresh Debian 13 VM**, its checksum-pinned cloud image and
cloud-init snippet. It has no Kubernetes providers, remote-state reads, shared
infrastructure dependencies, DNS records, router changes or application deployment.
The existing Pi-hole at `192.168.68.20` is neither managed nor used as bootstrap DNS.
All `.20` candidate addresses are rejected defensively.

## Prerequisites and inputs

- Terraform >= 1.11; committed lock pins `bpg/proxmox` 0.111.1, as in the other roots.
- Proxmox VE >= 8.4 with **Import** storage, **Snippets** storage, a VM disk datastore
  and LAN bridge already configured. They may be the same file datastore where
  compatible. Terraform does not create or reconfigure host storage/networking.
- Explicit unused VMID, reserved static IPv4/CIDR outside DHCP, canonical RFC1918
  LAN CIDR, gateway, independent bootstrap DNS, and operator **public** SSH key.
  Confirm VMID/IP availability on the real network yourself; offline validation
  cannot detect collisions. Never import or repurpose an existing guest.
- A dated official Debian 13 `genericcloud` amd64 QCOW2 URL and its **verified
  SHA256**. Select a release at <https://cloud.debian.org/images/cloud/trixie/>;
  authenticate publisher checksums/signatures first. If the publisher provides
  SHA512, verify that before computing SHA256 locally. No real checksum is supplied
  here. `latest`/`current`, insecure HTTP and placeholder checksums are rejected.
- PVE API token permissions for VM creation, disks and image download (including
  `Datastore.AllocateTemplate`, `Sys.Audit`, `Sys.Modify`). Snippet upload additionally
  requires PVE-host SSH via an already-loaded agent (`SSH_AUTH_SOCK`); explicitly
  set host IP and SSH username. Non-root SSH users need provider-compatible sudo
  privileges; see the [provider SSH documentation](https://bpg.sh/docs/).
  No Terraform private-key/password generation or file reads are used.

Copy `servers.tfvars.example` to ignored `servers.auto.tfvars` in this directory
and replace **all** placeholders. Terraform loads this file automatically. An
explicit alternate file can be passed through the runner's `plan`/`apply`
`--var-file` option. The example deliberately cannot deploy.
VM sizing is 2 vCPU, 2 GiB RAM, 16 GiB disk;
these conservative Pi-hole defaults do not select infrastructure identities.

## Backend and credentials

State uses the existing private R2 bucket `homelab-tfstate` with independent key
**`homelab/servers.tfstate`** and its `.tflock` object. Never override this key with
`homelab/shared.tfstate` or a cluster key; no other root needs to exist first.
Export only the credentials needed by this root using your approved secret
manager; do not put credentials in tracked inputs or load cluster credentials:

- API: `PROXMOX_VE_ENDPOINT`, `PROXMOX_VE_API_TOKEN`; TLS verification is enabled
  unless `proxmox_insecure = true` is explicitly selected.
- R2: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT_URL_S3`.
- SSH: already-loaded agent plus explicit `proxmox_ssh_address` and
  `proxmox_ssh_username`; do not use guest credentials to access Proxmox.

The independent runner `ansible/pihole.py` invokes Terraform directly and inherits
these environment variables. It deliberately does **not** call `terraform/tf.sh`
or load shared/cluster credentials. From the repository root (these are
**operator commands**, not part of offline checks):

```sh
python3 ansible/pihole.py init
python3 ansible/pihole.py plan
```

The runner's `init` accepts repeatable `--backend-config` options for non-secret
backend settings. Keep the state key `homelab/servers.tfstate` independent;
backend configuration is not a Terraform shared remote-state dependency. See
[`ansible/README.md`](../../ansible/README.md) for `apply`, `configure`, `check`,
`inspect`, and `verify`. Application settings and the password path are separate
runner inputs, never Terraform inventory fields.

The workstation, PVE host, API endpoint and bootstrap resolver must resolve/reach
Debian repositories without the existing Pi-hole. Use the PVE IP in the endpoint
when recovering DNS. Image download preserves TLS and verifies the supplied SHA256.
Downloads/snippets refuse to overwrite pre-existing files; names are scoped to the
explicit VMID and content digest. The VM has `prevent_destroy` and Proxmox deletion
protection. An image/identity change requiring replacement must fail until an
operator deliberately reviews recovery/replacement; removing this root from
configuration bypasses Terraform lifecycle protection, so protect state/config too.

## Bootstrap and inventory contract

Cloud-init creates only `operator`, installs `python3`, `python3-apt`, `sudo`, and
`qemu-guest-agent`, and grants passwordless sudo. `python3-apt` enables Ansible's
Debian package facts. Root/password SSH login is disabled. Wait for SSH,
`cloud-init status --wait`, `/usr/bin/python3 --version`, and `sudo -n true` before
Ansible; Terraform's guest-agent IP wait alone is not proof cloud-init succeeded.
Outbound apt access through the explicit independent resolver is required.

Before accepting the guest's first SSH host key, obtain its fingerprint through
trusted PVE-host SSH after cloud-init has started the QEMU guest agent. On the PVE
host, substitute the explicitly reserved VMID:

```sh
qm guest exec VMID -- /usr/bin/ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Compare the returned ED25519 fingerprint with the guest's first SSH prompt before
accepting it. Do not bypass host-key verification or trust `ssh-keyscan` alone.
The guest account has a locked password: this procedure requires trusted PVE-host
access, not a guest-console password login. If trusted PVE access or the guest
agent is unavailable, stop until the fingerprint can be verified securely.

`terraform output -json ansible_inventory` returns a **non-sensitive** object:

```json
{"all":{"children":{"pihole":{"hosts":{"dns_candidate":{"ansible_host":"<IP>","ansible_user":"operator","pihole_dns_bind":"<IP>","pihole_trusted_cidr":"<LAN_CIDR>","pihole_provisioned_by":"terraform/servers"}}}}}}
```

The alias is always `dns_candidate`; output has infrastructure identity only.
Docker (`docker.io`/`docker-compose` v2 from Debian 13 apt), Pi-hole image/version,
configuration and secrets belong to Ansible, not Terraform. No LXC/nesting or
privileged container is needed. Cloud-init is first-boot bootstrap, not an ongoing
configuration reconciler; modifying a snippet on an existing VM does not rerun it.
No DNS cutover is implied by provisioning or configuring this candidate.

## Offline checks (no credentials or live infrastructure)

From the repository root, without loading SOPS or credential environment variables:

```sh
terraform -chdir=terraform/servers fmt -check -recursive
terraform -chdir=terraform/servers init -backend=false
terraform -chdir=terraform/servers validate
terraform -chdir=terraform/servers test
python3 -m unittest discover -s terraform/servers/tests -p 'test_*.py'
```

Initialization downloads only the locked provider; mock plan tests never connect
it to PVE or R2. Test values are synthetic and must never be used for deployment.
Structural tests enforce the independent backend, single VM, required identities,
identity-only output, `prevent_destroy`, and absence of provisioners/remote state.
Mock tests cover bootstrap/inventory, checksum/image validation and unsafe targets.
