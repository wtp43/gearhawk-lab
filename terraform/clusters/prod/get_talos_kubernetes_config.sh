#!/bin/zsh

mkdir -p ~/.kube/
mkdir -p ~/.talos/
terragrunt output -raw kube_config >~/.kube/config
terragrunt output -raw talos_config >~/.talos/config
chmod 600 ~/.kube/config
chmod 600 ~/.talos/config
