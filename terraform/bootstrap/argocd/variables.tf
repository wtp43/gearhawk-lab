variable "kustomization_path" {
  description = "Path to the ArgoCD kustomization.yaml that pins the argo-cd chart"
  type        = string
}

variable "values_path" {
  description = "Path to the argo-cd chart values ArgoCD uses for itself"
  type        = string
}

variable "root_objects" {
  description = "AppProjects and Applications that hand the cluster over to git"
  type        = any
}

variable "apps_chart_version" {
  description = "argocd-apps chart version used to create the root objects"
  type        = string
  default     = "2.0.5"
}
