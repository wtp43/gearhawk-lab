"""Repack a symmetric 4-bit GPTQ checkpoint into compressed-tensors pack-quantized (same int4 values and scales)."""
import json, os, shutil, sys, time

import torch
from compressed_tensors.compressors.pack_quantized.helpers import pack_to_int32, unpack_from_int32
from safetensors import safe_open
from safetensors.torch import save_file

src, dst = sys.argv[1], sys.argv[2]
os.makedirs(dst, exist_ok=True)
cfg = json.load(open(f"{src}/config.json"))
q = cfg["quantization_config"]
assert q["bits"] == 4 and q["sym"] and not q["desc_act"], q
G = q["group_size"]
zero_offset = 1 if q.get("checkpoint_format", q.get("format")) == "gptq" else 0
SHIFTS = torch.arange(0, 32, 4, dtype=torch.int32)


def unpack_rows(x):  # [R/8, C] int32 packed along rows -> [R, C]
    return ((x.unsqueeze(1) >> SHIFTS.view(1, 8, 1)) & 0xF).reshape(-1, x.shape[1])


def unpack_cols(x):  # [R, C/8] int32 packed along cols -> [R, C]
    return ((x.unsqueeze(2) >> SHIFTS.view(1, 1, 8)) & 0xF).reshape(x.shape[0], -1)


index = json.load(open(f"{src}/model.safetensors.index.json"))
shards = sorted(set(index["weight_map"].values()))
new_map, ignore, checked = {}, set(), 0
t0 = time.time()
wmap = index["weight_map"]
handles = {}


def get(k):
    sh = wmap[k]
    if sh not in handles:
        handles[sh] = safe_open(f"{src}/{sh}", "pt")
    return handles[sh].get_tensor(k)


all_prefixes = sorted(k[: -len(".qweight")] for k in wmap if k.endswith(".qweight"))
quant_keys = {f"{p}.{s}" for p in all_prefixes for s in ("qweight", "qzeros", "scales", "g_idx")}
for shard in shards:
    out = {}
    prefixes = [p for p in all_prefixes if wmap[f"{p}.qweight"] == shard]
    for p in prefixes:
        qw, sc, qz = get(f"{p}.qweight"), get(f"{p}.scales"), get(f"{p}.qzeros")
        vals = unpack_rows(qw)
        n_in, n_out = vals.shape
        zeros = unpack_cols(qz) + zero_offset
        assert torch.all(zeros == 8), (p, zeros.unique())
        if f"{p}.g_idx" in wmap:
            assert torch.equal(get(f"{p}.g_idx").to(torch.int64), torch.arange(n_in) // G), p
        signed = (vals.t().contiguous() - 8).to(torch.int8)
        packed = pack_to_int32(signed, 4)
        if checked < 3:
            assert torch.equal(unpack_from_int32(packed, 4, torch.Size([n_out, n_in])), signed), p
            checked += 1
        out[f"{p}.weight_packed"] = packed
        out[f"{p}.weight_scale"] = sc.t().contiguous().to(torch.bfloat16)
        out[f"{p}.weight_shape"] = torch.tensor([n_out, n_in], dtype=torch.int64)
    for k in sorted(k for k, sh in wmap.items() if sh == shard and k not in quant_keys):
        t = get(k)
        out[k] = t
        if k.endswith(".weight") and t.ndim == 2 and "embed" not in k:
            ignore.add(k[: -len(".weight")])
    save_file(out, f"{dst}/{shard}", metadata={"format": "pt"})
    new_map.update({k: shard for k in out})
    print(f"{shard}: {len(prefixes)} quantized modules, {time.time() - t0:.0f}s", flush=True)

json.dump({"metadata": index.get("metadata", {}), "weight_map": new_map},
          open(f"{dst}/model.safetensors.index.json", "w"), indent=2)
if cfg.get("tie_word_embeddings"):
    ignore.add("lm_head")
cfg["quantization_config"] = {
    "quant_method": "compressed-tensors",
    "format": "pack-quantized",
    "quantization_status": "compressed",
    "config_groups": {"group_0": {
        "targets": ["Linear"],
        "format": "pack-quantized",
        "weights": {"num_bits": 4, "type": "int", "symmetric": True, "strategy": "group",
                    "group_size": G, "dynamic": False, "actorder": None, "observer": "minmax"},
        "input_activations": None, "output_activations": None,
    }},
    "ignore": sorted(ignore),
    "kv_cache_scheme": None,
}
json.dump(cfg, open(f"{dst}/config.json", "w"), indent=2)
for fn in os.listdir(src):
    if not (fn.endswith(".safetensors") or fn in ("config.json", "model.safetensors.index.json")):
        shutil.copy2(f"{src}/{fn}", dst, follow_symlinks=True)
print("ignore:", sorted({i.split(".")[-1] if "layers" in i else i for i in ignore}), len(ignore))
print("DONE", dst)
