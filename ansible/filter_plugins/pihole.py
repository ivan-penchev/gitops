"""Small, pure validation helpers shared by playbooks and offline tests."""
import ipaddress
import re

from ansible.errors import AnsibleFilterError

ROOT = "/opt/pihole-ansible"
OWNER = "gitops-ansible-pihole-v1"
PROJECT = "gitops-pihole"
IMAGE = re.compile(r"^pihole/pihole:20\d{2}\.\d{1,2}\.\d+(?:-\d+)?@sha256:[0-9a-f]{64}$")
NAME = re.compile(r"^(?=.{1,253}$)[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$")


def require(condition, message):
    if not condition:
        raise AnsibleFilterError(message)


def ipv4(value):
    require(isinstance(value, str), "IPv4 addresses must be strings")
    try:
        return ipaddress.IPv4Address(value)
    except ValueError as exc:
        raise AnsibleFilterError("Invalid IPv4 address") from exc


def name(value):
    require(isinstance(value, str) and NAME.fullmatch(value), "Invalid DNS name")
    require(all(0 < len(label) <= 63 and not label.startswith('-') and not label.endswith('-')
                for label in value.split('.')), "Invalid DNS label")


def validate(values, image_required=True):
    def value(key):
        require(key in values, f"Missing required variable: {key}")
        return values[key]

    bind = ipv4(value("pihole_dns_bind"))
    try:
        cidr = ipaddress.IPv4Network(value("pihole_trusted_cidr"), strict=True)
    except (TypeError, ValueError) as exc:
        raise AnsibleFilterError("Supply a canonical trusted LAN IPv4 CIDR") from exc
    private_ranges = [ipaddress.IPv4Network(net) for net in
                      ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")]
    require(any(cidr.subnet_of(net) for net in private_ranges), "Trusted LAN must be RFC1918 (not TEST-NET)")
    require(bind in cidr and bind not in (cidr.network_address, cidr.broadcast_address), "DNS bind must be a LAN host address")
    peers = value("pihole_peer_addresses")
    require(isinstance(peers, list) and peers, "Declare all Pi-hole peer addresses")
    peer_ips = [ipv4(peer) for peer in peers]
    require(bind in peer_ips, "Peer addresses must include this host")
    upstreams = value("pihole_upstreams")
    require(isinstance(upstreams, list) and upstreams, "Nonempty independent upstreams required")
    require(all(ipv4(upstream).is_global and not ipv4(upstream).is_multicast and
                not ipv4(upstream).is_reserved and ipv4(upstream) not in peer_ips for upstream in upstreams),
            "This slice requires independent public IPv4 upstreams; never forward to a Pi-hole peer")
    port = value("pihole_ui_port")
    require(isinstance(port, int) and not isinstance(port, bool) and 1024 <= port <= 65535 and port != 53, "UI port must be an integer in 1024..65535")
    timezone = value("pihole_timezone")
    require(isinstance(timezone, str) and re.fullmatch(r"[A-Za-z_+-]+(?:/[A-Za-z0-9_+-]+)+", timezone), "Supply an IANA timezone, e.g. Etc/UTC")
    hosts = value("pihole_local_hosts")
    cnames = value("pihole_local_cnames")
    require(isinstance(hosts, list) and isinstance(cnames, list), "Local hosts/CNAMEs must be lists (empty is allowed)")
    for record in hosts:
        require(isinstance(record, str) and len(record.split()) >= 2, "Local hosts use 'IPv4 name [alias ...]'")
        fields = record.split()
        ipv4(fields[0])
        for hostname in fields[1:]:
            name(hostname)
        require(record == ' '.join(fields), "Use single spaces in local hosts")
    for record in cnames:
        require(isinstance(record, str) and len(record.split(',')) == 2, "CNAMEs use 'alias,target'")
        for hostname in record.split(','):
            name(hostname)
    name(value("pihole_verify_external"))
    name(value("pihole_verify_local_name"))
    local_ip = str(ipv4(value("pihole_verify_local_address")))
    require(any(local_ip == record.split()[0] and values["pihole_verify_local_name"] in record.split()[1:]
                for record in hosts), "Verification record must exist in Git-owned local hosts")
    if value("pihole_verify_blocked_name"):
        name(values["pihole_verify_blocked_name"])
    if image_required:
        require(isinstance(value("pihole_image"), str) and IMAGE.fullmatch(values["pihole_image"]),
                "Supply an official Pi-hole date tag plus immutable sha256 digest; latest is forbidden")
        release = values["pihole_image"].split(':', 1)[1].split('@', 1)[0].split('.')
        year, month = int(release[0]), int(release[1])
        require(1 <= month <= 12 and (year, month) >= (2025, 2), "Pin a reviewed v6-era release, not a pre-v6 or malformed date tag")
    return True


def preflight(snapshot, values):
    """Never adopt existing state based only on a name or a marker."""
    require(not snapshot["native_paths"], "Native Pi-hole paths exist; migration is outside this slice")
    require(not snapshot["native_service"], "Native pihole-FTL service exists")
    require(snapshot["filesystem"] in ("ext4", "xfs", "btrfs", "zfs", "f2fs"), "Data must be on an approved local filesystem, not shared/NFS/overlay storage")
    require(not snapshot["symlinks"], "Managed paths must not be symlinks")
    require(values["pihole_dns_bind"] in snapshot["host_ipv4"], "DNS bind is not assigned to this host")
    require(not snapshot["rootless"], "A conventional rootful Docker Engine is required")
    containers = snapshot["containers"]
    own = [c for c in containers if c["labels"].get("io.gitops.owner") == OWNER]
    foreign = [c for c in containers if c not in own]
    for container in foreign:
        require(not (re.match(r"^(?:(?:index\.)?docker\.io/)?pihole/pihole(?::|@|$)", container["image"]) or
                     container["name"] == "pihole" or
                     container["labels"].get("com.docker.compose.project") == PROJECT or
                     any(mount["source"].startswith(ROOT) or mount["destination"] == "/etc/pihole"
                         for mount in container["mounts"])), "Unmanaged Pi-hole deployment or conflicting project/storage exists")
        require(not any(int(port) in (53, values["pihole_ui_port"]) for port in container["host_ports"]),
                "Another container publishes DNS/UI ports")
    marker = snapshot["marker"]
    if marker is None:
        require(not snapshot["root_exists"] and not own, "Unmanaged or interrupted deployment exists; manual recovery required")
        require(not snapshot["listeners"], "DNS/UI host port is occupied")
        return True
    require(snapshot["data_exists"] and snapshot["compose_exists"], "Managed data or Compose file is missing; manual recovery required")
    require(snapshot["marker_secure"], "Deployment metadata must be root-owned and not writable by others")
    require(marker.get("owner") == OWNER, "Invalid deployment provenance")
    require(marker.get("image") == values["pihole_image"], "Image changes are blocked: tested backup/upgrade/rollback procedure is not implemented")
    require(marker.get("dns_bind") == values["pihole_dns_bind"] and marker.get("ui_port") == values["pihole_ui_port"],
            "Changing published bindings requires a separate maintenance procedure")
    require(len(own) == 1, "Expected exactly one provenance-matched container; missing/duplicate state requires recovery")
    container = own[0]
    labels = container["labels"]
    require(labels.get("com.docker.compose.project") == PROJECT and labels.get("com.docker.compose.service") == "pihole" and
            labels.get("com.docker.compose.project.working_dir") == ROOT, "Container Compose provenance does not match")
    require(container["image"] == marker["image"] and container["image_id"] == snapshot["pinned_image_id"],
            "Actual running image does not match the pinned deployment")
    require({"source": ROOT + "/data", "destination": "/etc/pihole", "type": "bind", "rw": True} in container["mounts"],
            "Persistent data mount differs from managed local storage")
    require({"source": ROOT + "/secrets/webpassword", "destination": "/run/secrets/pihole_password", "type": "bind", "rw": False} in container["mounts"],
            "Password must be a read-only file-backed secret")
    expected = {"53/tcp": [{"HostIp": values["pihole_dns_bind"], "HostPort": "53"}],
                "53/udp": [{"HostIp": values["pihole_dns_bind"], "HostPort": "53"}],
                "80/tcp": [{"HostIp": "127.0.0.1", "HostPort": str(values["pihole_ui_port"])}]}
    require(container["bindings"] == expected, "Actual container bindings drifted; refusing to take over")
    require(all(listener["owned"] for listener in snapshot["listeners"]), "Host port listener is not the managed Docker proxy")
    require(values.get("pihole_backup_validated") is True and values.get("pihole_peer_health_validated") is True,
            "Reconfiguration requires manually validated recoverable backup and healthy peer")
    evidence = values.get("pihole_maintenance_evidence", "")
    require(isinstance(evidence, str) and len(evidence.strip()) >= 16, "Record current backup/restore and peer-health evidence (no secrets)")
    return True


class FilterModule:
    def filters(self):
        return {"pihole_validate": validate, "pihole_preflight": preflight}
