import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("pihole_workflow", Path(__file__).resolve().parents[1] / "pihole.py")
workflow = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workflow)


def inventory():
    return {"all": {"children": {"pihole": {"hosts": {"dns_candidate": {
        "ansible_host": "10.77.0.10", "ansible_user": "operator",
        "pihole_dns_bind": "10.77.0.10", "pihole_trusted_cidr": "10.77.0.0/24",
        "pihole_provisioned_by": "terraform/servers",
    }}}}}}


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / ".venv/bin").mkdir(parents=True)
        (self.root / ".venv/bin/ansible-playbook").touch()
        self.settings = self.root / "settings.json"
        self.settings.write_text(json.dumps({"pihole_image": "test-pin"}))
        self.password = self.root / "password"
        self.password.write_text("never-in-terraform-or-arguments\n")
        self.password.chmod(0o600)
        self.calls = []
        self.extra = []
        self.fail = None
        self.inv = inventory()
        self.addCleanup(patch.stopall)
        patch.object(workflow, "ANSIBLE", self.root).start()
        patch.object(workflow, "run", side_effect=self.execute).start()

    def execute(self, args, *, capture=False):
        self.calls.append(args)
        if self.fail and self.fail in args:
            raise subprocess.CalledProcessError(1, args)
        if "-e" in args:
            paths = [arg[1:] for arg in args if arg.startswith("@") and arg.endswith("settings.json")]
            self.extra.append(json.loads(Path(paths[0]).read_text()))
            inv = Path(args[args.index("-i") + 1])
            self.assertEqual(json.loads(inv.read_text()), inventory())
            self.assertEqual(inv.stat().st_mode & 0o777, 0o600)
            self.assertEqual(inv.parent.stat().st_mode & 0o777, 0o700)
        return subprocess.CompletedProcess(args, 0, json.dumps(self.inv) if capture else None)

    def invoke(self, command, *extra):
        workflow.main([command, "--settings", str(self.settings), *extra])

    def test_apply_provisions_then_prepares_and_configures(self):
        self.invoke("apply", "--password-file", str(self.password))
        self.assertEqual(self.calls[0][2:], ["apply", "-input=true"])
        self.assertEqual(self.calls[1][2:], ["output", "-json", "ansible_inventory"])
        self.assertEqual([args[-1] for args in self.calls[2:]],
                         ["playbooks/ready.yml", "playbooks/prepare.yml", "playbooks/configure.yml"])
        self.assertNotIn("auto-approve", str(self.calls))
        self.assertNotIn(self.password.read_text().strip(), str(self.calls) + str(self.extra))
        self.assertNotIn(str(self.password), str(self.calls[:2]))
        self.assertFalse(list(self.root.glob(".pihole-run-*")))
        self.assertEqual(self.extra[-1]["pihole_password_source"], str(self.password))

    def test_configure_never_applies_or_bootstraps(self):
        self.invoke("configure", "--password-file", str(self.password))
        self.assertEqual(self.calls[0][2:], ["output", "-json", "ansible_inventory"])
        self.assertFalse(any("apply" in args or "playbooks/prepare.yml" in args for args in self.calls))
        self.assertIn("ansible_ssh_common_args=-o StrictHostKeyChecking=yes", self.calls[-1])
        self.assertIn("@" + str(self.root / "group_vars/pihole.yml"), self.calls[-1])

    def test_check_does_not_need_password_or_bootstrap(self):
        self.invoke("check")
        self.assertEqual(self.calls[-1][-3:], ["playbooks/configure.yml", "--check", "--diff"])
        self.assertNotIn("pihole_password_source", self.extra[-1])

    def test_maintenance_is_explicit_and_not_in_terraform(self):
        maintenance = self.root / "maintenance.json"
        maintenance.write_text(json.dumps({"pihole_backup_validated": True, "pihole_peer_health_validated": True,
                                           "pihole_maintenance_evidence": "2026-11-07 restored backup; peer TCP/UDP passed"}))
        self.invoke("configure", "--password-file", str(self.password), "--maintenance-file", str(maintenance))
        self.assertTrue(self.extra[-1]["pihole_backup_validated"])
        self.assertNotIn("pihole_backup_validated", str(self.calls[0]))

    def test_failures_stop_pipeline_and_clean_inventory(self):
        for failure in ("apply", "output", "playbooks/ready.yml", "playbooks/prepare.yml", "playbooks/configure.yml"):
            with self.subTest(failure=failure):
                self.calls.clear()
                self.fail = failure
                with self.assertRaises(subprocess.CalledProcessError):
                    self.invoke("apply", "--password-file", str(self.password))
                self.assertIn(failure, self.calls[-1])
                self.assertFalse(list(self.root.glob(".pihole-run-*")))

    def test_reject_inventory_before_ssh(self):
        self.inv["all"]["children"]["pihole"]["hosts"]["dns_candidate"]["ansible_host"] = "192.168.68.20"
        with self.assertRaises(ValueError):
            self.invoke("check")
        self.assertEqual(len(self.calls), 1)

    def test_settings_cannot_override_identity_or_maintenance(self):
        for key in ("ansible_host", "pihole_target", "pihole_dns_bind", "pihole_backup_validated", "ansible_ssh_common_args"):
            self.settings.write_text(json.dumps({key: "untrusted"}))
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.invoke("apply", "--password-file", str(self.password))
        self.assertEqual(self.calls, [])

    def test_unsafe_password_rejected_before_apply(self):
        self.password.chmod(0o644)
        with self.assertRaises(ValueError):
            self.invoke("apply", "--password-file", str(self.password))
        self.assertEqual(self.calls, [])

    def test_password_symlink_rejected_before_apply(self):
        link = self.root / "password-link"
        link.symlink_to(self.password)
        with self.assertRaises(ValueError):
            self.invoke("apply", "--password-file", str(link))
        self.assertEqual(self.calls, [])

    def test_missing_password_rejected_before_apply(self):
        with self.assertRaises(SystemExit):
            self.invoke("apply")
        self.assertEqual(self.calls, [])

    def test_backend_file_path_resolved_before_chdir(self):
        workflow.main(["init", "--backend-config", "terraform/servers/backend.local.hcl"])
        self.assertIn(f"-backend-config={Path('terraform/servers/backend.local.hcl').resolve()}", self.calls[-1])

    def test_plan_and_init_only_invoke_terraform(self):
        workflow.main(["plan", "--var-file", str(self.root / "inputs.tfvars")])
        self.assertIn("-input=false", self.calls[-1])
        self.assertIn(f"-var-file={self.root}/inputs.tfvars", self.calls[-1])
        workflow.main(["init", "--backend-config=bucket=servers-state"])
        self.assertEqual(self.calls[-1][2:], ["init", "-input=false", "-backend-config=bucket=servers-state"])
        self.assertEqual(len(self.calls), 2)


class InventoryContractTests(unittest.TestCase):
    def test_valid_contract_and_discard_unexpected_groups(self):
        data = inventory()
        data["all"]["vars"] = {"ansible_connection": "local"}
        data["all"]["children"]["unrelated"] = {"hosts": {"danger": {}}}
        self.assertEqual(workflow.validate_inventory(data), inventory())

    def test_reject_unsafe_identity(self):
        changes = [
            {"ansible_host": "192.168.68.20", "pihole_dns_bind": "192.168.68.20", "pihole_trusted_cidr": "192.168.68.0/24"},
            {"ansible_host": "192.0.2.10", "pihole_dns_bind": "192.0.2.10", "pihole_trusted_cidr": "192.0.2.0/24"},
            {"ansible_user": "root"}, {"pihole_provisioned_by": "terraform/cluster"},
            {"ansible_host": "10.77.0.0", "pihole_dns_bind": "10.77.0.0"},
            {"ansible_connection": "local"}, {"pihole_dns_bind": "10.77.0.11"},
        ]
        for change in changes:
            data = inventory()
            data["all"]["children"]["pihole"]["hosts"]["dns_candidate"].update(change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                workflow.validate_inventory(data)

    def test_reject_multiple_targets(self):
        data = inventory()
        hosts = data["all"]["children"]["pihole"]["hosts"]
        hosts["peer"] = copy.deepcopy(hosts["dns_candidate"])
        with self.assertRaises(ValueError):
            workflow.validate_inventory(data)

    def test_transport_forces_config_and_host_checking(self):
        with patch.dict(os.environ, {"ANSIBLE_HOST_KEY_CHECKING": "False"}), patch.object(subprocess, "run") as execute:
            workflow.run(["ansible-playbook", "play.yml"])
        self.assertEqual(execute.call_args.kwargs["env"]["ANSIBLE_HOST_KEY_CHECKING"], "True")
        self.assertEqual(execute.call_args.kwargs["env"]["ANSIBLE_CONFIG"], str(workflow.ANSIBLE / "ansible.cfg"))


if __name__ == "__main__":
    unittest.main()
