import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

import dns.message
import dns.rcode
import dns.rrset
import yaml
from ansible.errors import AnsibleFilterError
from jinja2 import Environment

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'filter_plugins'))
from pihole import OWNER, PROJECT, ROOT as REMOTE_ROOT, preflight, validate

spec = importlib.util.spec_from_file_location('verify_dns', ROOT / 'files/verify_dns.py')
verify_dns = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_dns)
spec = importlib.util.spec_from_file_location('probe', ROOT / 'files/probe.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def variables():
    values = yaml.safe_load((ROOT / 'group_vars/pihole.yml').read_text())
    values.update(pihole_dns_bind='10.77.0.10', pihole_trusted_cidr='10.77.0.0/24',
                  pihole_peer_addresses=['10.77.0.10', '10.77.0.11'], pihole_upstreams=['1.1.1.1'],
                  pihole_image='pihole/pihole:2026.01.0@sha256:' + 'a' * 64)
    return values


def render_compose(values):
    environment = Environment()
    environment.filters['to_json'] = json.dumps
    return environment.from_string((ROOT / 'templates/compose.yml.j2').read_text()).render(values)


def snapshot(existing=False):
    values = variables()
    result = dict(native_paths=[], native_service=False, filesystem='ext4', symlinks=[],
                  host_ipv4=[values['pihole_dns_bind']], rootless=False, containers=[],
                  marker=None, root_exists=False, listeners=[], marker_secure=True, pinned_image_id='sha256:local',
                  data_exists=existing, compose_exists=existing)
    if existing:
        result.update(root_exists=True, marker=dict(owner=OWNER, image=values['pihole_image'],
                                                   dns_bind=values['pihole_dns_bind'], ui_port=8080))
        result['containers'] = [dict(name='gitops-pihole-pihole-1', image=values['pihole_image'], image_id='sha256:local',
                                    labels={'io.gitops.owner': OWNER, 'com.docker.compose.project': PROJECT,
                                            'com.docker.compose.service': 'pihole', 'com.docker.compose.project.working_dir': REMOTE_ROOT},
                                    mounts=[dict(source=REMOTE_ROOT+'/data', destination='/etc/pihole', type='bind', rw=True),
                                            dict(source=REMOTE_ROOT+'/secrets/webpassword', destination='/run/secrets/pihole_password', type='bind', rw=False)],
                                    bindings={'53/tcp': [{'HostIp': values['pihole_dns_bind'], 'HostPort': '53'}],
                                              '53/udp': [{'HostIp': values['pihole_dns_bind'], 'HostPort': '53'}],
                                              '80/tcp': [{'HostIp': '127.0.0.1', 'HostPort': '8080'}]}, host_ports=['53', '8080'])]
    return result


class SafetyTests(unittest.TestCase):
    def test_valid_input(self):
        self.assertTrue(validate(variables()))
        self.assertTrue(preflight(snapshot(), variables()))

    def test_invalid_inputs(self):
        cases = {'pihole_image': ['pihole/pihole:latest', 'pihole/pihole:2026.01.0', 'evil/image:2026.01.0@sha256:'+'a'*64],
                 'pihole_dns_bind': ['0.0.0.0', '127.0.0.1', '192.0.2.10', '10.77.0.999'],
                 'pihole_upstreams': [[], '1.1.1.1', ['10.77.0.11'], ['127.0.0.1']],
                 'pihole_ui_port': ['8080', True, 53], 'pihole_local_hosts': [None, ['1.2.3.4 good;bad']],
                 'pihole_local_cnames': [None, ['bad,name,extra']]}
        for key, bad_values in cases.items():
            for bad in bad_values:
                with self.subTest(key=key, value=bad), self.assertRaises(AnsibleFilterError):
                    validate(dict(variables(), **{key: bad}))

    def test_every_dynamic_compose_field_escapes_dollars(self):
        value = 'literal$PIHOLE_TEST${PIHOLE_TEST:-fallback}$$cash'
        settings = dict(variables(), pihole_image=value, pihole_dns_bind=value, pihole_ui_port=value,
                        pihole_timezone=value, pihole_upstreams=[value], pihole_local_hosts=[value],
                        pihole_local_cnames=[value])
        service = yaml.safe_load(render_compose(settings))['services']['pihole']
        escaped = value.replace('$', '$$')
        self.assertEqual(service['image'], escaped)
        self.assertEqual(service['ports'], [escaped + ':53:53/tcp', escaped + ':53:53/udp',
                                            '127.0.0.1:' + escaped + ':80/tcp'])
        for field in ('TZ', 'FTLCONF_dns_upstreams', 'FTLCONF_dns_hosts', 'FTLCONF_dns_cnameRecords'):
            self.assertEqual(service['environment'][field], escaped)
        for key in settings:
            if key in ('pihole_image', 'pihole_dns_bind', 'pihole_ui_port', 'pihole_timezone',
                       'pihole_upstreams', 'pihole_local_hosts', 'pihole_local_cnames'):
                with self.subTest(key=key), self.assertRaises(AnsibleFilterError):
                    validate(dict(variables(), **{key: settings[key]}))

    @unittest.skipUnless(shutil.which('docker'), 'Docker CLI unavailable; daemon-free Compose check skipped')
    def test_compose_cli_keeps_dollars_uninterpolated_without_daemon(self):
        version = subprocess.run(['docker', 'compose', 'version', '--short'], capture_output=True, text=True)
        if version.returncode:
            self.skipTest('Docker Compose CLI plugin unavailable')
        value = 'literal$PIHOLE_TEST${PIHOLE_TEST:-fallback}$$cash'
        settings = dict(variables(), pihole_timezone=value, pihole_upstreams=[value],
                        pihole_local_hosts=[value], pihole_local_cnames=[value])
        result = subprocess.run(['docker', 'compose', '--env-file', '/dev/null', '--project-directory',
                                 str(ROOT / 'tests'), '-f', '-', 'config', '--format', 'json'],
                                input=render_compose(settings), capture_output=True, text=True, timeout=30,
                                env=dict(os.environ, PIHOLE_TEST='MUST_NOT_INTERPOLATE'))
        self.assertEqual(result.returncode, 0, result.stderr)
        service = json.loads(result.stdout)['services']['pihole']
        self.assertNotIn('MUST_NOT_INTERPOLATE', result.stdout)
        # Compose re-escapes dollars when serializing its canonical config for reuse.
        for field in ('TZ', 'FTLCONF_dns_upstreams', 'FTLCONF_dns_hosts', 'FTLCONF_dns_cnameRecords'):
            self.assertEqual(service['environment'][field], value.replace('$', '$$'))
        self.assertEqual(service['environment']['WEBPASSWORD_FILE'], 'pihole_password')
        self.assertNotIn('FTLCONF_webserver_api_password', service['environment'])

    def test_password_secret_matches_upstream_basename_resolution(self):
        compose = yaml.safe_load(render_compose(variables()))
        service = compose['services']['pihole']
        basename = service['environment']['WEBPASSWORD_FILE']
        self.assertEqual(basename, 'pihole_password')
        self.assertNotIn('/', basename)
        self.assertEqual(service['secrets'], [basename])
        self.assertEqual(compose['secrets'][basename]['file'], REMOTE_ROOT + '/secrets/webpassword')
        mount = next(mount for mount in snapshot(True)['containers'][0]['mounts']
                     if mount['source'] == compose['secrets'][basename]['file'])
        self.assertEqual('/run/secrets/' + basename, mount['destination'])
        self.assertFalse(mount['rw'])

    def test_verify_does_not_require_pin(self):
        values = variables()
        del values['pihole_image']
        self.assertTrue(validate(values, False))

    def test_unmanaged_native_shared_or_occupied(self):
        for key, bad in [('native_paths', ['/etc/pihole']), ('native_service', True), ('filesystem', 'nfs4'),
                         ('symlinks', ['/opt/pihole-ansible/data']), ('root_exists', True),
                         ('listeners', [{'owned': False}]), ('host_ipv4', []), ('rootless', True)]:
            with self.subTest(key=key), self.assertRaises(AnsibleFilterError):
                preflight(dict(snapshot(), **{key: bad}), variables())

    def test_existing_requires_gates_and_actual_provenance(self):
        values = dict(variables(), pihole_backup_validated=True, pihole_peer_health_validated=True,
                      pihole_maintenance_evidence='Offline restore checked; peer UDP/TCP healthy today')
        self.assertTrue(preflight(snapshot(True), values))
        with self.assertRaises(AnsibleFilterError):
            preflight(snapshot(True), variables())
        for field, bad in [('image', 'pihole/pihole:latest'), ('image_id', 'sha256:drift'), ('mounts', []), ('bindings', {})]:
            observed = snapshot(True)
            observed['containers'][0][field] = bad
            with self.subTest(field=field), self.assertRaises(AnsibleFilterError):
                preflight(observed, values)
        with self.assertRaises(AnsibleFilterError):
            preflight(snapshot(True), dict(values, pihole_image='pihole/pihole:2026.02.0@sha256:'+'b'*64))
        observed = snapshot(True)
        observed['containers'][0]['labels'] = {}
        with self.assertRaises(AnsibleFilterError):
            preflight(observed, values)

    def test_marker_alone_and_name_alone_are_not_ownership(self):
        for observed in (dict(snapshot(True), containers=[]), dict(snapshot(True), marker=None)):
            with self.assertRaises(AnsibleFilterError):
                preflight(observed, variables())
        observed = snapshot(True)
        observed['containers'][0]['labels'] = {}
        observed['containers'][0]['name'] = 'pihole'
        with self.assertRaises(AnsibleFilterError):
            preflight(observed, variables())

    def test_probe_does_not_report_environment_or_unrelated_labels(self):
        container = {'Name': '/pihole', 'Image': 'sha256:example',
                     'Config': {'Image': variables()['pihole_image'], 'Env': ['PASSWORD=sentinel'],
                                'Labels': {'secret': 'sentinel', 'io.gitops.owner': OWNER}},
                     'Mounts': [], 'HostConfig': {'PortBindings': {}},
                     'NetworkSettings': {'Networks': {}}, 'State': {'Status': 'running'}}
        observed = probe.inspect_container(container)
        self.assertNotIn('sentinel', json.dumps(observed))
        self.assertEqual(observed['labels'], {'io.gitops.owner': OWNER})
        self.assertEqual(observed['health'], 'missing')

    def test_missing_data_and_foreign_listener_block_reconfigure(self):
        values = dict(variables(), pihole_backup_validated=True, pihole_peer_health_validated=True,
                      pihole_maintenance_evidence='Current restore and peer-health evidence')
        for key, bad in [('data_exists', False), ('compose_exists', False), ('marker_secure', False),
                         ('listeners', [{'owned': False}])]:
            with self.subTest(key=key), self.assertRaises(AnsibleFilterError):
                preflight(dict(snapshot(True), **{key: bad}), values)

    def test_password_content_assertions_reject_blank_and_multiline(self):
        tasks = yaml.safe_load((ROOT / 'playbooks/configure.yml').read_text())[0]['tasks']
        block = next(task['block'] for task in tasks if 'block' in task)
        task = next(task for task in block if task.get('name', '').startswith('Validate password content'))
        expressions = [Environment().compile_expression(condition)
                       for condition in task['ansible.builtin.assert']['that']]
        for value, expected in [('', False), ('  ', False), ('\n', False), ('first\nsecond', False),
                                ('first\rsecond', False), ('synthetic-test-value', True)]:
            with self.subTest(value=value):
                self.assertEqual(all(expression(pihole_private_password=value)
                                     for expression in expressions), expected)

    def test_empty_default_inventory(self):
        inventory = yaml.safe_load((ROOT / 'inventory.yml').read_text())
        self.assertEqual(inventory['all']['children']['pihole']['hosts'], {})

    def test_single_target_guard_precedes_all_remote_work(self):
        executable = Path(sys.executable).parent / 'ansible-playbook'
        for arguments in (['-e', 'pihole_target=one'], ['--limit', 'one'],
                          ['--limit', 'one', '-e', 'pihole_target=two']):
            with self.subTest(arguments=arguments):
                result = subprocess.run([str(executable), '-i', 'tests/inventory.yml', 'playbooks/inspect.yml',
                                         '--check', *arguments], cwd=ROOT, capture_output=True, text=True, timeout=30)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Require explicit single inventory host', result.stdout)
                self.assertNotIn('TASK [Read minimal', result.stdout)

    def test_existing_data_permissions_are_not_reset(self):
        tasks = yaml.safe_load((ROOT / 'playbooks/configure.yml').read_text())[0]['tasks']
        block = next(t['block'] for t in tasks if 'block' in t)
        data = next(t for t in block if t.get('ansible.builtin.file', {}).get('path') == REMOTE_ROOT + '/data')
        self.assertEqual(data['when'], 'pihole_snapshot.marker is none')

    def test_secret_tasks_never_log_or_diff(self):
        tasks = yaml.safe_load((ROOT / 'playbooks/configure.yml').read_text())[0]['tasks']
        apply = next(t for t in tasks if 'block' in t)
        self.assertEqual(apply['when'], 'not ansible_check_mode')
        for task in apply['block']:
            if 'password' in task.get('name', '').lower():
                self.assertIs(task['no_log'], True)
                self.assertIs(task['diff'], False)

    def test_dns_both_transports_and_negative_answers(self):
        calls = []
        def answer(query, server, timeout):
            calls.append(str(query.question[0].name))
            reply = dns.message.make_response(query)
            ip = '192.0.2.123' if str(query.question[0].name) == 'local.test.' else '93.184.215.14'
            reply.answer.append(dns.rrset.from_text(query.question[0].name, 30, 'IN', 'A', ip))
            return reply
        transports = {'udp': answer, 'tcp': answer}
        self.assertEqual(len(verify_dns.check('10.77.0.10', 'external.test', 'local.test', '192.0.2.123', '', transports)), 4)
        self.assertEqual(len(calls), 4)
        with self.assertRaises(RuntimeError):
            verify_dns.check('10.77.0.10', 'external.test', 'local.test', '192.0.2.124', '', transports)
        with self.assertRaises(RuntimeError):
            verify_dns.check('10.77.0.10', 'external.test', 'local.test', '192.0.2.123', 'not-blocked.test', transports)


if __name__ == '__main__':
    unittest.main()
