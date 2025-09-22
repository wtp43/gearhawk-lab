#!/bin/zsh

# NODE: work-00
NODE_IP="192.168.50.110"
MACHINE_CONFIG="./output/talos-machine-config-work-00.yaml"
USER_VOLUME="./post-bootstrap/work-00-user-volume.yaml"
COMBINED_CONFIG="./output/talos-machine-config-work-00-patched-vol.yaml"

# Combine both YAML files into a new file with document separator
cat "$MACHINE_CONFIG" "$USER_VOLUME" > "$COMBINED_CONFIG"

# Apply the new combined config using talosctl
talosctl apply-config -n "$NODE_IP" -f "$COMBINED_CONFIG"
talosctl get dv -n "$NODE_IP"
talosctl get mounts -n "$NODE_IP"
