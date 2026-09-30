include "root" {
  path           = find_in_parent_folders("root.hcl")
  merge_strategy = "deep"
}

terraform {
  before_hook "snapshot_state" {
    commands = ["apply", "destroy", "import"]
    execute  = ["${get_repo_root()}/terraform/scripts/snapshot-state.sh", "prod"]
  }
}

inputs = {
  via_terragrunt = true
}
