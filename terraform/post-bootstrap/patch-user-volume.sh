#!/bin/zsh

# NODE: work-00
NODE_IP="192.168.50.110"
MACHINE_CONFIG="./output/talos-machine-config-work-00.yaml"
USER_VOLUME="./post-bootstrap/work-00-user-volume.yaml"

# Combine both YAML files with document separator
cat "$USER_VOLUME" >>"$MACHINE_CONFIG"

# Apply combined config using talosctl
talosctl apply-config -n "$NODE_IP" -f "$MACHINE_CONFIG"
