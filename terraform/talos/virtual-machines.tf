# terraform/talos/virtual-machines.tf
resource "proxmox_virtual_environment_vm" "this" {
  for_each = var.nodes

  node_name = each.value.host_node

  name        = each.key
  description = each.value.machine_type == "controlplane" ? "Talos Control Plane" : "Talos Worker"
  tags        = each.value.machine_type == "controlplane" ? ["k8s", "control-plane"] : ["k8s", "worker"]
  on_boot     = true
  vm_id       = each.value.vm_id

  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"
  bios          = "seabios"

  agent {
    enabled = true
  }

  cpu {
    cores = each.value.cpu
    type  = "x86-64-v2-AES" # recommended for modern CPUs
  }

  memory {
    dedicated = each.value.ram_dedicated
  }

  network_device {
    bridge      = "vmbr0"
    mac_address = each.value.mac_address
  }

  disk {
    datastore_id = each.value.datastore_id
    interface    = "scsi0"
    iothread     = true
    cache        = "writethrough"
    discard      = "on"
    ssd          = true
    file_format  = "raw"
    size         = each.value.machine_type == "controlplane" ? 32 : (each.value.datastore_id == "local" ? 200 : 500)
    file_id      = proxmox_virtual_environment_download_file.this["${each.value.host_node}_${each.value.update == true ? local.update_image_id : local.image_id}"].id

  }

  boot_order = ["scsi0"]

  operating_system {
    type = "l26" # Linux Kernel 2.6 - 6.X.
  }

  initialization {
    datastore_id = each.value.datastore_id
    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.cluster.gateway
      }
    }
  }

  # dynamic "hostpci" {
  #   for_each = each.value.igpu ? [1] : []
  #   content {
  #     # Passthrough iGPU
  #     device  = "hostpci0"
  #     mapping = "iGPU"
  #     pcie    = true
  #     rombar  = true
  #     xvga    = false
  #   }
  # }
}
