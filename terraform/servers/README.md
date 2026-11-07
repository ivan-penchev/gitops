# Independent native Pi-hole LXC

This root owns **one fresh unprivileged Debian 13 LXC** and its checksum-pinned
Proxmox template, using only the Proxmox API. Ansible installs native Pi-hole;
**no VM or Docker** is involved. There are no PVE-host SSH connections, storage
changes, provisioners, cloud-init snippets, Kubernetes dependencies, shared remote
state, DNS records or router changes. Existing **CT100 and Pi-hole .20** are
protected by input checks; existing guests must never be imported or repurposed.

## Required inputs and template trust

Terraform >=1.11; the committed lock pins `bpg/proxmox` **0.111.1**. Supply explicit
`proxmox_node`, `proxmox_host_ipv4` (collision guard only), `network_bridge`,
`rootfs_datastore` (existing `rootdir` storage, e.g. `tank`), `template_datastore`
(existing `vztmpl` storage, e.g. `local`), unused `vm_id` in the shared VM/CT
namespace, public `ssh_public_key`, and `network={ipv4_cidr,lan_cidr,gateway,dns_servers}`.
No Import/snippets datastore or pre-created template is required. Resource sizing
is 2 amd64 cores, 1 GiB RAM, zero swap, and an 8 GiB root filesystem.

Reserve a fresh static RFC1918 address outside DHCP before connecting. Validation
rejects CT100, every candidate ending `.20`, the PVE host, gateway, network and
broadcast addresses, malformed/non-private networks and dependent bootstrap DNS.
Offline checks **cannot establish address or ID availability**. The API endpoint,
PVE host and later guest apt operations must work without existing Pi-hole DNS.

Set `debian_template_url` to an official versioned Debian13 standard amd64
`.tar.zst` URL and supply its independently authenticated `debian_template_sha256`.
The [official index](http://download.proxmox.com/images/system/) listed
`debian-13-standard_13.6-1_amd64.tar.zst` during research; this is discovery, not a
trusted checksum or a default. Obtain authenticated publisher metadata (e.g. the
Proxmox signed appliance catalog exposed by your authenticated PVE API), verify
its published digest against the archive, then compute SHA256 if it publishes
SHA512 instead. **Never trust a digest fetched alongside an archive over HTTP.**

The allowlist accepts official version-pinned HTTP or HTTPS URLs because the
public download host failed HTTPS hostname verification during research and the
official catalog advertises HTTP. Do not disable download TLS verification to
work around that. An independently authenticated SHA256 is mandatory for HTTP;
Terraform validates its format, not its provenance. No checksum is supplied here.
Downloads use native `vztmpl`, verify SHA256, and refuse unmanaged overwrite;
filenames include guest ID and digest. An archive replacement is not an in-place
OS upgrade: guest replacement requires deliberate review of `prevent_destroy` and
Proxmox deletion protection. Protect configuration/state too—removing a resource
block can bypass Terraform lifecycle protection.

Copy `servers.tfvars.example` to ignored `servers.auto.tfvars` and replace every
placeholder. Its identities/checksum are deliberately invalid. Never put secrets
in tracked inputs. Credentials must authorize container creation, template
download and rootfs allocation; feature settings can require elevated PVE API
permissions. Do not weaken container isolation to work around permission errors.

## Independent backend and credentials

S3-compatible R2 bucket `homelab-tfstate`, independent key
**`homelab/servers.tfstate`**, region `auto`, S3 lockfile enabled. Path-style and
provider-specific validation/checksum skips match repository backend conventions.
Do not override the key with shared/cluster state. There are no remote-state reads.
Export only these credentials through your approved secret manager:

- API: `PROXMOX_VE_ENDPOINT`, `PROXMOX_VE_API_TOKEN`.
- Backend: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT_URL_S3`.
- `proxmox_insecure` defaults **false**; true explicitly opts into a self-signed
  **API** certificate. It does not disable template-download verification.

The independent runner inherits the environment without loading cluster secrets
or invoking `terraform/tf.sh`. Operator commands from repository root:

```sh
python3 ansible/pihole.py init
python3 ansible/pihole.py plan
```

Runner init accepts repeatable `--backend-config` for non-secret backend settings;
plan/apply accept optional `--var-file`. Direct equivalent initialization is
`terraform -chdir=terraform/servers init`. Application settings and password paths
remain separate runner inputs. See [Ansible instructions](../../ansible/README.md).

## Safe staging, guest-console trust and bootstrap

`container_started` defaults **false**. `network_link_down` defaults **false**;
set it **true** to stage an unknown/unreserved candidate address safely. In this
mode Terraform omits the guest NIC **and** its IP configuration. It does not set
native `link_down`: bpg's `enabled=false` removes a NIC and refresh drops its IP
block, so omitting both avoids drift. There are no alternative interfaces.
`start_on_boot` is enabled only when
`container_started && !network_link_down && !bootstrap_dhcp`.

For stopped or isolated tests use Terraform directly, not the runner's apply,
which waits for guest SSH. These are **live operator commands**, not offline tests:

```sh
terraform -chdir=terraform/servers plan -var=container_started=false -var=network_link_down=true
terraform -chdir=terraform/servers apply -var=container_started=false -var=network_link_down=true
```

Persist staging flags in the operator tfvars. An isolated container can later be
started with `container_started=true, network_link_down=true` for guest-console
checks. It has no external network, SSH or apt access. Outside DHCP mode, static
inventory is still produced but is **not evidence of reachability or address ownership**.
Confirm/reserve the final IP, stop the guest, update/review inputs, then connect it
by setting `network_link_down=false` before explicitly starting it again.

### Temporary DHCP bootstrap (not production DNS)

`bootstrap_dhcp` defaults **false**. For an explicitly authorized connected test
without a reserved static address, set `bootstrap_dhcp=true`,
`network_link_down=false`, and `container_started=true` using direct Terraform.
The guest requests IPv4 DHCP, with no static gateway; the existing validated
static `network` inputs remain required but its candidate IP is **not assigned**.
Independent bootstrap DNS remains explicit. DHCP depends on the existing LAN
DHCP service; this root makes no router/DHCP-server changes. Isolation still wins:
`network_link_down=true` means no NIC, so no DHCP request can be made.

**`ansible_inventory` is null whenever `bootstrap_dhcp=true`, even when stopped.**
Terraform omits null root outputs from saved output state, so querying the named
output may report it missing rather than print JSON null. Either way the integrated
runner must fail closed; it requires a confirmed reserved static address and
`bootstrap_dhcp=false`. Never fall back to the placeholder static input.

For an authorized temporary native test, identify the actual leased address from
the authenticated PVE API `/nodes/<node>/lxc/<vm_id>/interfaces`, verify its SSH
fingerprint through the guest console below, and use a separately reviewed explicit
temporary inventory. Do not infer the lease from static Terraform inputs or expose
this DHCP guest as production DNS. Afterwards set `container_started=false` and
leave `bootstrap_dhcp=true` if no reserved static address is available; DHCP staging
never enables host autostart. Stop and review/apply the final reserved static inputs
before disabling DHCP and explicitly starting the production candidate.

### Authenticated guest host-key trust

For freshly created Debian LXC guests, Proxmox's template setup
`rewrite_ssh_host_keys` prints generated SSH host-key SHA256 fingerprints in the
**container create task log**. Retrieve that task log through the authenticated
PVE API and confirm its node, task/guest ID, successful creation and key algorithm.
Use only fingerprints actually present for this fresh candidate, not another
container or an earlier generation. A network `ssh-keyscan` result is untrusted:
calculate its fingerprint locally, require an exact algorithm/fingerprint match
to the authenticated task log, and only then pin that public key in `known_hosts`
for the verified address. Keep strict host-key checking enabled for every SSH and
Ansible connection. If the log lacks the expected fingerprint, fail closed rather
than accepting the scan. This path needs no guest-console permission; never use a
node console or expand privileges to bypass a missing `VM.Console` permission.

Alternatively, when already authorized for the authenticated guest console:

1. Over an authenticated trusted HTTPS session open the **container's Console**
   in Proxmox, not the node shell. `console.type="shell"` selects a shell **inside
   the guest**, requiring no guest password. Proxmox access control is the trust
   boundary; guest root in an unprivileged LXC is not PVE-host root.
2. Once the template has generated SSH host keys, run inside that guest console:
   `/usr/bin/ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`.
   If keys/SSH are absent or this console cannot be authenticated, stop and resolve
   template readiness through a trusted guest-only path. No Terraform host
   commands, QGA, unauthenticated key scans or password login are assumed.
3. After connecting the confirmed reserved address (or the authenticated API's
   actual DHCP lease for a temporary test), compare this fingerprint to the first
   `root@<IP>` SSH prompt before accepting. Keep strict host-key
   checking enabled for all subsequent Ansible runs.

Native container initialization supplies the root authorized public key and
connected networking. No password, sudo, cloud-init, Python or QGA readiness is
assumed. Ansible must bootstrap `python3`/`python3-apt` with guest SSH **raw apt**
before facts/package modules if absent, and manage native Pi-hole outside Terraform.
A successful apply proves neither SSH readiness nor successful application setup.
Provider address discovery is not an SSH/package readiness gate; in isolated mode
there are no NICs to wait for. No host mounts/devices, custom ID maps, nesting,
keyctl, FUSE or mknod privileges are enabled.

Outside DHCP staging, `terraform output -json ansible_inventory` returns only
non-sensitive identity:

```json
{"all":{"children":{"pihole":{"hosts":{"dns_candidate":{"ansible_host":"<IP>","ansible_user":"root","pihole_dns_bind":"<IP>","pihole_trusted_cidr":"<LAN_CIDR>","pihole_provisioned_by":"terraform/servers"}}}}}}
```

Alias `dns_candidate` and these five fields are constant. No application settings,
version/checksum, password, or key is in the inventory. Provisioning/configuring a
candidate does **not** authorize DNS/router cutover or changes to CT100/.20.

## Offline checks

Run in a clean checkout without operator tfvars, backend metadata or credentials:

```sh
terraform -chdir=terraform/servers fmt -check -recursive
terraform -chdir=terraform/servers init -backend=false -lockfile=readonly
terraform -chdir=terraform/servers validate
terraform -chdir=terraform/servers test
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s terraform/servers/tests -p 'test_*.py'
```

Init downloads the locked provider only; mock plans never contact PVE/R2.
Synthetic fixtures are not deployable. Tests cover root separation, one protected
unprivileged CT, identity-only root inventory, stopped/disconnected staging,
DHCP without static identity/autostart, template pinning/checksum and unsafe
addresses/IDs. They do not prove template
contents, root SSH availability or live API/storage permissions.

Migration from the un-deployed VM design renames `vm_datastore`→`rootfs_datastore`,
`image_datastore`→`template_datastore`, `debian_image_url/sha256`→
`debian_template_url/sha256`, and `vm_started`→`container_started`; adds
`network_link_down` and opt-in `bootstrap_dhcp`; changes inventory user
`operator`→`root` (inventory is suppressed during DHCP). No state move from
an existing VM is supported. Confirm state before applying this different design.

### Historical live validation — 2026-11-07 (superseded VM design)

The earlier stopped VM190 plan succeeded (`2 add / 0 change / 0 destroy`), but
actual apply stopped at native download HTTP500: `storage 'local' is not configured
for content-type 'import'`. No VM was provisioned or attempted, no end-to-end proof
was obtained, and no PVE-host SSH/storage changes occurred. This historical result
is **not successful LXC provisioning**; LXC live validation is separate.

The subsequent API-only LXC apply on **2026-11-07 succeeded**: template plus CT190,
`2 added / 0 changed / 0 destroyed`. Authenticated API checks confirmed CT190
**stopped**, `unprivileged=1`, and `eth0` on `vmbr0` with `ip=dhcp`; existing guest
IDs were unchanged apart from the new candidate, and CT100 remained running.
Creation warned that detected systemd 257 may need nesting. Nesting remains
**disabled**; any change requires runtime evidence and explicit review.

A subsequent boot-only apply succeeded (`0 added / 1 changed / 0 destroyed`).
CT190 received DHCP address `192.168.68.61`; its SSH key was verified against the
creation task log. Raw readiness, Debian/unprivileged-LXC facts, native pinned
installation, restricted FTL startup and gravity initialization passed. Manual
checks confirmed guest UDP DNS, controller TCP DNS, loopback admin HTTP and real
password authentication/logout, without enabling nesting.

The complete Ansible run is **not yet successful**: controller UDP DNS was
intercepted (external answers still arrived with FTL stopped), causing the local
record assertion to fail. The rescue path stopped/disabled FTL and left no
ownership marker. FTL was subsequently started manually for diagnosis and admin
access, initially through a localhost-only SSH tunnel. Following explicit approval,
admin HTTP was bound to the candidate LAN IPv4 and loopback on port80, with an ACL
restricting access to loopback and the trusted LAN. Direct LAN HTTP and private
password authentication/logout passed; autostart was left off. This was a
temporary DHCP test, not a production DNS candidate or verified day-2 rerun.
Resolve controller DNS interception before a fresh deployment and full retest.
The observed DHCP address is not a reserved address to reuse.

At the operator's request, CT190 and its dedicated downloaded template were
subsequently destroyed through Terraform on **2026-11-07**. A private teardown
configuration first applied a protection-only update, then a reviewed plan with
exactly those two deletions. Repository deletion guards remained enabled.
Authenticated API checks verified both resources absent, all other guest IDs
unchanged and CT100's running status unchanged; `homelab/servers.tfstate` contains
no managed resources. Shared/cluster Terraform roots and router DNS were untouched.
The candidate admin endpoint and its temporary SSH tunnel are no longer available.

Source references: pinned [download resource](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/docs/resources/download_file.md),
[container resource](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/docs/resources/virtual_environment_container.md),
[container implementation](https://github.com/bpg/terraform-provider-proxmox/blob/v0.111.1/proxmoxtf/resource/container/container.go),
and [Proxmox guest console modes](https://pve.proxmox.com/pve-docs/pct.conf.5.html).
