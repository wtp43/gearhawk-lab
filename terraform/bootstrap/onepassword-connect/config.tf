resource "helm_release" "onepassword-connect" {
  name       = "onepassword-connect"
  repository = "https://1password.github.io/connect-helm-charts/"
  chart      = "connect"
  version    = "2.1.1"
  set_sensitive = [
    {
      name  = "connect.credentials_base64"
      type  = "string"
      value = var.onepassword.connect_credentials
    },
    {
      name  = "operator.token.value"
      type  = "string"
      value = var.onepassword.operator_token
    }
  ]
  # Deploy the Kubernetes Operator alongside the Connect Server
  set = [{
    name  = "operator.create"
    value = true
  }]
}

