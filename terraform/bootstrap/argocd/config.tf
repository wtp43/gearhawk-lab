locals {
  chart = one([
    for chart in yamldecode(file(var.kustomization_path)).helmCharts : chart if chart.name == "argo-cd"
  ])

  projects = {
    for o in var.root_objects : o.metadata.name => merge(o.spec, { namespace = o.metadata.namespace })
    if o.kind == "AppProject"
  }
  applications = {
    for o in var.root_objects : o.metadata.name => merge(o.spec, { namespace = o.metadata.namespace })
    if o.kind == "Application"
  }
}

resource "helm_release" "argocd" {
  name             = local.chart.releaseName
  namespace        = local.chart.namespace
  create_namespace = true
  repository       = local.chart.repo
  chart            = local.chart.name
  version          = local.chart.version
  wait             = false
  values           = [file(var.values_path)]

  lifecycle {
    ignore_changes = all
  }
}

resource "helm_release" "root" {
  depends_on = [helm_release.argocd]

  name       = "argocd-root"
  namespace  = local.chart.namespace
  repository = local.chart.repo
  chart      = "argocd-apps"
  version    = var.apps_chart_version

  values = [yamlencode({
    projects     = local.projects
    applications = local.applications
  })]

  lifecycle {
    ignore_changes = all
  }
}
