#!/usr/bin/env python3
"""Provision a separate Pi-hole LXC, then configure its Terraform-derived target."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ANSIBLE = Path(__file__).resolve().parent
SERVERS = ANSIBLE.parent / "terraform" / "servers"
ALIAS = "dns_candidate"
SETTINGS = {
    "pihole_core_version", "pihole_core_commit", "pihole_installer_sha256",
    "pihole_web_version", "pihole_web_commit", "pihole_ftl_version", "pihole_ftl_sha256", "pihole_interface", "pihole_upstreams", "pihole_peer_addresses",
    "pihole_timezone", "pihole_ui_port", "pihole_local_hosts", "pihole_local_cnames",
    "pihole_verify_external", "pihole_verify_local_name", "pihole_verify_local_address",
    "pihole_verify_blocked_name",
}
MAINTENANCE = {
    "pihole_backup_validated", "pihole_peer_health_validated", "pihole_maintenance_evidence",
}


def run(args, *, capture=False):
    environment = os.environ.copy()
    environment.update(ANSIBLE_CONFIG=str(ANSIBLE / "ansible.cfg"), ANSIBLE_HOST_KEY_CHECKING="True")
    return subprocess.run(args, cwd=ANSIBLE, check=True, text=True, env=environment,
                          stdout=subprocess.PIPE if capture else None)


def load_settings(path, allowed):
    values = json.loads(path.read_text())
    if not isinstance(values, dict) or set(values) - allowed:
        raise ValueError(f"{path}: expected an object with only approved settings: {sorted(allowed)}")
    return values


def validate_inventory(inventory):
    try:
        hosts = inventory["all"]["children"]["pihole"]["hosts"]
        host = hosts[ALIAS]
        ip = ipaddress.IPv4Address(host["ansible_host"])
        network = ipaddress.IPv4Network(host["pihole_trusted_cidr"], strict=True)
        allowed = {"ansible_host", "ansible_user", "pihole_dns_bind", "pihole_trusted_cidr", "pihole_provisioned_by"}
        private = [ipaddress.IPv4Network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")]
        if (set(hosts) != {ALIAS} or set(host) != allowed
                or host["ansible_user"] != "root"
                or host["pihole_provisioned_by"] != "terraform/servers"
                or str(ip) != host["pihole_dns_bind"]
                or ip not in network or ip in (network.network_address, network.broadcast_address)
                or str(ip) == "192.168.68.20"
                or not any(network.subnet_of(n) for n in private)):
            raise ValueError("Unsafe or unexpected Terraform inventory")
    except (KeyError, TypeError, ipaddress.AddressValueError, ipaddress.NetmaskValueError) as exc:
        raise ValueError("Invalid Terraform inventory contract") from exc
    # Rebuild rather than trust extra groups, vars or connection settings in state.
    return {"all": {"children": {"pihole": {"hosts": {ALIAS: host}}}}}


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("command", choices=("init", "plan", "apply", "configure", "check", "inspect", "verify"))
    result.add_argument("--var-file", type=Path, help="Terraform inputs, used only by plan/apply")
    result.add_argument("--backend-config", action="append", default=[], help="Terraform init backend setting or file")
    result.add_argument("--settings", type=Path, help="Reviewed non-secret Pi-hole JSON settings")
    result.add_argument("--password-file", type=Path, help="Private controller password file; never passed to Terraform")
    result.add_argument("--maintenance-file", type=Path, help="Current backup/peer attestations as JSON")
    return result


def main(argv=None):
    cli = parser()
    args = cli.parse_args(argv)
    if args.var_file and args.command not in ("plan", "apply"):
        cli.error("--var-file is only for plan/apply; configuration reads existing Terraform state")
    if args.backend_config and args.command != "init":
        cli.error("--backend-config is only for init")
    tf = ["terraform", f"-chdir={SERVERS}"]
    if args.command == "init":
        backend = [value if "=" in value else str(Path(value).resolve()) for value in args.backend_config]
        run(tf + ["init", "-input=false"] + [f"-backend-config={value}" for value in backend])
        return
    tfvars = [f"-var-file={args.var_file.resolve()}"] if args.var_file else []
    if args.command == "plan":
        run(tf + ["plan", "-input=false"] + tfvars)
        return
    if not args.settings:
        cli.error("--settings is required for configuration and verification")
    settings = load_settings(args.settings, SETTINGS)
    if args.maintenance_file:
        settings.update(load_settings(args.maintenance_file, MAINTENANCE))
    if args.command in ("apply", "configure"):
        if not args.password_file:
            cli.error("--password-file is required for apply/configure")
        password = args.password_file.absolute()
        stat = password.lstat()
        if password.is_symlink() or not password.is_file() or stat.st_mode & 0o777 not in (0o400, 0o600) or stat.st_size == 0:
            raise ValueError("Password must be a nonempty regular private file (0400 or 0600), not a symlink")
        settings["pihole_password_source"] = str(password)
    playbook = ANSIBLE / ".venv/bin/ansible-playbook"
    if not playbook.is_file():
        raise ValueError("Install ansible/requirements.txt into ansible/.venv first (see README)")
    if args.command == "apply":
        # Terraform retains its interactive approval. No auto-approve or hidden apply.
        run(tf + ["apply", "-input=true"] + tfvars)
    inventory = validate_inventory(json.loads(run(tf + ["output", "-json", "ansible_inventory"], capture=True).stdout))
    settings["pihole_target"] = ALIAS
    # Explicitly load group_vars below: the temporary inventory lives in its own directory.
    with tempfile.TemporaryDirectory(prefix=".pihole-run-", dir=ANSIBLE) as scratch:
        directory = Path(scratch)
        inv = directory / "inventory.json"
        extra = directory / "settings.json"
        inv.write_text(json.dumps(inventory))
        extra.write_text(json.dumps(settings))
        os.chmod(inv, 0o600)
        os.chmod(extra, 0o600)
        base = [str(playbook), "-i", str(inv), "--limit", ALIAS,
                "-e", "@" + str(ANSIBLE / "group_vars/pihole.yml"), "-e", "@" + str(extra)]
        # Force trusted-key checking even if the controller environment disables it.
        base += ["-e", json.dumps({"ansible_ssh_common_args": "-o StrictHostKeyChecking=yes"})]
        run(base + ["playbooks/ready.yml"])
        if args.command == "apply":
            run(base + ["playbooks/prepare.yml"])
        selected = "configure" if args.command in ("apply", "check") else args.command
        flags = ["--check", "--diff"] if args.command == "check" else []
        run(base + [f"playbooks/{selected}.yml"] + flags)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Pi-hole workflow stopped: {error}", file=sys.stderr)
        sys.exit(1)
