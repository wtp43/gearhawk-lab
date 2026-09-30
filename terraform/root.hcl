terraform_binary = "terraform"

terraform {
  source = "${get_repo_root()}//terraform/${path_relative_to_include()}"

  extra_arguments "onepassword" {
    commands = get_terraform_commands_that_need_vars()
    env_vars = {
      OP_SERVICE_ACCOUNT_TOKEN = run_cmd("--terragrunt-quiet", "security", "find-generic-password", "-a", get_env("USER"), "-s", "op-service-account-gearhawk-k8s", "-w")
    }
  }
}

inputs = {
  output_dir = "${get_original_terragrunt_dir()}/output"
}
