<div align="center">

# DataFlareLabs Kubernetes Cluster

Repository for [Kubernetes](https://kubernetes.io/) cluster using [GitOps](https://en.wikipedia.org/wiki/DevOps) practices.

</div>

## Stack

- **Virtualization:** [Proxmox VE](https://www.proxmox.com/en/proxmox-virtual-environment)
- **OS:** [Talos Linux](https://talos.dev)
- **Provisioning:** [Terraform](https://www.terraform.io/), [Terragrunt](https://terragrunt.gruntwork.io/), [Task](https://taskfile.dev/), [UniFi](https://ui.com/) (DHCP reservations)
- **Terraform state:** [Cloudflare R2](https://developers.cloudflare.com/r2/)
- **Orchestration:** [Kubernetes](https://kubernetes.io/)
- **GitOps:** [Argo CD](https://argoproj.github.io/cd/)
- **Networking:** [Cilium](https://cilium.io/), [Gateway API](https://gateway-api.sigs.k8s.io/), [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- **Certificates:** [cert-manager](https://cert-manager.io/)
- **Secrets:** [1Password Connect](https://developer.1password.com/docs/connect/)
- **Storage:** [Longhorn](https://longhorn.io/)
- **Databases:** [CloudNativePG](https://cloudnative-pg.io/) (backups to R2), [Typesense](https://typesense.org/)
- **Messaging:** [RabbitMQ](https://www.rabbitmq.com/)
- **Task orchestration:** [Hatchet](https://hatchet.run/)
- **Observability:** [SigNoz](https://signoz.io/), OpenTelemetry
- **GPU:** [NVIDIA device plugin](https://github.com/NVIDIA/k8s-device-plugin), [vLLM](https://docs.vllm.ai/)

# Terraform

## Upgrading Kubernetes

1. Go to the cluster directory:

   ```sh
   cd terraform/clusters/prod
   ```

2. Pick the target version: the latest patch of the **next** minor version. Never skip a minor version.

   ```sh
   kubectl get nodes                                   # current version
   curl -sL https://dl.k8s.io/release/stable-1.XX.txt  # latest patch of 1.XX
   talosctl version --client --short                   # must be the cluster's Talos minor version
   ```

   Check that the running Cilium version lists the target version as tested on its [Kubernetes compatibility page](https://docs.cilium.io/en/stable/network/kubernetes/compatibility/). If it doesn't, upgrade Cilium first.

3. In `talos_cluster.auto.tfvars`, set `kubernetes_version` to that version. Change nothing else.

   ```hcl
   kubernetes_version           = "<version>"
   ```

4. Dry-run the upgrade:

   ```sh
   talosctl --talosconfig output/talos-config.yaml -n 192.168.50.100 upgrade-k8s --to <version> --dry-run
   ```

   - Expected: control-plane component and kubelet updates, CoreDNS changes, `config.k8s.io/owning-inventory` annotations, and a trailing-newline change in `cilium-envoy-config` / `hubble-relay-config`.
   - Stop if `DaemonSet/cilium`, `Deployment/cilium-operator` or `ConfigMap/cilium-config` changes. Terraform's Cilium render no longer matches ArgoCD's, and the upgrade would roll Cilium.

5. Plan:

   ```sh
   terragrunt plan
   ```

   - Expected: `talos_cluster.this` updated in place, every `talos_machine` updated in place with only `machine_configuration` changed, and every `local_file.machine_configs` replaced.
   - Stop if anything else is created, replaced or destroyed.
   - If the plan errors in `data.helm_template.cilium`, the Cilium chart doesn't support this Kubernetes version. Bump Cilium via ArgoCD first.

6. Apply:

   ```sh
   terragrunt apply
   ```

   - State is snapshotted to `~/tfstate-backups/` and R2 `backups/dataflarelabs/prod/` before Terraform runs.
   - Nodes don't reboot. Pods may restart briefly as each node's kubelet restarts.
   - If it fails partway, run `terragrunt apply` again. It continues where it stopped.

7. Verify:

   ```sh
   kubectl get nodes                    # all nodes show the new version
   kubectl get applications -n argocd   # all Synced / Healthy
   curl -sI https://api.gearhawk.io      # a Gateway route answers
   ```

   Use a route that goes through the Gateway. `docs.dataflarelabs.com` bypasses it.

8. Repeat from step 2 until you reach the target version.

Don't change `talos_image.version`, `talos_machine_config_version`, `talos_nodes.auto.tfvars` or `extra_manifests`. `extra_manifests` must stay matched to `k8s/infra/crds`.

> [!WARNING]
> Talos owns everything in its bootstrap manifests (`extra_manifests` and the Cilium inline manifest) and **prunes objects that drop out of them** on the next `upgrade-k8s`. Removing the Gateway API bundle from `extra_manifests` deletes the Gateway API CRDs, and with them every Gateway and HTTPRoute.

### If something goes wrong

- **Apply failed partway:** run `terragrunt apply` again.
- **Gateway routes fail after a Cilium change:** check `kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.envoy-xds-mode}'` is `split`. In `ads` mode every agent restart drops Gateway traffic on that node for about 60 s. If routes still return 503 `no healthy upstream`, run `kubectl -n kube-system rollout restart ds/cilium-envoy`.
- **The upgrade itself is bad:** fix forward. Kubernetes can't be downgraded.
- **The state is broken:**
  1. Find a snapshot:
     ```sh
     ls -t ~/tfstate-backups/prod-*
     aws s3 ls s3://dataflarelabs-tfstate/backups/dataflarelabs/prod/ --profile dataflarelabs-tfstate
     ```
  2. If a lock was left behind:
     ```sh
     terraform force-unlock <lock-id>
     ```
  3. Restore it:
     ```sh
     terraform state push -force <snapshot>
     ```
  4. Confirm there are no unexpected changes:
     ```sh
     terragrunt plan
     ```
