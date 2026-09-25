locals {
  machines = module.talos.machines
}

resource "terraform_data" "vm" {
  for_each = module.talos.vm_ids
  input    = each.value
}

# Nodes upgrade one at a time via this depends_on chain.
# Replace with serialize_upgrades once released: https://github.com/siderolabs/terraform-provider-talos/issues/412
resource "talos_machine" "ctrl_00" {
  node                            = local.machines["ctrl-00"].node
  client_configuration            = module.talos.machine_client_configuration
  machine_configuration           = local.machines["ctrl-00"].machine_configuration
  image                           = module.talos.installer_images["ctrl-00"]
  drain_on_upgrade                = false
  ignore_kubernetes_upgrade_drift = true

  lifecycle {
    replace_triggered_by = [terraform_data.vm["ctrl-00"]]
  }
}

resource "talos_machine" "ctrl_05" {
  depends_on = [talos_machine.ctrl_00]

  node                            = local.machines["ctrl-05"].node
  client_configuration            = module.talos.machine_client_configuration
  machine_configuration           = local.machines["ctrl-05"].machine_configuration
  image                           = module.talos.installer_images["ctrl-05"]
  drain_on_upgrade                = false
  ignore_kubernetes_upgrade_drift = true

  lifecycle {
    replace_triggered_by = [terraform_data.vm["ctrl-05"]]
  }
}

resource "talos_machine" "ctrl_06" {
  depends_on = [talos_machine.ctrl_05]

  node                            = local.machines["ctrl-06"].node
  client_configuration            = module.talos.machine_client_configuration
  machine_configuration           = local.machines["ctrl-06"].machine_configuration
  image                           = module.talos.installer_images["ctrl-06"]
  drain_on_upgrade                = false
  ignore_kubernetes_upgrade_drift = true

  lifecycle {
    replace_triggered_by = [terraform_data.vm["ctrl-06"]]
  }
}

resource "talos_machine" "work_04" {
  depends_on = [talos_machine.ctrl_06]

  node                            = local.machines["work-04"].node
  client_configuration            = module.talos.machine_client_configuration
  machine_configuration           = local.machines["work-04"].machine_configuration
  image                           = module.talos.installer_images["work-04"]
  drain_on_upgrade                = false
  ignore_kubernetes_upgrade_drift = true

  lifecycle {
    replace_triggered_by = [terraform_data.vm["work-04"]]
  }
}

resource "talos_machine" "work_02" {
  depends_on = [talos_machine.work_04]

  node                            = local.machines["work-02"].node
  client_configuration            = module.talos.machine_client_configuration
  machine_configuration           = local.machines["work-02"].machine_configuration
  image                           = module.talos.installer_images["work-02"]
  drain_on_upgrade                = false
  ignore_kubernetes_upgrade_drift = true

  lifecycle {
    replace_triggered_by = [terraform_data.vm["work-02"]]
  }
}

resource "talos_machine" "work_06" {
  depends_on = [talos_machine.work_02]

  node                            = local.machines["work-06"].node
  client_configuration            = module.talos.machine_client_configuration
  machine_configuration           = local.machines["work-06"].machine_configuration
  image                           = module.talos.installer_images["work-06"]
  drain_on_upgrade                = false
  ignore_kubernetes_upgrade_drift = true

  lifecycle {
    replace_triggered_by = [terraform_data.vm["work-06"]]
  }
}

resource "talos_machine" "work_05" {
  depends_on = [talos_machine.work_06]

  node                            = local.machines["work-05"].node
  client_configuration            = module.talos.machine_client_configuration
  machine_configuration           = local.machines["work-05"].machine_configuration
  image                           = module.talos.installer_images["work-05"]
  drain_on_upgrade                = false
  ignore_kubernetes_upgrade_drift = true

  lifecycle {
    replace_triggered_by = [terraform_data.vm["work-05"]]
  }
}

resource "talos_machine" "work_00" {
  depends_on = [talos_machine.work_05]

  node                            = local.machines["work-00"].node
  client_configuration            = module.talos.machine_client_configuration
  machine_configuration           = local.machines["work-00"].machine_configuration
  image                           = module.talos.installer_images["work-00"]
  drain_on_upgrade                = false
  ignore_kubernetes_upgrade_drift = true

  lifecycle {
    replace_triggered_by = [terraform_data.vm["work-00"]]
  }
}

resource "talos_cluster" "this" {
  depends_on = [talos_machine.work_00]

  node                 = module.talos.control_plane_ips[0]
  control_plane_nodes  = module.talos.control_plane_ips
  client_configuration = module.talos.machine_client_configuration
  kubernetes_version   = "v${trimprefix(var.talos_cluster_config.kubernetes_version, "v")}"
}

resource "terraform_data" "kubernetes_ready" {
  triggers_replace = talos_cluster.this.id

  provisioner "local-exec" {
    command = "talosctl --talosconfig ${local_file.talos_config.filename} -e ${module.talos.control_plane_ips[0]} -n ${module.talos.control_plane_ips[0]} health --wait-timeout 15m"
  }
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on = [talos_cluster.this]

  node                 = module.talos.control_plane_ips[0]
  client_configuration = module.talos.machine_client_configuration
}
