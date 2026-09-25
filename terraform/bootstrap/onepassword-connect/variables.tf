variable "connect_credentials" {
  description = "Base64-encoded 1password-credentials.json for the Connect server"
  type        = string
  ephemeral   = true
}

variable "operator_token" {
  description = "Connect access token used by the operator"
  type        = string
  ephemeral   = true
}

variable "revision" {
  description = "Bump to push rotated credentials to the cluster"
  type        = number
  default     = 1
}
