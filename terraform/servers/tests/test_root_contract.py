"""Offline structural checks for boundaries not observable in a mock plan."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class RootContract(unittest.TestCase):
    def test_only_standalone_proxmox_resources(self):
        source = "\n".join(path.read_text() for path in ROOT.glob("*.tf"))
        resources = re.findall(r'^resource\s+"([^"]+)"\s+"([^"]+)"', source, re.M)
        self.assertCountEqual(resources, [
            ("proxmox_download_file", "debian"),
            ("proxmox_virtual_environment_file", "cloud_init"),
            ("proxmox_virtual_environment_vm", "pihole"),
        ])
        self.assertNotRegex(source, r'(?m)^\s*(data|module|import)\s+["{]')
        self.assertNotRegex(source, r'(?m)^\s*provisioner\s+"')
        self.assertNotRegex(source, r'\b(file|filebase64)\s*\(')
        self.assertNotIn("terraform_remote_state", source)
        self.assertNotIn('provider "kubernetes"', source)
        self.assertNotIn('provider "cloudflare"', source)

    def test_backend_is_separate_and_locked(self):
        backend = (ROOT / "backend.tf").read_text()
        self.assertRegex(backend, r'key\s*=\s*"homelab/servers\.tfstate"')
        self.assertRegex(backend, r'use_lockfile\s*=\s*true')
        for sibling in ("shared", "cluster"):
            self.assertNotIn('"homelab/servers.tfstate"',
                             (ROOT.parent / sibling / "backend.tf").read_text())

    def test_vm_cannot_be_destroyed_or_multiplied(self):
        source = (ROOT / "main.tf").read_text()
        vm = source.split('resource "proxmox_virtual_environment_vm" "pihole" {', 1)[1]
        self.assertRegex(vm, r'lifecycle\s*\{\s*prevent_destroy\s*=\s*true\s*\}')
        self.assertNotRegex(vm, r'\b(count|for_each|clone)\s*[={]')
        self.assertNotIn("proxmox_virtual_environment_container", source)
        self.assertRegex(vm, r'import_from\s*=\s*proxmox_download_file\.debian\.id')
        self.assertRegex(vm, r'user_data_file_id\s*=\s*proxmox_virtual_environment_file\.cloud_init\.id')
        self.assertRegex(vm, r'servers\s*=\s*var\.network\.dns_servers')

    def test_deployment_identity_has_no_defaults(self):
        source = (ROOT / "variables.tf").read_text()
        for name in ("vm_id", "network", "ssh_public_key", "proxmox_node",
                     "vm_datastore", "image_datastore", "snippet_datastore",
                     "network_bridge", "proxmox_ssh_address", "proxmox_ssh_username",
                     "debian_image_url", "debian_image_sha256"):
            body = source.split(f'variable "{name}" {{', 1)[1].split('\nvariable "', 1)[0]
            self.assertNotRegex(body, r'(?m)^\s*default\s*=')

    def test_only_identity_output(self):
        source = (ROOT / "outputs.tf").read_text()
        self.assertEqual(re.findall(r'^output "([^"]+)"', source, re.M), ["ansible_inventory"])
        self.assertRegex(source, r'sensitive\s*=\s*false')
        self.assertNotRegex(source, r'(?i)(image|password|ssh_public_key|api_token)')

    def test_mock_tests_never_use_real_provider(self):
        source = (ROOT / "tests/servers.tftest.hcl").read_text()
        self.assertIn('mock_provider "proxmox" {}', source)
        self.assertNotRegex(source, r'command\s*=\s*apply')
        self.assertNotIn('provider "proxmox" {', source.replace('mock_provider "proxmox" {}', ''))


if __name__ == "__main__":
    unittest.main()
