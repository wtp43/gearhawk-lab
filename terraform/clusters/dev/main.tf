# terraform/clusters/dev/main.tf
#
# Dev cluster — reuses the SAME ./talos module as prod (../../talos).
# Purpose: exercise the Talos VIP as the Kubernetes API endpoint and test
# failover when a control-plane node goes down while etcd quorum holds.
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
