locals {
  # All nodes merged for uniform VM creation, tagged with their Talos role.
  nodes = merge(
    { for k, v in var.control_planes : k => merge(v, { role = "controlplane" }) },
    { for k, v in var.workers : k => merge(v, { role = "worker" }) },
  )

  # Talos control-plane endpoint = the VIP (HA API).
  cluster_endpoint = "https://${var.cluster_vip}:6443"

  # First control plane — the single node we run `talos bootstrap` against.
  first_control_plane = "cp-1"

  # Talos Image Factory metal ISO URL for the pinned schematic + version.
  talos_iso_url = "https://factory.talos.dev/image/${var.talos_schematic_id}/${var.talos_version}/metal-amd64.iso"
}

# ---------------------------------------------------------------------------
# Talos: secrets, machine configuration, per-node apply, bootstrap, kubeconfig.
# The whole cluster identity (secrets.yaml) lives in Terraform state — back it up.
# ---------------------------------------------------------------------------

locals {
  # Cluster-wide patch shared by control-plane and worker configs.
  cluster_patch = templatefile("${local.talos_patches_dir}/cluster.yaml.tmpl", {
    install_disk = "/dev/sda" # virtio-scsi boot disk (scsi0)
    nameserver   = local.shared.network.nameserver
    # Install the Image Factory schematic installer (NOT the provider's bundled
    # ghcr.io/siderolabs/installer:<machinery-version>). This pins the on-disk
    # system to our exact Talos version AND bakes in the qemu-guest-agent (and
    # any other schematic) extension so Proxmox keeps seeing the guest agent
    # after the node kexecs into the installed system.
    install_image = "factory.talos.dev/installer/${var.talos_schematic_id}:${var.talos_version}"
  })

  # Cilium is bootstrapped as a Talos inline manifest so the CNI is present the
  # moment the first control-plane node comes up — otherwise Flux's own
  # controllers (ordinary pods) could never schedule to install it (chicken/egg).
  # Rendered from the Cilium Helm chart (talos/cilium/cilium.yaml); Cilium is
  # owned here (git-versioned in the Talos config), NOT by Flux. Applied to the
  # control-plane config only. yamlencode keeps the multi-doc string well-formed.
  cilium_inline_patch = yamlencode({
    cluster = {
      inlineManifests = [
        {
          name     = "cilium"
          contents = file(local.cilium_manifest_path)
        },
      ]
    }
  })

  # A cluster without workers runs its workloads on the control planes.
  control_plane_patches = concat(
    [local.cluster_patch, local.cilium_inline_patch],
    length(var.workers) == 0 ? [yamlencode({ cluster = { allowSchedulingOnControlPlanes = true } })] : [],
  )

  # In Talos maintenance mode each node DHCPs a temporary lease; the qemu guest
  # agent reports it. We target that IP for the FIRST config apply (which then
  # sets the real static IP + reboots). Pick the first routable, non-loopback,
  # non-link-local IPv4 the agent exposes.
  node_maintenance_ip = {
    for k, vm in proxmox_virtual_environment_vm.this : k => try(
      [
        for ip in flatten(vm.ipv4_addresses) : ip
        if ip != "127.0.0.1" && !startswith(ip, "169.254.") && !startswith(ip, "172.17.")
      ][0],
      null
    )
  }
}

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_config_contract

  # talos_version here is only the contract used when the secrets were first
  # generated. Changing it makes provider 0.11 plan every secret as unknown,
  # and its Update writes back only talos_version, so a change could wipe the
  # secrets from state. Existing state still holds the full creation version.
  lifecycle {
    ignore_changes = [talos_version]
  }
}

# Base machine configs (one per role), with the cluster-wide patch baked in.
data "talos_machine_configuration" "controlplane" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_config_contract
  kubernetes_version = var.kubernetes_version
  config_patches     = local.control_plane_patches
}

data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_config_contract
  kubernetes_version = var.kubernetes_version
  config_patches     = [local.cluster_patch]
}

# Apply config to each node at its maintenance IP. The per-node patch sets the
# hostname + static IP (control-plane nodes also get the shared API VIP).
resource "talos_machine_configuration_apply" "this" {
  for_each = local.nodes

  client_configuration = talos_machine_secrets.this.client_configuration
  machine_configuration_input = (
    each.value.role == "controlplane"
    ? data.talos_machine_configuration.controlplane.machine_configuration
    : data.talos_machine_configuration.worker.machine_configuration
  )

  node     = local.node_maintenance_ip[each.key]
  endpoint = local.node_maintenance_ip[each.key]

  config_patches = [
    templatefile("${local.talos_patches_dir}/node.yaml.tmpl", {
      hostname = "${var.cluster_name}-${each.key}"
      ip       = each.value.ip
      cidr     = local.shared.network.cidr_bits
      gateway  = local.shared.network.gateway
      vip      = each.value.role == "controlplane" ? var.cluster_vip : ""
      region   = var.proxmox_region
      zone     = var.proxmox_node
    })
  ]

  depends_on = [proxmox_virtual_environment_vm.this]
}

# Bootstrap etcd on exactly one control-plane node (at its post-reboot static IP).
resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.control_planes[local.first_control_plane].ip
  endpoint             = var.control_planes[local.first_control_plane].ip

  depends_on = [talos_machine_configuration_apply.this]
}

# Kubeconfig for the cluster (used by the kubernetes/flux providers + local file).
resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.control_planes[local.first_control_plane].ip
  endpoint             = var.cluster_vip

  depends_on = [terraform_data.api_ready]
}

# Bootstrap returns before the API server listens. The kubernetes and helm
# providers read the kubeconfig above, so waiting here holds back every
# in-cluster resource. Any HTTP status counts, since only "connection
# refused" means the server isn't up yet.
resource "terraform_data" "api_ready" {
  triggers_replace = [talos_machine_bootstrap.this.id, var.cluster_vip]

  provisioner "local-exec" {
    command = <<-EOT
      for i in $(seq 1 60); do
        code=$(curl -sk -o /dev/null -m 5 -w '%%{http_code}' https://${var.cluster_vip}:6443/readyz)
        [ "$code" != "000" ] && exit 0
        sleep 10
      done
      echo "API server at ${var.cluster_vip} not up after 10 minutes" >&2
      exit 1
    EOT
  }
}

# talosconfig for day-2 talosctl access (endpoints = control-plane static IPs).
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [for k, v in var.control_planes : v.ip]
  nodes                = [for k, v in local.nodes : v.ip]
}

# One VM per Talos node (control-plane + workers) via the accepted tuning profile:
# CPU type=host, no ballooning (floating=0), q35+SeaBIOS, virtio-scsi + iothread +
# discard + ssd, guest agent on, boot disk on ZFS `tank`, Talos ISO as CD-ROM.
