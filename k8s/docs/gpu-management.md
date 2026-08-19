# K8s GPU Management

Spec for running heterogeneous GPUs on `work-00` with per-card scheduling and per-card power limits.
Written to be pasted into Superthread; kept here because no Superthread integration is wired up yet.

## Current state

- `work-00` holds a single RTX 3090. It is the only GPU node (`nvidia.com/gpu: 1`).
- Drivers come from Talos extensions, not a GPU Operator:
  - `extensions.talos.dev/nonfree-kmod-nvidia-production=595.71.05-v1.13.8`
  - `extensions.talos.dev/nvidia-container-toolkit-production=595.71.05-v1.19.1`
- `RuntimeClass/nvidia` plus the standalone `nvidia-device-plugin` in `kube-system`.
- Card envelope: default 370 W, min 100 W, max 380 W, persistence mode enabled.
- UUID `GPU-f303736f-ed53-32b9-edb4-5495556a23d2`, bus `00000000:01:00.0`.

Mutual exclusion between `vllm` and `vllm-openai` today is an accident of scarcity: one GPU,
two claimants, so the scheduler serialises them. Adding a second card silently ends that.

## Problem 1 — targeting a specific GPU

`nvidia.com/gpu: 1` is a fungible request. With two different cards there is nothing stopping the
26B model landing on the weaker one.

Setting `NVIDIA_VISIBLE_DEVICES=<uuid>` with no resource request does pin the card, but it bypasses
device-plugin accounting — the same failure the `vllm-openai` manifest already warns about for
`nodeName`. Nothing then prevents two pods claiming one card.

### Approach: pattern-based resource names

The device plugin supports mapping a device-name pattern to a distinct resource name
(`api/config/v1/resources.go`, present since at least v0.13.0):

```yaml
version: v1
resources:
  gpus:
    - pattern: "*3090*"
      name: nvidia.com/rtx3090
    - pattern: "*<second model>*"
      name: nvidia.com/<second>
```

Each card becomes its own countable resource:

```yaml
# vllm-openai        -> the 3090
resources: { limits: { nvidia.com/rtx3090: 1 } }
# vllm-openai2       -> the weaker card
resources: { limits: { nvidia.com/<second>: 1 } }
```

Resource names are forced under the `nvidia.com/` prefix by `NewResourceName`.

Properties:

- The scheduler enforces placement; no env-var bypass.
- Two identical cards form a pool of 2 — pods get distinct physical devices, because kubelet's
  device manager allocates from `healthy − allocated` and passes explicit device IDs to the plugin.
  A third pod stays `Pending` with `Insufficient nvidia.com/rtx3090`.
- Keeping `vllm` and `vllm-openai` both on `nvidia.com/rtx3090` preserves their mutual exclusion
  deliberately rather than by accident.
- Limitation: patterns match on product name, so two identical 3090s cannot be told apart. Fine
  unless the slots differ meaningfully (x16 vs x4).

### Cutover

Renaming the advertised resource is a coordinated change. The moment the plugin stops advertising
`nvidia.com/gpu`, anything still requesting it becomes unschedulable — `vllm`, `vllm-openai`, and
`runtime-test`. Plugin config and all consumers must land in the same commit. Do this before the
second card arrives so only one variable is in play.

## Problem 2 — power limits

Talos is immutable with no shell, so `nvidia-smi -pl` cannot be run on the host and there is no
systemd unit to hang it off. It has to run in a pod.

Requirements:

1. Device access — `runtimeClassName: nvidia`, `NVIDIA_VISIBLE_DEVICES=all`,
   `NVIDIA_DRIVER_CAPABILITIES=utility`.
2. Privilege — setting the limit is `nvmlDeviceSetPowerManagementLimit`. `SYS_ADMIN` is sufficient;
   full `privileged: true` is not needed. The device plugin already uses exactly this.
3. No `nvidia.com/gpu` request — otherwise it competes with vLLM for a card.
4. A namespace with `pod-security.kubernetes.io/enforce: privileged`. The cluster enforces
   **baseline**, which rejects `SYS_ADMIN` and hostPath. `signoz` and `longhorn-system` already
   set the label; a new namespace must too, or use `managedNamespaceMetadata` on the Application.

### Why a DaemonSet and not a Job

The limit lives in the driver, not on disk. It resets on node reboot and on driver reload — which
includes Talos upgrades, since the driver is a node extension. A Job is terminal and will not re-run,
so the limit silently disappears at the next reboot. A DaemonSet pod is bound to node lifecycle and
re-applies on every restart. It is a reconciler that happens to have one replica.

Select on the extension label rather than hostname, so a future GPU node is covered with no edit:

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: extensions.talos.dev/nonfree-kmod-nvidia-production
              operator: Exists
```

`Exists`, not equality — the value carries the driver version and changes on every bump.

### Image

`nvidia-smi` is bind-mounted in by the container toolkit, so a CUDA image is unnecessary.
`debian:stable-slim` (~30 MB) works; `busybox:glibc` does not (`libdl.so.2` missing).

### Applying per-card limits

Key the policy on model name so it can be written before the hardware arrives, apply via bus ID,
and clamp into each card's own envelope — `nvidia-smi -pl` errors on an out-of-range value rather
than clamping.

```sh
nvidia-smi -pm 1
nvidia-smi --query-gpu=uuid,pci.bus_id,name,power.min_limit,power.max_limit \
           --format=csv,noheader,nounits |
while IFS=, read -r uuid bus name minw maxw; do
  name=$(echo "$name" | xargs)
  case "$name" in
    *"RTX 3090"*)     want=280 ;;
    *"<second card>"*) want=<W> ;;
    *)                want=$(awk "BEGIN{printf \"%d\", $maxw*0.80}") ;;
  esac
  want=$(awk "BEGIN{w=$want; if(w<$minw)w=$minw; if(w>$maxw)w=$maxw; printf \"%d\", w}")
  nvidia-smi -i "$bus" -pl "$want" || echo "FAILED: $name ($bus)"
done
```

Run it in a privileged **init** container with a `pause` main container, so nothing long-lived holds
`SYS_ADMIN`.

### Choosing a wattage

On a 3090 doing LLM inference, ~250–280 W typically costs under 10% throughput for ~25–30% less
power, because the top of the clock curve is disproportionately expensive. Decode on a low-active
MoE is memory-bandwidth-bound, so the penalty may be smaller still. Measure rather than assume —
`DCGM_FI_DEV_POWER_USAGE` gives the timeseries once dcgm-exporter is scraped into SigNoz.

## Open items

- Second card model and target wattage are unknown; both the plugin pattern and the power case
  statement need them.
- Decide whether `vllm` and `vllm-openai` should stay mutually exclusive once a second 3090 exists,
  or be allowed to run concurrently on separate cards.
- The comment in `k8s/apps/vllm-openai/deployment.yaml` about the scheduler guaranteeing exclusivity
  goes stale as soon as capacity exceeds 1.
