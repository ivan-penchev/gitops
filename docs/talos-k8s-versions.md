# Talos and Kubernetes versions

Both versions live in `terraform/talos-versions.auto.tfvars`, which is tracked in Git. Terraform loads it automatically and it overrides `terraform.tfvars`, so don't set the versions there.

Renovate watches the `siderolabs/talos` and `kubernetes/kubernetes` GitHub releases. Each new release gets its own PR with the `manual-upgrade` label. Patch and minor bumps come as separate PRs, so a Talos minor jump has a patch PR to land first. Renovate never automerges these.

## What merging does

Nothing on the running nodes changes. The next `terraform apply` will:

- download the new Talos ISO (VMs ignore cdrom changes, so they keep the old one)
- change the installer image and Kubernetes version in the machine configs

A running node only upgrades its OS when you run `talosctl upgrade`. Kubernetes only upgrades when you run `talosctl upgrade-k8s`. The live PR test doesn't cover either.

## Upgrade order

Upgrade with talosctl first, then merge the PR and apply. If you apply first, Terraform pushes the new Kubernetes version straight into the machine config, and that skips the checks `upgrade-k8s` runs.

1. Read the release notes. For Kubernetes, check the [Talos support matrix](https://www.talos.dev/latest/introduction/support-matrix/) and the Cilium compatibility list in `docs/cilium-upgrade.md`.
2. Talos, one node at a time. Wait for `talosctl health` to pass before you move to the next node:

   ```sh
   talosctl --talosconfig talosconfig -n <node-ip> upgrade \
     --image factory.talos.dev/installer/<schematic-id>:<new-version>
   talosctl --talosconfig talosconfig -n <node-ip> health
   ```

3. Kubernetes, run against one control-plane node. It rolls the whole cluster:

   ```sh
   talosctl --talosconfig talosconfig -n <cp-ip> upgrade-k8s --to <new-version> --dry-run
   talosctl --talosconfig talosconfig -n <cp-ip> upgrade-k8s --to <new-version>
   ```

4. Merge the Renovate PR, then run `terraform plan`. Expect in-place updates to `talos_machine_configuration_apply` and a replaced `proxmox_download_file.talos_iso`. No VM should be replaced. Apply.
