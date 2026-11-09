import importlib.util
import json
import os
from pathlib import Path
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
from pihole import OWNER, PINS, ROOT as REMOTE_ROOT, native_config, preflight, validate

spec = importlib.util.spec_from_file_location('verify_dns', ROOT / 'files/verify_dns.py')
verify_dns = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify_dns)
spec = importlib.util.spec_from_file_location('probe', ROOT / 'files/probe.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def variables():
    values = yaml.safe_load((ROOT / 'group_vars/pihole.yml').read_text())
    values.update(json.loads((ROOT / 'pihole.settings.example.json').read_text()))
    values.update(pihole_dns_bind='10.77.0.10', pihole_trusted_cidr='10.77.0.0/24',
                  pihole_peer_addresses=['10.77.0.10', '10.77.0.11'], pihole_upstreams=['1.1.1.1'])
    return values


def snapshot(existing=False):
    values = variables()
    result = dict(native_paths=[], native_service=False, native_user=False, filesystem='ext4', symlinks=[],
                  interface_ipv4=[values['pihole_dns_bind']], docker_present=False, unsafe_services=[],
                  marker=None, root_exists=False, listeners=[], marker_secure=True,
                  config_exists=existing, service_active=existing)
    if existing:
        marker = {pin: values['pihole_' + pin] for pin in PINS}
        marker.update(owner=OWNER, dns_bind=values['pihole_dns_bind'], ui_port=values['pihole_ui_port'],
                      interface='eth0', service_sha256='service')
        result.update(root_exists=True, marker=marker, native_service=True,
                      core_commit=marker['core_commit'], web_commit=marker['web_commit'],
                      ftl_sha256=marker['ftl_sha256'], ftl_version=marker['ftl_version'],
                      repos_clean=True, service_sha256='service', listeners=[{'owned': True}])
    return result


def maintenance():
    return dict(variables(), pihole_backup_validated=True, pihole_peer_health_validated=True,
                pihole_maintenance_evidence='synthetic unit-test backup restoration and peer evidence')


class SafetyTests(unittest.TestCase):
    def test_valid_input(self):
        self.assertTrue(validate(variables()))
        self.assertTrue(preflight(snapshot(), variables()))

    def test_supported_web_ports(self):
        for port in (80, 1024, 8080, 65535):
            with self.subTest(port=port):
                values = dict(variables(), pihole_ui_port=port)
                self.assertTrue(validate(values))
                self.assertEqual(native_config(values)['webserver.port'], f'127.0.0.1:{port},10.77.0.10:{port}')

    def test_invalid_inputs(self):
        cases = {'pihole_core_version': ['latest', 'v5.0', 'v6.5;exit'],
                 'pihole_core_commit': ['latest', 'a' * 39, 'a' * 40 + ';'],
                 'pihole_ftl_sha256': ['latest', 'a' * 63], 'pihole_interface': ['eth0;id', '', 'a' * 16],
                 'pihole_dns_bind': ['0.0.0.0', '127.0.0.1', '192.0.2.10', '10.77.0.999'],
                 'pihole_upstreams': [[], '1.1.1.1', ['10.77.0.11'], ['127.0.0.1']],
                 'pihole_ui_port': ['80', '8080', True, 0, 22, 53, 443, 65536], 'pihole_local_hosts': [None, ['1.2.3.4 good;bad']],
                 'pihole_local_cnames': [None, ['bad,name,extra']]}
        for key, bad_values in cases.items():
            for bad in bad_values:
                with self.subTest(key=key, value=bad), self.assertRaises(AnsibleFilterError):
                    validate(dict(variables(), **{key: bad}))

    def test_each_native_pin_required(self):
        for pin in PINS:
            values = variables()
            del values['pihole_' + pin]
            with self.subTest(pin=pin), self.assertRaises(AnsibleFilterError):
                validate(values)

    def test_native_configuration_limits_all_listeners(self):
        config = native_config(variables())
        self.assertEqual(config['dns.listeningMode'], 'NONE')
        self.assertEqual(config['misc.dnsmasq_lines'], ['bind-interfaces', 'listen-address=10.77.0.10,127.0.0.1'])
        self.assertEqual(config['webserver.port'], '127.0.0.1:80,10.77.0.10:80')
        self.assertEqual(config['webserver.acl'], '+127.0.0.1,+10.77.0.0/24')
        for key in ('dhcp.active', 'ntp.ipv4.active', 'ntp.ipv6.active', 'ntp.sync.active', 'misc.etc_dnsmasq_d'):
            self.assertIs(config[key], False)

    def test_unmanaged_native_shared_or_occupied(self):
        cases = {'native_paths': ['/etc/pihole'], 'native_service': True, 'native_user': True,
                 'root_exists': True, 'filesystem': 'nfs', 'symlinks': ['/etc/pihole'],
                 'listeners': [{'owned': False}], 'docker_present': True,
                 'unsafe_services': ['systemd-resolved'], 'interface_ipv4': ['10.77.0.11']}
        for key, value in cases.items():
            with self.subTest(key=key), self.assertRaises(AnsibleFilterError):
                preflight(dict(snapshot(), **{key: value}), variables())

    def test_existing_requires_current_maintenance(self):
        self.assertTrue(preflight(snapshot(True), maintenance()))
        for changes in ({}, {'pihole_backup_validated': True}, {'pihole_peer_health_validated': True},
                        {'pihole_backup_validated': True, 'pihole_peer_health_validated': True}):
            with self.subTest(changes=changes), self.assertRaises(AnsibleFilterError):
                preflight(snapshot(True), dict(variables(), **changes))

    def test_marker_alone_does_not_authorize_adoption(self):
        data = snapshot()
        data['marker'] = snapshot(True)['marker']
        with self.assertRaises(AnsibleFilterError):
            preflight(data, maintenance())

    def test_native_drift_and_missing_runtime_block(self):
        cases = {'config_exists': False, 'native_service': False, 'service_active': False,
                 'core_commit': 'b' * 40, 'web_commit': 'b' * 40, 'ftl_sha256': 'b' * 64,
                 'ftl_version': 'v6.9', 'repos_clean': False, 'service_sha256': 'foreign',
                 'marker_secure': False, 'listeners': [{'owned': False}]}
        for key, value in cases.items():
            with self.subTest(key=key), self.assertRaises(AnsibleFilterError):
                preflight(dict(snapshot(True), **{key: value}), maintenance())

    def test_every_release_or_binding_change_blocked(self):
        for key in (*PINS, 'dns_bind', 'interface', 'ui_port'):
            values = maintenance()
            values['pihole_' + key] = 'changed'
            with self.subTest(key=key), self.assertRaises(AnsibleFilterError):
                preflight(snapshot(True), values)

    def test_installer_never_invokes_unsafe_main_or_updater(self):
        script = (ROOT / 'files/install-native.sh').read_text()
        self.assertIn('export SKIP_INSTALL=true', script)
        self.assertNotIn('curl', script)
        self.assertNotIn('installCron', script)
        self.assertNotIn('installLogrotate', script)
        self.assertNotIn('setpassword', script)
        tasks = (ROOT / 'playbooks/tasks/install.yml').read_text()
        self.assertIn('checksum: "sha256:{{ pihole_installer_sha256 }}"', tasks)
        self.assertIn('checksum: "sha256:{{ pihole_ftl_sha256 }}"', tasks)
        self.assertIn('update: false', tasks)

    def test_marker_written_only_after_verification(self):
        text = (ROOT / 'playbooks/configure.yml').read_text()
        self.assertLess(text.index('import_tasks: tasks/verify.yml'), text.index('dest: /opt/pihole-ansible/ownership.json'))
        self.assertIn('when: pihole_native_change.changed or pihole_service_config.changed', text)
        self.assertNotIn('state: restarted', text)
        self.assertNotIn('recurse:', text)

    def test_password_content_assertions_reject_blank_and_multiline(self):
        tasks = yaml.safe_load((ROOT / 'playbooks/configure.yml').read_text())[0]['tasks']
        block = next(task['block'] for task in tasks if 'block' in task)
        task = next(task for task in block if task.get('name', '').startswith('Validate password content'))
        expressions = [Environment().compile_expression(condition)
                       for condition in task['ansible.builtin.assert']['that']]
        for value, expected in [('', False), ('  ', False), ('\n', False), ('first\nsecond', False),
                                ('first\rsecond', False), ('first\x00second', False), ('synthetic\n', True),
                                ('synthetic\n\n', False), ('x' * 4097, False), ('é' * 2049, False),
                                ('synthetic-test-value', True)]:
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
                self.assertIn('Require the exact provisioned root-SSH candidate', result.stdout)
                self.assertNotIn('TASK [Read minimal', result.stdout)

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
