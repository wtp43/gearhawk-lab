# terraform/talos/output.tf
output "client_configuration" {
  value     = data.talos_client_configuration.this
  sensitive = true
}

output "machine_client_configuration" {
  value     = talos_machine_secrets.this.client_configuration
  sensitive = true
}

output "machine_config" {
  value = data.talos_machine_configuration.this
}

output "machines" {
  value = {
    for name, node in var.nodes : name => {
      node                  = node.ip
      machine_configuration = data.talos_machine_configuration.this[name].machine_configuration
    }
  }
  sensitive  = true
  depends_on = [proxmox_virtual_environment_vm.this]
}

output "installer_images" {
  value = { for name, urls in data.talos_image_factory_urls.this : name => urls.urls.installer }
}

output "vm_ids" {
  value = { for name, vm in proxmox_virtual_environment_vm.this : name => vm.id }
}

output "control_plane_ips" {
  value = [for name, node in var.nodes : node.ip if node.machine_type == "controlplane"]
}
