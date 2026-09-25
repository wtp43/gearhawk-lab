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
