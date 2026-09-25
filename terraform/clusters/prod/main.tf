module "talos" {
  source = "../../talos"

  providers = {
    proxmox = proxmox
    helm    = helm.template
  }

  image   = var.talos_image
  cluster = var.talos_cluster_config
  nodes   = var.talos_nodes
}
