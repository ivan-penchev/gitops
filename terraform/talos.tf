# ---------------------------------------------------------------------------
# Talos: secrets, machine configuration, per-node apply, bootstrap, kubeconfig.
# The whole cluster identity (secrets.yaml) lives in Terraform state — back it up.
# ---------------------------------------------------------------------------

locals {
  # Cluster-wide patch shared by control-plane and worker configs.
  cluster_patch = templatefile("${path.module}/../talos/patches/cluster.yaml.tmpl", {
    install_disk = "/dev/sda" # virtio-scsi boot disk (scsi0)
    nameserver   = var.nameserver
  })

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
  talos_version = var.talos_version
}

# Base machine configs (one per role), with the cluster-wide patch baked in.
data "talos_machine_configuration" "controlplane" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
  config_patches     = [local.cluster_patch]
}

data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
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
    templatefile("${path.module}/../talos/patches/node.yaml.tmpl", {
      hostname = "${var.cluster_name}-${each.key}"
      ip       = each.value.ip
      cidr     = var.network_cidr_bits
      gateway  = var.network_gateway
      vip      = each.value.role == "controlplane" ? var.cluster_vip : ""
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

  depends_on = [talos_machine_bootstrap.this]
}

# talosconfig for day-2 talosctl access (endpoints = control-plane static IPs).
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [for k, v in var.control_planes : v.ip]
  nodes                = [for k, v in local.nodes : v.ip]
}
