removed {
  from = module.talos.talos_machine_configuration_apply.this

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.talos.talos_machine_bootstrap.this

  lifecycle {
    destroy = false
  }
}

moved {
  from = module.talos.talos_cluster_kubeconfig.this
  to   = talos_cluster_kubeconfig.this
}
