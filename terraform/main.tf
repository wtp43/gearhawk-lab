module "talos" {
  source = "./talos"

  providers = {
    proxmox = proxmox
  }

  image   = var.talos_image
  cluster = var.talos_cluster_config
  nodes   = var.talos_nodes
}

module "onepassword_connect" {
  depends_on = [module.talos]
  source     = "./bootstrap/onepassword-connect"
  providers = {
    kubernetes = kubernetes
    helm       = helm
  }
  onepassword = {
    connect_credentials = file("${path.module}/bootstrap/onepassword-connect/1password-credentials.b64")
    operator_token      = file("${path.module}/bootstrap/onepassword-connect/operator_token.key")
  }
}
