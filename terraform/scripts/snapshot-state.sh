#!/bin/sh
set -eu
umask 077
cluster="$1"
dir="$HOME/tfstate-backups"
file="$dir/$cluster-$(date +%F-%H%M%S).tfstate"
mkdir -p "$dir"
terraform state pull > "$file"
AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
  aws s3 cp "$file" "s3://dataflarelabs-tfstate/backups/dataflarelabs/$cluster/$(basename "$file")" \
  --profile dataflarelabs-tfstate --only-show-errors
find "$dir" -name "$cluster-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].tfstate" -mtime +7 -delete
echo "state snapshot: $file"
