locals {
  onepassword_vault = data.onepassword_vault.gearhawk_k8s.uuid
  k8s_dir           = "${path.root}/../../../k8s"
}

data "onepassword_vault" "gearhawk_k8s" {
  name = "gearhawk-k8s"
}

data "onepassword_item" "connect_credentials" {
  vault = local.onepassword_vault
  title = "intrend-k8s Credentials File"
}

ephemeral "onepassword_item" "connect_token" {
  vault = local.onepassword_vault
  title = "intrend-k8s Access Token: Kubernetes"
}

module "onepassword_connect" {
  source     = "../../bootstrap/onepassword-connect"
  depends_on = [terraform_data.kubernetes_ready]

  connect_credentials = data.onepassword_item.connect_credentials.file[0].content
  operator_token      = ephemeral.onepassword_item.connect_token.credential
}

module "argocd" {
  source     = "../../bootstrap/argocd"
  depends_on = [module.onepassword_connect]

  kustomization_path = "${local.k8s_dir}/infra/controllers/argocd/kustomization.yaml"
  values_path        = "${local.k8s_dir}/infra/controllers/argocd/values.yaml"
  root_objects = [
    yamldecode(file("${local.k8s_dir}/infra/controllers/project.yaml")),
    {
      apiVersion = "argoproj.io/v1alpha1"
      kind       = "Application"
      metadata = {
        name      = "onepassword-connect"
        namespace = "argocd"
      }
      spec = {
        project = "controllers"
        source = {
          repoURL        = "https://github.com/wtp43/gearhawk-lab"
          targetRevision = var.argocd_revision
          path           = "k8s/infra/controllers/onepassword-connect"
          plugin         = { name = "kustomize-build-with-helm" }
        }
        destination = {
          name      = "in-cluster"
          namespace = "argocd"
        }
        syncPolicy = {
          automated   = { selfHeal = true, prune = true }
          syncOptions = ["ServerSideApply=true"]
        }
      }
    },
  ]
}
