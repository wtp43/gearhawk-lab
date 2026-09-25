resource "talos_machine_secrets" "this" {
  talos_version = var.cluster.talos_machine_config_version
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster.name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes                = [for k, v in var.nodes : v.ip]
  # Don't use vip in talosconfig endpoints
  # ref - https://www.talos.dev/v1.9/talos-guides/network/vip/#caveats
  endpoints = [for k, v in var.nodes : v.ip if v.machine_type == "controlplane"]
}

locals {
  cilium_chart = one([
    for chart in yamldecode(file("${path.root}/${var.cluster.cilium.kustomization_path}")).helmCharts : chart if chart.name == "cilium"
  ])
}

data "helm_template" "cilium" {
  name         = local.cilium_chart.releaseName
  namespace    = local.cilium_chart.namespace
  repository   = local.cilium_chart.repo
  chart        = local.cilium_chart.name
  version      = local.cilium_chart.version
  kube_version = var.cluster.kubernetes_version
  include_crds = true
  values       = [file("${path.root}/${var.cluster.cilium.values_file_path}")]
}

data "talos_machine_configuration" "this" {
  for_each     = var.nodes
  cluster_name = var.cluster.name
  # This is the Kubernetes API Server endpoint.
  # ref - https://www.talos.dev/v1.9/introduction/prodnotes/#decide-the-kubernetes-endpoint
  cluster_endpoint   = "https://${var.cluster.endpoint}:6443"
  talos_version      = var.cluster.talos_machine_config_version
  kubernetes_version = trimprefix(var.cluster.kubernetes_version, "v")
  machine_type       = each.value.machine_type
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  config_patches = concat([
    yamlencode({
      machine = {
        install = {
          image = data.talos_image_factory_urls.this[each.key].urls.installer
        }
      }
    }),
    templatefile("${path.module}/machine-config/common.yaml.tftpl", {
      node_name    = each.value.host_node
      cluster_name = var.cluster.proxmox_cluster
      hostname     = each.key
      ip           = each.value.ip
      mac_address  = lower(each.value.mac_address)
      gateway      = var.cluster.gateway
      subnet_mask  = var.cluster.subnet_mask
      vip          = each.value.machine_type == "controlplane" ? var.cluster.vip : null
      machine_type = each.value.machine_type
    }),
    ], each.value.machine_type == "controlplane" ? [
    templatefile("${path.module}/machine-config/control-plane.yaml.tftpl", {
      extra_manifests = jsonencode(var.cluster.extra_manifests)
      api_server      = var.cluster.api_server
      inline_manifests = jsonencode([{
        name     = "cilium"
        contents = data.helm_template.cilium.manifest
      }])
      allow_scheduling_on_control_planes = var.cluster.allow_scheduling_on_control_planes
      cert_sans                          = var.cluster.cert_sans
    })] : [],
    [yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      hostname   = each.key
      auto       = "off"
    })],
    tonumber(split(".", local.node_image[each.key].version)[1]) >= 14 ? [yamlencode({
      apiVersion = "v1alpha1"
      kind       = "FilesystemTrimConfig"
      interval   = "168h0m0s"
  })] : [])
}
