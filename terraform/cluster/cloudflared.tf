# Flux owns the cloudflared namespace and renders the cloudflared-token Secret
# from kubernetes/infrastructure/controllers/cloudflared.yaml. Terraform only
# writes the tunnel secret to cluster-secrets-tf (see flux.tf). The account id
# and tunnel id are already in cluster-config-tf.

locals {
  cloudflared_secrets = {
    cloudflared_tunnel_secret = random_id.tunnel_secret.b64_std
  }
}

# Terraform used to create both. Forget them without deleting them, so the
# tunnel stays up while Flux takes over.
removed {
  from = kubernetes_namespace_v1.cloudflared

  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_secret_v1.cloudflared_token

  lifecycle {
    destroy = false
  }
}
