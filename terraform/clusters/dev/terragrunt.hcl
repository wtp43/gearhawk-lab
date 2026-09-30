include "root" {
  path           = find_in_parent_folders("root.hcl")
  merge_strategy = "deep"
}

terraform {
  extra_arguments "proxmox" {
    commands           = get_terraform_commands_that_need_vars()
    required_var_files = ["${get_terragrunt_dir()}/../prod/proxmox.auto.tfvars"]
  }
}
