# Dell T640 GPU Server

Planned inference node: Dell PowerEdge T640 with dual Xeon Platinum 8268 and 3× RTX 3080 20GB (blower,
memory-modded, sourced from Taobao). Each GPU runs its own model replica; no tensor parallelism.

## Required hardware

| Item                                                 | Qty | Notes                                                                                                    |
| ---------------------------------------------------- | --- | -------------------------------------------------------------------------------------------------------- |
| Xeon Platinum 8268                                   | 2   | Both sockets required: slots 6/8 hang off CPU2, and Dell requires 2 CPUs for GPUs                        |
| DDR4 RDIMM, 2R, 16/32/64 GB                          | 12  | One DIMM per channel (6 per socket). 3200 sticks run at 2933                                             |
| RTX 3080 20GB blower, 2-slot, 2× 8-pin               | 3   | See [GPU purchase checks](#gpu-purchase-checks)                                                          |
| GPU power cable, CPU/EPS 8-pin → 2× 8-pin (6+2) PCIe | 3   | One per GPU. See [Power cables](#power-cables)                                                           |
| GPU power interposer board                           | 1   | Four `J_GPU_POWER_225W` connectors, one per GPU                                                          |
| High-performance middle fans (Fan3–Fan6)             | 4   | Fan1/Fan2 stay standard                                                                                  |
| External GPU fans, left (8DF31) and right (K22DD)    | 2   | Both required once a GPU is in slot 6 or 8                                                               |
| GPU air shroud (MRY2P)                               | 1   | Installed alongside the main air shroud                                                                  |
| GPU card holder                                      | 1   | Supports the far end of full-length cards                                                                |
| PSU, 1600 W / 2000 W / 2400 W Platinum               | 2   | Dell minimum for GPUs is 1100 W, but 3 GPUs + 2× 205 W CPUs is ~1.5 kW. 2000/2400 W need 200–240 V input |

Not supported with GPUs: the 18× 3.5" drive chassis, dual PERC, Fresh Air configs. Two 205 W CPUs or
300 W GPUs cap ambient at 30 °C.

## GPU slots

All four double-wide slots are Gen3 x16, wired directly to a CPU (no PCIe switch, no lane sharing).

| Slot | CPU  | Lanes    |
| ---- | ---- | -------- |
| 1    | CPU1 | Gen3 x16 |
| 3    | CPU1 | Gen3 x16 |
| 6    | CPU2 | Gen3 x16 |
| 8    | CPU2 | Gen3 x16 |

Use slots 1, 3 and one of 6/8. Three GPUs use 48 of the 96 CPU lanes.

## Bandwidth

| Path                          | Theoretical         | Realistic                                      |
| ----------------------------- | ------------------- | ---------------------------------------------- |
| 3080 VRAM (320-bit GDDR6X)    | 760 GB/s per card   | Full speed — on-card, the host cannot limit it |
| PCIe per GPU (Gen3 x16)       | 15.75 GB/s each way | ~12–13 GB/s                                    |
| DDR4 per socket (6 ch @ 2933) | 140.8 GB/s          | ~105–115 GB/s (estimate)                       |
| DDR4 both sockets             | 281.6 GB/s          | ~200–230 GB/s (estimate)                       |

- The 3080 supports PCIe 4.0 but runs at Gen3 here. With the model resident in VRAM this only costs
  model load time (~2 s for 16–20 GB) and a few ms for host-RAM features such as embedding offload.
- Do not run tensor parallelism across these cards: Gen3 links, no GeForce P2P on the stock driver, and
  the slots span both sockets so traffic would also cross UPI.
- Optional: pin each inference pod to the NUMA node of its GPU (kubelet Topology Manager
  `single-numa-node` + static CPU manager). Small gain.
- 24 DIMMs (2 per channel) drops memory to 2666 MT/s (~9% less bandwidth). System RAM bandwidth barely
  matters for GPU-resident inference, so buy RAM for capacity.

### EPYC vs Xeon memory bandwidth

AMD EPYC/Threadripper are built from chiplets (CCDs), each with a narrow link to the I/O die, so a
4-CCD part reaches roughly half of its memory channels' bandwidth. The Xeon 8268 is a monolithic die
with no CCDs, so its 24 cores can saturate all 6 channels. Either way, CPU memory bandwidth only matters
for CPU or RAM-offloaded inference, not models held in VRAM.

## Power

- Each GPU gets 225 W from the interposer cable + 75 W from the slot = **300 W max**.
- Stock 3080 is rated 320 W; the blower 3080 20GB draws ~350 W at full load. Both exceed the per-slot
  budget, so every card must be power-limited.

### Power limit

| Setting      | Value                                                          |
| ------------ | -------------------------------------------------------------- |
| Target       | 280 W (keeps cable draw ≤ 205 W, leaves margin for transients) |
| Hard ceiling | 300 W (cable at its 225 W rating)                              |
| Never        | Stock/unlimited — 350 W puts ~275 W through a 225 W connector  |

```
nvidia-smi -q -d POWER          # check min/default/max limits the VBIOS allows
nvidia-smi -pm 1                # persistence mode
nvidia-smi -i <idx> -pl 280     # per card
```

- Modded VBIOSes may report unusual min/max limits — confirm 280 W is inside the allowed range on
  each card before relying on it.
- The limit resets on reboot and driver reload. Apply it at boot on the node (e.g. a privileged
  DaemonSet that runs `nvidia-smi -pl` per card) and verify with `nvidia-smi --query-gpu=power.limit
--format=csv` before scheduling inference pods.
- Prefill is compute-bound, so the cap costs a few percent of prefill throughput; decode is
  bandwidth-bound and is barely affected.
- The limit is an average: Ampere cards spike well above it for milliseconds. Size PSUs with headroom.

## Power cables

Required layout: server end **8-pin CPU/EPS**, card end **2× 8-pin (6+2) PCIe**, ≥16–18 AWG.

- [MODDIY DELL-R530-PCIE2](https://www.moddiy.com/products/6339/GPU-8-Pin-to-Dual-8-Pin-PCIE-Power-Cable-for-Dell-PowerEdge-R530-R720.html) — 38 cm, 18 AWG, lists T640
- [COMeap 21-inch (53 cm)](https://www.comeap.com/COMeap-CPU-8-Pin-Male-to-Dual-8-Pin-6-2-Male-PCIe-Power-Adapter-Cable-for-Dell-PowerEdge-T620-T630-T640-and-NVIDIA-Tesla-GPU-21-inch-53cm-p373003.html) — 18 AWG, lists T620/T630/T640

Length: Dell's own T640 GPU cables are 51–61 cm and COMeap says its 38 cm version is short for T6x0.
Measure from the interposer board to the GPU sockets in slots 6/8 before buying a 35–38 cm cable.

Do not use:

| Cable                                                             | Why                                   |
| ----------------------------------------------------------------- | ------------------------------------- |
| Dell DRXPD (8-pin → 6 + 6+2)                                      | One output is 6-pin                   |
| Dell 5D9DW, "8-pin to 8-pin" Tesla cables (K80/M40/P40/P100/V100) | Single output, EPS card end for Tesla |
| 8-pin → 8+6 cables (incl. Dell N08NH / 9H6FV)                     | One output is 6-pin                   |

Sellers attach part numbers such as J30DG loosely — go by the pictured connectors.

## Cooling

- iDRAC cannot read GeForce temperatures, so server fans do not react to GPU heat.
- Keep iDRAC's **third-party PCIe card default cooling response** enabled (do not apply the common
  homelab command that disables it), and set a fan speed offset or minimum fan speed.
- Monitor GPU temperatures with `nvidia-smi` / DCGM.
- Blower cards exhaust out the rear bracket, matching server airflow. Fill empty slots and bays with
  blanks so air goes through the cards.

## GPU purchase checks

The 3080 20GB is a third-party memory mod (no warranty; early-failure risk). Some mods use a new PCB with
a 16-pin 12VHPWR connector instead of 2× 8-pin. Ask the seller before buying, and request a photo of the
power connectors and bracket end:

| Question                             | Want     |
| ------------------------------------ | -------- |
| 供电接口是双8pin还是16pin(12VHPWR)？ | 2× 8-pin |

## References

- [Dell PowerEdge T640 Technical Guide](https://i.dell.com/sites/csdocuments/product_docs/en/poweredge-t640-technical-guide.pdf) (slot table, memory speeds, GPU restrictions, PSU options)
- [Dell PowerEdge T640 Installation and Service Manual](https://www.gotomojo.com/wp-content/uploads/2019/07/Dell-PowerEdge-T640-Owners-Manual.pdf) (GPU card restrictions, GPU power interposer board)
