terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">=0.114.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = ">=0.12.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    unifi = {
      source  = "ubiquiti-community/unifi"
      version = "~> 0.56"
    }
  }
}
