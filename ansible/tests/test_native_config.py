import base64
import ctypes
import hashlib
import importlib.util
import os
from pathlib import Path
import stat
import tempfile
import types
import unittest
from unittest.mock import patch

import tomlkit

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('native_config', ROOT / 'library/pihole_native_config.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


class NativeConfigTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir=ROOT)
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'pihole.toml'

    def synthetic_hash(self, password, salt):
        # Tests idempotence/serialization only, never used to configure a real guest.
        return hashlib.sha256(salt + password).digest()

    def test_nettle_binding_matches_upstream_abi_and_ftl_parameters(self):
        calls = []
        def calculate(*args):
            calls.append(args[:6])
            ctypes.memmove(args[-1], b'x' * 32, 32)
        class Function:
            def __init__(self, callback):
                self.callback = callback
            def __call__(self, *args):
                return self.callback(*args)
        library = types.SimpleNamespace(
            nettle_balloon_itch=Function(lambda digest, space: (space + 1) * digest),
            nettle_balloon_sha256=Function(calculate))
        with patch.object(native.ctypes.util, 'find_library', return_value='synthetic'), \
             patch.object(native.ctypes, 'CDLL', return_value=library):
            self.assertEqual(native.balloon(b'test', b's' * 16), b'x' * 32)
        self.assertEqual(calls, [(1024, 32, 4, b'test', 16, b's' * 16)])
        self.assertEqual(library.nettle_balloon_sha256.argtypes[3], ctypes.c_void_p)

    def test_missing_nettle_fails_closed(self):
        with patch.object(native.ctypes.util, 'find_library', return_value=None), self.assertRaises(ValueError):
            native.balloon(b'test', b's' * 16)

    def test_native_hash_is_salted_preserved_and_rotated(self):
        with patch.object(native, 'balloon', side_effect=self.synthetic_hash):
            first = native.password_hash(b'synthetic', '')
            self.assertRegex(first, native.PHC)
            self.assertEqual(native.password_hash(b'synthetic', first), first)
            self.assertNotEqual(native.password_hash(b'changed', first), first)
            self.assertNotEqual(native.password_hash(b'synthetic', ''), first)
            fields = native.PHC.fullmatch(first)
            self.assertEqual(len(base64.b64decode(fields[1])), 16)
            self.assertEqual(len(base64.b64decode(fields[2])), 32)

    def test_malformed_hash_fails_closed(self):
        with self.assertRaises(ValueError):
            native.password_hash(b'example', '$BALLOON-SHA256$v=1$s=1024,t=32$bad$bad')

    def test_nested_merge_preserves_policy_and_has_a_true_noop(self):
        document = tomlkit.parse('# existing\n[dns]\nupstreams = ["9.9.9.9"]\n[webserver.api]\nmax_sessions = 20\n')
        settings = {'dns.upstreams': ['1.1.1.1'], 'ntp.ipv4.active': False, 'webserver.port': '127.0.0.1:8080'}
        with patch.object(native, 'balloon', side_effect=self.synthetic_hash):
            self.assertTrue(native.merge(document, settings, b'synthetic'))
            rendered = tomlkit.dumps(document)
            self.assertFalse(native.merge(document, settings, b'synthetic'))
            self.assertEqual(rendered, tomlkit.dumps(document))
        parsed = tomlkit.parse(rendered)
        self.assertEqual(parsed['webserver']['api']['max_sessions'], 20)
        self.assertFalse(parsed['ntp']['ipv4']['active'])
        self.assertIn('# existing', rendered)
        self.assertNotIn('synthetic', rendered)

    def test_plaintext_pseudo_property_is_removed(self):
        document = tomlkit.parse('[webserver.api]\npassword="old-sensitive"\n')
        with patch.object(native, 'balloon', side_effect=self.synthetic_hash):
            native.merge(document, {}, b'synthetic')
        self.assertNotIn('password', document['webserver']['api'])
        self.assertNotIn('old-sensitive', tomlkit.dumps(document))

    def test_atomic_write_and_unchanged_target_on_failure(self):
        self.path.write_text('original')
        native.atomic_write(self.path, 'replacement', os.getuid(), os.getgid())
        self.assertEqual(self.path.read_text(), 'replacement')
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o640)
        with patch.object(native.os, 'replace', side_effect=OSError('synthetic failure')), self.assertRaises(OSError):
            native.atomic_write(self.path, 'unsafe partial', os.getuid(), os.getgid())
        self.assertEqual(self.path.read_text(), 'replacement')
        self.assertFalse(self.path.with_name('.pihole.toml.ansible-new').exists())

    def test_existing_staging_file_is_not_overwritten_or_deleted(self):
        stage = self.path.with_name('.pihole.toml.ansible-new')
        stage.write_text('previous failure')
        with self.assertRaises(FileExistsError):
            native.atomic_write(self.path, 'replacement', os.getuid(), os.getgid())
        self.assertEqual(stage.read_text(), 'previous failure')

    def test_private_file_content_and_metadata_guards(self):
        real_fstat = os.fstat
        def root_stat(fd):
            info = real_fstat(fd)
            return types.SimpleNamespace(st_mode=info.st_mode, st_uid=0)
        with patch.object(native.os, 'fstat', side_effect=root_stat):
            for value, valid in ((b'one line\n', True), (b' spaces preserved ', True), (b'', False),
                                 (b'\n', False), (b'a\nb', False), (b'a\rb', False), (b'a\0b', False),
                                 (b'x' * 4097, False), (b'x' * 4096 + b'\nignored', False)):
                self.path.write_bytes(value)
                self.path.chmod(0o600)
                if valid:
                    self.assertEqual(native.read_password(self.path), value.removesuffix(b'\n'))
                else:
                    with self.assertRaises(ValueError):
                        native.read_password(self.path)
            self.path.write_bytes(b'synthetic')
            self.path.chmod(0o644)
            with self.assertRaises(ValueError):
                native.read_password(self.path)

    def test_changed_config_cannot_write_after_a_noop_preview(self):
        self.path.write_text('[dns]\nport=53\n')
        result = {}
        def failure(**kwargs):
            result.update(kwargs)
            raise SystemExit
        module = types.SimpleNamespace(params={'settings': {'dns.port': 54},
            'password_file': 'unused', 'write_allowed': False}, check_mode=False, fail_json=failure)
        with patch.object(native, 'AnsibleModule', return_value=module), \
             patch.object(native, 'Path', return_value=self.path), \
             patch.object(native, 'read_password', return_value=b'synthetic'), \
             patch.object(native, 'balloon', side_effect=self.synthetic_hash), \
             patch.object(native, 'atomic_write') as writer, self.assertRaises(SystemExit):
            native.main()
        writer.assert_not_called()
        self.assertIn('without disclosing contents', result['msg'])

    def test_symlinked_password_is_never_followed(self):
        self.path.write_text('synthetic')
        link = self.path.with_name('link')
        link.symlink_to(self.path)
        with self.assertRaises(OSError):
            native.read_password(link)


if __name__ == '__main__':
    unittest.main()
