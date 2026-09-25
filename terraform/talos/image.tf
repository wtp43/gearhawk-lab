resource "talos_image_factory_schematic" "this" {
  for_each = {
    std = var.image.schematic_path
    gpu = var.image.gpu_schematic_path
  }
  schematic = file("${path.root}/${each.value}")
}

locals {
  node_image = {
    for name, node in var.nodes : name => {
      host_node = node.host_node
      flavor    = node.gpu ? "gpu" : "std"
      version   = coalesce(node.talos_version, var.image.version)
      download  = "${node.host_node}_${node.gpu ? "gpu" : "std"}_${coalesce(node.talos_version, var.image.version)}"
    }
  }

  downloads = merge([for img in values(local.node_image) : { (img.download) = img }]...)
}

data "talos_image_factory_urls" "this" {
  for_each      = local.node_image
  talos_version = each.value.version
  schematic_id  = talos_image_factory_schematic.this[each.value.flavor].id
  platform      = var.image.platform
  architecture  = var.image.arch
}

resource "proxmox_virtual_environment_download_file" "this" {
  for_each = local.downloads

  node_name    = each.value.host_node
  content_type = "iso"
  datastore_id = var.image.proxmox_datastore

  file_name = "talos-${talos_image_factory_schematic.this[each.value.flavor].id}-${each.value.version}-${var.image.platform}-${var.image.arch}${var.image.file_name_suffix}.img"

  url                     = "${var.image.factory_url}/image/${talos_image_factory_schematic.this[each.value.flavor].id}/${each.value.version}/${var.image.platform}-${var.image.arch}.raw.gz"
  decompression_algorithm = "gz"
  overwrite               = false
}
