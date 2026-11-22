# Known Issues

## Longhorn volumes are `unlabeled_t` under Talos SELinux

**Status:** open, worked around on the ClickHouse volume. **Upstream:**
[siderolabs/talos#14875](https://github.com/siderolabs/talos/pull/14875) (the CRI relabels unlabeled volumes;
open as of 2026-11-22), [longhorn/longhorn#12318](https://github.com/longhorn/longhorn/issues/12318) (`seLinuxMount`
support). Background: [siderolabs/talos#14182](https://github.com/siderolabs/talos/issues/14182).

### Symptom

work-00's console and `talosctl dmesg` fill with:

```
audit: audit_lost=4444477 audit_rate_limit=4096 audit_backlog_limit=8192
audit: rate limit exceeded
```

`talosctl -n <node> logs auditd` shows `avc: denied { write ... }` from `pod_t` on `tcontext=...unlabeled_t`,
with `permissive=1`. The writes succeed. The flood costs kernel CPU and drops other audit records.

### Cause

CSI volumes are mounted by the driver, outside Talos's mount manager, so nothing labels them. Every Longhorn
volume in the cluster, old or new, holds `unlabeled_t` files, and every write a pod makes there is logged as a
permissive denial. ClickHouse writes enough to exceed the 4096/s audit rate limit. Clusters created before Talos
1.10 have this problem; this one is older.

### Why the StorageClass workaround doesn't work here

The workaround from #14182 is a mount option that labels the whole filesystem at mount time:

```yaml
mountOptions:
  - context=system_u:object_r:ephemeral_t:s0
```

1. Use `ephemeral_t` on Talos v1.14. `pod_file_t` exists only in newer policy; a v1.14.1 kernel rejects it
   (`security_context_str_to_sid ... failed with errno=-22`). Talos main still lets pods write `ephemeral_t`.
2. Longhorn passes the flag to `mount`, but libmount in the CSI plugin image drops it ("SELinux fix options /
   remove context" under `LIBMOUNT_DEBUG=all`). libselinux reports SELinux as disabled unless
   `/etc/selinux/config` exists, and the image has none. With that file present, the context mount works. The
   `longhorn-csi-plugin` DaemonSet belongs to Longhorn's driver deployer, so patching it in place doesn't stick.

### Workaround: relabel a volume once

New files inherit their directory's label, so a one-time relabel fixes a volume for good. It runs online with no
pod restart and touches only SELinux xattrs. From a privileged pod on the volume's node, with hostPath mounts of
`/var/lib/kubelet` (`mountPropagation: HostToContainer`) and `/sys`:

```sh
mkdir -p /etc/selinux && printf 'SELINUX=permissive\nSELINUXTYPE=talos\n' > /etc/selinux/config
P=$(grep -E '<pvc-id>/mount ' /proc/mounts | awk '{print $2}' | head -1)
chcon -R --no-dereference system_u:object_r:ephemeral_t:s0 "$P"
chcon -R --no-dereference system_u:object_r:ephemeral_t:s0 "$P"   # second pass for files created during the first
```

Run it in a namespace that enforces the `privileged` Pod Security level (e.g. `gpu-power`).

| Volume                                    | Workload   | Relabeled  | Result                                         |
| ----------------------------------------- | ---------- | ---------- | ---------------------------------------------- |
| `pvc-8425f0b9-0530-407b-8d69-3167005cc299` | ClickHouse | 2026-11-22 | 494k files; rate-limit warnings stopped        |

The other volumes are still unlabeled: about 23 denials a minute from Postgres on work-00, well under the
limit. New PVCs start unlabeled.

### When upstream lands

With #14875 in a Talos release and per-pod SELinux categories enabled, the CRI relabels volumes itself. At that
point check `ls -Z` on a fresh PVC, retire the manual relabel, and close this entry. Before switching SELinux
to enforcing, every volume must be labeled, or pods lose write access.
