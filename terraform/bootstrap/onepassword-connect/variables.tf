variable "connect_credentials" {
  description = "Contents of the Connect server's 1password-credentials.json"
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
