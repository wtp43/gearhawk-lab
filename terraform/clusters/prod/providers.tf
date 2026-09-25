# terraform/providers.tf
terraform {
  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = ">=0.12.0"
    }
    proxmox = {
      source  = "bpg/proxmox"
      version = ">=0.114.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    onepassword = {
      source  = "1Password/onepassword"
      version = "~> 3.3"
    }
    unifi = {
      source  = "ubiquiti-community/unifi"
      version = "~> 0.56"
    }
  }
}

provider "helm" {
  alias = "template"
}

provider "helm" {
  kubernetes = {
    host                   = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
    client_certificate     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
    client_key             = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
    cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
  }
}

provider "proxmox" {
  endpoint = var.proxmox.endpoint
  insecure = var.proxmox.insecure

  username = "${var.proxmox.username}@pam"
  password = var.proxmox.password

  # api_token = var.proxmox.api_token
  ssh {
    agent = true
    # username = var.proxmox.username
  }
}

provider "kubernetes" {
  host                   = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
  client_certificate     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
  client_key             = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
  cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
}

provider "onepassword" {
  account = "my.1password.com"
}

ephemeral "onepassword_item" "unifi" {
  vault = local.onepassword_vault
  title = "unifi-api-key"
}

provider "unifi" {
  api_url        = "https://192.168.50.1"
  api_key        = ephemeral.onepassword_item.unifi.note_value
  site           = "default"
  allow_insecure = true
}
