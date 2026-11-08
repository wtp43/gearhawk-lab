# Gemma 4 26B-A4B replacement candidates

Which open-weight LLMs could replace `cyankiwi/gemma-4-26B-A4B-it-qat-AWQ-INT4` on the single RTX 3090
behind `vllm-openai` (`k8s/apps/vllm-openai/deployment-gemma4-a4b.yaml`), with text prefill at least as
fast as Gemma, better code generation, and less sensitivity to prompt wording. Researched 2026-10-16
from model cards, `config.json` files, vLLM source at tag `v0.31.0`/`main`, and vLLM issues and PRs.
Gemma, Qwen3.8-27B, Mellum2.1, Nemotron 3.5 Lightning and LFM2.5-24B-A2B have since been benchmarked on
our card (2026-10-16 to 2026-10-18); see [Measured on our 3090](#measured-on-our-3090). Every other prefill
figure is either a cited measurement from other hardware or an estimate whose arithmetic is shown.

## Measured on our 3090

`vllm bench serve` against the live `vllm-openai` pod on work-00 (RTX 3090, 250 W cap, vLLM 0.31.0 unless
noted), random dataset, `--ignore-eos`, no warm-up, prefix caching off. Each run took under 40 s and none
preempted.
- **Prefill:** total tok/s, 4000-token prompts, 64 output tokens, 32 prompts (16 for Qwen3.8).
- **Decode:** output tok/s, 1000-token prompts, 256 output tokens.
- **int8:** `VLLM_MARLIN_INPUT_DTYPE=int8` (W4A8 on int8 tensor cores).

| Model | Quant | Max seqs | Prefill c=8 | Prefill c=32 | Decode c=8 | Decode c=32 | Decode c=64 |
|---|---|---|---|---|---|---|---|
| **LFM2.5-24B-A2B, int8** | aiprimebuilds GPTQ sym g32, repacked to compressed-tensors | 64 | **13,506** | **15,865** | **673** | **1,437** | **1,893** |
| LFM2.5-24B-A2B | same, plain GPTQ (no int8) | 64 | 9,493 | 10,475 | 660 | 1,201 | 1,468 |
| Nemotron 3.5 Lightning, int8 | useful-quants W4A16 + PR #61405 patch | 32 | 10,680 | 11,726 | 645 | 1,050 | — |
| Nemotron 3.5 Lightning | same, no int8 | 32 | 6,532 | 6,868 | 554 | 808 | — |
| Mellum2.1-12B-A2.5B | cyankiwi AWQ-INT4 (asymmetric, so no int8) | 64 | 9,303 | 9,918 | 592 | 868 | 907 |
| Gemma 4 26B-A4B (baseline) | cyankiwi AWQ-INT4 + int8 MLP/encoder patches | 64 | 8,821 | 9,040 | 484 | 620 | 625 |
| Qwen3.8-27B (HyperQwen, dense) | AutoRound W4A16, vLLM 0.29.0 | — | 1,670 | 1,704 (c=16) | 191 | 255 (c=16) | — |

Single-request (c=1) runs: Gemma 4,727 prefill / 125 decode, Mellum 6,007 / 194.

**LFM2.5 notes** (`k8s/apps/vllm-openai/deployment-lfm25.yaml`, uncommitted on dev, 2026-10-18):
- Flags: `--max-model-len=32768 --max-num-seqs=64 --max-num-batched-tokens=8192 --async-scheduling
  --no-enable-prefix-caching --gpu-memory-utilization=0.92`, compilation config
  `{"max_cudagraph_capture_size":64,"custom_ops":["+rms_norm","+silu_and_mul"]}`,
  `--reasoning-parser=deepseek_r1 --enable-auto-tool-choice --tool-call-parser=lfm2`, env
  `VLLM_MARLIN_INPUT_DTYPE=int8`, plus the PR #61405 startup patch.
- vLLM 0.31's GPTQ MoE path rejects int8 activations on 4-bit weights ("W8A8-INT8 is not supported by
  marlin kernel"). The symmetric GPTQ checkpoint was repacked losslessly into compressed-tensors
  pack-quantized (same int4 values and scales, every zero point checked = 8), which takes the int8 path.
  The copy lives on the PVC at `syv-cache/models/LFM2.5-24B-A2B-GPTQ-CT`.
- `--max-num-batched-tokens 16384` changed nothing within noise (13,448 / 16,111 prefill; 703 / 1,430 /
  1,875 decode), raised TTFT and cost ~30k tokens of KV, so it stays at 8192.
- KV cache: 401k tokens at 32k max length.
- **It always reasons, and that dominates real cost.** A one-line sentiment label took 438 tokens.
  Forcing `<think></think>` (off-distribution) on 16 short classification prompts + 4 maths problems,
  3 samples each, Liquid's sampling:

  | | Classification | Maths | Tokens/answer |
  |---|---|---|---|
  | Thinking on | 45/48 (all 3 misses on one debatable label) | 12/12 | ~352 |
  | Forced off | 40/48 (e.g. USB-C charger → "kitchen", a Logitech mouse → spam) | 0/12 | ~41 |

  At ~350 tokens per answer, c=64 decode alone caps it near 5 classifications/s, so Lightning with
  thinking off may still finish real jobs sooner. Compare on real prompts before switching.

## Recommendation

Test these in order. Prefill estimates are relative to Gemma's measured ~9.0k tok/s (`vllm bench`,
random 4000-in/64-out at concurrency 8-32). See [Prefill estimates](#how-the-prefill-estimates-were-made).

No reasoning is needed for our traffic. Every model below runs with thinking **fully off**. How to turn
it off was checked in each model's own `chat_template.jinja`, not only its card.

1. **Qwen3.6-35B-A3B family.** Start with the base model. Then try the coding fine-tune
   `Kwaipilot/KAT-Coder-V2.5-Dev` and the instruction-following fine-tune `InternScience/Agents-A1`
   with the same quantization.
   - Why: best coding in every third-party table, IFEval 91-93, Apache-2.0/MIT, mainline vLLM, native
     vision. Its sibling Qwen3.8-27B scored 69/69 on our prompt suites.
   - Thinking off: `chat_template_kwargs: {"enable_thinking": false}`. All four templates (base, KAT,
     Agents-A1, Ornith) insert an empty `<think></think>`. No card publishes non-thinking scores.
   - Prefill: about 7-10k tok/s, **low confidence**. Gated DeltaNet runs on Triton on sm86, and nobody
     has published a single-3090 vLLM number.
   - ⚠️ Verify wording sensitivity: IFBench is only ~64 in three independent harnesses.
   - Hybrid model, so the prefix-cache drift we hit on Qwen3.8 is a risk.
   - Needs our own int4 quant (GDN layers included) to leave room for KV.
2. **Poolside Laguna XS 2.1 / XS.2 (33B-A3B).**
   - Why: attention only (30 SWA-512 + 10 global layers), so prefix caching and attention kernels work
     as they do for Gemma. SWE-bench Verified ~70. XS.2 is Apache-2.0; XS 2.1 is OpenMDW-1.1.
   - Thinking off: this is the template default (`enable_thinking | default(false)`, which emits
     `</think>`). Just don't set the card's `--default-chat-template-kwargs '{"enable_thinking": true}'`.
     The card recommends thinking on for agentic coding and publishes no non-thinking scores.
   - Prefill: about 9-10k tok/s, medium confidence.
   - ⚠️ Verify wording sensitivity: no IF data has been published.
   - Needs our own full-int4 quant (official INT4 is 23.9 GB).
3. **JetBrains Mellum2.1-12B-A2.5B-Thinking.**
   - Why: the fastest shortlisted model, about 11-14k tok/s. Fits even as W8A8-int8 (~12 GB), which
     runs on vLLM's int8 Triton fused-MoE path with no patch. LiveCodeBench v6 82.0 and IFEval 90.6
     (self-reported). Apache-2.0, attention only.
   - Thinking off: the card doesn't mention it, but the template honours
     `chat_template_kwargs: {"enable_thinking": false}` (empty `<think></think>`).
   - ⚠️ It is a thinking-trained model and every published score is in thinking mode, so quality
     without thinking is unknown and could drop the most of any candidate.
   - Agentic coding is weak (SWE-bench Verified 47). That matters little for single-turn code
     generation.
4. **NVIDIA Nemotron 3.5 Lightning 30B-A3B.**
   - Why: strong instruction following (IFBench 71.9 on NVIDIA's harness, IFEval 94.2 on Liquid's).
     A community W4A16 quant is already validated on a 3090 with vLLM. OpenMDW license.
   - Thinking off: `enable_thinking=False` is supported per the card.
   - ⚠️ Evidence of a drop without thinking: a community IFEval of the W4A16 quant with thinking off and
     greedy decoding scored 73.9% prompt-strict, against 94.19 on Liquid's table.
   - Prefill: about 8.5-10k tok/s.
   - Coding is *not* better than Gemma in NVIDIA's own table, so pick it only if classification wins.
   - Hybrid (Mamba2), with the same prefix-cache caveat as Qwen3.6.
5. **Qwen3-Coder-30B-A3B-Instruct.**
   - Why: the only candidate that is non-thinking by design, so there is no question of quality
     dropping without reasoning. Attention only and very mature in vLLM.
   - Prefill: ~parity at 4k and ~0.85× at 8k because its full-attention KV is heavy (about 7.5-9k
     tok/s). Borderline.
   - Coding is roughly Gemma-level (Kwaipilot harness 31.8 vs 35.8), so it is a safe baseline rather
     than a likely winner.

Next in line: **Cohere North-Mini-Code-1.0**. It is attention only, Apache-2.0, and SWE-bench Verified
67.6, and it fits 8×16k with fp8 KV. Thinking can be turned off with
`chat_template_kwargs: {"reasoning": false}` or `{"reasoning_effort": "none"}`, which emit an empty
thinking block. It stays off the shortlist because estimated prefill is ~8-8.6k tok/s (borderline), and
the card says it "works best when turned on".

**Ranked much lower because they always reason:**
- **LFM2.5-24B-A2B** has the best IF scores and the fastest measured prefill (13.5-15.9k tok/s with
  int8), but it always reasons: its template opens `<think>` on every assistant turn, with no switch,
  and forcing it off loses accuracy (see [Measured](#measured-on-our-3090)). It also has a $10M
  revenue cap.
- **gpt-oss-20b**'s `reasoning_effort` can only go down to `low`, and it has Harmony-format brittleness.

Their reasoning tokens would add decode cost to every classification call.

Cheap side experiment: `google/gemma-4-26B-A4B-it-qat-q4_0-unquantized` is Google's QAT checkpoint of
the current model, published unquantized. Quantizing it ourselves to GPTQ/compressed-tensors W4A16 could
improve Gemma's int4 quality at no prefill cost
([HF google org](https://huggingface.co/google)).

### What changed the ranking (workload, 2026-10-16)

- Traffic is single-turn classification plus some code generation. Lifetime counters show 4.8M prompt
  tokens vs 62k generated (~78:1), so prefill dominates.
- Prompts are a few thousand tokens, at most ~8-16k. Fit is judged at **8 concurrent × 8-16k
  tokens**, not 32k.
- Tool-call parser bugs and long-context ability are no longer ranking factors and are only mentioned in
  passing.
- Instruction following and output-format consistency are weighted above coding. Code-generation
  quality comes second, and prefill ≥ ~9k tok/s is the hard bar.
- For single-turn code generation, LiveCodeBench/HumanEval-style scores are more relevant than agentic
  SWE-bench.
- No reasoning is needed. Instruct and non-thinking models, or models whose thinking can be fully
  disabled, are preferred. Models that always reason rank much lower, because their reasoning tokens
  add decode cost to every classification. Where a card says quality drops without thinking, that is
  recorded.
- Models with mainline vLLM support and a working Ampere quant rank above otherwise-equal models.
- Image requests are moving to another box. The image column is informational only.

## Comparison table

Columns:
- **Est. prefill**: estimated text prefill vs Gemma's 9.0k tok/s on our bench (method below).
- **Image**: ✅ native image input, ⚠️ only a separate VL sibling exists, ❌ text only.
- **Think off?**: whether reasoning can be fully disabled, and how. Checked in each repo's
  `chat_template.jinja`.
- **Coding**: vendor numbers unless marked. Compare only within one harness, because Gemma 4 26B-A4B's
  SWE-bench Verified varies from 17.4 to 57.4 depending on who ran it (see
  [Gemma's harness spread](#gemma-4-26b-a4bs-benchmark-numbers-depend-on-the-harness)).

| # | Model | Released | Total / active | Arch (attention) | License | vLLM (min) | Best Ampere quant (size) | Image | Est. prefill | Coding | IF evidence / wording flag | Think off? |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| base | Gemma 4 26B-A4B | before 2026-04 | 25.2B / 3.8B | 25 SWA-1024 + 5 global, 128 experts top-8 | Apache-2.0 | in use (0.31.0 + patches) | cyankiwi AWQ-INT4 (QAT) | ✅ | **9.0k (measured)** | LCB v6 77.1; SWE-V 17.4-57.4 | IFBench 77.25 (NVIDIA) / 47.44 (Liquid); our suites 61-63/69 | yes |
| 1 | Qwen3.6-35B-A3B | 2026-04-15 | 36B / 3B | 30 GDN + 10 gated full attn, 256 exp top-8+1 | Apache-2.0 | ≥0.17 (card: ≥0.19) | self-quant GPTQ W4A16 incl. GDN (~19.4 GB); amd w4a16 (19.4 GB text) | ✅ (vLLM ✅) | ~0.8-1.1× (7-10k), low conf. | SWE-V 73.4 (Qwen), 70.1 (NVIDIA), 66.2 (Liquid), 64.4 (Kwai); LCB v6 80.4 | IFEval 91.3-93.1; IFBench 63.7-64.4 ⚠️ verify | yes: `enable_thinking: false` |
| 1a | KAT-Coder-V2.5-Dev | 2026-07 | 35B / 3B | = Qwen3.6, vision removed | Apache-2.0 | ≥0.19 | self-quant as above | ⚠️ (base Qwen3.6) | = Qwen3.6 | SWE-V 69.4 vs Qwen3.6 64.4 vs Gemma 35.8 (same harness) | none published ⚠️ verify | yes: `enable_thinking: false` |
| 1b | Agents-A1 | 2026-06-26 | 35B / ~3B | = Qwen3.6 | Apache-2.0 | vLLM main / ≥0.19 | cyankiwi AWQ-INT4, compute1 GPTQ-INT4 (sizes unchecked) | ✅ (inherited) | = Qwen3.6 | none published | IFEval 94.8, IFBench 80.6 (self) | yes: template honours `enable_thinking: false` (card silent) |
| 1c | Ornith-1.5-35B-A3B | 2026-08-18 | 36B / 3B | = Qwen3.6 | MIT | ≥0.19.1 | self-quant; official NVFP4 20.8 GB (W4A16 only on sm86) | ✅ (inherited) | = Qwen3.6 | SWE-V 79, Pro 59.6, TB2.1 67.8 (self) | none ⚠️ verify | yes: template honours `enable_thinking: false` (card silent) |
| 2 | Laguna XS 2.1 / XS.2 | 2026-06-20 / 2026-04-23 | 33.4B / 3B | 30 SWA-512 + 10 global, 256 exp top-8+1 | OpenMDW-1.1 / Apache-2.0 | ≥0.21.0 | self-quant W4A16 (~18.5 GB est.) | ❌ | ~1.1× (9-10k) | SWE-V 70.9 / 69.9, TB2.0 37.5 / 35.7 | none ⚠️ verify | yes: off by template default |
| 3 | Mellum2.1-12B-A2.5B-Thinking | 2026-09-20 | 12.1B / 2.5B | 21 SWA-1024 + 7 global, 64 exp top-8 | Apache-2.0 | ≥0.23.0 | W8A8-int8 (~12.5 GB) or W4A16 (~7 GB) | ❌ | ~1.5× (11-14k) | LCB v6 82.0, HumanEval+ 91.5, SWE-V 47.0 | IFEval 90.6 (self); no IFBench | yes: template honours `enable_thinking: false`; ⚠️ thinking-trained, all scores with thinking on |
| 4 | Nemotron 3.5 Lightning 30B-A3B | 2026-08-11 | 31.6B / 3B | 23 Mamba2 + 23 MoE + 6 attn, 128 exp top-6+1 | OpenMDW-1.1 | 0.27.1 (card) | useful-quants W4A16 g64 (16.6 GiB, 3090-validated) | ❌ (⚠️ older Nano 3 Omni) | ~0.95-1.15× (8.5-10k) | SWE-V 51.6 vs Gemma 57.4 (NVIDIA) | IFBench 71.9 (NVIDIA); IFEval 94.2 (Liquid), 73.9 strict (community W4A16, thinking off) ⚠️ verify | yes: `enable_thinking: false`; IF may drop |
| 5 | Qwen3-Coder-30B-A3B-Instruct | 2025-07-31 | 30.5B / 3.3B | 48 full GQA, 128 exp top-8 | Apache-2.0 | mature | QuantTrio AWQ (16.8 GB) / GPTQ | ⚠️ Qwen3-VL-30B-A3B | ~0.85-1.0× (7.5-9k) | SWE-V 51.6 (Qwen), 31.8 (Kwai) | Qwen3-30B-A3B-2507 IFEval 84.7 ⚠️ verify | **non-thinking by design** |
| next | North-Mini-Code-1.0 | 2026-06-09 | 30.5B / 3B | 36 SWA-4096 + 13 global NoPE, 128 exp top-8 | Apache-2.0 ("research release") | ≥0.23 (#44747 fix) | cyankiwi AWQ-INT4 (18.5 GB) | ❌ | ~0.9-0.96× (8-8.6k) | SWE-V 67.6, Pro 40.2, LCB v6 70.3 | none ⚠️ verify | yes: `reasoning: false` or `reasoning_effort: "none"`; card: "works best when turned on" |
| low | LFM2.5-24B-A2B | 2026-10-12 | 24B / 2.45B | 30 short-conv + 10 GQA, 64 exp top-4 | **LFM 1.0, $10M revenue cap** | ≥0.23.0 | aiprimebuilds GPTQ sym g32 (14.4 GB), repacked to ct for int8 | ❌ | **13.5-15.9k (measured)** | SWE-V 51.0 vs Gemma 25.8, SciCode 32.7 vs 35.4 (Liquid) | IFEval 96.75, IFBench 74.69 (vendor) | **no: template always opens `<think>`** |
| low | gpt-oss-20b | 2025-08-05 | 21B / 3.6B | 12 SWA-128 + 12 full, sinks; 32 exp top-4 | Apache-2.0 | mature | MXFP4 (13.8 GB, W4A16 only); amd w4a16 (12.8 GB) | ❌ | ~0.85-1.05× | SWE-V 60.7 (OpenAI, high), 52.4 (NVIDIA) | IFBench 68.5 (NVIDIA); ⚠️ strong Harmony-format brittleness | **no: `reasoning_effort` floor is `low`** |

## Fastest first

Estimated single-3090 text prefill, fastest first. Rows marked **measured** come from our card (see
[Measured on our 3090](#measured-on-our-3090)); the anchors below still use only Gemma and Qwen3.8-27B.
Every other number is an **estimate**, computed as follows.

1. **FLOPs per prompt token at an 8k prompt.** Active non-embedding matmul FLOPs plus attention and
   linear-layer FLOPs; see the next section.
2. **Effective rate, calibrated on our two anchors:**
   - Gemma 4 26B-A4B: 7.3 GFLOP/token × 9.0k tok/s ≈ **66 TFLOP/s** for int4 MoE with int8 activations
     through Marlin.
   - Qwen3.8-27B: ~52 GFLOP/token × 1.7k tok/s ≈ **88 TFLOP/s** for dense W8A8-int8. This anchor's FLOP
     count is my estimate for a 27B dense model with 16 full-attention layers.
3. **Raw estimate** = effective rate ÷ FLOPs/token.
4. **Kernel discount**, a judgment call:
   - Int8 activations through `VLLM_MARLIN_INPUT_DTYPE` work only on GPTQ, AWQ or compressed-tensors
     int4. FP8, NVFP4 and MXFP4 checkpoints fall back to 16-bit activations: ×0.65-0.8.
   - GDN, Mamba2, KDA and MLA use Triton fallbacks on sm86: ×0.7-0.95, depending on how much of the
     model they make up.
   - 256 small experts (intermediate 512) fill Marlin tiles poorly: ×0.85-0.95.

| # | Model | GFLOP/token @8k | Kernel path on sm86 | Prefill tok/s | Label | Status |
|---|---|---|---|---|---|---|
| 1 | Ling-3.0-tiny 7.9B-A1.3B | ~1.9 | official ct int4 + int8 Marlin; KDA Triton + TRITON_MLA; tiny GEMMs (hidden 1536) | ~15-25k | estimate, very low confidence | rejected: quality below Gemma |
| 2 | LFM2.5-24B-A2B | 4.7 | sym GPTQ repacked to ct int4 + int8 Marlin; short-conv layers cheap | **13.5k / 15.9k** (est. ~12-14k) | **measured** c=8 / c=32 | low: always reasons, revenue cap |
| 3 | Mellum2.1-12B-A2.5B | 4.8 | cyankiwi AWQ int4, no int8 (asymmetric); W8A8 or sym GPTQ + int8 untested | **9.3k / 9.9k** (est. ~11-14k with int8) | **measured** c=8 / c=32, no int8 | shortlist #3 |
| 4 | Laguna XS 2.1 / XS.2 | 6.6 | self-made GPTQ + int8 Marlin; SWA/global attention as Gemma; 256 small experts | ~9-10k | estimate | shortlist #2 |
| 5 | Nemotron 3.5 Lightning | 6.2 | ct W4A16 + int8 Marlin (#61405); Mamba2 Triton | **10.7k / 11.7k** (6.5k / 6.9k without int8; est. ~8.5-10k) | **measured** c=8 / c=32 | shortlist #4 |
| 6 | Qwen3.6-35B-A3B (+ fine-tunes) | 5.7 | self-made GPTQ + int8 Marlin; GDN Triton; 256 small experts | ~7-10k | estimate, low confidence | shortlist #1 |
| — | **Gemma 4 26B-A4B (current)** | 7.3 | AWQ/ct int4 + int8 Marlin, W8A8 MLP, FlashInfer | **9.0k** (8.8k at conc 8) | **measured**, vLLM bench 4000-in/64-out | baseline |
| 7 | gpt-oss-20b | 6.8 | MXFP4 → Marlin W4A16, no int8 (~6.5-8k); amd w4a16 int4 + int8 Marlin (~8.5-9.5k) | ~6.5-9.5k | estimate | low: reasoning floor `low` |
| 8 | North-Mini-Code-1.0 | 8.2 (7.2 at 4k) | cyankiwi int4 + int8 Marlin (#61405); SWA-4096 is costly at 8k | ~8-8.6k (≈9k at 4k) | estimate | next in line |
| 9 | Qwen3-Coder-30B-A3B | 8.6 (7.0 at 4k) | GPTQ/AWQ + int8 Marlin; 48 full-attention layers | ~7.5-9k (≈9k at 4k) | estimate | shortlist #5 |
| 10 | GLM-4.7-Flash | ~10.5 | AWQ + int8 Marlin; MLA via Triton/FA, bf16 KV only | ~5-6k | estimate | rejected |
| 11 | Dense 9-10B (MiMo-V2.6-Distill-9B, Ornith-1.5-9B, Qwen3.5-9B) | ~17 | dense W8A8 int8 (as Qwen3.8); GDN Triton | ~4-5k | estimate | rejected |
| 12 | Granite 4.0 H-Small 32B-A9B | ~18 | int4 + int8 Marlin; Mamba2 Triton | ~3-4k | estimate | rejected |
| 13 | Devstral Small 2 24B (dense) | ~50 | dense W8A8 int8 | ~1.8k | estimate | rejected |
| — | **Qwen3.8-27B (HyperQwen, dense)** | ~52 | dense W8A8 int8, GDN | **~1.7k** | **measured** | previous model |
| 14 | Seed-OSS-36B (dense) | ~70 | dense W8A8 int8 | ~1.3k | estimate | rejected |

Read this table as roughly ±30%. The two anchors already differ by 1.33× in effective TFLOP/s: dense
int8 GEMMs run more efficiently than small-expert MoE. The three measured candidates landed within that
band: Lightning and LFM2.5 slightly above their estimates, Mellum below (it ran without int8). No
candidate has a public single-3090 vLLM prefill measurement; the community numbers below come from
llama.cpp or 2×3090 setups.

## How the prefill estimates were made

Baseline: our Gemma deployment measured 8.8k total tok/s at concurrency 8 and 9.0k at 32 (random
4000-in/64-out). The 8k-prompt prefill test gave ~7.8k tok/s after the MLP int8 patch.

**FLOPs per prompt token.** I counted 2 × (non-embedding active matmul params) plus causal attention
at an 8k prompt (average context 4k):
- Score + value FLOPs per layer ≈ 4 × q_heads × head_dim × context.
- For sliding-window layers, context = min(position, window).
- vLLM computes the LM head only for sampled positions, so embeddings and the LM head are excluded.

| Model | Matmul GFLOP/token | Attention GFLOP/token @8k | Total | vs Gemma |
|---|---|---|---|---|
| Gemma 4 26B-A4B | 6.2 (attn proj 1.2B + dense MLP 0.53B + 8×704 experts 1.43B) | 0.42 (SWA) + 0.67 (5 global, head 512) | 7.3 | 1.00 |
| Qwen3.6-35B-A3B | 4.8 (MoE 1.13B, GDN proj 1.0B, attn 0.27B) | 0.67 (10 full) + ~0.2 (GDN chunk scan) | ~5.7 | 1.28 |
| Laguna XS | 5.1 | 1.0 (10 global, 48 heads) + 0.5 (SWA-512, 64 heads) | 6.6 | 1.10 |
| Mellum2.1 | 4.0 | 0.47 (7 global) + 0.33 (SWA-1024) | 4.8 | 1.52 |
| Nemotron 3.5 Lightning | 5.7 (MoE 1.84B, Mamba proj 0.89B, attn 0.14B) | 0.40 (6 attn) + SSD scan | ~6.2 | 1.18 |
| LFM2.5-24B-A2B | 4.4 | 0.34 (10 GQA) + short-conv (negligible) | 4.7 | 1.55 |
| North-Mini-Code | 5.5 | 0.87 (13 global) + 1.81 (36 SWA-4096) | 8.2 | 0.89 (0.96 at 4k) |
| Qwen3-Coder-30B-A3B | 5.4 | 3.2 (48 full layers) | 8.6 | 0.85 (1.0 at 4k) |
| gpt-oss-20b | 6.0 | 0.8 (12 full) | 6.8 | 1.07 |
| GLM-4.7-Flash | ~6.6 | ~3.9 (47 MLA layers, 20 heads × 256) | ~10.5 | ~0.70 |

**Kernel corrections.** FLOPs alone over-predict for the hybrids, so I applied these discounts by
judgment. They are not measured.

- **Gated DeltaNet:** on sm86 it runs on Triton/FLA only; FlashInfer GDN is SM90+
  ([qwen_gdn_linear_attn.py](https://github.com/vllm-project/vllm/blob/v0.31.0/vllm/model_executor/layers/mamba/gdn/qwen_gdn_linear_attn.py#L93-L146)).
  Open issue [#53787](https://github.com/vllm-project/vllm/issues/53787) reports long prefill 1.9×
  slower than expected.
- **Mamba2:** also Triton
  ([config/mamba.py](https://github.com/vllm-project/vllm/blob/v0.31.0/vllm/config/mamba.py#L25-L103)).
- **Hybrid discount:** −10 to −30%.
- **Qwen3.6 / Laguna expert size:** 256 small experts (intermediate 512) give each expert about half as
  many tokens per 2560-token batch as Gemma's 128 experts. Marlin MoE tiles run less full, which is
  another reason for low confidence on Qwen3.6.
- **int8 activations:** the estimates assume the same int8 path as Gemma, i.e.
  `VLLM_MARLIN_INPUT_DTYPE=int8` on a GPTQ or compressed-tensors int4 checkpoint. A model stuck on
  W4A16 because it is FP8/NVFP4/MXFP4 or AutoRound loses that int8 speedup. PR #24722 measured
  W4A8-int8 at about 2.6× W4A16 at prefill-sized M on a 4090
  ([PR #24722](https://github.com/vllm-project/vllm/pull/24722)).

**Community data points** (all from other configurations; none is a single-3090 vLLM run at 8k):

| Model | Hardware / engine | Prefill | Source |
|---|---|---|---|
| Qwen3.6-35B-A3B NVFP4 | 2×3090 TP=2, vLLM | 8,289 tok/s @10K | [club-3090 BENCHMARKS](https://github.com/noonghunna/club-3090/blob/master/BENCHMARKS.md) |
| Qwen3.6-35B-A3B AWQ | 2×3090 TP=2, vLLM | ~10.2k tok/s at a 60K prompt | [tfriedel/qwen3.6-rtx3090-lab](https://github.com/tfriedel/qwen3.6-rtx3090-lab) |
| Qwen3.6-35B-A3B IQ4_XS | 1×3090, llama.cpp | 2,960 tok/s @4K | same |
| Gemma 4 26B-A4B UD-Q4_K_XL | 1×3090, llama.cpp | 4,019 tok/s @17K | same (GEMMA_FINDINGS.md) |
| gpt-oss-20b MXFP4 | 1×3090, llama.cpp | pp8192 4,772 tok/s | [llama.cpp discussion #15396](https://github.com/ggml-org/llama.cpp/discussions/15396) |
| gpt-oss-20b MXFP4 | 1×4090, llama.cpp | pp8192 7,265 tok/s | same |
| GLM-4.7-Flash Q4_K_XL | 1×3090, llama.cpp | 1,517 tok/s @8K | [hardware-corner](https://www.hardware-corner.net/glm-4-7-flash-llm-hardware/) |

The llama.cpp numbers show Gemma 4 at roughly 1.35× Qwen3.6 on the same single 3090 at short
prompts. That is the opposite of the FLOP ratio, and it is why Qwen3.6's estimate is a wide band. Our
vLLM Gemma (9k) is already ~2× llama.cpp, so these numbers only bound relative behaviour.

**Fit** at `--gpu-memory-utilization 0.92` (23.7 GB). Usable KV ≈ 23.7 GB − weights − ~1.5 GB
activations and CUDA graphs. Requirement: 8 × 16k = 131k tokens (8 × 8k = 65k).

| Model | Weights | KV per token (bf16) | 131k tokens bf16 / fp8 | Verdict |
|---|---|---|---|---|
| Qwen3.6 (self-quant, text only) | ~19.4 GB | 20 KB (10 full layers) + ~30 MiB GDN state/seq | 2.7 / 1.35 GB | 8×16k with fp8 KV; with the vision encoder loaded (~0.9 GB) still fits with fp8 |
| Laguna XS (self-quant) | ~18.5 GB | 40 KB global + 0.5 GB SWA total | 5.7 / 2.9 GB | 8×16k with fp8; 8×8k in bf16 |
| Mellum2.1 W8A8 | ~12.5 GB | 14 KB global + small SWA | 1.9 GB bf16 | trivially |
| Lightning W4A16 | 17.8 GB | ~6 KB + Mamba state | <1 GB | trivially; card profile caps `--max-num-seqs 32` |
| LFM2.5 AWQ | 15.2 GB | 20 KB | 2.7 GB bf16 | yes, bf16 |
| North-Mini-Code AWQ | 18.5 GB | 26.6 KB global + 302 MB/seq SWA (bf16) | 5.9 / 2.95 GB | 8×16k only with fp8 KV (recomputed; it failed at 8×32k) |
| Qwen3-Coder-30B AWQ | 16.8 GB | 98 KB | 12.9 / 6.4 GB | 8×8k with fp8; 8×16k slightly short (~110k tokens) |
| gpt-oss-20b | 13.8 GB | ~24 KB avg | ~3.2 GB | yes |
| GLM-4.7-Flash AWQ | 19.8 GB | 54 KB MLA, **bf16 only on sm86** | 7.1 GB | no: ~44k tokens, under 8×8k |

## Candidate details

### 1. Qwen3.6-35B-A3B and its fine-tunes

**Repos**
- Base: [Qwen/Qwen3.6-35B-A3B](https://huggingface.co/Qwen/Qwen3.6-35B-A3B), released 2026-04-15/16,
  Apache-2.0.
- Quants that exist:
  - [amd/Qwen3.6-35B-A3B-w4a16-llmcompressor](https://huggingface.co/amd/Qwen3.6-35B-A3B-w4a16-llmcompressor):
    19.4 GB text-only, GDN layers quantized. Its card targets AMD EPYC CPUs, so the GPU Marlin path is
    unverified.
  - Intel int4-mixed AutoRound: 20.1 GB text-only. AutoRound ignores `VLLM_MARLIN_INPUT_DTYPE`, see the
    patches list below.
  - palmfuture GPTQ-Int4 (21.8 GB) and cyankiwi AWQ-4bit (23.5 GB) keep GDN in bf16 and are too big.
  - FP8/NVFP4 builds are W-only on sm86.
- **Best plan:** quantize it ourselves with llm-compressor GPTQ W4A16 g128, quantizing the GDN in/out
  projections too and keeping the router and gates bf16, then serve with `--language-model-only`.

**Architecture** ([config.json](https://huggingface.co/Qwen/Qwen3.6-35B-A3B/raw/main/config.json))
- `Qwen3_5MoeForConditionalGeneration`, 40 layers = 10 × (3 Gated DeltaNet + 1 gated full attention).
- Full attention: 16 Q / 2 KV heads, head_dim 256.
- MoE: 256 experts, top-8 + 1 shared, expert intermediate size 512. 1 MTP layer.
- Native context 262k.

**vLLM**
- Arch since v0.17.0 ([release](https://github.com/vllm-project/vllm/releases/tag/v0.17.0)); text-only
  class `Qwen3_5MoeForCausalLM` since v0.27.0
  ([release](https://github.com/vllm-project/vllm/releases/tag/v0.27.0)). The card recommends ≥0.19.0.
- Known issues:
  - [#53726](https://github.com/vllm-project/vllm/issues/53726): RTX 3090 illegal memory access with
    GDN + MTP + async scheduling. Keep MTP off; club-3090 also measured MTP as net-negative.
  - [#51663](https://github.com/vllm-project/vllm/issues/51663): throughput regression since v0.24
    (FP8).
  - [#50780](https://github.com/vllm-project/vllm/issues/50780): hybrid KV pool 18-24% too small since
    v0.26.
  - [#54775](https://github.com/vllm-project/vllm/issues/54775): GDN scan buffers are not profiled, so
    large `--max-num-batched-tokens` can OOM.

**Image:** ✅ native. vLLM supports the vision part since v0.17.0. If images go elsewhere,
`--language-model-only` "skips the vision encoder and multimodal profiling to free up memory"
([card](https://huggingface.co/Qwen/Qwen3.6-35B-A3B)). With the encoder loaded but idle, budget
~0.9 GB of weights plus the multimodal profiling reserve (~36B total − ~35B text ≈ 0.45B vision params,
my estimate from the safetensors totals).

**Coding**, from the Qwen card's table, where Gemma 4 26B-A4B is in the same table:
- SWE-bench Verified: 73.4 vs 17.4.
- Terminal-Bench 2.0: 51.5 vs 34.2.
- LiveCodeBench v6: 80.4 vs 77.1.

Independent harnesses also put Qwen3.6 ahead of Gemma on SWE-bench Verified:
- NVIDIA: 70.12 vs 57.40
  ([Lightning card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16)).
- Liquid: 66.2 vs 25.8 ([LFM2.5 card](https://huggingface.co/LiquidAI/LFM2.5-24B-A2B)).
- Kwaipilot: 64.4 vs 35.8 ([KAT card](https://huggingface.co/Kwaipilot/KAT-Coder-V2.5-Dev)).

For single-turn code generation, the LiveCodeBench gap (+3.3) is what counts, and it is modest.

**Instruction following and wording: ⚠️ verify**
- IFEval is 91.3 (InternScience table) and 93.06 (Liquid; Gemma 92.00).
- IFBench is 64.4 (InternScience), 64.21 (Liquid; Gemma 47.44) and 63.71 (NVIDIA; Gemma 77.25). That is
  consistently mid-60s, and NVIDIA's harness has Gemma clearly ahead.
- Thinking is on by default. Turn it off with `chat_template_kwargs: {"enable_thinking": false}`; the
  template then emits an empty `<think></think>`.
- The card does not say whether quality drops without thinking, and it publishes no non-thinking
  scores. Its non-thinking sampling is temperature 0.7, top_p 0.8, top_k 20, `presence_penalty` 1.5.
  For classification, test greedy decoding as well.
- Positive evidence: the same-family Qwen3.8-27B scored 69/69 on our suites.
- Tool-parser and template bugs exist ([#50989](https://github.com/vllm-project/vllm/issues/50989),
  [#57699](https://github.com/vllm-project/vllm/issues/57699)) but no longer matter for our workload.

**Prefix caching risk.** This is a GDN hybrid. Our Qwen3.8-27B (same layer family) lost quality with
prefix caching on (`docs/hyperqwen/prefix-caching.md`). Our classification prompts likely share long
prefixes, so caching matters. Benchmark raw prefill with caching off, and repeat the quality A/B with
caching on before relying on it.

**Fine-tunes** (same architecture, same quant and serving path):
- [Kwaipilot/KAT-Coder-V2.5-Dev](https://huggingface.co/Kwaipilot/KAT-Coder-V2.5-Dev): Apache-2.0,
  July 2026, **text only** (vision weights removed, so less VRAM). Best independent coding table:
  - Same harness, KAT / Qwen3.6 / Gemma4-26B: SWE-bench Verified 69.4 / 64.4 / 35.8; SciCode 44.2 /
    37.5 / 30.8.
  - The card notes Gemma hallucinated an unavailable tool in that harness.
  - Thinking toggle as in Qwen3.6. No IF numbers ⚠️.
- [InternScience/Agents-A1](https://huggingface.co/InternScience/Agents-A1): Apache-2.0, 2026-06-26.
  - Self-reported IFEval 94.82 and IFBench 80.61 vs Qwen3.6 91.3 / 64.4 in the same table, which makes
    it the most interesting variant for classification.
  - No coding numbers. Vision kept.
  - The card documents no thinking toggle, but its `chat_template.jinja` honours
    `enable_thinking: false`. The IF scores above are presumably with thinking on.
- [ornith-ai/Ornith-1.5-35B-A3B](https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B): MIT,
  2026-08-18. Self-reported SWE-bench Verified 79, Pro 59.6, Terminal-Bench 2.1 67.8.
  - No IF numbers ⚠️. The card gives no thinking off switch, but its own template honours
    `enable_thinking: false`.
  - It uses its own chat template. The official NVFP4 is 20.8 GB and W-only on sm86.
- Lower priority:
  - Qwen3.5-35B-A3B: same architecture, dominated by 3.6.
  - Jackrong Qwopus3.6 Coder: unclear provenance, only a subset benchmark.

**vLLM patch needed:** none for the model. Quantization needs the [patch list](#vllm-patches-that-apply-to-several-candidates).

### 2. Poolside Laguna XS 2.1 / Laguna XS.2

**Repos**
- [poolside/Laguna-XS-2.1](https://huggingface.co/poolside/Laguna-XS-2.1): 2026-06-20, OpenMDW-1.1
  (permissive, MIT-like: [license](https://openmdw.ai/license/1-1/)).
- [poolside/Laguna-XS.2](https://huggingface.co/poolside/Laguna-XS.2): 2026-04-23, Apache-2.0.
- Official quants are FP8, NVFP4 and Laguna-XS-2.1-INT4. The INT4 is 23.9 GB because layers 31-39 stay
  int8, so it does not fit. cyankiwi AWQ is 23.1 GB, also too big.
- **Self-quantize** to full W4A16 g128: 33.4B × ~0.53 B/param + bf16 embeddings/head ≈ 18.5 GB
  (estimate).

**Architecture** ([config.json](https://huggingface.co/poolside/Laguna-XS-2.1/raw/main/config.json))
- `LagunaForCausalLM`, 40 layers. Every 4th layer is global attention (48 Q heads); the rest are
  sliding window 512 (64 Q heads). 8 KV heads, head_dim 128.
- MoE: 256 experts, top-8 + shared (512 intermediate). Context 262k.

**vLLM:** ≥0.21.0 (PR #41129). Parsers `poolside_v1` need PR #47311; they don't matter for us.
**Image:** ❌ text only, no VL sibling.
**Coding (Poolside harness):**

| Benchmark | XS 2.1 | XS.2 | Qwen3.6 (same table) |
|---|---|---|---|
| SWE-bench Verified | 70.9 | 69.9 | 73.4 |
| SWE-bench Pro | 47.6 | 46.3 | 49.5 |
| Terminal-Bench 2.0 | 37.5 | 35.7 | 51.5 |

No LiveCodeBench is published, and Gemma 4 26B-A4B is not in Poolside's table.

**Wording: ⚠️ verify.** No IFEval/IFBench published.
**Thinking:** the template defaults to off (`enable_thinking | default(false)`, which emits `</think>`).
The card turns it on server-wide with `--default-chat-template-kwargs '{"enable_thinking": true}'`;
leave that flag out. The card recommends thinking on for agentic coding, and all its benchmarks ran with
thinking on. Non-thinking quality is unpublished.
**Why ranked #2:** it is the only strong coder that is attention only, so it keeps Gemma's attention
kernels and prefix-cache behaviour. Prefill is estimated at ~1.1×.
**Risks**
- 256 small experts (as in Qwen3.6) mean less efficient Marlin MoE tiles.
- The self-made int4 quality is unknown.
- The 64-head SWA layers are an unusual shape; check that FlashInfer/FA2 picks them up on sm86.

### 3. JetBrains Mellum2.1-12B-A2.5B-Thinking

**Repo:** [JetBrains/Mellum2.1-12B-A2.5B-Thinking](https://huggingface.co/JetBrains/Mellum2.1-12B-A2.5B-Thinking),
released 2026-09-20 (HF creation date), Apache-2.0.
**Architecture** ([config.json](https://huggingface.co/JetBrains/Mellum2.1-12B-A2.5B-Thinking/raw/main/config.json))
- `MellumForCausalLM`, 28 layers: 3 SWA-1024 then 1 full, repeated.
- 32 Q / 4 KV heads, head_dim 128. MoE: 64 experts, top-8, intermediate 896. Context 131k.

**vLLM:** arch added in v0.23.0 ([PR #43992](https://github.com/vllm-project/vllm/pull/43992)). Card:
`--reasoning-parser qwen3`.
**Quant**
- 12.1B total, so **W8A8-int8 fits** (~12.5 GB). vLLM's int8 MoE oracle picks Triton `fused_moe`
  int8_w8a8, which needs compute capability ≥ 7.5, so it runs on sm86
  ([int8 oracle](https://github.com/vllm-project/vllm/blob/v0.31.0/vllm/model_executor/layers/fused_moe/oracle/int8.py),
  [triton_moe.py](https://github.com/vllm-project/vllm/blob/v0.31.0/vllm/model_executor/layers/fused_moe/experts/triton_moe.py#L118-L156)).
- The 20 community quants on HF were not inspected. Make our own with llm-compressor, and A/B W8A8 vs
  GPTQ W4A16 + int8 Marlin.

**Image:** ❌.
**Benchmarks** (self-reported, thinking mode):

| Benchmark | Mellum2.1 | Qwen3.5-9B (same table) |
|---|---|---|
| LiveCodeBench v6 | 82.0 | 75.4 |
| HumanEval+ | 91.5 | — |
| MBPP+ | 79.4 | — |
| SWE-bench Verified | 47.0 | 50.0 |
| IFEval | 90.6 | 92.4 |

Gemma 4 26B-A4B's LiveCodeBench v6 is 77.1 on Google's card
([Gemma card](https://huggingface.co/google/gemma-4-26B-A4B-it)), but that is a different harness.

**Thinking:** the card documents no off switch. Its `chat_template.jinja` does honour
`chat_template_kwargs: {"enable_thinking": false}` and emits `<think>\n\n</think>`. However:
- It is thinking-trained, and every published score is in thinking mode.
- The non-thinking sibling Mellum2-12B-A2.5B-Instruct is much weaker (LCB v6 37.2).

So expect the largest quality drop without thinking of any shortlisted model. Test it before relying on
its speed.
**Measured here (2026-10-17):** cyankiwi AWQ-INT4 (asymmetric, so int8 fails with "W8A8 is not
supported by marlin kernel") gave prefill 9.3k / 9.9k tok/s (c=8 / 32) and decode 592 / 868 / 907
(c=8 / 32 / 64). See [Measured](#measured-on-our-3090).
**Risks**
- Small total size means less world knowledge for open-ended role checks.
- Self-reported numbers only.
- ⚠️ No IFBench or wording data.

### 4. NVIDIA Nemotron 3.5 Lightning 30B-A3B

**Repos**
- [nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16):
  GA 2026-08-11, OpenMDW-1.1.
- 3090 quant: [useful-quants/...-W4A16](https://huggingface.co/useful-quants/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-W4A16),
  compressed-tensors int4 g64, 16.6 GiB, validated on an RTX 3090 with vLLM 0.27.1 and
  `--max-num-seqs 32`.
- NVIDIA's NVFP4 build is W4A16 on Ampere, and its FP8 Mamba projections hit
  [#55008](https://github.com/vllm-project/vllm/issues/55008). Avoid it.

**Architecture** ([config.json](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16/raw/main/config.json))
- `NemotronHForCausalLM`, hidden 2688, 52 layers (23 Mamba2, 23 MoE, 6 GQA attention with 2 KV heads).
- MoE: 128 experts, top-6 + shared, relu².

**Image:** ❌ text only. The vision sibling is the older-generation
[Nemotron-3-Nano-Omni-30B-A3B-Reasoning](https://recipes.vllm.ai/nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning-BF16),
built on Nemotron 3 Nano, not Lightning; vLLM 0.20.0 supports its image input.
**Benchmarks** (NVIDIA harness, Lightning / Gemma 4 26B-A4B / gpt-oss-20b / Qwen3.6):

| Benchmark | Lightning | Gemma 4 26B-A4B | gpt-oss-20b | Qwen3.6 |
|---|---|---|---|---|
| SWE-bench Verified | 51.56 | 57.40 | 52.44 | 70.12 |
| Terminal-Bench 2.1 | 24.58 | 37.22 | 15.17 | 44.38 |
| IFBench | 71.88 | 77.25 | 68.50 | 63.71 |

Liquid's table gives Lightning IFEval 94.19 and IFBench 71.67.

**Wording: ⚠️ verify.** A community IFEval of the W4A16 quant with greedy decoding and thinking off gave
73.9% prompt-strict
([useful-quants ifeval.md](https://huggingface.co/useful-quants/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-W4A16/blob/main/benchmarks/ifeval.md)).
That is far below the vendor figure, so quantization or thinking-off may hurt instruction following.
**Thinking:** `chat_template_kwargs: {"enable_thinking": false}` is supported per the card. The card
does not quantify the non-thinking quality. The community 73.9% thinking-off IFEval above is the only
evidence, and it points to a drop.
**Throughput (community, 3090):** decode 817 tok/s at 8 sequences; no 8k prefill measurement
([curve](https://huggingface.co/useful-quants/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-W4A16/blob/main/benchmarks/rtx3090-throughput-curve.md)).
**Measured here (2026-10-17):** with int8 and the #61405 patch, prefill 10.7k / 11.7k tok/s (c=8 / 32),
decode 645 / 1,050; without int8, 6.5k / 6.9k and 554 / 808. See [Measured](#measured-on-our-3090).
**Risks**
- Hybrid prefix-cache bugs: [#60008](https://github.com/vllm-project/vllm/issues/60008) (align mode
  −11-16%), [#53912](https://github.com/vllm-project/vllm/issues/53912) (prefix cache + MTP
  corrupts). Keep MTP off.
- Coding is not an improvement over Gemma.

### Ranked low: LiquidAI LFM2.5-24B-A2B (always reasons, revenue-capped)

**Repo:** [LiquidAI/LFM2.5-24B-A2B](https://huggingface.co/LiquidAI/LFM2.5-24B-A2B), 2026-10-12.
⚠️ **License:** LFM Open License v1.0. Commercial use is not licensed for entities with ≥ $10M annual
revenue ([LICENSE](https://huggingface.co/LiquidAI/LFM2.5-24B-A2B/blob/main/LICENSE)).
**Architecture** ([config.json](https://huggingface.co/LiquidAI/LFM2.5-24B-A2B/raw/main/config.json))
- `Lfm2MoeForCausalLM`, hidden 2048, 40 layers: 30 short-convolution + 10 GQA (8 KV heads).
- 2 dense layers. MoE: 64 experts, top-4, intermediate 1536. Context 131k.

**vLLM:** native since v0.23.0 ([Liquid docs](https://docs.liquid.ai/lfm/inference/vllm)).
**Quant:** in use: [aiprimebuilds/LFM2.5-24B-A2B-GPTQ](https://huggingface.co/aiprimebuilds/LFM2.5-24B-A2B-GPTQ)
at `89f6370` (GPTQModel 7.6.0, 4-bit sym g32, 14.4 GB), repacked to compressed-tensors so int8 works.
[cyankiwi/LFM2.5-24B-A2B-AWQ-INT4](https://huggingface.co/cyankiwi/LFM2.5-24B-A2B-AWQ-INT4) (15.2 GB) is
asymmetric, so it can't use int8. The official FP8 (~24 GB) does not fit.
**Measured here (2026-10-18):** prefill 13.5k / 15.9k tok/s (c=8 / 32), decode 673 / 1,437 / 1,893
(c=8 / 32 / 64) with int8; the fastest model we've run. See [Measured](#measured-on-our-3090).
**Image:** ❌. Liquid's VL models are 450M-3B, not a sibling of this size.
**Benchmarks** (Liquid harness, LFM2.5 / Qwen3.6 / Gemma4-26B / Lightning):

| Benchmark | LFM2.5 | Qwen3.6 | Gemma 4 26B-A4B | Lightning |
|---|---|---|---|---|
| IFEval | 96.75 | 93.06 | 92.00 | 94.19 |
| IFBench | 74.69 | 64.21 | 47.44 | 71.67 |
| SWE-bench Verified (OpenCode) | 51.0 | 66.2 | 25.8 | 53.4 |
| SciCode | 32.71 | 37.35 | 35.42 | 27.78 |

**Thinking:** "a pure reasoning model that always thinks before it answers"
([card](https://huggingface.co/LiquidAI/LFM2.5-24B-A2B)). Its `chat_template.jinja` appends
`<|im_start|>assistant\n<think>` unconditionally, so there is no switch. Forcing an empty
`<think></think>` is off-distribution and measurably worse (40/48 vs 45/48 on short classifications,
0/12 vs 12/12 on maths). Every classification pays ~350 reasoning tokens, which is why it ranks low
despite the fastest measured prefill.
**Risks:** revenue cap, always-on thinking, a one-download community quant with no published accuracy
check, and the same hybrid prefix-cache caveat as Qwen3.6.

### Next in line: Cohere North-Mini-Code-1.0

**Repos**
- [CohereLabs/North-Mini-Code-1.0](https://huggingface.co/CohereLabs/North-Mini-Code-1.0): blog dated
  2026-06-09 ([blog](https://huggingface.co/blog/CohereLabs/introducing-north-mini-code)). Apache-2.0;
  the card calls it a "research release", but the license has no NC clause.
- Use [cyankiwi/North-Mini-Code-1.0-AWQ-INT4](https://huggingface.co/cyankiwi/North-Mini-Code-1.0-AWQ-INT4)
  (18.5 GB). Cohere's own `-w4a16` is NVFP4-packed (group 16), so on sm86 it gets no int8 activations.

**Architecture** ([config.json](https://huggingface.co/CohereLabs/North-Mini-Code-1.0/raw/main/config.json))
- `Cohere2MoeForCausalLM`, hidden 2048, 49 layers: 13 global NoPE + 36 sliding window 4096.
- 32 Q / 4 KV heads, head_dim 128. MoE: 128 experts, top-8, intermediate 768.

**vLLM:** loads since PR #44747 ([issue #46366](https://github.com/vllm-project/vllm/issues/46366)), so
v0.31.0 is fine. Parsers need `cohere_melody`.
**Image:** ❌. Cohere's vision models are not permissively licensed.
**Coding:** SWE-bench Verified 67.6, Pro 40.2, Terminal-Bench 2 36.0 (card). LiveCodeBench v6 70.3 is
from the vendor chart, read off by a helper, and is *below* Gemma's 77.1.
**Wording: ⚠️ verify.** No IF data. Recommended temperature is 1.0.
**Thinking:** the card says thinking "works best when turned on" and documents no off switch. Its
`chat_template.jinja` disables it with `chat_template_kwargs: {"reasoning": false}` or
`{"reasoning_effort": "none"}`, which emit an empty `<|START_THINKING|><|END_THINKING|>`. By the card's
own wording, expect some quality loss.
**Fit, recomputed for 8×16k:** fits only with fp8 KV (table above).
**Prefill:** the 4096 sliding window makes its "local" layers expensive at 8k, giving 0.89× (8k) to
0.96× (4k). Borderline.

### 5. Qwen3-Coder-30B-A3B-Instruct (non-thinking by design)

**Repo:** [Qwen/Qwen3-Coder-30B-A3B-Instruct](https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct),
2025-07-31, Apache-2.0.
- Arch: `Qwen3MoeForCausalLM`, 48 full-GQA layers (4 KV heads), 128 experts top-8, non-thinking only.
- Quants: [QuantTrio AWQ](https://huggingface.co/QuantTrio/Qwen3-Coder-30B-A3B-Instruct-AWQ) (16.8 GB)
  or a GPTQ int4. GPTQ is preferred for the int8 path.

**Image:** ⚠️ the sibling is Qwen3-VL-30B-A3B-Instruct.
**Coding**
- SWE-bench Verified 51.6 (Qwen, OpenHands).
- Kwaipilot's harness has it *below* Gemma: 31.8 vs 35.8.

**IF:** none published for the Coder model. Qwen3-30B-A3B-Instruct-2507 reports IFEval 84.7
([card](https://huggingface.co/Qwen/Qwen3-30B-A3B-Instruct-2507)).
**Thinking:** none. It is an instruct-only model with no reasoning mode, so there is no quality cliff
from turning reasoning off.
**Use:** a pure-attention, non-thinking baseline. It wins only if the hybrids fail on prefix caching or
lose quality without thinking.

### Also evaluated: gpt-oss-20b

**Repo:** [openai/gpt-oss-20b](https://huggingface.co/openai/gpt-oss-20b), 2025-08-05, Apache-2.0.
OpenAI has released no newer open-weight LLM.
**vLLM on Ampere:** TRITON_ATTN + Marlin MXFP4 MoE
([recipe](https://docs.vllm.ai/projects/recipes/en/latest/OpenAI/GPT-OSS.html)). MXFP4 takes no int8
activations ([marlin_utils_fp4.py](https://github.com/vllm-project/vllm/blob/main/vllm/model_executor/layers/quantization/utils/marlin_utils_fp4.py#L190-L194)),
so for parity use [amd/gpt-oss-20b-BF16-w4a16-llmcompressor](https://huggingface.co/amd/gpt-oss-20b-BF16-w4a16-llmcompressor)
plus the #61405 patch.
**Wording: ⚠️ strongest negative evidence of any candidate.**
- An independent reproduction matched OpenAI's SWE-bench only with a native-Harmony harness; Chat
  Completions conversion is lossy ([arXiv 2604.00362](https://arxiv.org/abs/2604.00362)).
- Reasoning can only be lowered to `reasoning_effort: low`, not removed, so every classification pays
  reasoning tokens. That puts it in the "ranked low" group.
- Coding is roughly Gemma-level (NVIDIA harness 52.4 vs 57.4).

**Image:** ❌. Not shortlisted.

## vLLM patches that apply to several candidates

All verified against v0.31.0 source.

- **`VLLM_MARLIN_INPUT_DTYPE=int8`** is the W4A8-int8 Marlin path from PR #24722 (v0.12.0). `int8` is
  the only valid value on sm86; `fp8` raises
  ([marlin_utils.py](https://github.com/vllm-project/vllm/blob/main/vllm/model_executor/layers/quantization/utils/marlin_utils.py#L720-L739)).
  How each checkpoint format handles it:
  - **GPTQ:** linear and MoE paths honour it. This is the safest format for every candidate.
  - **compressed-tensors W4A16 MoE:** produces garbage without
    [PR #61405](https://github.com/vllm-project/vllm/pull/61405), which we already carry in
    `deployment-gemma4-a4b.yaml`. Every compressed-tensors candidate needs it: cyankiwi quants,
    useful-quants Lightning, self-made llm-compressor quants.
  - **AWQ MoE (`AutoAWQMoEMethod`):** hardcodes `input_dtype=None`. Whether its experts get the int8
    layout is unconfirmed, so A/B it or prefer GPTQ/compressed-tensors.
  - **AutoRound/INC:** silently ignores the variable
    ([#48904](https://github.com/vllm-project/vllm/issues/48904); fix in PR #49039).
  - **FP8 Marlin:** raises "Marlin W8A8 is not supported"
    ([marlin_utils_fp8.py](https://github.com/vllm-project/vllm/blob/main/vllm/model_executor/layers/quantization/utils/marlin_utils_fp8.py#L78-L80)).
    Setting the variable globally therefore breaks FP8 checkpoints.
  - **NVFP4/MXFP4:** no int8 activations. Re-quantize to int4 GPTQ instead.
- **Humming** (`--moe-backend humming --linear-backend humming`,
  `VLLM_HUMMING_INPUT_QUANT_CONFIG='{"dtype":"int8"}'`) is a second W4A8-int8 path in v0.31.0 (PR
  #56685). No Ampere numbers are published; worth one A/B per candidate.
- **W8A8-int8 MoE** runs on sm86 via Triton `fused_moe` and is the natural path for Mellum2.1. Larger
  models don't fit at 8 bits.
- **No fix available on sm86 for these:**
  - MLA → TRITON_MLA only, with no fp8 KV
    ([cuda.py](https://github.com/vllm-project/vllm/blob/v0.31.0/vllm/platforms/cuda.py#L83-L151)).
    This is what sinks GLM-4.7-Flash.
  - GDN, KDA and Mamba2 run on Triton only. FlashKDA and FlashInfer GDN are SM90+.

## Gemma 4 26B-A4B's benchmark numbers depend on the harness

SWE-bench Verified for the same Gemma model varies by more than 3×, so never compare a candidate's
number with Gemma's number from a different table:

| Harness | Gemma 4 26B-A4B SWE-bench Verified |
|---|---|
| Qwen | 17.4 |
| Liquid (OpenCode) | 25.8 |
| Kwaipilot | 35.8 |
| NVIDIA | 57.4 |

IFBench is just as unstable: 77.25 (NVIDIA) vs 47.44 (Liquid). Kwaipilot reports that Gemma
hallucinated calls to a non-existent tool in its harness, which explains part of the low scores. Our
own suites are the only trustworthy comparison.

## Rejected

- **Too big for 24 GB:**
  - Qwen3-Coder-Next and Qwen3-Next-80B-A3B (~80B; int4 ≥ 43 GB).
  - Qwen3.8-Flash-Next (125B + n-gram embeddings; Qwen Community License with MAU/revenue and
    coding-assistant clauses).
  - Hunyuan-A13B (80B; license also excludes EU/UK/South Korea).
  - Kimi-Linear-48B-A3B (int4 30.5 GB). A REAP-35B prune exists only as GGUF.
  - GLM-5.3-Flash (321B), Step-3.5/3.7-Flash (~200B), MiMo-V2/V2.5/V2.6-Flash (~310B), MiniMax-M2.7/M3,
    Ling-flash-2.0/2.6/3.0/3.1 (≥103B), LongCat-Flash-Lite (69B), Mistral Small 4 / Leanstral 1.5
    (119B-A6B), Jamba2-Mini (51.6B), Laguna-S-2.1 (117.6B).
  - Nemotron 3.5 Bolt 74B-A9B-24GB: IQ2 experts, card lists Blackwell only, `--max-num-seqs 1`.
- **Fits but fails prefill or KV:**
  - GLM-4.7-Flash: MLA on all 47 layers, ~0.7× prefill, bf16-only MLA KV on sm86 gives <8×8k.
    Open #43888 (quantized MLA crash in chunked prefill).
  - Seed-OSS-36B (dense, ~1.3k tok/s est.).
  - Devstral Small 2 24B (dense, ~1.8k tok/s est.).
  - Granite 4.0 H-Small (9B active, ~3-4k tok/s est.).
  - Small dense coders: Ornith-1.5-9B, MiMo-V2.6-Distill-Qwen-9B, Qwen3.5-9B, gemma-4-12B,
    FrogMini-14B. All dense 9-15B. They estimate at ~2.5-5k tok/s even with dense W8A8 int8 (e.g.
    MiMo-9B ≈ 17 GFLOP/token at the 88 TFLOP/s dense anchor ≈ 5k); see
    [Fastest first](#fastest-first).
- **Weaker than Gemma, or superseded:**
  - Qwen3.5-35B-A3B (same architecture as 3.6, worse).
  - Qwen3-30B-A3B-Instruct-2507 (LCB v6 43.2).
  - Nemotron 3 Nano 30B-A3B (superseded by Lightning; SWE-bench Verified 34.1).
  - ERNIE-4.5-21B-A3B-Thinking (Sept 2025, no LCB/SWE, IFEval 84.3).
  - Ling-3.0-tiny 7.9B-A1.3B (MIT, fast, but below Gemma; KDA Triton on sm86).
  - Ling/Ring-mini-2.0 (2025, LCB 34.8).
  - Granite 4.0 H-Tiny.
  - sarvam-30b (SWE-bench Verified 34.0).
  - Mellum2-12B-A2.5B-Instruct (LCB 37.2).
  - Arcee Trinity Mini 26B-A3B (no coding benchmarks).
- **Not coders:** Qwen-AgentWorld-35B-A3B (world model), Tencent Hy-Memory-30B-A3B (memory writer),
  Hy-MT2-30B-A3B (translation), Intern-S2-Mobius (no coding numbers).
- **No usable vLLM path:**
  - SmallThinker-21B-A3B (not in the registry).
  - Trillion Labs Gravity-16B/30B (GravityMoE not in the registry).
  - ServiceNow Apriel2 / SuperApriel-15B.
  - FlexOlmo (Transformers fallback only).
  - MiniCPM-V-4.7-35B-A3B (support merged 2026-10-11, after v0.31.0; a VLM).
- **License:**
  - Cohere North-Small-Translate (CC-BY-NC-4.0).
  - facebook/MobileMoE (FAIR non-commercial).
  - kakaocorp kanana-2-30b-a3b: Kanana license needs a separate agreement above 10M monthly users. It
    is not NC, but it is restricted, and it is also MLA (same sm86 problem as GLM). Not pursued.
- **Not released:** no open Qwen3.7/3.8 small MoE, no new OpenAI, Meta, Microsoft Phi, AllenAI MoE,
  Moonshot or MiniMax small model in 2026.

## How to verify

Run each shortlisted model on `work-00` with the Gemma deployment as the template.
- Settings: `--max-model-len 16384` (or 32768 if it fits), `--max-num-seqs 16-64`,
  `--max-num-batched-tokens 2560`, async scheduling, CUDA graphs ≤64.
- Disable MTP and speculative decoding.
- Hybrids: start with `--no-enable-prefix-caching`.

1. **Prefill gate**, the same tests as Gemma:
   - `vllm bench serve --dataset-name random --random-input-len 4000 --random-output-len 64` at
     concurrency 8 and 32. Gemma: 8.8k / 9.0k total tok/s.
   - The 8k-prompt prefill test. Gemma: ~7.8k tok/s.
   - Add a 16k-input run.
   - A/B `VLLM_MARLIN_INPUT_DTYPE=int8` (Marlin) against Humming int8 per model.
   - Fail anything under ~9k on the 4000-in bench.
2. **Fit:** 8 concurrent 16k-token requests with no preemption. Check the vLLM log's KV cache token
   count against the fit table.
3. **Classification quality:**
   - The 69-case prompt suites. Gemma scored 61-63/69, Qwen3.8-27B 69/69.
   - The 78- and 302-case role checks used for Gemma's MLP int8 change.
   - Always run with thinking off, using the switch from the comparison table.
   - For Mellum2.1, Lightning and North-Mini-Code, whose scores are published with thinking on, also run
     a thinking-on pass once to measure how much quality the switch costs.
   - Record the mean output tokens per call, to confirm no reasoning leaks through.
4. **Wording perturbation:**
   - Write 5 paraphrases of each classification instruction: reorder sentences, use synonyms for the
     task verb, change list/heading formatting, rename the label set, and move the format spec
     before/after the content.
   - Measure label flip rate vs the canonical prompt and output-format violations, with Gemma as the
     reference.
5. **Code generation:** a held-out set of our own single-turn code tasks, plus a small public slice
   (e.g. 30 aider-polyglot or LiveCodeBench v6 problems), thinking off.
6. **Prefix caching (hybrids only):** re-run step 3 with caching on (`--mamba-cache-mode align`) and
   compare outputs byte-for-byte with the cache-off run, as in `docs/hyperqwen/prefix-caching.md`.

## Sources

Model cards and configs (Hugging Face):
- https://huggingface.co/google/gemma-4-26B-A4B-it and [config.json](https://huggingface.co/google/gemma-4-26B-A4B-it/raw/main/config.json)
- https://huggingface.co/Qwen/Qwen3.6-35B-A3B and [config.json](https://huggingface.co/Qwen/Qwen3.6-35B-A3B/raw/main/config.json)
- https://huggingface.co/Qwen/Qwen3.5-35B-A3B
- https://huggingface.co/amd/Qwen3.6-35B-A3B-w4a16-llmcompressor
- https://huggingface.co/Kwaipilot/KAT-Coder-V2.5-Dev
- https://huggingface.co/InternScience/Agents-A1
- https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B
- https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B-NVFP4
- https://huggingface.co/poolside/Laguna-XS-2.1 and [config.json](https://huggingface.co/poolside/Laguna-XS-2.1/raw/main/config.json)
- https://huggingface.co/poolside/Laguna-XS.2
- https://huggingface.co/JetBrains/Mellum2.1-12B-A2.5B-Thinking and [config.json](https://huggingface.co/JetBrains/Mellum2.1-12B-A2.5B-Thinking/raw/main/config.json)
- https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16 and [config.json](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16/raw/main/config.json)
- https://huggingface.co/useful-quants/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-W4A16 (IFEval and 3090 throughput files)
- https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16
- https://recipes.vllm.ai/nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning-BF16
- https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Bolt-74B-A9B-24GB
- https://huggingface.co/LiquidAI/LFM2.5-24B-A2B, [config.json](https://huggingface.co/LiquidAI/LFM2.5-24B-A2B/raw/main/config.json), [LICENSE](https://huggingface.co/LiquidAI/LFM2.5-24B-A2B/blob/main/LICENSE)
- https://huggingface.co/cyankiwi/LFM2.5-24B-A2B-AWQ-INT4
- https://huggingface.co/CohereLabs/North-Mini-Code-1.0, [config.json](https://huggingface.co/CohereLabs/North-Mini-Code-1.0/raw/main/config.json), [blog](https://huggingface.co/blog/CohereLabs/introducing-north-mini-code)
- https://huggingface.co/cyankiwi/North-Mini-Code-1.0-AWQ-INT4
- https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct and [config.json](https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct/raw/main/config.json)
- https://huggingface.co/QuantTrio/Qwen3-Coder-30B-A3B-Instruct-AWQ
- https://huggingface.co/Qwen/Qwen3-30B-A3B-Instruct-2507
- https://huggingface.co/openai/gpt-oss-20b and [config.json](https://huggingface.co/openai/gpt-oss-20b/raw/main/config.json)
- https://huggingface.co/amd/gpt-oss-20b-BF16-w4a16-llmcompressor
- https://huggingface.co/zai-org/GLM-4.7-Flash and [config.json](https://huggingface.co/zai-org/GLM-4.7-Flash/raw/main/config.json)
- https://huggingface.co/QuantTrio/GLM-4.7-Flash-AWQ
- https://huggingface.co/moonshotai/Kimi-Linear-48B-A3B-Instruct
- https://huggingface.co/inclusionAI/Ling-3.0-tiny
- https://huggingface.co/inclusionAI/Ling-mini-2.0
- https://huggingface.co/XiaomiMiMo/MiMo-V2.6-Distill-Qwen-9B
- https://huggingface.co/ibm-granite/granite-4.0-h-small
- https://huggingface.co/mistralai/Devstral-Small-2-24B-Instruct-2512
- https://mistral.ai/news/mistral-small-4/
- https://huggingface.co/arcee-ai/Trinity-Mini
- https://huggingface.co/Qwen/Qwen3.8-Flash-Next and [LICENSE](https://huggingface.co/Qwen/Qwen3.8-Flash-Next/blob/main/LICENSE)
- https://huggingface.co/google
- https://openmdw.ai/license/1-1/
- https://docs.liquid.ai/lfm/inference/vllm

vLLM source, docs, releases, PRs and issues:
- https://github.com/vllm-project/vllm/blob/main/vllm/model_executor/models/registry.py
- https://github.com/vllm-project/vllm/releases/tag/v0.17.0, https://github.com/vllm-project/vllm/releases/tag/v0.27.0, https://github.com/vllm-project/vllm/releases/tag/v0.12.0
- https://github.com/vllm-project/vllm/pull/24722 (W4A8 Marlin), https://github.com/vllm-project/vllm/pull/61405, https://github.com/vllm-project/vllm/pull/58326, https://github.com/vllm-project/vllm/pull/43992, https://github.com/vllm-project/vllm/pull/55737
- https://github.com/vllm-project/vllm/blob/main/vllm/envs.py#L1562-L1565
- https://github.com/vllm-project/vllm/blob/main/vllm/model_executor/layers/quantization/utils/marlin_utils.py#L720-L739
- https://github.com/vllm-project/vllm/blob/main/vllm/model_executor/layers/quantization/utils/marlin_utils_fp8.py#L78-L80
- https://github.com/vllm-project/vllm/blob/main/vllm/model_executor/layers/quantization/utils/marlin_utils_fp4.py#L190-L194
- https://github.com/vllm-project/vllm/blob/v0.31.0/vllm/model_executor/layers/fused_moe/oracle/int8.py
- https://github.com/vllm-project/vllm/blob/v0.31.0/vllm/model_executor/layers/fused_moe/experts/triton_moe.py#L118-L156
- https://github.com/vllm-project/vllm/blob/v0.31.0/vllm/model_executor/layers/fused_moe/oracle/mxfp4.py#L342-L390
- https://github.com/vllm-project/vllm/blob/v0.31.0/vllm/model_executor/layers/mamba/gdn/qwen_gdn_linear_attn.py#L93-L146
- https://github.com/vllm-project/vllm/blob/v0.31.0/vllm/config/mamba.py#L25-L103
- https://github.com/vllm-project/vllm/blob/v0.31.0/vllm/platforms/cuda.py#L83-L151
- https://github.com/vllm-project/vllm/blob/v0.31.0/cmake/external_projects/flashkda.cmake#L25-L32
- https://github.com/vllm-project/vllm/blob/main/docs/features/quantization/README.md
- https://docs.vllm.ai/projects/recipes/en/latest/OpenAI/GPT-OSS.html
- https://github.com/vllm-project/humming
- Issues: https://github.com/vllm-project/vllm/issues/53787, https://github.com/vllm-project/vllm/issues/53726, https://github.com/vllm-project/vllm/issues/51663, https://github.com/vllm-project/vllm/issues/50780, https://github.com/vllm-project/vllm/issues/54775, https://github.com/vllm-project/vllm/issues/55008, https://github.com/vllm-project/vllm/issues/60008, https://github.com/vllm-project/vllm/issues/53912, https://github.com/vllm-project/vllm/issues/48904, https://github.com/vllm-project/vllm/issues/46366, https://github.com/vllm-project/vllm/issues/43888, https://github.com/vllm-project/vllm/issues/50989, https://github.com/vllm-project/vllm/issues/57699

Chat templates checked for thinking switches (`raw/main/chat_template.jinja`):
- https://huggingface.co/JetBrains/Mellum2.1-12B-A2.5B-Thinking/raw/main/chat_template.jinja
- https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B/raw/main/chat_template.jinja
- https://huggingface.co/InternScience/Agents-A1/raw/main/chat_template.jinja
- https://huggingface.co/CohereLabs/North-Mini-Code-1.0/raw/main/chat_template.jinja
- https://huggingface.co/LiquidAI/LFM2.5-24B-A2B/raw/main/chat_template.jinja
- https://huggingface.co/poolside/Laguna-XS-2.1/raw/main/chat_template.jinja

Papers and community data (secondary, labelled as such above):
- https://arxiv.org/abs/2604.00362 (gpt-oss Harmony reproduction)
- https://arxiv.org/abs/2508.10925 (gpt-oss model card)
- https://github.com/noonghunna/club-3090 (BENCHMARKS.md, KV_MATH.md)
- https://github.com/tfriedel/qwen3.6-rtx3090-lab
- https://github.com/ggml-org/llama.cpp/discussions/15396
- https://www.hardware-corner.net/glm-4-7-flash-llm-hardware/
- https://www.hardware-corner.net/gpu-ranking-local-llm/
