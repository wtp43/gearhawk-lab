locals {
  onepassword_vault = "eaoayya6ri4l6rw4umfonud5mu"
  k8s_dir           = "${path.root}/../../../k8s"
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
  depends_on = [talos_cluster.this]

  connect_credentials = data.onepassword_item.connect_credentials.file[0].content_base64
  operator_token      = ephemeral.onepassword_item.connect_token.credential
}

module "argocd" {
  source     = "../../bootstrap/argocd"
  count      = var.bootstrap_argocd ? 1 : 0
  depends_on = [module.onepassword_connect]

  kustomization_path = "${local.k8s_dir}/infra/controllers/argocd/kustomization.yaml"
  values_path        = "${local.k8s_dir}/infra/controllers/argocd/values.yaml"
  root_objects = [
    for f in ["project.yaml", "infrastructure.yaml", "applications.yaml"] :
    yamldecode(file("${local.k8s_dir}/sets/${f}"))
  ]
}
