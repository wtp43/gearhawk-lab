#!/bin/sh
set -eu
: "${OP_SERVICE_ACCOUNT_TOKEN:=$(security find-generic-password -a "$USER" -s op-service-account-gearhawk-k8s -w)}"
export OP_SERVICE_ACCOUNT_TOKEN
op item get r2-dataflarelabs-tfstate-api-token --vault gearhawk-k8s --format json --reveal |
  jq '{
    Version: 1,
    AccessKeyId: (.fields[] | select(.label == "access-key-id") | .value),
    SecretAccessKey: (.fields[] | select(.label == "secret-access-key") | .value)
  }'
