#!/bin/bash
set -euo pipefail
if [ $# -ne 2 ]; then
  echo "usage (inside the vllm-openai pod): bench.sh <model path or HF snapshot dir> <served model name>" >&2
  exit 1
fi
M=$1; N=$2
run() {
  vllm bench serve --backend vllm --base-url http://127.0.0.1:8000 --model "$M" --served-model-name "$N" \
    --dataset-name random --random-input-len $2 --random-output-len $3 --ignore-eos \
    --max-concurrency $4 --num-prompts $(($4*4)) --seed $((700+$4)) --num-warmups 0 2>&1 \
  | awk -v l="$1 c=$4" '/Output token throughput/{o=$NF} /Total token throughput/{t=$NF} /Mean TTFT/{f=$NF} END{printf "%-8s total=%s out=%s meanTTFT=%sms\n", l, t, o, f}'
}
run prefill 4000 64 8; run prefill 4000 64 32
run decode 1000 256 8; run decode 1000 256 32; run decode 1000 256 64
