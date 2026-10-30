terraform {
  # The operator bootstrap module uses write-only secret arguments.
  required_version = ">= 1.11"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = ">= 1.22"
    }
  }
}
