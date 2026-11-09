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
            ("proxmox_virtual_environment_container", "pihole"),
        ])
        self.assertNotRegex(source, r'(?m)^\s*(data|module|import)\s+["{]')
        self.assertNotRegex(source, r'(?m)^\s*provisioner\s+"')
        self.assertNotRegex(source, r'\b(file|filebase64)\s*\(')
        self.assertNotIn("terraform_remote_state", source)
        self.assertNotIn('provider "kubernetes"', source)
        self.assertNotIn('provider "cloudflare"', source)

    def test_api_only_without_host_ssh_or_snippets(self):
        source = "\n".join(path.read_text() for path in ROOT.glob("*.tf"))
        self.assertNotRegex(source, r'(?m)^\s*ssh\s*\{')
        self.assertNotRegex(source, r'\b(proxmox_ssh_\w+|snippet_datastore|SSH_AUTH_SOCK)\b')
        self.assertNotIn("proxmox_virtual_environment_file", source)
        self.assertNotRegex(source, r'\b(source_raw|cloud_config|runcmd|packages)\s*[={]')
        self.assertNotRegex(source, r'\b(password|private_key|file_id|\w+_data_file_id)\s*=')

    def test_backend_is_separate_and_locked(self):
        backend = (ROOT / "backend.tf").read_text()
        self.assertRegex(backend, r'key\s*=\s*"homelab/servers\.tfstate"')
        self.assertRegex(backend, r'use_lockfile\s*=\s*true')
        self.assertNotRegex(backend, r'key\s*=\s*"homelab/(shared|cluster)[^"]*"')

    def test_container_cannot_be_destroyed_or_privileged(self):
        source = (ROOT / "main.tf").read_text()
        container = source.split('resource "proxmox_virtual_environment_container" "pihole" {', 1)[1]
        self.assertRegex(container, r'lifecycle\s*\{\s*prevent_destroy\s*=\s*true\s*\}')
        self.assertNotRegex(container, r'(?m)^  (count|for_each|clone)\s*[={]')
        self.assertNotIn("proxmox_virtual_environment_vm", source)
        self.assertRegex(container, r'template_file_id\s*=\s*proxmox_download_file\.debian\.id')
        self.assertNotRegex(container, r'\b(idmap|mount_point|device_passthrough|hook_script_file_id|entrypoint|environment_variables)\s*[={]')
        self.assertRegex(container, r'unprivileged\s*=\s*true')
        self.assertRegex(container, r'servers\s*=\s*var\.network\.dns_servers')
        for feature in ("nesting", "keyctl", "fuse", "mknod"):
            self.assertRegex(container, rf'{feature}\s*=\s*false')

    def test_deployment_identity_has_no_defaults(self):
        source = (ROOT / "variables.tf").read_text()
        for name in ("vm_id", "network", "ssh_public_key", "proxmox_node",
                     "rootfs_datastore", "template_datastore",
                     "network_bridge", "proxmox_host_ipv4",
                     "debian_template_url", "debian_template_sha256"):
            body = source.split(f'variable "{name}" {{', 1)[1].split('\nvariable "', 1)[0]
            self.assertNotRegex(body, r'(?m)^\s*default\s*=')

    def test_only_identity_output(self):
        source = (ROOT / "outputs.tf").read_text()
        self.assertEqual(re.findall(r'^output "([^"]+)"', source, re.M), ["ansible_inventory"])
        self.assertRegex(source, r'sensitive\s*=\s*false')
        self.assertNotRegex(source, r'(?i)(image|password|ssh_public_key|api_token)')

    def test_dhcp_inventory_is_fail_closed(self):
        source = (ROOT / "outputs.tf").read_text()
        self.assertRegex(source, r'value\s*=\s*var\.bootstrap_dhcp\s*\?\s*null\s*:')
        variables = (ROOT / "variables.tf").read_text()
        body = variables.split('variable "bootstrap_dhcp" {', 1)[1].split('\n}', 1)[0]
        self.assertRegex(body, r'type\s*=\s*bool')
        self.assertRegex(body, r'default\s*=\s*false')
        self.assertRegex(body, r'nullable\s*=\s*false')

    def test_mock_tests_never_use_real_provider(self):
        source = (ROOT / "tests/servers.tftest.hcl").read_text()
        self.assertIn('mock_provider "proxmox" {}', source)
        self.assertNotRegex(source, r'command\s*=\s*apply')
        self.assertNotIn('provider "proxmox" {', source.replace('mock_provider "proxmox" {}', ''))


if __name__ == "__main__":
    unittest.main()
