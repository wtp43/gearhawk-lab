# TODOs

## Hardware and maintenance

- Fit NVMe heatsinks on msa21 and msa22: their NM790s run at 70–76°C and throttle above 90°C, which stalled the etcd leader (ctrl-06 on msa22) on 2026-09-28.
- Repaste the RTX 3090 and compare hot spot and memory junction temperatures before and after:
  - Find a way to read both. NVML/DCGM usually only report the core temperature on GeForce cards, so check what `dcgm-exporter` actually exposes first.
  - Before: record core, hot spot and memory junction temperatures, fan speed, power draw and clocks at idle and after ~20 minutes of sustained vllm-openai load. Note the room temperature.
  - Repaste. While the card is open, check the thermal pads, since memory junction temperature depends on them rather than the paste.
  - After: repeat the same load at a similar room temperature and compare the numbers.

## Storage

- Rename the `no-replicas` StorageClass: the name is misleading, since it actually keeps one Longhorn replica, strict-local. StorageClass names and `storageClassName` on a PVC are both immutable, so add a new class with identical parameters (e.g. `longhorn-single-local`) and move each workload onto it. Delete `no-replicas` only once no PVC references it; volume expansion fails if a PVC's class is missing.
  - Multi-instance CNPG (`infra`, `hatchet`, `data-warehouse`): change `storage.storageClass`, then run `kubectl cnpg destroy` on one replica at a time so it re-clones onto the new class. Switch over and do the old primary last.
  - Single-instance CNPG (`dev`, `solidtime`): temporarily set `instances: 2`, switch over to the new instance, destroy the old one, then scale back.
  - `vllm-openai`: the model cache re-downloads, so swap the PVC. For `spark-dashboard`, check what its PVC holds before swapping.
  - Typesense (`typesense-cluster`, `typesense-dev`) and RabbitMQ: the RabbitMQ operator refuses storage class changes, and the Typesense operator's behaviour is untested. Do it during a rebuild or as a pod-by-pod PVC swap, trying `typesense-dev` first.
  - Never force a Replace sync on a PVC to change its class: `reclaimPolicy: Delete` destroys the data.

## Documentation

- Write detailed homelab infrastructure docs in `README.md`, modelled on https://github.com/niklasfrick/homelab. Today the README has a flat Stack list plus the Talos/Kubernetes upgrade runbook. Add:
  - Component tables grouped by subsystem (platform, networking, storage, databases, observability, security, GPU/compute), each saying what the component does here.
  - A hardware and cluster table: Proxmox hosts, the Talos VMs on each (prod and dev), node roles, and GPU/disk notes such as the 3090 and work-00's IronWolf.
  - A network quick reference: node IPs, VIP, pod/service CIDRs, and how Cloudflare Tunnel and the Cilium Gateway route external traffic.
  - An annotated repository layout covering `terraform/`, `k8s/` (sets, infra, apps), `dev/` and `Taskfile.yml`.
  - Day 0/1/2 procedures:
    - Bootstrap via Terragrunt.
    - ArgoCD hand-off.
    - Ongoing ops, linking the existing upgrade runbook and CNPG backup/restore.

## Renames

- Rename the repo `wtp43/gearhawk-lab` to `wtp43/dataflarelabs-infrastructure`. GitHub redirects the old URL after a rename, so do the rename first and then update references while the redirect covers the gap:
  - This repo:
    - `repoURL` and `sourceRepos` in `k8s/sets/*`, every `k8s/**/application-set.yaml` and `project.yaml`, `k8s/docs/argocd.yaml`, and `k8s/infra/gpu/nvidia/{nvidia-device-plugin,dcgm-exporter}.yaml`.
    - `terraform/clusters/dev/bootstrap.tf`.
    - The README title. Also fix the stale R2 key in `terraform/clusters/dev/README.md`: it says `gearhawk-lab/dev`, but `backend.tf` uses `dataflarelabs/dev`.
    - Run `git grep -i gearhawk-lab` afterwards to catch anything else.
  - ArgoCD: update the repository credential secret URL if it is repo-scoped, then hard-refresh and check every Application still syncs.
  - gearhawk repo:
    - `DEPLOYMENT_REPO` in `.github/workflows/build-and-update-{api-gearhawk,web-gearhawk,crawlers,data-pipeline-workers}.yml` and `trigger-vllm-build.yml`.
    - `.claude/skills/gearhawk-*/SKILL.md`.
    - `docs/talos-cluster-terraform.md`.
    - Check that the CI token/deploy key that pushes image bumps still has access after the rename.
  - Other repos: grep `dataflarelabs-website` and the docs site for references.
  - Local:
    - Rename `~/Projects/dataflarelabs/gearhawk-lab` and update git remotes.
    - Move the Claude Code memory dir `~/.claude/projects/-Users-wt-Projects-dataflarelabs-gearhawk-lab` to match the new path, otherwise the memories stop loading.
- Rename the 1Password vault `gearhawk-k8s` (e.g. to `dataflarelabs-infrastructure`). Every `OnePasswordItem` `itemPath` references the vault by name, so first switch them to the vault UUID (or rename the vault and update all `itemPath`s in one commit). Check that the Connect server's vault access and the Terraform service account still resolve it afterwards.
- Rename the gearhawk repo to `gearhawk`.
