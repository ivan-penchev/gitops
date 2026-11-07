# Native Pi-hole on a dedicated Debian 13 LXC

This narrowly scoped deployment creates **no Docker containers**. Terraform in
`terraform/servers` provisions a fresh, unprivileged Debian 13 amd64 LXC through
the Proxmox API; `pihole.py` derives its singleton inventory from Terraform output
and connects directly to the **guest as root over SSH**. No Proxmox-host SSH,
cloud-init, nesting, privileged LXC, resolver rewrite, OS upgrade, DHCP/NTP server,
public web listener, or adoption of an existing Pi-hole is supported.

The existing `192.168.68.20` Pi-hole is explicitly rejected. Other peers are never
configuration targets. This does not modify router/DHCP DNS settings or perform a
production cutover. A dedicated native VM or physical host is also rejected:
the current identity gate deliberately requires an unprivileged LXC.

## Prerequisites and ownership

The Terraform-created LXC must have systemd, root public-key SSH access, a static
RFC1918 IPv4 on the selected interface, working routing and an independent
resolver. Python is **not** assumed: `ready.yml` uses TCP readiness and raw SSH;
`prepare.yml` checks guest identity with raw commands before installing missing
Python, apt bindings and network-inspection tools. Neither uses Python-dependent
connection waiting before bootstrap. Ansible does not stop or replace an existing
resolver/web service to make installation fit; conflicting services, native files,
Pi-hole accounts, occupied ports, or Docker/Podman state require manual recovery.

Authenticate the guest SSH host key using a trusted Proxmox/API console channel
before running the workflow. Host-key checking stays enabled; unverified
`ssh-keyscan` output is not trusted enrollment. Provide the private SSH key via
the operator's normal SSH agent/config, not inventory connection-variable extras.
The controller must reach guest TCP/22 and DNS TCP+UDP/53; the guest must reach
Debian package repositories, GitHub release/source URLs, its DNS upstreams and
its initial public blocklist. Existing repository virtual environments may be
reused; otherwise install declared controller dependencies:

```sh
python3 -m venv ansible/.venv
ansible/.venv/bin/pip install -r ansible/requirements.txt
export PATH="$PWD/ansible/.venv/bin:$PATH"
```

All tasks use Ansible built-ins; `requirements.yml` declares no collections.
`sudo` is installed only because upstream Pi-hole runtime scripts use it to drop
root privileges. The SSH connection does not require or invoke sudo/become.
A temporary DHCP test guest's client on UDP/68 is not a conflicting DHCP server;
UDP/67 and the DNS/web/NTP ports remain guarded.

Inventory has exactly one host, `all.children.pihole.hosts.dns_candidate`, with
exactly these five fields:

- `ansible_host`: chosen private IPv4, matching `pihole_dns_bind`.
- `ansible_user: root`.
- `pihole_dns_bind`: dedicated DNS IPv4.
- `pihole_trusted_cidr`: canonical RFC1918 LAN CIDR containing the address.
- `pihole_provisioned_by: terraform/servers`.

The wrapper reconstructs a clean inventory, rejecting extra host fields and
ignoring unrelated groups/global variables. Every guest play requires the exact
explicit singleton limit and matching target identity. The default inventory is
empty. `inventory.example.yml` intentionally uses TEST-NET and is rejected by
safety gates; do not substitute the example for Terraform provenance.

Missing or null `ansible_inventory` output stops the wrapper before SSH, without
falling back to input addresses. DHCP-only Terraform staging intentionally has
no usable inventory; the production wrapper requires reserved-static provisioning.

## Reviewed native releases, not a mutable installer

Copy `pihole.settings.example.json` to a reviewed, non-secret JSON settings file.
Replace its peer and local verification records with your chosen topology. Its
seven required release pins replace the old `pihole_image` setting:

| Setting | Reviewed example |
| --- | --- |
| `pihole_core_version` | `v6.5` |
| `pihole_core_commit` | `f503a65d3a07cb71fd931389f1d3babf718249aa` |
| `pihole_installer_sha256` | `0c67c8f8358fede4b4dd8d51b429114461c9bb90ad56ff00ef05637f664bf3ac` |
| `pihole_web_version` | `v6.6.1` |
| `pihole_web_commit` | `fb699c4e3fd6965d1c9a5253250d8a9b3c6f7a0e` |
| `pihole_ftl_version` | `v6.8` |
| `pihole_ftl_sha256` | `1f511e7053a5ddfae1db1f439ebb986dd8025bf7223e1f70fb8087d9c0fd2b0e` |

The installer is downloaded at the core commit and checked against the reviewed
SHA256 before execution. Core/Web are checked out at exact commits and their
release tags must resolve to those commits. The architecture-specific FTL release
binary is independently SHA256-verified. The implementation **does not execute
installer main**: that path can select newer component releases, start services,
change resolver settings and pass passwords through command arguments. Instead,
`files/install-native.sh` sources the verified script with `SKIP_INSTALL=true`
and calls only its reviewed user/script/config/default-list installation
primitives. It installs the pinned logrotate template without migration helpers.
There is no curl-to-shell pipeline, latest-release lookup, updater, repo reset,
automatic gravity schedule or automatic component upgrade.

The initial gravity build uses the upstream default StevenBlack list. Thereafter,
refresh lists deliberately through the password-protected UI or a separately reviewed
maintenance mechanism; this slice does not silently install upstream cron jobs.
New release pins, binding/interface changes, source edits or service tampering on
an owned installation are refused, not treated as an upgrade. Review a separate
backup/restore/replacement procedure before changing releases. The pin mechanism
alone is not a promise that arbitrary future v6 releases share these semantics.

Other allowed JSON settings are `pihole_interface` (default `eth0`),
`pihole_upstreams`, `pihole_peer_addresses`, `pihole_timezone`, `pihole_ui_port`,
`pihole_local_hosts`, `pihole_local_cnames`, `pihole_verify_external`,
`pihole_verify_local_name`, `pihole_verify_local_address`, and optional
`pihole_verify_blocked_name`. Peer addresses must include this target; upstreams
must be independent public IPv4 addresses, never Pi-hole peers. A local test name
and address must match an explicitly configured local host record. Unknown JSON
keys, arbitrary Ansible variables and Docker-image settings are rejected.

## Provision once, then rerun Ansible independently

Run from the repository root. Terraform variables/backend configuration remain
owned by `terraform/servers`; the wrapper supplies no Proxmox credentials or
passwords through Ansible settings.

```sh
ansible/.venv/bin/python ansible/pihole.py init
ansible/.venv/bin/python ansible/pihole.py plan --var-file /absolute/path/candidate.tfvars
ansible/.venv/bin/python ansible/pihole.py apply \
  --var-file /absolute/path/candidate.tfvars \
  --settings /absolute/path/native-settings.json \
  --password-file /absolute/path/private-webpassword
```

`apply` performs Terraform apply, reads `ansible_inventory`, then invokes
ready → prepare → configure. Preparation is intentionally fresh-only: do not use
`apply` to re-adopt or re-bootstrap an installed candidate. These commands read
existing Terraform output but **never run Terraform apply**:

```sh
ansible/.venv/bin/python ansible/pihole.py inspect --settings /absolute/path/native-settings.json
ansible/.venv/bin/python ansible/pihole.py verify --settings /absolute/path/native-settings.json
ansible/.venv/bin/python ansible/pihole.py check \
  --settings /absolute/path/native-settings.json --maintenance-file /absolute/path/current-evidence.json
ansible/.venv/bin/python ansible/pihole.py configure \
  --settings /absolute/path/native-settings.json \
  --password-file /absolute/path/private-webpassword \
  --maintenance-file /absolute/path/current-evidence.json
```

`check` runs configure with `--check --diff`: identity/preflight inspection and
sanitized configuration rendering only, without reading passwords, modifying
files/packages/services or claiming runtime readiness. It requires Python already
bootstrapped. `verify` checks the native binary/source identity, ownership and
service hashes, exact safe settings/listeners, LAN admin HTTP, and controller-origin
external/local DNS over both UDP and TCP. An optional blocked-name check verifies
an operator-maintained deny rule. It does not fabricate backup or peer evidence.

Every managed configure/check requires a JSON evidence file containing exactly
the permitted maintenance keys. Record **actual current** backup/restore testing
and peer TCP/UDP DNS checks, including timestamps and artifact/check references:

- `pihole_backup_validated`: boolean true only after validating recoverability.
- `pihole_peer_health_validated`: boolean true only after validating healthy peers.
- `pihole_maintenance_evidence`: meaningful current evidence, at least 16 characters.

These are operator attestations, not automatic backup creation or proof by string
length. No example pre-asserts success. Preserve `/etc/pihole` (including gravity,
policy, native config and runtime databases) and root-private ownership/secret
state in protected recoverable backups; do not place database contents or private
files into Git. Coordinate consistent backups using Pi-hole's supported export
and/or stopped-service filesystem backups, and test restore separately.

## Secrets, configuration and failure behavior

The password comes from a private regular controller file (0400/0600), containing
one nonempty UTF-8 line, at most 4096 bytes and an optional final LF. No CR, embedded
LF or NUL is accepted. Keep the file out of Git and retrieve it using your secret
manager; never put plaintext in CLI arguments, environment variables or settings.
Ansible copies it with `no_log` and `diff: false` to
`/opt/pihole-ansible/secrets/webpassword` as root:root0600 under root0700 parents.

The native module uses system Nettle's BALLOON-SHA256 primitive and FTL's exact
salt/cost/PHC format, installing only the hash in `webserver.api.pwhash`. It does
not call `pihole setpassword` or the FTL password setter, both of which can expose
plaintext through argv. Matching hashes are reused. The first installation proves
authentication using a private loopback API request and closes the session before
claiming ownership. Controller unit tests validate ABI/encoding/idempotence using
a mocked primitive; the real Linux library/FTL compatibility is verified by that
first-install API check, not by the controller tests.

Ansible atomically merges its explicit TOML keys while preserving unrelated
UI-owned settings and gravity/policy databases. Changed settings stop FTL first
to avoid concurrent UI writes, replace and fsync the config, and restart; identical
settings/password/service content do not restart. A concurrent managed-key change
after a no-op preview is refused without writing to the running service. DNS listens only on the selected
IPv4 and loopback, with mode `NONE` plus explicit dnsmasq bindings. DHCP/NTP,
reverse forwarding, extra dnsmasq snippets and advanced web overrides are disabled.
The password-protected web server binds to the selected LAN IPv4 and loopback,
using port **80** by default. Open `http://CHOSEN_PRIVATE_IP/admin/` from a LAN
computer. Its access-control list allows only loopback and `pihole_trusted_cidr`;
it does not bind wildcard or IPv6 addresses. Do not forward this port from the
internet. HTTP is unencrypted; use an SSH tunnel on untrusted networks:

```sh
ssh -N -L 127.0.0.1:18080:127.0.0.1:80 root@CHOSEN_PRIVATE_IP
# Open http://127.0.0.1:18080/admin/ on the controller running this tunnel.
```

Existing managed installations reject port changes until separately reviewed
maintenance is performed; changing the default does not authorize adoption.

The service drop-in retains only DNS-required ambient capabilities compatible
with an unprivileged LXC. It does not relax host security or enable nesting. Real
LXC/systemd startup must still pass runtime verification on the selected template.

Ownership `/opt/pihole-ansible/ownership.json` is written root0600 only after
successful runtime/DNS/private-auth verification. Partial installation leaves
residue and no ownership marker; error handling attempts to stop and disable the
new service. An interrupted/unreachable run cannot guarantee cleanup. Subsequent
runs refuse that residue: inspect the candidate via its trusted console and
recreate/recover it deliberately. Never manufacture a marker or delete individual
files merely to bypass the gate. Managed failures preserve the existing marker
and require investigation; no automatic rollback or implicit adoption is claimed.

## Live validation status — 2026-11-07

CT190 on Debian 13.6 passed readiness, raw bootstrap and native installation with
nesting disabled. The FTL service, exact bindings/configuration and gravity build
passed; the Linux Nettle password hash was independently verified by successful
API login/logout. Guest UDP DNS, controller TCP DNS and the tunneled admin login
page also passed manual checks.

The full configure play failed its controller UDP local-record assertion. The
controller still received external UDP DNS answers while the candidate's FTL was
stopped, demonstrating interception rather than a valid candidate response. Do
not weaken or skip that check: pause/reconfigure the controller's DNS-intercepting
software or use an unaffected controller before a fresh deployment. No completed
ownership marker or successful day-2 run is claimed. FTL was manually started for
diagnosis/admin access; guest and FTL autostart were left disabled throughout the
test. Production peers and router DNS were not modified.

Following explicit approval, the candidate's admin interface was changed to port
80 on its LAN IPv4 and loopback, with a trusted-LAN ACL. Direct controller HTTP
access passed. This supersedes the initial loopback-only web configuration; a
successful HTTP login page does not establish DNS readiness.

At the operator's request, Terraform subsequently destroyed CT190 and its dedicated
Debian template on the same date. The separate servers state is empty; the existing
Pi-hole and all other guests were preserved. The candidate admin endpoint and SSH
tunnel are no longer available. These results describe the historical test, not a
currently deployed service or successful end-to-end configuration.

## Offline validation and upstream references

```sh
ansible/.venv/bin/python -m unittest discover -s ansible/tests -v
(cd ansible && .venv/bin/ansible-playbook -i localhost, tests/render.yml)
(cd ansible && .venv/bin/ansible-playbook -i inventory.example.yml playbooks/configure.yml --syntax-check)
bash -n ansible/files/install-native.sh
```

- [Pinned official installer](https://github.com/pi-hole/pi-hole/blob/f503a65d3a07cb71fd931389f1d3babf718249aa/automated%20install/basic-install.sh)
- [Native FTL configuration](https://docs.pi-hole.net/ftldns/configfile/)
- [FTL v6.8 password implementation](https://github.com/pi-hole/FTL/blob/v6.8/src/api/password.c)
- [Nettle BALLOON interface](https://www.lysator.liu.se/~nisse/nettle/nettle.html#Key-derivation-functions)
- [Native API authentication](https://docs.pi-hole.net/api/auth/)

Offline checks do not replace a disposable fresh-LXC live test and a second
attested no-op run. Do not cut over production clients based on a render alone.
