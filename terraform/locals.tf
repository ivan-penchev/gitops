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
