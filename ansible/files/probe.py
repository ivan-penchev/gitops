"""Read-only host inventory. Never return Docker environment or secret contents."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path('/opt/pihole-ansible')
OWNER = 'gitops-ansible-pihole-v1'


def run(*args, optional=False):
    result = subprocess.run(args, capture_output=True, text=True, check=False)
    if result.returncode and not optional:
        # Do not leak subprocess output (Docker configuration can contain secrets).
        raise RuntimeError('Read-only prerequisite command failed: ' + args[0])
    return result.stdout.strip()


def inspect_container(container):
    config = container['Config']
    return {
        'name': container['Name'].lstrip('/'),
        'image': config['Image'], 'image_id': container['Image'],
        'labels': {k: v for k, v in (config.get('Labels') or {}).items()
                   if k == 'io.gitops.owner' or k.startswith('com.docker.compose.')},
        'mounts': [{'source': m['Source'], 'destination': m['Destination'],
                    'type': m['Type'], 'rw': m['RW']} for m in container['Mounts']],
        'bindings': container['HostConfig'].get('PortBindings') or {},
        'host_ports': [p['HostPort'] for ports in (container['HostConfig'].get('PortBindings') or {}).values()
                       for p in (ports or [])],
        'networks': [n['IPAddress'] for n in container['NetworkSettings']['Networks'].values()],
        'health': container['State'].get('Health', {}).get('Status', 'missing'),
        'status': container['State']['Status'],
    }


def collect(ui_port):
    info = json.loads(run('docker', 'info', '--format', '{{json .}}'))
    version = run('docker', 'compose', 'version', '--short').lstrip('v')
    parts = tuple(int(p) for p in version.split('.')[:2])
    if parts < (2, 24):
        raise RuntimeError('Docker Compose >= 2.24.0 is required')
    ids = run('docker', 'ps', '-aq').split()
    containers = [inspect_container(c) for c in json.loads(run('docker', 'inspect', *ids))] if ids else []
    marker_path = ROOT / 'metadata.json'
    marker = json.loads(marker_path.read_text()) if marker_path.is_file() else None
    ancestor = ROOT
    while not ancestor.exists():
        ancestor = ancestor.parent
    # Check the data path separately: it could be its own mount even when /opt is local.
    data_path = ROOT / 'data'
    filesystem = run('findmnt', '-n', '-o', 'FSTYPE', '-T', str(data_path if data_path.exists() else ancestor))
    paths = [Path('/opt'), ROOT, data_path, ROOT / 'secrets', marker_path,
             ROOT / 'compose.yml', ROOT / 'secrets/webpassword']
    listeners = []
    own = [c for c in containers if c['labels'].get('io.gitops.owner') == OWNER]
    for line in run('ss', '-H', '-lntup').splitlines():
        fields = line.split()
        endpoint = fields[4]
        port = endpoint.rsplit(':', 1)[-1]
        if port not in ('53', str(ui_port)):
            continue
        owned = False
        pids = re.findall(r'pid=(\d+)', line)
        for pid in pids:
            try:
                args = Path('/proc', pid, 'cmdline').read_bytes().decode().strip('\0').split('\0')
                options = dict(zip(args[1::2], args[2::2]))
                if Path(args[0]).name == 'docker-proxy' and len(own) == 1:
                    owned = (options.get('-container-ip') in own[0]['networks'] and
                             options.get('-host-port') == port and
                             options.get('-proto') == fields[0] and
                             options.get('-host-ip') == endpoint.rsplit(':', 1)[0].strip('[]'))
            except (OSError, UnicodeError):
                owned = False
            if not owned:
                break
        listeners.append({'endpoint': endpoint, 'protocol': fields[0], 'owned': owned})
    addresses = json.loads(run('ip', '-j', '-4', 'address', 'show'))
    service = run('systemctl', 'show', 'pihole-FTL.service', '--property=LoadState', '--value')
    pinned_id = None
    if marker and isinstance(marker.get('image'), str):
        # This only inspects the local image cache. It never pulls an image.
        image_json = run('docker', 'image', 'inspect', marker['image'], optional=True)
        if image_json:
            image = json.loads(image_json)[0]
            digest = marker['image'].split('@')[-1]
            if any(d.endswith('@' + digest) for d in image.get('RepoDigests', [])):
                pinned_id = image['Id']
    return {
        'docker_version': info['ServerVersion'], 'compose_version': version,
        'rootless': any('rootless' in s for s in info.get('SecurityOptions', [])),
        'native_paths': [p for p in ('/etc/pihole', '/usr/local/bin/pihole', '/usr/bin/pihole') if os.path.lexists(p)],
        'native_service': service != 'not-found',
        'root_exists': os.path.lexists(ROOT), 'marker': marker,
        'data_exists': data_path.is_dir(), 'compose_exists': (ROOT / 'compose.yml').is_file(),
        'marker_secure': bool(marker and marker_path.stat().st_uid == 0 and not marker_path.stat().st_mode & 0o022),
        'filesystem': filesystem, 'symlinks': [str(p) for p in paths if p.is_symlink()],
        'host_ipv4': [a['local'] for interface in addresses for a in interface['addr_info'] if a['family'] == 'inet'],
        'containers': containers, 'managed_containers': own,
        'listeners': listeners, 'pinned_image_id': pinned_id,
    }


if __name__ == '__main__':
    print(json.dumps(collect(int(sys.argv[1]))))
