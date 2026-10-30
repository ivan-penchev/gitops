# Talos and Kubernetes versions

Each cluster keeps its versions in `terraform/clusters/<name>/talos-versions.tfvars`, tracked in Git. `terraform/tf.sh` passes it as a `-var-file`. The commands below use `homelab-prd`.

Renovate watches the `siderolabs/talos` and `kubernetes/kubernetes` GitHub releases. Each new release gets its own PR with the `manual-upgrade` label. Patch and minor bumps come as separate PRs, so a Talos minor jump has a patch PR to land first. Renovate never automerges these.

## What merging does

Nothing on the running nodes changes. The next `terraform/tf.sh homelab-prd apply` will:

- download the new Talos ISO and delete the old one. VMs ignore cdrom changes, so eject the ISO first, see step 6 below
- change the installer image and Kubernetes version in the machine configs

The machine configs keep their format. `talos_config_contract` in the same file sets the format, and Renovate never touches it.

A running node only upgrades its OS when you run `talosctl upgrade`. Kubernetes only upgrades when you run `talosctl upgrade-k8s`. The live PR test doesn't cover either.

The `talos-docker-test` workflow runs on these PRs. It boots the cluster's Talos version, contract, cluster patch and Cilium manifest in Docker, at the base branch's Kubernetes version. If the PR changes `kubernetes_version`, it runs `upgrade-k8s` to the new one and checks again. It can't test `talosctl upgrade`, the ISO or Proxmox.

## Config contract

`talos_version` picks the installer image and the ISO. `talos_config_contract`, for example `v1.13`, picks the format the Talos provider generates for the machine configs and the secrets. Keep it at the minor version the cluster was created with.

Talos 1.14 shows why. With a `v1.14` contract, provider 0.12 splits the config into new documents such as `KubeNodeConfig` and `UnattendedInstallConfig`. It also adds `SecurityProfileConfig` with `workloadIsolation: true`. Talos leaves workload isolation off on upgraded clusters, so raising the contract turns it on for the first time. Provider 0.11 ignores contracts above `v1.13`, which hid this until the provider bump.

Raise the contract as its own change. Read the new config format first, check that `talos/patches/*` still apply, and test it on a staging cluster.

Use the talosctl that matches the target Talos version. The Nix-managed one can lag behind.

## Upgrade order

Upgrade with talosctl first, then merge the PR and apply. If you apply first, Terraform pushes the new Kubernetes version straight into the machine config, and that skips the checks `upgrade-k8s` runs.

1. Check that `talosctl health` passes, then take an etcd snapshot:

   ```sh
   talosctl --talosconfig talosconfig -n <cp-ip> etcd snapshot ~/talos-backups/<cluster>-etcd-$(date +%Y%m%d-%H%M).db
   ```

2. Read the release notes. For Kubernetes, check the [Talos support matrix](https://www.talos.dev/latest/introduction/support-matrix/) and the Cilium compatibility list in `docs/cilium-upgrade.md`.
3. Talos, workers first, then control planes, one node at a time. Wait for `talosctl health` to pass before you move to the next node. With a single control plane the Kubernetes API is down while that node reboots. On homelab-prd that took about two minutes:

   ```sh
   talosctl --talosconfig talosconfig -n <node-ip> upgrade \
     --image factory.talos.dev/installer/<schematic-id>:<new-version> --wait --timeout 20m
   talosctl --talosconfig talosconfig -n <node-ip> health
   ```

4. Kubernetes, run against one control-plane node. It rolls the whole cluster:

   ```sh
   talosctl --talosconfig talosconfig -n <cp-ip> upgrade-k8s --to <new-version> --dry-run
   talosctl --talosconfig talosconfig -n <cp-ip> upgrade-k8s --to <new-version>
   ```

5. Check the cluster. Every node should report the new version, and Flux should be green:

   ```sh
   talosctl --talosconfig talosconfig -n <node-ips> version | grep Tag
   kubectl get nodes
   kubectl get pods -A | grep -vE 'Running|Completed'
   flux get ks -A; flux get hr -A
   ```

   Pods that talk to the API can crash while the control plane reboots and then sit in back-off. After the 1.13.12 upgrade the proxmox-csi controller logged `dial tcp 10.96.0.1:443: connect: no route to host` and blocked `infrastructure-controllers` and everything after it. Deleting the pod fixed it.

6. Eject the ISO from every VM of the cluster. The ISO file name carries the Talos version, so the apply deletes the old file, and Proxmox can refuse to start a VM whose cdrom points at a missing file. Terraform ignores cdrom changes, so this does not show up in the plan:

   ```sh
   curl -sk -X PUT -H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN" \
     --data-urlencode "ide2=none,media=cdrom" \
     "$PROXMOX_VE_ENDPOINT/api2/json/nodes/<node>/qemu/<vmid>/config"
   ```

7. Merge the Renovate PR, then run `terraform/tf.sh homelab-prd plan`. Expect in-place updates to `talos_machine_configuration_apply` and a replaced `proxmox_download_file.talos_iso`. No VM should be replaced, and `talos_machine_secrets` must not change. Stop if it does. Apply.
