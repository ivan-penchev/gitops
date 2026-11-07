# Pi-hole: standalone Terraform + Ansible

**Not deployed. Not completion of issue #134.** This foundation configures one fresh,
dedicated Debian VM or physical device with official Pi-hole v6 Docker Compose.
It does not convert, adopt, stop, or replace a native Pi-hole/LXC deployment. In
particular, there is no implicit writable `.20` target.

## Integrated VM workflow (recommended)

[`terraform/servers`](../terraform/servers/README.md) is an independent Linux-server
root and state, starting with one **fresh Debian 13 VM**. It does not read shared
or cluster state, move the fileserver/PostgreSQL, or depend on Kubernetes. Terraform
owns the VM/image/cloud-init; Ansible owns Docker prerequisites and Pi-hole settings.
There are no Terraform provisioners, destroy/recreate triggers for Ansible changes,
or automatic applies from Git. Run the operator command again after changing Ansible.

1. Install controller dependencies below and Terraform; prepare the servers root's
   explicit inputs/backend credentials as documented there. Reserve an actually free
   VMID/IP and verify the Debian image checksum. Do not use the current primary.
   Provisioning also requires authorized Proxmox-host SSH access through an agent
   and a snippets-enabled datastore for cloud-init; API access alone is insufficient.
   Confirm both before applying. This workflow does not reconfigure host storage.
2. Copy `pihole.settings.example.json` to `pihole.settings.local.json`, replace TEST-NET
   addresses (including the candidate in the peer list), and review the image pin and
   local DNS records. This file contains **application configuration only**, never
   connection overrides or passwords. Keep your final non-secret desired settings in
   a reviewed Git file if preferred; the `*.local.json` examples are ignored.
3. Export the password to a private file as described below. Terraform never receives it.
4. From the repository root, with the independent backend/Proxmox credentials already
   in your environment:

   ```sh
   python3 ansible/pihole.py init --backend-config=terraform/servers/backend.local.hcl
   python3 ansible/pihole.py plan --var-file=terraform/servers/servers.auto.tfvars
   python3 ansible/pihole.py apply \
     --var-file=terraform/servers/servers.auto.tfvars \
     --settings=ansible/pihole.settings.local.json \
     --password-file=ansible/secrets/dns-candidate-password
   ```

   `apply` presents Terraform's plan and **requires its normal approval**. After a
   successful apply it reads `ansible_inventory` from that root's state, checks its
   single-target contract, waits up to five minutes for trusted SSH/Python, waits for
   cloud-init, installs missing Debian Docker/Compose packages, then configures and
   verifies Pi-hole. It never invokes `terraform/tf.sh all` or accesses cluster state.
   `--backend-config` can be repeated. Backend **file paths are resolved from your
   current directory**, and files must contain no plaintext credentials.

**First-boot SSH trust is deliberately not automatic.** Through your trusted
Proxmox-host SSH connection, run
`qm guest exec VMID -- /usr/bin/ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`
after cloud-init starts the guest agent. Compare the returned fingerprint with your
first `ssh operator@CANDIDATE_IP` prompt before accepting it. This avoids needing a
guest console password; cloud-init configures key-only access.
The runner uses the controller's known_hosts and SSH key/agent, never
`StrictHostKeyChecking=no`, blind `ssh-keyscan` trust, or password authentication
setup. Verify/accept while the first run waits, or rerun `apply` after it times out:
a successful VM creation is retained, not rolled back. A changed host key requires
independent verification, not automatic known_hosts deletion.

For day-2 changes, there is **no Terraform apply and no package bootstrap**:

```sh
python3 ansible/pihole.py check --settings=ansible/pihole.settings.local.json \
  --maintenance-file=ansible/maintenance.local.json
python3 ansible/pihole.py configure --settings=ansible/pihole.settings.local.json \
  --password-file=ansible/secrets/dns-candidate-password \
  --maintenance-file=ansible/maintenance.local.json
python3 ansible/pihole.py verify --settings=ansible/pihole.settings.local.json
```

`inspect` is also available with the same `--settings`. Check/inspect/verify need
no password. These commands read existing Terraform state to regenerate identity;
they do not refresh/apply infrastructure. Temporary inventory/settings live in an
owner-only ignored directory and are removed even on failure; group variables are
loaded explicitly. No inventory copy becomes a second source of truth.

Maintenance JSON accepts only the three existing attestations (see **Safe day-2
boundary**), e.g. `pihole_backup_validated`, `pihole_peer_health_validated`, and dated
`pihole_maintenance_evidence`. Supply true only after actually checking backup and
peer health; do not permanently enable them. Image/binding changes remain blocked.
A failure stops the pipeline without cleanup, rollback, DNS cutover or peer writes.
After a bootstrap failure, rerun `apply` with a reviewed unchanged Terraform plan;
a partial Pi-hole deployment still requires manual recovery, not a blind retry.
Use one operator/run at a time: Terraform's state lock does not lock Ansible.

No live deployment or end-to-end idempotence is claimed. Before production, test
first boot, second-run convergence, firewall reachability and recovery on a
throwaway VM; review the resulting plan before every infrastructure change.

## Scope and prerequisites

- Controller: Python **3.12–3.14**, SSH client, and connectivity to the candidate's
  SSH port and LAN DNS port 53 TCP **and** UDP. Local tests were run with Python
  3.14, the exact `requirements.txt` pins, and `community.docker` 4.8.2. Python 3.15
  is not a supported controller for this pinned Ansible release.
- Target: dedicated **Debian 12+ VM or physical host**, Python 3, rootful Docker
  Engine, Docker Compose plugin **2.24.0+**, `ip`, `ss`, `findmnt`, and systemd.
  For the integrated **Debian 13 VM**, `prepare.yml` installs missing `docker.io`,
  `docker-cli`, `docker-compose` (v2), `iproute2`, and `util-linux` from signed distribution apt
  repositories. Direct playbook users must supply prerequisites themselves.
  Neither path runs a curl installer, apt-upgrade, or reboot. Terraform cloud-init
  sets initial networking/resolvers; Ansible does not rewrite host resolvers.
- Reserve a verified-free static **RFC1918 IPv4** address, already assigned to
  the candidate, and explicitly declare its trusted LAN CIDR. DNS binds only to
  that address, not `0.0.0.0`, IPv6, or host networking. Independently verify that
  host/router/Docker forwarding rules admit only trusted clients. An address
  binding is **not** a firewall: no public port forwarding or public UI ingress.
- Data is a host-local `/opt/pihole-ansible/data` bind at container `/etc/pihole`.
  Supported local filesystems: ext4, XFS, Btrfs, ZFS, F2FS. No NFS/CIFS, shared
  SQLite, Kubernetes storage, symlinked managed paths, or existing native data.
- Disable competing updaters/Watchtower for this host. Do not use `pihole -up`.
  This role owns the Compose project `gitops-pihole` and the entire
  `/opt/pihole-ansible` directory; it does not adopt unrelated containers.
- Review the [official Docker releases](https://github.com/pi-hole/docker-pi-hole/releases)
  and [Docker configuration](https://docs.pi-hole.net/docker/). Supply an explicit
  per-host `pihole/pihole:YYYY.MM.N@sha256:<64 lowercase hex>` v6 image pin whose
  digest supports that host's architecture. **There is no group-wide image default.**
  The TEST-NET example includes the official `2026.10.1` multi-architecture index
  digest reviewed on 2026-11-07 for amd64/arm64; explicitly reconfirm it for your
  target. Date validation cannot prove digest contents: upstream release/architecture
  review remains an operator gate.

## Controller setup (no global installation)

Run all commands from `ansible/` so its configuration and inventory-relative group
variables are loaded. No setup command contacts a managed host.

```sh
cd ansible
mkdir -p .cache
python3.14 -m venv .venv
export TMPDIR="$PWD/.cache"
export ANSIBLE_GALAXY_CACHE_DIR="$PWD/.cache/galaxy"
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/ansible-galaxy collection install -r requirements.yml -p .collections
```

`inventory.yml` intentionally contains an **empty** `pihole` group. Tests and
examples never imply permission to contact an address. Create a private copy:

```sh
(umask 077; cp inventory.example.yml inventory.local.yml)
```

Replace **all TEST-NET example addresses**, SSH identity, peer list, trusted CIDR,
and password source path in that copy before use; reconfirm the example image pin
for the target architecture. TEST-NET binds are rejected. The example is documentation, not runnable infrastructure.
The checked-in group variables explicitly define timezone, local records, CNAMEs,
and probes; replace the illustrative `recovery-check.home.arpa` record/address
with an approved real local record before deployment. Keep desired non-secret
settings under review in Git; keep actual access details in the private inventory.
If the inventory is elsewhere, copy/link its `group_vars/pihole.yml` deliberately
or explicitly load this file; Ansible group-variable search is inventory-relative.

Set **all** Pi-hole node IPs in `pihole_peer_addresses`, including the candidate.
This slice accepts only public unicast IPv4 `pihole_upstreams`, never either
Pi-hole, loopback, or an empty list. Verify their actual independent routing from
this host; an IP check cannot prove an upstream's network path. Private recursive
upstreams and nonstandard upstream port/syntax support are deferred.

## Private password

Use a distinct password for each node. Provision a one-line, nonempty password
into an **absolute controller-private file** using your password manager's secure
file export (not a literal CLI argument or environment variable). For example,
choose `ansible/secrets/dns-candidate-password`, under an owner-only directory:

```sh
(umask 077; mkdir -p secrets)
chmod 700 secrets
# Export securely to secrets/dns-candidate-password, then:
chmod 600 secrets/dns-candidate-password
```

Set `pihole_password_source` to that file's absolute path. Do not add this file,
private inventories, Teleporter exports, or backups to Git. The subtree's
`.gitignore` excludes `secrets/`, `inventory.local.yml`, and local tooling.
Controller source must be a regular non-symlink file with mode 0400 or 0600.
Ansible copies it root-owned **0600** to
`/opt/pihole-ansible/secrets/webpassword`; Compose mounts the file read-only at
`/run/secrets/pihole_password`. Set `WEBPASSWORD_FILE: pihole_password` to the
**secret basename**, not an absolute path: the pinned official image prepends
`/run/secrets/` itself. An absolute value would point at the wrong location.
No password is templated into Compose, CLI arguments, environment values, or
metadata. All secret tasks and Compose execution use `no_log: true`, `diff: false`.
Do not enable secret-revealing custom callbacks/transport debug. Root/controller
administrators necessarily retain access to the plaintext runtime file.

## Explicit one-host workflow

Every play requires **exactly one selected inventory alias** and the matching
`pihole_target` argument. `serial: 1` plus `any_errors_fatal: true` also prevents a
failure from progressing to a peer. The guard runs before remote fact gathering.
Use the inventory alias, not a guessed IP; choose a fresh candidate, not the
existing primary. These commands are examples to run only after preflight review:

```sh
.venv/bin/ansible-playbook -i inventory.local.yml playbooks/inspect.yml \
  --limit dns_candidate -e pihole_target=dns_candidate --ask-become-pass
.venv/bin/ansible-playbook -i inventory.local.yml playbooks/configure.yml \
  --limit dns_candidate -e pihole_target=dns_candidate --check --diff --ask-become-pass
.venv/bin/ansible-playbook -i inventory.local.yml playbooks/configure.yml \
  --limit dns_candidate -e pihole_target=dns_candidate --ask-become-pass
.venv/bin/ansible-playbook -i inventory.local.yml playbooks/verify.yml \
  --limit dns_candidate -e pihole_target=dns_candidate --ask-become-pass
```

- **Inspect** reads host/Docker state, metadata, native-path/service presence,
  filesystem, and listeners; reports sanitized image IDs/health/mounts/ports, never
  Docker environment or secret content. Requires Docker prerequisites but no image
  variable or password. Nothing is installed or reconciled.
- **Configure --check** runs read-only validation/probes and renders non-secret
  Compose in memory. It does not read the password, create target paths, pull an
  image, or run Compose. It deliberately does not predict container convergence;
  missing first-host directories cannot trigger mutation in check mode.
- **Configure** refuses native Pi-hole, existing unmanaged/partial data, symlinks,
  shared storage, competing Docker projects, foreign Pi-hole containers, and
  occupied DNS/UI ports. Existing ownership requires metadata **and** actual
  Compose labels, image ID/digest, local bind mounts, and precise published ports.
  A container merely named `pihole` is never adopted. Host-port validation is
  conservative: other bindings on these port numbers are rejected even when an
  address-specific combination might work. Existing Docker proxy listeners must
  match this managed container; no host service is stopped to free a port.
- **Verify** waits indirectly through Compose's health wait during configure;
  standalone verify reads current health. It requires a running, healthy,
  provenance-matched image, and issues real A queries **from the controller** to
  the explicit LAN IP over both UDP/TCP. External resolution and a Git-owned local
  A record must succeed. Optional `pihole_verify_blocked_name` must return NXDOMAIN
  or `0.0.0.0` (other blocking modes require a future probe extension). It does not
  modify gravity lists. Verify also queries in `--check`: DNS queries are read-only.

The management UI publishes only **127.0.0.1:8080** by default (configurable high
port). Use a tunnel, with the actual candidate's SSH address:

```sh
ssh -N -L 8080:127.0.0.1:8080 operator@YOUR_CANDIDATE_IP
# Open http://127.0.0.1:8080/admin/ locally.
```

No public HTTPS/Cloudflare ingress, DHCP, or NTP capability is configured.
`FTLCONF_dns_listeningMode=ALL` is necessary inside the Docker bridge; host
publishing/firewall controls the permitted client network. DHCP and IPv4/IPv6 NTP
servers are explicitly disabled. Environment-owned FTL settings (upstreams,
local hosts/CNAMEs) are Git's authority and must not also be written via TOML,
dnsmasq files, APIs, or policy synchronization. Empty arrays serialize as explicit
empty strings to clear those settings, never YAML null. UI-owned gravity policy
is deliberately separate.

## Safe day-2 boundary

**Image changes are always blocked on an existing managed deployment.** There is
no `force`/upgrade override. Config-only convergence uses the same immutable image
and `pull: missing`, not an implicit tag update. Do not edit/delete metadata to
bypass the gate. Published DNS/UI binding changes are similarly blocked.

Every repeat configure (even a no-op/check run) requires current operator evidence:

1. Take a private pre-change Teleporter export and a consistent recoverable state
   backup; validate restoration separately. A copy of live SQLite files is not a
   validated backup. Retain the exact image alongside compatible state.
2. Query the healthy peer over UDP/TCP for external/local/blocked records, and
   prove management access/emergency DNS does not depend on the node being changed.
3. Record non-secret dated evidence and set `pihole_backup_validated: true`,
   `pihole_peer_health_validated: true`, and `pihole_maintenance_evidence` for this
   invocation via a private `-e @maintenance.yml` file. Both flags default false.
   These are **human attestations**, not automated backup validation. Do not store
   permanently true flags in inventory. Rotate the password only within this gate;
   a changed secret deliberately recreates the container so Docker rereads it.

Compose recreation can interrupt this node. A second same-host VM gives only
maintenance redundancy, not Proxmox-host HA. If first creation fails after paths
are created, the next run fails closed rather than adopting partial state. Preserve
and inspect that state manually; no automated cleanup, data deletion, or rollback
is included. Verification failure also stops without blind rollback. Re-running
healthy unchanged desired state with valid attestations should yield no changes;
**runtime idempotence has not yet been demonstrated on a disposable daemon**.

Deferred: native/LXC migration and `.20` cutover,
router DHCP/IPv6 changes, peer installation/cutover, selective Nebula Sync,
backup scheduling/encryption/export automation, tested image+state upgrades and
rollback, offline image archives, OS/Docker maintenance, CNAME/AAAA/PTR and client
failover coverage, and independent-host disaster recovery. Nothing here claims
that issue #134 or its production acceptance criteria are complete.

## Offline validation

No test below contacts the example/production IPs or any Docker daemon:

```sh
.venv/bin/python -m unittest discover -s tests -v
.venv/bin/ansible-playbook -i localhost, tests/render.yml
for playbook in inspect configure verify ready prepare; do
  .venv/bin/ansible-playbook --syntax-check "playbooks/$playbook.yml" || exit 1
done
```

Unit tests cover dangerous inputs, empty inventory, native/unmanaged/shared-state
refusal, metadata versus actual-state drift, image-update and maintenance gates,
secret logging constraints, and mocked UDP/TCP success/failure. Every dynamic
Compose field escapes `$` as `$$` before YAML quoting; validation also rejects
interpolation syntax in deployment settings. Password file bytes never pass through
Compose interpolation. When Docker CLI with its Compose plugin is available, the
unit suite additionally runs **daemon-free** `docker compose config` over stdin
with a synthetic interpolation fixture and no `.env` file; otherwise that check is
explicitly skipped. The controller-only Ansible play checks real filter integration,
string/list serialization, and dollar escaping without writing a Compose file.
Syntax checks load the pinned collection. A future isolated
runtime test must demonstrate first creation, second-run idempotence, password
rotation, actual v6 health, firewall reachability, and restart from cached image
before production use.
