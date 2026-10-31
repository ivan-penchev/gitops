# Plan-only tests with mocked providers. They need no credentials and run in CI.
# The variables describe a small made-up cluster, not homelab-prd.

mock_provider "proxmox" {}
mock_provider "cloudflare" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "postgresql" {}
mock_provider "local" {}
mock_provider "null" {}
mock_provider "random" {}

mock_provider "talos" {
  # The kubernetes and helm providers base64decode these.
  mock_resource "talos_cluster_kubeconfig" {
    defaults = {
      kubernetes_client_configuration = {
        host               = "https://192.0.2.10:6443"
        ca_certificate     = "Y2E="
        client_certificate = "Y2VydA=="
        client_key         = "a2V5"
      }
    }
  }
}

override_data {
  target = data.terraform_remote_state.shared
  values = {
    outputs = {
      network = {
        cidr       = "192.0.2.0/24"
        gateway    = "192.0.2.1"
        cidr_bits  = 24
        nameserver = "192.0.2.2"
      }
      postgres_ready              = true
      postgres_fqdn               = "pg.example.test"
      postgres_ip                 = "192.0.2.5"
      postgres_superuser_password = "test"
    }
  }
}

variables {
  talos_version         = "v1.13.7"
  talos_config_contract = "v1.13"
  kubernetes_version    = "1.36.2"
  talos_schematic_id    = "0000"
  cluster_name          = "test"
  cluster_vip           = "192.0.2.10"
  control_planes = {
    cp-1 = { vmid = 901, ip = "192.0.2.11", cpu = 2, memory = 4096, disk = 20 }
  }
  workers = {
    work-1 = { vmid = 902, ip = "192.0.2.12", cpu = 2, memory = 4096, disk = 20 }
  }
  proxmox_node              = "pve"
  proxmox_region            = "test"
  proxmox_csi_endpoint      = "https://192.0.2.3:8006/api2/json"
  iso_datastore             = "local"
  vm_datastore              = "tank"
  network_bridge            = "vmbr0"
  cloudflare_zone           = "example.test"
  public_domain             = "test.example.test"
  lan_domain                = "int.example.test"
  dns_owner_id              = "test"
  cloudflare_tunnel_name    = "test"
  flux_git_url              = "https://github.com/ivan-penchev/gitops.git"
  flux_path                 = "kubernetes/clusters/homelab"
  iso_name_prefix           = "test-talos"
  kubeconfig_file           = "kubeconfig-test"
  talosconfig_file          = "talosconfig-test"
  csi_proxmox_role          = "test-CSI"
  csi_proxmox_user          = "test-csi@pve"
  pve_exporter_proxmox_user = "test-pve-exporter@pve"
  sops_age_key_file         = ""
  extra_zones               = { other = "other.test" }
  postgres_databases = [
    { name = "app", namespaces = ["app-a", "app-b"] },
    { name = "wiki", namespaces = ["wiki"] },
  ]
}

run "cilium_uses_kubeprism" {
  command = plan

  assert {
    condition     = strcontains(local.cilium_inline_patch, "7445") && !strcontains(local.cilium_inline_patch, "192.0.2.10")
    error_message = "The Cilium inline manifest must reach the API through KubePrism, not a cluster VIP."
  }

  assert {
    condition     = contains(data.talos_machine_configuration.controlplane.config_patches, local.cilium_inline_patch)
    error_message = "Control planes must get the Cilium inline manifest."
  }

  assert {
    condition     = !contains(data.talos_machine_configuration.worker.config_patches, local.cilium_inline_patch)
    error_message = "Workers must not carry the Cilium inline manifest."
  }
}

run "nodes_get_static_ips_and_the_vip" {
  command = plan

  assert {
    condition     = strcontains(talos_machine_configuration_apply.this["cp-1"].config_patches[0], "192.0.2.11/24") && strcontains(talos_machine_configuration_apply.this["cp-1"].config_patches[0], "ip: 192.0.2.10")
    error_message = "cp-1 must get its static IP and the VIP."
  }

  assert {
    condition     = strcontains(talos_machine_configuration_apply.this["work-1"].config_patches[0], "192.0.2.12/24") && !strcontains(talos_machine_configuration_apply.this["work-1"].config_patches[0], "vip:")
    error_message = "work-1 must get its static IP and no VIP."
  }
}

run "control_planes_stay_unschedulable_with_workers" {
  command = plan

  assert {
    condition     = !strcontains(join("\n", data.talos_machine_configuration.controlplane.config_patches), "allowSchedulingOnControlPlanes")
    error_message = "With workers, control planes must not take workloads."
  }
}

run "single_node_cluster_schedules_on_control_plane" {
  command = plan

  variables {
    workers = {}
  }

  assert {
    condition     = strcontains(join("\n", data.talos_machine_configuration.controlplane.config_patches), "allowSchedulingOnControlPlanes")
    error_message = "Without workers, control planes must take workloads."
  }
}

run "one_postgres_secret_per_namespace" {
  command = plan

  assert {
    condition     = toset(keys(kubernetes_secret_v1.db)) == toset(["app/app-a", "app/app-b", "wiki/wiki"])
    error_message = "Expected one Secret per (database, namespace) pair."
  }

  assert {
    condition     = kubernetes_secret_v1.db["app/app-b"].metadata[0].name == "postgres-app" && kubernetes_secret_v1.db["app/app-b"].metadata[0].namespace == "app-b"
    error_message = "The Secret for app in app-b must be postgres-app in namespace app-b."
  }

  assert {
    condition     = kubernetes_secret_v1.db["wiki/wiki"].data.POSTGRES_HOST == "pg.example.test" && kubernetes_secret_v1.db["wiki/wiki"].data.POSTGRES_DB == "wiki"
    error_message = "The Secret must point at pg-01 from the shared outputs."
  }

  assert {
    condition     = toset(keys(postgresql_database.db)) == toset(["app", "wiki"])
    error_message = "Expected one database per entry."
  }
}

run "no_postgres_until_pg01_is_ready" {
  command = plan

  override_data {
    target = data.terraform_remote_state.shared
    values = {
      outputs = {
        network = {
          cidr       = "192.0.2.0/24"
          gateway    = "192.0.2.1"
          cidr_bits  = 24
          nameserver = "192.0.2.2"
        }
        postgres_ready              = false
        postgres_fqdn               = "pg.example.test"
        postgres_ip                 = "192.0.2.5"
        postgres_superuser_password = "test"
      }
    }
  }

  assert {
    condition     = length(postgresql_database.db) == 0 && length(kubernetes_secret_v1.db) == 0
    error_message = "Nothing on pg-01 may run before postgres_ready."
  }
}

run "per_cluster_names_come_from_variables" {
  command = plan

  assert {
    condition     = cloudflare_zero_trust_tunnel_cloudflared.tunnel.name == "test" && proxmox_virtual_environment_user.csi.user_id == "test-csi@pve"
    error_message = "Tunnel and CSI user names must come from the cluster's tfvars."
  }

  assert {
    condition     = proxmox_virtual_environment_user.pve_exporter[0].user_id == "test-pve-exporter@pve" && proxmox_acl.pve_exporter[0].role_id == "PVEAuditor"
    error_message = "The pve-exporter user must come from tfvars and stay read-only."
  }

  assert {
    condition     = kubernetes_config_map_v1.cluster_config_tf.data["pve_exporter_target"] == "192.0.2.3"
    error_message = "The exporter must scrape the host from proxmox_csi_endpoint."
  }

  assert {
    condition = alltrue([
      kubernetes_config_map_v1.cluster_config_tf.data.proxmox_csi_url == "https://192.0.2.3:8006/api2/json",
      kubernetes_config_map_v1.cluster_config_tf.data.proxmox_insecure == "true",
      contains(keys(kubernetes_secret_v1.cluster_secrets_tf.data), "proxmox_csi_token_secret"),
      contains(keys(kubernetes_secret_v1.cluster_secrets_tf.data), "cloudflared_tunnel_secret"),
    ])
    error_message = "Flux needs the CSI URL in cluster-config-tf and the CSI and tunnel secrets in cluster-secrets-tf."
  }

  assert {
    condition     = proxmox_virtual_environment_vm.this["cp-1"].name == "test-cp-1" && proxmox_virtual_environment_vm.this["cp-1"].vm_id == 901
    error_message = "VM names must use cluster_name."
  }

  assert {
    condition = alltrue([
      kubernetes_config_map_v1.cluster_config_tf.data.public_domain == "test.example.test",
      kubernetes_config_map_v1.cluster_config_tf.data.lan_domain == "int.example.test",
      kubernetes_config_map_v1.cluster_config_tf.data.dns_owner_id == "test",
    ])
    error_message = "cluster-config-tf must carry the cluster's domains and DNS owner ID."
  }

  assert {
    condition     = contains(keys(kubernetes_config_map_v1.cluster_config_tf.data), "other_cf_zone_id")
    error_message = "cluster-config-tf must carry a zone id for each extra zone."
  }

  assert {
    condition     = length(kubernetes_secret_v1.sops_age) == 0
    error_message = "No sops-age Secret without a key file."
  }
}

run "pve_exporter_is_off_unless_the_cluster_opts_in" {
  command = plan

  variables {
    pve_exporter_proxmox_user = ""
  }

  assert {
    condition     = length(proxmox_virtual_environment_user.pve_exporter) == 0 && !contains(keys(kubernetes_config_map_v1.cluster_config_tf.data), "pve_exporter_target")
    error_message = "Only the cluster that sets pve_exporter_proxmox_user may create the exporter user or hand Flux its values."
  }
}

run "talos_upgrade_keeps_the_config_contract" {
  command = plan

  variables {
    talos_version = "v1.14.5"
  }

  assert {
    condition     = strcontains(local.cluster_patch, "/installer/0000:v1.14.5")
    error_message = "The installer image must follow talos_version."
  }

  assert {
    condition = alltrue([
      data.talos_machine_configuration.controlplane.talos_version == "v1.13",
      data.talos_machine_configuration.worker.talos_version == "v1.13",
      talos_machine_secrets.this.talos_version == "v1.13",
    ])
    error_message = "Machine configs and secrets must use talos_config_contract, not talos_version."
  }
}

run "config_contract_is_major_minor_only" {
  command = plan

  variables {
    talos_config_contract = "v1.13.7"
  }

  expect_failures = [var.talos_config_contract]
}

run "public_domain_must_be_inside_the_zone" {
  command = plan

  variables {
    public_domain = "other.test"
  }

  expect_failures = [var.public_domain]
}

run "lan_domain_must_be_inside_the_zone" {
  command = plan

  variables {
    lan_domain = "int.other.test"
  }

  expect_failures = [var.lan_domain]
}

run "lan_domain_must_not_cover_public_domain" {
  command = plan

  variables {
    public_domain = "app.int.example.test"
  }

  expect_failures = [var.lan_domain]
}

run "lan_domain_must_differ_from_public_domain" {
  command = plan

  variables {
    public_domain = "int.example.test"
  }

  expect_failures = [var.lan_domain]
}
