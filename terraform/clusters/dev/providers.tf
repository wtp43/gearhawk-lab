# terraform/clusters/dev/providers.tf
terraform {
  required_providers {
    talos = {
      source = "siderolabs/talos"
      # >=0.11.0 generates Talos v1.13.x machine configs (dev runs v1.13.4).
      version = ">=0.11.0"
    }
    proxmox = {
      source  = "bpg/proxmox"
      version = ">=0.109.0"
    }
    http = {
      source  = "hashicorp/http"
      version = ">=3.6.0"
    }
  }
}

provider "proxmox" {
  endpoint = var.proxmox.endpoint
  insecure = var.proxmox.insecure

  username = "${var.proxmox.username}@pam"
  password = var.proxmox.password

  ssh {
    agent = true
  }
}
