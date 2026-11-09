#!/usr/bin/python3
"""Read-only, secret-free evidence for the dedicated native guest."""
import hashlib
import grp
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tomllib
import pwd

ROOT = Path('/opt/pihole-ansible')
NATIVE = ['/etc/pihole', '/etc/.pihole', '/opt/pihole', '/var/www/html/admin',
          '/usr/local/bin/pihole', '/usr/bin/pihole-FTL', '/etc/dnsmasq.d',
          '/etc/systemd/system/pihole-FTL.service', '/etc/systemd/system/pihole-FTL.service.d',
          '/etc/logrotate.d/pihole', '/etc/cron.d/pihole', '/etc/init.d/pihole-FTL',
          '/etc/bash_completion.d/pihole', '/etc/bash_completion.d/pihole-FTL', '/usr/local/bin/pihole-FTL', '/var/lib/pihole', '/var/log/pihole', '/etc/dnsmasq.conf']


def required(*args):
    return subprocess.run(args, text=True, capture_output=True, check=True).stdout.strip()


def run(*args):
    result = subprocess.run(args, text=True, capture_output=True, check=False)
    return result.stdout.strip() if result.returncode == 0 else ''


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest() if Path(path).is_file() else ''


def probe(bind, interface, port):
    marker_path = ROOT / 'ownership.json'
    paths = [ROOT, marker_path, ROOT / 'secrets', ROOT / 'secrets/webpassword', Path('/etc/pihole/pihole.toml'), Path('/etc/systemd/system/pihole-FTL.service.d/10-native-lxc.conf'), *map(Path, NATIVE)]
    symlinks = sorted({str(p) for path in paths for p in [path, *path.parents] if p.is_symlink()})
    if symlinks:
        raise ValueError('Managed paths contain symlinks')
    marker = json.loads(marker_path.read_text()) if marker_path.is_file() else None
    if marker is not None:
        allowed = {'owner', 'core_version', 'core_commit', 'installer_sha256', 'web_version', 'web_commit',
                   'ftl_version', 'ftl_sha256', 'dns_bind', 'ui_port', 'interface', 'service_sha256'}
        if not isinstance(marker, dict) or set(marker) != allowed:
            raise ValueError('Invalid ownership fields')
    rows = json.loads(required('ip', '-j', '-4', 'address', 'show', 'dev', interface))
    addresses = sorted(a['local'] for row in rows for a in row.get('addr_info', []) if a['family'] == 'inet')
    listeners = []
    for line in required('ss', '-H', '-lntup').splitlines():
        columns = line.split()
        if len(columns) < 5:
            continue
        address, _, number = columns[4].rpartition(':')
        if number not in ('53', '67', '123', '80', '443', str(port)):
            continue
        address = address.strip('[]')
        owned = '"pihole-FTL"' in line and ((number == '53' and address in (bind, '127.0.0.1')) or
                                                   (number == str(port) and address in (bind, '127.0.0.1')))
        listeners.append({'address': address, 'port': int(number), 'owned': owned})
    secure = False
    if marker_path.exists():
        info = marker_path.stat()
        secure = info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o600 and ROOT.stat().st_uid == 0 and stat.S_IMODE(ROOT.stat().st_mode) == 0o700
    service = '/etc/systemd/system/pihole-FTL.service'
    config = {}
    if Path('/etc/pihole/pihole.toml').is_file():
        native = tomllib.loads(Path('/etc/pihole/pihole.toml').read_text())
        for key in ('dns.upstreams', 'dns.hosts', 'dns.cnameRecords', 'dns.interface', 'dns.listeningMode', 'dns.port', 'dns.revServers', 'webserver.advancedOpts',
                    'dhcp.active', 'ntp.ipv4.active', 'ntp.ipv6.active', 'ntp.sync.active', 'webserver.port', 'webserver.acl',
                    'misc.etc_dnsmasq_d', 'misc.dnsmasq_lines', 'files.gravity_tmp'):
            value = native
            for part in key.split('.'):
                value = value.get(part) if isinstance(value, dict) else None
            config[key] = value
    try:
        pwd.getpwnam('pihole')
        native_user = True
    except KeyError:
        native_user = False
    try:
        grp.getgrnam('pihole')
        native_user = True
    except KeyError:
        pass
    return {
        'config': config, 'native_user': native_user,
        'filesystem': run('findmnt', '-n', '-o', 'FSTYPE', '-T', str(ROOT if ROOT.exists() else ROOT.parent)),
        'root_exists': ROOT.exists(), 'marker': marker, 'marker_secure': secure, 'symlinks': symlinks,
        'interface_ipv4': addresses, 'listeners': listeners,
        'docker_present': any(Path(p).exists() for p in ('/var/lib/docker', '/var/lib/containers', '/usr/bin/docker', '/usr/bin/podman', '/run/docker.sock')),
        'unsafe_services': [name for name in ('systemd-resolved', 'dnsmasq', 'unbound', 'named', 'apache2', 'nginx', 'lighttpd')
                            if run('systemctl', 'is-active', name) == 'active' or run('systemctl', 'is-enabled', name) in ('enabled', 'enabled-runtime')],
        'native_paths': [p for p in NATIVE if os.path.lexists(p)],
        'native_service': Path(service).exists(), 'config_exists': Path('/etc/pihole/pihole.toml').is_file(),
        'service_active': run('systemctl', 'is-active', 'pihole-FTL') == 'active',
        'core_commit': run('git', '-C', '/etc/.pihole', 'rev-parse', 'HEAD') if Path('/usr/bin/pihole-FTL').exists() else '',
        'web_commit': run('git', '-C', '/var/www/html/admin', 'rev-parse', 'HEAD') if Path('/usr/bin/pihole-FTL').exists() else '',
        'repos_clean': all(run('git', '-C', p, 'rev-parse', '--is-inside-work-tree') == 'true' and not required('git', '-C', p, 'status', '--porcelain') for p in ('/etc/.pihole', '/var/www/html/admin')) if Path('/etc/.pihole').exists() else False,
        'ftl_sha256': digest('/usr/bin/pihole-FTL') if Path('/usr/bin/pihole-FTL').exists() else '',
        'ftl_version': run('/usr/bin/pihole-FTL', '--version') if Path('/usr/bin/pihole-FTL').exists() else '',
        'service_sha256': digest(service) + digest(service + '.d/10-native-lxc.conf'),
    }


if __name__ == '__main__':
    try:
        print(json.dumps(probe(sys.argv[1], sys.argv[2], int(sys.argv[3]))))
    except Exception:
        sys.exit('Native evidence unavailable or unsafe; manual inspection required')
