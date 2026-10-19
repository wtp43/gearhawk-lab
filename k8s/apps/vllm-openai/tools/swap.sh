#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
f=${1:-}
if [ -z "$f" ] || [ ! -f "$f" ]; then
  echo "usage: tools/swap.sh <deployment file>" >&2
  ls deployment*.yaml >&2
  exit 1
fi
sed -i -E "s/^  - deployment[^ ]*\.yaml$/  - $f/" kustomization.yaml
grep -q "^  - $f$" kustomization.yaml
kubectl kustomize . | python3 -c '
import json, sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d and d["kind"] in ("ConfigMap", "Deployment")]
json.dump({"apiVersion": "v1", "kind": "List", "items": docs}, sys.stdout)
' | kubectl apply -f - 2>&1 | grep -v "^Warning: would violate PodSecurity"
kubectl -n vllm-openai rollout status deploy/vllm-openai --timeout=20m
