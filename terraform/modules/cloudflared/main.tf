# Namespace and credentials Secret for the cloudflared Deployment Flux runs.

resource "kubernetes_namespace_v1" "cloudflared" {
  metadata {
    name = "cloudflared"
  }
}

# Same name + key as the old SOPS `cloudflared-token`, so cloudflared.yaml's
# volume mount is unchanged.
resource "kubernetes_secret_v1" "cloudflared_token" {
  metadata {
    name      = "cloudflared-token"
    namespace = kubernetes_namespace_v1.cloudflared.metadata[0].name
  }

  data = {
    "credentials.json" = var.credentials_json
  }

  type = "Opaque"
}

# Terraform-managed half of the Flux substitution config. Static values
# (domains, LB IPs) stay in Git at kubernetes/clusters/homelab/cluster-config.yaml.
