# terraform/clusters/dev/main.tf
#
# Dev cluster — reuses the SAME ./talos module as prod (../../talos).
# Purpose: exercise the Talos VIP as the Kubernetes API endpoint and test
# failover when a control-plane node goes down while etcd quorum holds.
module "talos" {
  source = "../../talos"

  providers = {
    proxmox = proxmox
  }

  image = var.talos_image
  # skip_health_check is driven by the top-level var (default false) so installs
  # enforce health while `task destroy` can pass -var skip_health_check=true.
  cluster = merge(var.talos_cluster_config, {
    skip_health_check = var.skip_health_check
  })
  nodes = var.talos_nodes
}
