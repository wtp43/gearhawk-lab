locals {
  chart = one([
    for chart in yamldecode(file(var.kustomization_path)).helmCharts : chart if chart.name == "argo-cd"
  ])
}

resource "helm_release" "argocd" {
  name             = local.chart.releaseName
  namespace        = local.chart.namespace
  create_namespace = true
  repository       = local.chart.repo
  chart            = local.chart.name
  version          = local.chart.version
  wait             = false

  values = [
    file(var.values_path),
    yamlencode({ extraObjects = var.root_objects }),
  ]

  lifecycle {
    ignore_changes = all
  }
}
