locals {
  machines = module.talos.machines
}

resource "terraform_data" "vm" {
  for_each = module.talos.vm_ids
  input    = each.value
}

# Nodes upgrade one at a time via this depends_on chain.
# Replace with serialize_upgrades once released: https://github.com/siderolabs/terraform-provider-talos/issues/412
resource "talos_machine" "ctrl_dev_00" {
  node                            = local.machines["ctrl-dev-00"].node
  client_configuration            = module.talos.machine_client_configuration
  machine_configuration           = local.machines["ctrl-dev-00"].machine_configuration
  image                           = module.talos.installer_images["ctrl-dev-00"]
  drain_on_upgrade                = false
  ignore_kubernetes_upgrade_drift = true

  lifecycle {
    replace_triggered_by = [terraform_data.vm["ctrl-dev-00"]]
  }
}

resource "talos_machine" "ctrl_dev_01" {
  depends_on = [talos_machine.ctrl_dev_00]

  node                            = local.machines["ctrl-dev-01"].node
  client_configuration            = module.talos.machine_client_configuration
  machine_configuration           = local.machines["ctrl-dev-01"].machine_configuration
  image                           = module.talos.installer_images["ctrl-dev-01"]
  drain_on_upgrade                = false
  ignore_kubernetes_upgrade_drift = true

  lifecycle {
    replace_triggered_by = [terraform_data.vm["ctrl-dev-01"]]
  }
}

resource "talos_machine" "ctrl_dev_02" {
  depends_on = [talos_machine.ctrl_dev_01]

  node                            = local.machines["ctrl-dev-02"].node
  client_configuration            = module.talos.machine_client_configuration
  machine_configuration           = local.machines["ctrl-dev-02"].machine_configuration
  image                           = module.talos.installer_images["ctrl-dev-02"]
  drain_on_upgrade                = false
  ignore_kubernetes_upgrade_drift = true

  lifecycle {
    replace_triggered_by = [terraform_data.vm["ctrl-dev-02"]]
  }
}

resource "talos_machine" "work_dev_00" {
  depends_on = [talos_machine.ctrl_dev_02]

  node                            = local.machines["work-dev-00"].node
  client_configuration            = module.talos.machine_client_configuration
  machine_configuration           = local.machines["work-dev-00"].machine_configuration
  image                           = module.talos.installer_images["work-dev-00"]
  drain_on_upgrade                = false
  ignore_kubernetes_upgrade_drift = true

  lifecycle {
    replace_triggered_by = [terraform_data.vm["work-dev-00"]]
  }
}

resource "talos_cluster" "this" {
  depends_on = [talos_machine.work_dev_00]

  node                 = module.talos.control_plane_ips[0]
  control_plane_nodes  = module.talos.control_plane_ips
  client_configuration = module.talos.machine_client_configuration
  kubernetes_version   = "v${trimprefix(var.talos_cluster_config.kubernetes_version, "v")}"
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on = [talos_cluster.this]

  node                 = module.talos.control_plane_ips[0]
  client_configuration = module.talos.machine_client_configuration
}
