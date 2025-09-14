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

  #TODO: define custom size for each datastore
  disk {
    datastore_id = each.value.datastore_id
    interface    = "scsi0"
    iothread     = true
    cache        = "writethrough"
    discard      = "on"
    ssd          = true
    file_format  = "raw"
    size         = each.value.machine_type == "controlplane" ? 32 : 200

    # file_id      = proxmox_virtual_environment_download_file.this["${each.value.host_node}_${each.value.update == true ? local.update_image_id : local.image_id}"].id
    file_id = proxmox_virtual_environment_download_file.this[
      "${each.value.host_node}_${
        each.value.update == true
        ? (each.value.gpu ? local.update_gpu_image_id : local.update_image_id)
        : (each.value.gpu ? local.gpu_image_id : local.image_id)
      }"
    ].id
  }

  dynamic "disk" {
    for_each = each.key == "work-00" ? [1] : []
    content {
      datastore_id = each.value.datastore_id2
      interface    = "scsi1"
      size         = 11000
      iothread     = true
      cache        = "writethrough"
      discard      = "on"
    }
  }

  boot_order = ["scsi0"]

  operating_system {
    type = "l26" # Linux Kernel 2.6 - 6.X.
  }

  initialization {
    datastore_id = each.value.datastore_id

    # Optional DNS Block.  Update Nodes with a list value to use.
    dynamic "dns" {
      for_each = try(each.value.dns, null) != null ? { "enabled" = each.value.dns } : {}
      content {
        servers = each.value.dns
      }
    }

    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.cluster.subnet_mask}"
        gateway = var.cluster.gateway
      }
    }
  }

  dynamic "hostpci" {
    for_each = each.value.gpu ? [1] : []
    content {
      # Passthrough iGPU
      device = "hostpci0"
      id     = each.value.gpu_device_id
      pcie   = true
      rombar = true
      xvga   = false
    }
  }
}
