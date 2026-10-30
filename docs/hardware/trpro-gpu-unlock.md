# trpro RTX 3090 Unlock

GeForce cards run fp16/bf16 tensor math with fp32 accumulation at half rate, set by a hardware flag.
[gpu-unlock](https://github.com/Zagitta/gpu-unlock) is a kernel module that clears that flag at boot.
It runs on the Proxmox host `trpro`, before `vfio-pci` passes the 3090 (`0000:41:00.0`) to `work-00`
(VM 200). Nothing changes in Talos, Kubernetes or Terraform.

The Qwen model on `vllm-openai` benefits even though it is quantized: W4A16 and int8 Marlin only store
the weights as integers and run the math in fp16 with fp32 accumulation, and FlashInfer and the
linear-attention kernels do the same. Prefill and batched throughput get faster; single-stream decode
is memory-bound and doesn't change.

## Boot flow

1. The initramfs `init-top/gpu-unlock` hook loads `gpu_unlock` before udev starts.
2. With `gpu_unlock.targets=0000:41:00.0` on the kernel command line, it starts the card's SEC2 with
   NVIDIA's 610.43.03 Booter firmware, opens the speed registers (SS0 `0x88888888`, SS1 `0x8`) and
   resets the card (FLR), which leaves the setting in place.
3. `vfio_pci` loads later from `/etc/modules` and claims the card; the VM starts.
4. The guest driver (Talos `nonfree-kmod-nvidia-production`, 595.91.07) boots the card as if it were
   cold.

The setting survives FLR (the module checks the registers after its own FLR) and is lost only when
the card loses power. The 3090's `reset_method` is `flr bus`, it reports `NoSoftRst+`, and the slot
has no D3cold power resources, so VM start/stop and guest reboots should keep it. If the card is
already bound to a driver or was initialised since power-on, the module skips it.

## Installed on trpro

| Item                                 | Version / path                                                             |
| ------------------------------------ | -------------------------------------------------------------------------- |
| `gpu-unlock-dkms`                    | 2.0.0, upstream commit `7eb51bccae0a0b7e599e084d971170e9a1e82d0c`          |
| `gpu-unlock-firmware`                | 2.0.0, firmware from NVIDIA 610.43.03 in `/lib/firmware/gpu-unlock`        |
| `dkms`, `gcc`, `make`, `dpkg-dev`    | Debian 13, `--no-install-recommends`                                       |
| `proxmox-headers-7.0.14-19-pve`      | Headers for the running kernel only                                        |
| Kernel argument                      | `/etc/default/grub.d/gpu-unlock.cfg`                                       |
| Package files                        | `/root/gpu-unlock-2.0.0/*.deb`                                             |

The recovery boot entry doesn't get the argument, so it boots without the unlock.

| File                                            | sha256                                                             |
| ----------------------------------------------- | ------------------------------------------------------------------ |
| `gpu-unlock-dkms_2.0.0_all.deb`                 | `4038efc75b957a7f1db432abb0aa64cee51006572b3fd5bcc9de9933e723d3c8` |
| `gpu-unlock-firmware_2.0.0_all.deb`             | `3c1b34d628aed9923d8aca5459fe2463b2a49c30481c99ece3326698ff40f51c` |
| `NVIDIA-Linux-x86_64-610.43.03-no-compat32.run` | `e084451db730a6df29d3d74f655749c4d236e3c945f7d94b5205e84318fe2f90` |
| `NVIDIA-kernel-module-source-610.43.03.tar.xz`  | `7e118923c7a23edc36114d63273a46e3e04e9af98695a42203e7ac2dfe9fc1dc` |

## Build

On `dev`, in a throwaway Debian 13 container, so build tools and the NVIDIA downloads stay off the
hypervisor:

```sh
git clone https://github.com/Zagitta/gpu-unlock ~/build/gpu-unlock
cd ~/build/gpu-unlock && git checkout <commit>
docker run --rm -v $PWD:/src -w /src -e HOME=/root debian:13 bash -c '
  apt-get update && apt-get install -y --no-install-recommends \
    build-essential debhelper dh-dkms python3 zstd git xz-utils ca-certificates
  git config --global --add safe.directory /src
  make deb INPUTS=/src/.inputs'
```

The packages land in `build/deb/`. Copy them to `/root/gpu-unlock-<version>/` on trpro and install:

```sh
apt-get install --no-install-recommends dkms gcc proxmox-headers-$(uname -r) \
  ./gpu-unlock-firmware_<version>_all.deb ./gpu-unlock-dkms_<version>_all.deb
```

## Verify

On trpro after boot:

```sh
journalctl -k -b | grep gpu_unlock    # stage=flr ... ss0=0x88888888 ss1=0x8, then "unlocked"
lspci -nnk -s 41:00                   # still "Kernel driver in use: vfio-pci"
```

In the guest, a bf16 matmul tells locked from unlocked: the locked card tops out around 75 TFLOPS.

## Kernel upgrades

DKMS rebuilds the module only for kernels that have headers. `proxmox-default-headers` isn't installed
because it would also have pulled in a newer kernel; add it with the next kernel upgrade:

```sh
apt-get install --no-install-recommends proxmox-default-headers
```

After any kernel upgrade, `dkms status` must list `gpu-unlock/2.0.0` as `installed` for the new
kernel. If it isn't, the card boots locked and nothing else reports it.

## Rollback

```sh
rm /etc/default/grub.d/gpu-unlock.cfg && update-grub    # then reboot
apt-get purge gpu-unlock-dkms gpu-unlock-firmware       # optional; rebuilds the initramfs
```

For a single boot without the unlock, pick the recovery entry or edit the argument out in GRUB
through the BMC console (192.168.50.30).

## Results

Measured 2026-10-30 at the 250 W cap.

4096² matmul in a pod on `work-00` (vLLM scaled to 0):

| dtype | Locked                   | Unlocked                  | Change |
| ----- | ------------------------ | ------------------------- | ------ |
| bf16  | 61.6 TFLOPS @ 1,680 MHz  | 96.5 TFLOPS @ 1,335 MHz   | +57%   |
| fp16  | 60.4 TFLOPS @ 1,650 MHz  | 90.8 TFLOPS @ 1,245 MHz   | +50%   |

The unlock held after a guest reboot (`talosctl reboot`) and a `qm shutdown`/`qm start` with 30 s in
D3hot: bf16 96.6 and 97.3 TFLOPS.

`tools/bench.sh` on HyperQwen `batch` (Qwen3.8-27B W4A16), total tok/s:

| Run                  | Locked | Unlocked | Change |
| -------------------- | ------ | -------- | ------ |
| prefill 4000/64 c=8  | 1,651  | 1,736    | +5%    |
| prefill 4000/64 c=32 | 1,687  | 1,803    | +7%    |
| decode 1000/256 c=8  | 944    | 976      | +3%    |
| decode 1000/256 c=32 | 1,462  | 1,539    | +5%    |
| decode 1000/256 c=64 | 1,425  | 1,547    | +9%    |

HyperQwen gains far less than the matmul because its prefill already runs above the locked
fp16/fp32-accumulate rate (~1,700 tok/s × 54 GFLOP/token ≈ 90 TFLOPS > 61.6), so its main GEMMs use a
path the lock doesn't affect. Only the rest (attention and the other bf16 kernels) speeds up. Models
that run their GEMMs in plain bf16/fp16 should gain more.
