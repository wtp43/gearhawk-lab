#!/bin/sh
set -eu
op item get r2-dataflarelabs-tfstate-api-token --vault gearhawk-k8s --format json --reveal |
  jq '{
    Version: 1,
    AccessKeyId: (.fields[] | select(.label == "access-key-id") | .value),
    SecretAccessKey: (.fields[] | select(.label == "secret-access-key") | .value)
  }'
