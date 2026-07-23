# terraform/clusters/dev/variables.tf
variable "proxmox" {
  type = object({
    name         = string
    cluster_name = string
    endpoint     = string
    insecure     = bool
    username     = string
    password     = string
    api_token    = string
  })
  sensitive = true
}

variable "skip_health_check" {
  description = "Skip the talos_cluster_health gate. Default false (installs enforce health); task destroy sets true so teardown is not blocked by an unhealthy cluster."
  type        = bool
  default     = false
}

variable "talos_image" {
  description = "Talos image configuration"
  type = object({
    factory_url           = optional(string, "https://factory.talos.dev")
    version               = string
    schematic_path        = string
    gpu_schematic_path    = string
    update_version        = optional(string)
    update_schematic_path = optional(string)
    arch                  = optional(string, "amd64")
    platform              = optional(string, "nocloud")
    proxmox_datastore     = optional(string, "local")
    file_name_suffix      = optional(string, "")
  })
}

variable "talos_cluster_config" {
  description = "Talos cluster configuration"
  type = object({
    name                               = string
    endpoint                           = string
    vip                                = optional(string)
    gateway                            = string
    subnet_mask                        = optional(string, "24")
    allow_scheduling_on_control_planes = optional(bool, false)
    use_hostname_config                = optional(bool, false)
    skip_health_check                  = optional(bool, false)
    talos_machine_config_version       = optional(string)
    proxmox_cluster                    = string
    kubernetes_version                 = string
    extra_manifests                    = optional(list(string))
    kubelet                            = optional(string)
    api_server                         = optional(string)
    cert_sans                          = optional(list(string), [])
    cilium = object({
      bootstrap_manifest_path = string
      values_file_path        = string
    })
  })
}

variable "talos_nodes" {
  type = map(
    object({
      host_node              = string
      machine_type           = string
      ip                     = string
      dns                    = optional(list(string))
      mac_address            = string
      vm_id                  = number
      cpu                    = number
      ram_dedicated          = number
      update                 = optional(bool, false)
      gpu                    = optional(bool, false)
      gpu_device_id          = optional(string)
      default_datastore_size = number
      datastore_id           = optional(string)
      datastore_id2          = optional(string)
    })
  )
  validation {
    condition     = length([for n in var.talos_nodes : n if contains(["controlplane", "worker"], n.machine_type)]) == length(var.talos_nodes)
    error_message = "Node machine_type must be either 'controlplane' or 'worker'."
  }
}
