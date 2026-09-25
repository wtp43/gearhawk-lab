resource "kubernetes_namespace_v1" "onepassword" {
  metadata {
    name = "onepassword"
  }
}

resource "kubernetes_secret_v1" "credentials" {
  metadata {
    name      = "op-credentials"
    namespace = kubernetes_namespace_v1.onepassword.metadata[0].name
  }
  data_wo = {
    "1password-credentials.json" = var.connect_credentials
  }
  data_wo_revision = var.revision
}

resource "kubernetes_secret_v1" "token" {
  metadata {
    name      = "onepassword-token"
    namespace = kubernetes_namespace_v1.onepassword.metadata[0].name
  }
  data_wo = {
    token = var.operator_token
  }
  data_wo_revision = var.revision
}
