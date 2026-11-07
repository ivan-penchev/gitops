"""Small, pure validation helpers shared by playbooks and offline tests."""
import ipaddress
import re

from ansible.errors import AnsibleFilterError

ROOT = "/opt/pihole-ansible"
OWNER = "gitops-ansible-pihole-native-v1"
PINS = ('core_version', 'core_commit', 'installer_sha256', 'web_version', 'web_commit', 'ftl_version', 'ftl_sha256')
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


def validate(values, pins_required=True):
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
    require(isinstance(port, int) and not isinstance(port, bool) and (port == 80 or 1024 <= port <= 65535), "UI port must be 80 or an integer in 1024..65535")
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
    require(isinstance(value("pihole_interface"), str) and
            re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]{0,14}", values["pihole_interface"]), "Invalid dedicated interface")
    if pins_required:
        for pin in PINS:
            pattern = r"v6\.\d+(?:\.\d+)?" if pin.endswith("version") else (r"[0-9a-f]{40}" if pin.endswith("commit") else r"[0-9a-f]{64}")
            require(isinstance(value("pihole_" + pin), str) and re.fullmatch(pattern, values["pihole_" + pin]),
                    "Supply explicit reviewed native release pin: " + pin)
    return True


def preflight(snapshot, values):
    """A marker is necessary but never sufficient evidence of ownership."""
    require(snapshot["filesystem"] in ("ext4", "xfs", "btrfs", "zfs", "f2fs"), "Require local storage")
    require(not snapshot["symlinks"], "Managed paths must not be symlinks")
    require(snapshot["interface_ipv4"] == [values["pihole_dns_bind"]], "Dedicated interface must carry exactly the chosen IPv4")
    require(not snapshot["docker_present"], "Docker/Podman deployment is outside native ownership")
    require(not snapshot["unsafe_services"], "Conflicting resolver/web service exists; manual recovery required")
    marker = snapshot["marker"]
    if marker is None:
        require(not snapshot["root_exists"] and not snapshot["native_paths"] and not snapshot["native_service"] and not snapshot["native_user"],
                "Existing or interrupted deployment: do not adopt; manual recovery required")
        require(not snapshot["listeners"], "DNS/UI/DHCP/NTP host port occupied")
        return True
    require(snapshot["marker_secure"] and marker.get("owner") == OWNER, "Invalid native ownership metadata")
    require(all(marker.get(pin) == values["pihole_" + pin] for pin in PINS), "Release changes are blocked; explicit upgrade procedure required")
    require(all(marker.get(key) == values["pihole_" + key] for key in ("dns_bind", "ui_port", "interface")), "Binding changes require separate maintenance")
    require(snapshot["config_exists"] and snapshot["native_service"] and snapshot["service_active"], "Missing native runtime: manual recovery required")
    require(snapshot["core_commit"] == marker["core_commit"] and snapshot["web_commit"] == marker["web_commit"] and
            snapshot["ftl_sha256"] == marker["ftl_sha256"] and snapshot["ftl_version"] == marker["ftl_version"], "Installed release drift")
    require(snapshot["service_sha256"] == marker.get("service_sha256") and snapshot["repos_clean"], "Installed source/service drift")
    require(all(listener["owned"] for listener in snapshot["listeners"]), "Foreign DNS/UI listener")
    require(values.get("pihole_backup_validated") is True and values.get("pihole_peer_health_validated") is True,
            "Reconfiguration requires validated recoverable backup and healthy peer")
    evidence = values.get("pihole_maintenance_evidence", "")
    require(isinstance(evidence, str) and len(evidence.strip()) >= 16, "Record current backup/restore and peer-health evidence")
    return True


def native_config(values):
    return {
        "dns.upstreams": values["pihole_upstreams"], "dns.hosts": values["pihole_local_hosts"],
        "dns.cnameRecords": values["pihole_local_cnames"], "dns.interface": values["pihole_interface"],
        "dns.listeningMode": "NONE", "dns.port": 53, "dns.revServers": [], "dhcp.active": False,
        "webserver.advancedOpts": [],
        "ntp.ipv4.active": False, "ntp.ipv6.active": False, "ntp.sync.active": False,
        "webserver.port": "127.0.0.1:" + str(values["pihole_ui_port"]) + "," + values["pihole_dns_bind"] + ":" + str(values["pihole_ui_port"]),
        "webserver.acl": "+127.0.0.1,+" + values["pihole_trusted_cidr"],
        "misc.etc_dnsmasq_d": False, "files.gravity_tmp": "/etc/pihole/gravity-work",
        "misc.dnsmasq_lines": ["bind-interfaces", "listen-address=" + values["pihole_dns_bind"] + ",127.0.0.1"],
    }


class FilterModule:
    def filters(self):
        return {"pihole_validate": validate, "pihole_preflight": preflight, "pihole_native_config": native_config}
