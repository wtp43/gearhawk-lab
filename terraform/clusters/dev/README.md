# dev cluster

A throwaway 3-node Talos cluster that **reuses the same `../../talos` module as
prod**. Its purpose is to validate the Talos VIP as the Kubernetes API endpoint
and confirm failover when a control-plane node dies while etcd quorum holds.

etcd quorum for 3 nodes is 2, so the cluster tolerates exactly **one** node
loss: stop 1 VM → 2/3 up → quorum holds → VIP fails over. Stop 2 → 1/3 < 2 →
quorum lost → the VIP cannot move (etcd has no quorum) and the API is down.

## Layout

```
clusters/dev/
  main.tf                 module "talos" { source = "../../talos" }
  providers.tf            proxmox provider (creds from prod's proxmox.auto.tfvars)
  variables.tf            root var schemas
  output.tf               writes kubeconfig/talosconfig/machine-configs to output/
  talos_cluster.auto.tfvars   endpoint = VIP (.69), allowSchedulingOnControlPlanes
  talos_nodes.auto.tfvars     3 control planes: .60/.61/.62 on trpro/msa21/msa22
  talos_image.auto.tfvars     dev-owned image: version, update_version, -dev suffix
  image/                      dev's own schematic.yaml / gpu_schematic.yaml
  cilium-values.yaml          dev copy (cluster name talos-dev, id 2)
  Taskfile.yml
```

State is **local and separate** from prod (`clusters/dev/terraform.tfstate`), so
a dev `destroy` cannot touch prod.

## Addressing (all within 192.168.50.60-95, no prod overlap)

| Node         | Host   | IP            | vm_id |
|--------------|--------|---------------|-------|
| VIP          | —      | 192.168.50.69 | —     |
| ctrl-dev-00  | trpro  | 192.168.50.60 | 300   |
| ctrl-dev-01  | msa21  | 192.168.50.61 | 301   |
| ctrl-dev-02  | msa22  | 192.168.50.62 | 302   |

## Usage

```sh
task init
task plan      # review before first apply
task create
export KUBECONFIG=$(pwd)/output/kube-config.yaml   # server: https://192.168.50.69:6443 (the VIP)
kubectl get nodes
```

## Testing VIP failover

```sh
# which control-plane node currently holds the VIP
talosctl --talosconfig output/talos-config.yaml \
  -n 192.168.50.60,192.168.50.61,192.168.50.62 get addresses | grep 192.168.50.69

# stop the VIP holder's *VM* (not the physical host — prod shares these hosts).
# Either `talosctl shutdown -n <holder-ip>` or stop the VM in Proxmox.

# quorum (2/3) still holds; VIP should move and the API stay reachable:
kubectl get nodes          # keeps working against https://192.168.50.69:6443
```

## Testing a Talos upgrade

dev owns its image (`talos_image.auto.tfvars` + `image/`), independent of prod,
so you can trial a new Talos release here first.

```sh
# dev runs v1.13.4; prod is on v1.11.5.
# 1. set the target release in talos_image.auto.tfvars
#    update_version = "v1.14.0"
# 2. flip one node to the new image in talos_nodes.auto.tfvars
#    "ctrl-dev-02" = { ... update = true }
task plan      # only ctrl-dev-02 should change (reprovisioned onto v1.14.0)
task create
# 3. verify, then roll the rest by setting update = true on the others
talosctl --talosconfig output/talos-config.yaml -n 192.168.50.62 version
```

Each node's image carries the `-dev` suffix and dev's own schematic, so none of
this touches prod's images or nodes.

## Health gate

`task create` enforces the `talos_cluster_health` check (a 10-minute gate);
`task destroy` passes `-var skip_health_check=true` so teardown is never blocked
by an unhealthy cluster. To install without the gate while debugging, run
`terraform apply -var skip_health_check=true ...` directly.

## Caveats

- **Talos image is isolated, not shared.** dev sets `image.file_name_suffix =
  "-dev"` (talos_image.auto.tfvars), so it downloads the same image content from
  the factory but stores it as `talos-<schematic>-<version>-nocloud-amd64-dev.img`
  — a distinct file from prod's. dev and prod each manage their own ISO, so a dev
  `terraform destroy` only removes the `-dev` copy and never touches prod.
- **kubeconfig points at the VIP** (`192.168.50.69`), by design. Reach it from a
  host on the 192.168.50.0/24 L2 segment.
- Do **not** point `talosctl` endpoints at the VIP — use the node IPs
  (.60/.61/.62). The talosconfig this writes already does this correctly.
- **kubelet serving cert approver at bootstrap.** The kubelet uses
  `rotate-server-certificates`, so its `:10250` serving cert needs a CSR
  approver. Prod deploys `kubelet-serving-cert-approver` post-bootstrap (in
  `k8s/bootstrap_argocd.sh`), but the Talos 1.13.4 bootstrap health check fails
  without it (`KubeletStaticPodController ... tls: internal error`). dev applies
  the approver via `extra_manifests` so cert rotation works from the start.
