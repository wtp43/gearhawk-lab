variable "image" {
  description = "Talos image configuration"
  type = object({
    factory_url        = optional(string, "https://factory.talos.dev")
    schematic_path     = string
    gpu_schematic_path = string
    version            = string
    arch               = optional(string, "amd64")
    platform           = optional(string, "nocloud")
    proxmox_datastore  = optional(string, "local")
    file_name_suffix   = optional(string, "")
  })
}

variable "cluster" {
  description = "Cluster configuration"
  type = object({
    name        = string
    endpoint    = string
    vip         = optional(string)
    gateway     = string
    subnet_mask = optional(string, "24")
    # Allow regular workloads to schedule on control-plane nodes.
    # Needed for clusters with no dedicated workers (e.g. the dev cluster).
    allow_scheduling_on_control_planes = optional(bool, false)
    talos_machine_config_version       = string
    proxmox_cluster                    = string
    kubernetes_version                 = string
    extra_manifests                    = optional(list(string))
    kubelet                            = optional(string)
    api_server                         = optional(string)
    # Extra Subject Alternative Names added to the kube-apiserver serving cert,
    # e.g. the VIP + each control-plane node IP so the API validates on any of
    # them. Empty by default (only the auto-derived endpoint SAN is present).
    cert_sans = optional(list(string), [])
    cilium = object({
      kustomization_path = string
      values_file_path   = string
    })
  })
}

variable "nodes" {
  description = "Configuration for cluster nodes"
  type = map(object({
    host_node              = string
    machine_type           = string
    datastore_id           = optional(string, "local")
    datastore_id2          = optional(string, "local")
    default_datastore_size = number
    ip                     = string
    dns                    = optional(list(string))
    mac_address            = string
    vm_id                  = number
    cpu                    = number
    ram_dedicated          = number
    talos_version          = optional(string)
    gpu                    = optional(bool, false)
    gpu_device_id          = optional(string)
  }))
}
