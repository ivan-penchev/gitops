import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("native_probe", Path(__file__).resolve().parents[1] / "files/probe.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class ListenerTests(unittest.TestCase):
    def listeners(self, rows, port=80):
        with patch.object(probe.Path, "is_symlink", return_value=False), \
             patch.object(probe.Path, "is_file", return_value=False), \
             patch.object(probe.Path, "exists", return_value=False), \
             patch.object(probe.os.path, "lexists", return_value=False), \
             patch.object(probe.pwd, "getpwnam", side_effect=KeyError), \
             patch.object(probe.grp, "getgrnam", side_effect=KeyError), \
             patch.object(probe, "run", return_value=""), \
             patch.object(probe, "required", side_effect=['[]', rows]):
            return probe.probe("10.77.0.10", "eth0", port)["listeners"]

    def test_dhcp_client_does_not_conflict_with_dns_only_install(self):
        rows = 'udp UNCONN 0 0 0.0.0.0:68 0.0.0.0:* users:(("dhclient",pid=185,fd=7))'
        self.assertEqual(self.listeners(rows), [])

    def test_dhcp_server_and_other_conflicting_ports_are_still_detected(self):
        for port in (53, 67, 123, 80, 443, 8080):
            with self.subTest(port=port):
                rows = f'udp UNCONN 0 0 0.0.0.0:{port} 0.0.0.0:* users:(("other",pid=185,fd=7))'
                self.assertEqual(self.listeners(rows, port=8080), [{"address": "0.0.0.0", "port": port, "owned": False}])

    def test_only_explicit_local_and_lan_web_bindings_are_owned(self):
        for port in (80, 8080):
            for address in ('127.0.0.1', '10.77.0.10', '0.0.0.0', '[::]', '10.77.0.11'):
                with self.subTest(port=port, address=address):
                    rows = f'tcp LISTEN 0 200 {address}:{port} 0.0.0.0:* users:(("pihole-FTL",pid=185,fd=7))'
                    owned = address in ('127.0.0.1', '10.77.0.10')
                    self.assertEqual(self.listeners(rows, port), [{"address": address.strip('[]'), "port": port, "owned": owned}])


if __name__ == "__main__":
    unittest.main()
