terraform {
  required_version = ">= 1.11"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = ">= 1.22"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
  }
}
