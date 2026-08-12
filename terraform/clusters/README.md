# Upgrading Talos

Terraform does **not** upgrade Talos. An upgrade is two separate things that must
both happen, in this order:

1. `talosctl upgrade` on each node — the actual OS upgrade, in place.
2. Terraform config + state updated to describe the new version — bookkeeping only.

Doing (1) without (2) leaves Terraform believing the fleet is on the old release.
Doing (2) without (1) does nothing to the running nodes.

## `update = true` reprovisions, it does not upgrade

The per-node `update` flag is the module's mechanism for a **staged reprovision**.
It selects `update_version`'s image instead of `version`'s for that node, which
changes the disk's `file_id`. `file_id` is ForceNew, so bpg/proxmox **replaces the
VM** — a fresh disk, not an upgraded one:

```
proxmox_virtual_environment_vm.this["work-02"] must be replaced
  ~ file_id           = "...-v1.13.8-nocloud-amd64.img" -> (known after apply) # forces replacement
  ~ path_in_datastore = "202/vm-202-disk-0.raw"         -> (known after apply)
```

It is still the right tool for two jobs:

- **Rebuilding a node from scratch** on a new release, when nothing on it matters.
  This is what `clusters/dev/README.md` documents, and dev is disposable.
- **Expressing a partially-upgraded fleet.** `version` is global, so mid-rollout
  the config cannot say "these nodes are on the new release and those are not"
  without per-node `update` + `update_version`. Once every node has moved, set
  `version` to the new release and clear the flags.

It is the wrong tool for upgrading a **prod node that holds data**. Every prod
node currently carries Longhorn volumes on the `no-replicas` StorageClass
(`numberOfReplicas: 1`, `dataLocality: strict-local`) — one copy, pinned to that
node, which Longhorn cannot rebuild elsewhere. Replacing the VM deletes them.

The same applies to bumping `talos_image.version` and applying without the state
reconciliation in step 4: it changes `image_id`, therefore every VM's `file_id`,
therefore all eight VMs.

So: upgrade in place with `talosctl`, then reconcile Terraform. Reach for
`update = true` when you actually want a node rebuilt.

## Node inventory

| Node    | Host  | IP             | vm_id | Schematic |
|---------|-------|----------------|-------|-----------|
| VIP     | —     | 192.168.50.99  | —     | —         |
| ctrl-00 | trpro | 192.168.50.100 | 100   | non-GPU   |
| ctrl-05 | msa21 | 192.168.50.105 | 105   | non-GPU   |
| ctrl-06 | msa22 | 192.168.50.106 | 106   | non-GPU   |
| work-00 | trpro | 192.168.50.110 | 200   | **GPU**   |
| work-02 | m75q2 | 192.168.50.112 | 202   | non-GPU   |
| work-04 | m70q2 | 192.168.50.114 | 204   | non-GPU   |
| work-05 | msa21 | 192.168.50.115 | 205   | non-GPU   |
| work-06 | msa22 | 192.168.50.116 | 206   | non-GPU   |

Schematic IDs (from `terraform.tfstate`, derived from `talos/image/*.yaml`):

```
non-GPU  48bea7bcca5ee550b40c0708829ac911409408192aca4a5faa390f847d41b9b0
GPU      a3953709238dcdb47de26d7e848df3eebc0e504e1a15f4c92c196d8685589015
```

work-00 **must** use the GPU schematic — it carries
`nonfree-kmod-nvidia-production` and `nvidia-container-toolkit-production`. Using
the wrong one strips the drivers and the GPU disappears from the node.

Schematic IDs are version-independent; the factory resolves each extension to the
right version for the Talos release, so the nvidia driver moves with the OS.

## Procedure

### 0. Pick the path

Skipping minor versions is unsupported — go through every intermediate minor at
its latest patch. v1.11.5 → v1.13.8 means v1.11.5 → v1.12.9 → v1.13.8.

### 1. Warm the factory

The Image Factory builds artifacts on demand. The first request for a
schematic+version it has never built can take minutes, and Proxmox's metadata
fetch times out with `HTTP 596 — Connection timed out`. The GPU image is ~1.2 GB
and the most likely to trip this.

```sh
SCHEM=a3953709238dcdb47de26d7e848df3eebc0e504e1a15f4c92c196d8685589015
curl -sI "https://factory.talos.dev/image/$SCHEM/v1.13.8/nocloud-amd64.raw.gz" | head -3
```

Repeat until it returns `302` with a `content-length`. Do the same for the
non-GPU schematic.

### 2. Upgrade the OS, one host at a time

Each physical host may carry both a control plane and a worker. Never take down
two control planes at once — etcd quorum is 2 of 3.

```sh
export TC=clusters/prod/output/talos-config.yaml
SCHEM=48bea7bcca5ee550b40c0708829ac911409408192aca4a5faa390f847d41b9b0  # GPU id for work-00

talosctl --talosconfig $TC upgrade -n 192.168.50.105 \
  --image factory.talos.dev/installer/$SCHEM:v1.12.9
# wait for Ready, then repeat with :v1.13.8
```

Between every hop, wait for the node to return and — for control planes — for
etcd to report all members:

```sh
until kubectl get node ctrl-05 -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' | grep -q True; do sleep 15; done
until [ "$(talosctl --talosconfig $TC -n 192.168.50.105 etcd members | grep -c '')" -ge 4 ]; do sleep 15; done
```

There is no `--preserve` flag; preservation of the EPHEMERAL partition (and so
`/var/lib/longhorn`) is the default. Workers do not need draining — pods whose
volumes are strict-local on that node simply go Pending until it returns — but
draining first is cleaner if the node hosts anything without a peer.

### 3. Update the Terraform config

```hcl
# clusters/prod/talos_image.auto.tfvars
version        = "v1.13.8"
update_version = "v1.13.8"

# clusters/prod/talos_cluster.auto.tfvars
talos_machine_config_version = "v1.13.8"
```

`talos_machine_config_version` also feeds `talos_machine_secrets.talos_version`.
Verify the plan shows it as **updated in-place** — if it ever shows as replaced,
stop: that regenerates the cluster PKI.

### 4. Reconcile `file_id` in state

Bumping `version` creates new boot images and leaves each VM's `file_id` pointing
at the old one, which forces replacement. The VMs were genuinely built from the
old image and upgraded in place, so the fix is to correct state, not the
infrastructure. `terraform apply -refresh-only` cannot do this — refresh compares
state to reality, and reality already matches; the mismatch is state vs config.

Apply the new image downloads first, then patch state:

```sh
cd clusters/prod
terraform apply -target='module.talos.proxmox_virtual_environment_download_file.this'
cp terraform.tfstate /tmp/tfstate.backup
terraform state pull > /tmp/state.json
# rewrite every VM's disk[0].file_id: -vOLD-nocloud -> -vNEW-nocloud, then serial += 1
terraform state push /tmp/state-patched.json
terraform plan   # must show no proxmox_virtual_environment_vm actions
```

Gate on that plan. If any VM shows `must be replaced`, restore the backup.

Do **not** paper over this with `lifecycle { ignore_changes = [disk[0].file_id] }`.
It works, but it permanently blinds Terraform to boot-image drift.

### 5. Apply

```sh
terraform apply     # untargeted
terraform plan      # must end at "No changes"
```

This pushes regenerated machine configs to every node and rewrites the files in
`output/`. Config pushes to control planes restart kube-apiserver, so apply them
one at a time if you want to be careful:

```sh
terraform apply -target='module.talos.talos_machine_configuration_apply.this["ctrl-00"]'
```

`-target` only reaches resources inside `module.talos`. The `local_file` resources
that write `output/` live in the **root** module, so a targeted apply skips them
and the plan stays dirty until you run an untargeted apply.

## Kubernetes is upgraded separately

`talosctl upgrade` does not change the Kubernetes version. The kubelet image lives
in the machine config; the control-plane components are updated by
`talosctl upgrade-k8s`. A fleet on Talos v1.13.8 can sit on Kubernetes v1.34.0
indefinitely — Talos 1.13 supports 1.31–1.36.

Before running `upgrade-k8s`, note that `cluster.kubernetes_version` in tfvars is
currently **never passed** to `data "talos_machine_configuration"`. It is a no-op,
and the kubelet version in generated configs is the provider's default for the
Talos release. Wire it into `machine.kubelet.image` first, or an out-of-band
Kubernetes upgrade will be silently reverted by the next Terraform apply.

## CPU model

`talos/virtual-machines.tf` pins `cpu.type = "x86-64-v3"`. v3 is the highest level
every host supports, so live migration is unaffected:

| Host          | CPU                       | v3 | v4 (AVX-512) |
|---------------|---------------------------|----|--------------|
| trpro         | Threadripper PRO 3975WX   | ✅ | ❌ |
| msa21 / msa22 | Ryzen 9 7940HX            | ✅ | ✅ |
| m75q2         | Ryzen 5 PRO 4650GE        | ✅ | ❌ |
| m70q2         | i5-11400T                 | ✅ | ❌ |
| m70q5         | i5-14400T                 | ✅ | ❌ |

v2 must not be used: it predates AVX, and vLLM/PyTorch abort on a CPU without it
(`UCX library was compiled with avx but CPU does not support it`). `host` would
pin each VM to its own host's feature set and block migration.

Changing `cpu.type` or `ram_dedicated` is an in-place update that power-cycles the
VM — verify the plan says `update in-place`, never `must be replaced`, and roll it
out one node at a time with `-target`.

## kubeconfig

`output/kube-config.yaml` is generated pointing at whichever control-plane IP
Terraform talked to. Point it at the VIP instead so it survives any single control
plane going down:

```
server: https://192.168.50.99:6443
```

The apiserver certificate includes the VIP and all three control-plane IPs via
`cert_sans` in `talos_cluster.auto.tfvars`, so this needs no cert changes.
