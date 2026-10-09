# HyperQwen prefix caching

Why `vllm-openai` serves Qwen3.8-27B with prefix caching off, what we suspect is broken, and what
it would take to turn it back on.

## Decision

Prefix caching stays **disabled** until one of the suspects below is confirmed and fixed, or ruled
out by the A/B test at the end of this doc.

`k8s/apps/vllm-openai/deployment.yaml` sets both of these, and both are required:

- `PREFIX_CACHE=0`, so HyperQwen's launcher does not add `--enable-prefix-caching --mamba-cache-mode align`.
- `--no-enable-prefix-caching` in `EXTRA_ARGS`. From vLLM 0.28, hybrid models get prefix caching by
  default, so `PREFIX_CACHE=0` on its own only drops align mode and leaves caching on.

## Symptom

With caching on, responses served from a cached prefix were much worse than the same prompt
prefilled fresh. This was a large quality decline, not the small numeric drift the 2026-10-06
investigation attributed it to. Caching was disabled on 2026-10-06 (commit `3ba79d6`).

Running at the time:

- Image `ghcr.io/syv-ai/hyperqwen@sha256:65f399a1…` (vLLM 0.29.0), `batch` profile.
- `--kv-cache-dtype fp8`, `--mamba-ssm-cache-dtype float16`, int8 activations on the MLP layers.
- No speculative decoding (batch mode has no drafter).
- Vision on, up to 4 images per conversation, about 2048 tokens per image.
- Async scheduling, `--max-num-batched-tokens 2048`, up to 64 concurrent requests.
- Traffic: multi-turn agent conversations with screenshots and long shared prefixes.

## How caching works for this model

Qwen3.8-27B is a hybrid: 48 Gated DeltaNet (recurrent, mamba-style) layers and 16 full-attention
layers. Attention layers can reuse cached KV at any block. The recurrent layers can only resume
where vLLM saved a snapshot of their state.

vLLM 0.30 has three `--mamba-cache-mode` values:

| Mode | Behaviour | For Qwen3.8 |
|---|---|---|
| `none` | No prefix caching | What we run |
| `align` | Snapshots the recurrent state at block boundaries (about 800 tokens here); a hit is cut back to the last boundary and resumes from that snapshot | The only working mode |
| `all` | Snapshots every token | Not implemented for Qwen3.5/3.8; falls back to `align` with a warning. Deprecated in 0.30, removed on vLLM main |

The real choice is therefore **align or no caching**. The CPU KV offload tier, LMCache and Mooncake
all sit on top of align mode, so they inherit any align bug. LMCache also asserts it is "not
verified yet" for Qwen3.5/3.6 (vllm#45407).

## Suspects

None of these is confirmed on our exact config. Almost every *confirmed* hybrid prefix-cache
corruption bug needs speculative decoding, KVarN, a draft model, or pipeline parallelism, and we
use none of those. These are the open ones that could apply without them.

### 1. A cache hit ending inside an image (HyperQwen #50)

- **Symptom:** a screenshot agent with a growing history gets confident answers about the
  **previous** turn's image: 1 correct out of 12 turns with caching on, all correct with it off.
- **Cause:** align mode cuts each hit back to a block boundary, and nothing keeps that boundary out
  of an image's token span. A hit that ends partway through an image is handled wrongly. Whether
  it triggers depends on where the images fall relative to the blocks.
- **Fix:** a proof-of-concept patch pulls the hit back to the start of the image. On the same
  requests it went from 6 of 14 stale answers to 14 of 14 correct, and a text-only check still
  passed. It was never merged.
- **Fit with us:** our blocks are about 800 tokens and our images about 2048, so hits often land
  inside an image. The failing setup in #50 used KVarN and `--prefix-match-unit 128`, and one bf16
  control was clean. **fp8 KV is untested.**
- **Also noted there:** two images in one message were wrong about half the time even with no cache
  hits.

Links:

- Issue: https://github.com/syv-ai/HyperQwen/issues/50
- Wrong-answer repro on a single 3090: https://github.com/syv-ai/HyperQwen/issues/50#issuecomment-5611177125
- Root cause and the PoC fix: https://github.com/syv-ai/HyperQwen/issues/50#issuecomment-5635427310
- Same engine hang on text-only Qwen3.8 agent traffic (~34k-token shared system prompt), fixed only
  by removing `--enable-prefix-caching`: https://github.com/syv-ai/HyperQwen/issues/50#issuecomment-5927365025
- Related: HyperQwen #107 (engine stops stepping, open), vllm#53912 (hybrid GDN prefix-cache family)

### 2. Recurrent state poisoned by abort and retry (vllm#56524, vllm#56525)

- **Cause:** vLLM marks a recurrent-state block as cached when it is *scheduled*, before it has
  been written, and never clears recurrent-state pages when it reuses them.
- **Symptom:** a client cancels mid-prefill and immediately resends the same prefix. The retry
  resumes from garbage and caches it. Every later request sharing that prefix is then bad until
  the engine restarts.
- **Fit with us:** agent clients that time out and retry match the trigger. It was only seen on
  Kimi-K3 with speculative decoding also on, so it has not been isolated. Both PRs are open and
  unmerged.
- **Related:** vllm#43569 (open), where the same early registration is not rolled back on
  preemption or abort.

Links: https://github.com/vllm-project/vllm/pull/56524, https://github.com/vllm-project/vllm/pull/56525

### 3. Unexplained collapse on Qwen3.6 (vllm#55291)

Qwen3.6-27B-FP8 with prefix caching and no speculative decoding collapses to "!!!!", and it
persists until restart. The cause is unknown, and a repro attempt on vLLM 0.28.0 was negative.

Link: https://github.com/vllm-project/vllm/issues/55291

### 4. Align-mode numerics (vllm#59764)

Splitting a prefill at a block boundary, as align mode does, moves token probabilities by up to
0.44 (median 0.068) on Qwen3.6. This is real, but it flips near-ties rather than wrecking answers,
so it does not explain a large decline.

Link: https://github.com/vllm-project/vllm/issues/59764

### Ruled out

- **Bugs needing speculative decoding, KVarN, a draft model or pipeline parallelism**, including
  HyperQwen #208 / #222 ("!!!!" from KVarN) and vllm #50729, #51113, #53919, #47123, #60210 and #55601.
- **Image position data and the encoder cache**, from reading the vLLM 0.30 source: image grid data
  survives prefix stripping, and the encoder-cache mismatch (#57696) needs client-supplied media UUIDs.
- **Cascade attention:** off by default.
- **The align-mode state-copy bug fixed by HyperQwen's `mamba-chunked-prefill-align.patch`:** fixed
  in both images.

### The new image does not fix any of this

HyperQwen `3acb93f` (vLLM 0.30.0) contains no fix for suspects 1–3. The two related upstream fixes
merged on 2026-10-07 (#60210, #55601) are not in any vLLM release yet, and both need configs we
don't run.

### HyperQwen's quality numbers never covered cache hits

HyperQwen's perplexity checks use `prompt_logprobs`, and vLLM skips the prefix cache for any
request that asks for them (`skip_reading_prefix_cache` in `vllm/sampling_params.py`). "Quality
unchanged with caching" was never measured on the cached path.

## Telling the suspects apart

| What the bad answers look like | Points to |
|---|---|
| About the wrong or previous screenshot; text-only traffic fine | Suspect 1 |
| Garbage or "!!!!" stuck to one prompt or conversation until a restart | Suspect 2 or 3 |
| Merely worse or more generic, text-only traffic affected too | Suspect 4, or something not yet found |

## Ways to get caching back

| Option | Covers | Cost / caveat |
|---|---|---|
| Keep caching off (current) | Everything | Every turn re-prefills its whole history |
| Port the #50 clamp patch into our own HyperQwen build | Suspect 1 only | Written for vLLM 0.28 + KVarN; needs porting to 0.30 and an image we maintain |
| Caching on, unique `cache_salt` on requests that must be correct | Those requests | They get no speedup; other requests are still exposed |
| Put each turn's screenshot last in the prompt | Suspect 1, maybe | Untested; needs client changes |
| Wait for upstream (#56524/#56525 merged, a fix for #50) | Suspects 1–2 | No timeline |
| Another engine | Depends | NInfer resumes from exact fp32 checkpoints, but max 8 concurrent and 1 image user. SGLang has a GDN-hybrid prefix cache; not verified for Qwen3.8 or images |

## A/B test before re-enabling

Run against a server with caching on, at concurrency 1 and temperature 0, so batch effects (#59764)
don't confound the result. Each case is sent twice: once with a unique `cache_salt`, which forces a
miss, and once unsalted after priming, which gives a hit. Compare the answers, the first-token
logprobs, and `usage.prompt_tokens_details.cached_tokens`.

1. **Screenshots (suspect 1):** the protocol from #50. Fourteen turns, each adding a new distinct
   image showing N coloured blocks and asking for the count, with the history accumulating.
2. **Text-only control:** the same multi-turn shape without images. HyperQwen's
   `bench/needle_reuse.py` and `bench/residue_sweep.py` cover this.
3. **Abort and retry (suspect 2):** cancel a long prefill about 1 s in, immediately resend the same
   prefix under some concurrency, then check later requests that share that prefix.

Set `VLLM_COMPUTE_NANS_IN_LOGITS=1` for all of them. It adds `Corrupted: N reqs` to the stats line
and the `vllm:corrupted_requests_total` metric. On vLLM 0.29 it forces a cold compile of about
3.5 minutes.

Before trusting the run, check the boot log for `Setting attention block size to N tokens`. The
~800 used throughout this doc is calculated, not observed.

Re-enable only if all three cases show the same answers with and without hits. If case 1 fails
alone, the #50 clamp patch is the fix to pursue.
