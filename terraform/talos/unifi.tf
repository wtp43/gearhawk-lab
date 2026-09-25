resource "unifi_client" "node" {
  for_each = var.nodes

  mac            = lower(each.value.mac_address)
  name           = each.key
  fixed_ip       = each.value.ip
  note           = "Talos ${each.value.machine_type} on ${each.value.host_node} (terraform)"
  allow_existing = true
}
