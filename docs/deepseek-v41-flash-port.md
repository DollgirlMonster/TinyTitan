# DeepSeek-V4.1-Flash port — integration concept

**Status: concept. Nothing here is implemented, and no width is supported.**

Requested: integrate `deepseek-ai/DeepSeek-V4.1-Flash` into TinyTitan at 4-bit and
8-bit, each derived from the original 16-bit.

This document is the source-verified design record that a later implementation
session works against, in the shape of
[`qwen38-flash-next-port.md`](qwen38-flash-next-port.md). Every geometry value,
tensor name, dtype and byte figure below was read from the published checkpoint
(its `config.json`, its `model.safetensors.index.json`, the safetensors headers
of the shards that carry the interesting tensors) or from the official
`inference/` reference code in the same repository. Anything inferred rather
than read is labelled **inferred**. Anything unverified is listed as an open
unknown in §12 rather than guessed at.

The conclusion, stated up front so it is not buried: **this is not a wiring
job.** It is not a `MODELS` row in `prepare_agentworld.py`, and it is not a
sibling of the Qwen3.8-Flash-Next port. Four of its subsystems — Engram,
Compressed Sparse Attention 2, the FP4-expert quantization format, and a
missing chat template — have no counterpart anywhere in this tree, and one of
them (Engram) alone is larger than every model this project has ever shipped.

---

## 1. The checkpoint, verified

| | Value | Read from |
| --- | --- | --- |
| Repo | `deepseek-ai/DeepSeek-V4.1-Flash` | HF API |
| Pinned sha | `dba1be0a40aa45a94ad051997016db3960a90277` | HF API (`lastModified` 2026-09-10) |
| `gated` | `false` | HF API |
| License | MIT | `LICENSE`, card `license: mit` |
| `architectures` / `model_type` | `DeepseekV41ForCausalLM` / `deepseek_v41` | `config.json` |
| Nested configs | `text_config.model_type` `deepseek_v41_text`, `vision_config.model_type` `deepseek_v41_vision` | `config.json` |
| Shards / tensors | 48 safetensors / 96,085 index entries | index + tree API |
| Size on disk | **510.3 GB** (`total_size` 510,286,023,000; tree total 510,311,613,821) | index + tree API |
| Declared parameters | **763,205,315,794** | safetensors metadata (HF API) |
| Card's parameter claim | 552 B backbone + 196 B Engram = 748 B | card README |
| Context | 1,048,576 (`max_position_embeddings`) | `config.json` |
| `tie_word_embeddings` | `false` — the head is a real tensor (`head.weight`, `[129280, 5120]`, BF16) | `config.json` + shard 43 header |
| Chat template | **absent.** "This release does not include a Jinja-format chat template." | card README |
| `generation_config.json` | **absent** — the repo has no such file | tree API |

The card's 748 B and the safetensors metadata's 763.2 B do not reconcile, and
neither source explains the gap. Both figures are recorded; the tech report that
would settle it is an unreadable Git-LFS pointer (§12).

### Text geometry

| Field | Value |
| --- | --- |
| `num_hidden_layers` | 40 (card: 20-layer causal encoder + 20-layer decoder) |
| `hidden_size` | 5120 |
| `vocab_size` | 129280 |
| `num_attention_heads` / `num_key_value_heads` | 64 / **1** |
| `head_dim` / `qk_rope_head_dim` | 512 / 64 |
| `q_lora_rank` / `o_lora_rank` / `o_groups` | 1280 / 1024 / 8 |
| `n_routed_experts` / `n_shared_experts` / `num_experts_per_tok` | 384 / 1 / 6 |
| `moe_intermediate_size` | 2304 |
| `scoring_func` / `topk_method` | `sqrtsoftplus` / `noaux_tc` |
| `norm_topk_prob` / `routed_scaling_factor` | `true` / 1.5 |
| `hidden_act` / `swiglu_limit` | silu / **10.0** |
| `rms_norm_eps` | 1e-20 |
| `rope_scaling` | yarn, factor 16, `original_max_position_embeddings` 65536, theta 10000 |
| `sliding_window` | 128 |
| `compress_ratios` | 43 entries: `[0, 0, 18×2, 20×1, 0, 0, 0]` |
| `kv_source_layer_ids` / `index_source_layer_ids` | [2,8,14,20] / [2,8,14,20,24,28,32,36] |
| `index_n_heads` / `index_head_dim` / `index_topk` | 32 / 128 / 512 |
| `candidate_source_layer_id` / `candidate_topk_blocks` / `candidate_block_size` | 20 / 2048 / 8 |
| `hc_mult` / `hc_sinkhorn_iters` / `hc_eps` | 4 / 20 / 1e-6 |
| `engram_layer_ids` / `engram_num_embeddings` | [1, 14] / [384006168, 384016682] |
| `engram_vocab_size` / `engram_max_ngram_size` / `engram_n_heads` / `engram_head_dim` | 16,000,000 / 4 / 8 / 256 |
| `num_nextn_predict_layers` / `dspark_*` | 3 draft layers at 128 experts top-3, `dspark_block_size` 5 |

### The tensor inventory, by category

Counted from `model.safetensors.index.json`; the checkpoint's own top-level
namespaces are `layers.*`, `mtp.*`, `vision.*`, `aligner.*`, `embed.weight`,
`head.weight`, `norm.weight`, `image_start`, `image_end`, `image_newline`.

| Category | Tensors | Stored bytes (from shard headers) |
| --- | ---: | ---: |
| routed experts (40 layers × 384 experts × w1/w2/w3) | 92,160 | ≈ 288.8 GB |
| Engram (2 layers × 6 tensors) | 12 | **≈ 202.8 GB** |
| attention (wq_a, wq_b, wkv, wo_a, wo_b, sink, norms) | 603 | ≈ 6.45 GB |
| hyper-connections (`hc_*`, 6 per layer) | 240 | ≈ 1.77 GB |
| shared experts | 240 | ≈ 1.77 GB |
| router gate (`weight`, `bias`, `bias_vl` per layer) | 120 | ≈ 0.90 GB |
| MTP/DSpark (3 layers, 128 experts each) | 2,401 | ≈ 6.35 GB |
| vision tower + aligner | ≈ 263 | ≈ 0.26 GB |
| `embed.weight` | 1 | 1.32 GB |
| `head.weight` | 1 | 1.32 GB |
| norms, image specials, `norm.weight` | ≈ 45 | ≈ 0.31 GB |

Per-tensor shapes that matter, read from the safetensors headers:

```
layers.0.attn.wq_a.weight    F8_E4M3  [1280, 5120]     scale F8_E8M0 [40, 160]
layers.0.attn.wq_b.weight    F8_E4M3  [32768, 1280]    scale F8_E8M0 [1024, 40]
layers.0.attn.wkv.weight     F8_E4M3  [512, 5120]      scale F8_E8M0 [16, 160]
layers.0.attn.wo_a.weight    F8_E4M3  [8192, 4096]     scale F8_E8M0 [256, 128]
layers.0.attn.wo_b.weight    F8_E4M3  [5120, 8192]     scale F8_E8M0 [160, 256]
layers.0.attn.attn_sink      F32      [64]
layers.0.ffn.gate.weight     BF16     [384, 5120]
layers.0.ffn.gate.bias       F32      [384]
layers.0.ffn.gate.bias_vl    F32      [384]
layers.0.ffn.experts.0.w1.weight  I8   [2304, 2560]    scale F8_E8M0 [2304, 160]
layers.0.ffn.experts.0.w2.weight  I8   [5120, 1152]    scale F8_E8M0 [5120, 72]
layers.0.ffn.experts.0.w3.weight  I8   [2304, 2560]    scale F8_E8M0 [2304, 160]
layers.0.hc_attn_fn          F32      [24, 20480]
layers.14.engram.embed.weight F8_E4M3 [384016682, 256] scale F8_E8M0 [384016682, 8]
layers.14.engram.wkv.weight  F8_E4M3  [25600, 6144]    scale F8_E8M0 [800, 192]
layers.14.engram.q_weight    BF16     [4, 5120]
layers.14.engram.k_weight    BF16     [4, 5120]
embed.weight                 BF16     [129280, 5120]
head.weight                  BF16     [129280, 5120]
```

Two whole shards — `model-00047` and `model-00048`, 101.5 GB each — contain
**six tensors each, and all six are Engram**. The Engram tables are 40% of this
checkpoint's bytes.

---

## 2. First correction: there is no 16-bit source to convert from

The request says "each converted from original 16-Bit". That premise does not
hold for this checkpoint, and the difference changes the conversion design.

`config.json` declares `"dtype": "bfloat16"`, but that is a declaration, not the
storage format. The checkpoint's own `quantization_config` says:

```json
{ "quant_method": "fp8", "activation_scheme": "dynamic",
  "weight_block_size": [32, 32], "scale_fmt": "ue8m0", "expert_dtype": "fp4" }
```

The safetensors metadata agrees: 204.0 B of `F8_E4M3` values, 557.2 B of `I8`
values, only 2.0 B BF16 and 42.3 M F32. The `I8` bucket is the routed experts —
`557,171,343,360` is exactly `384·3·5120·2304·40 + 128·3·5120·2304·3`, the routed
expert value count — stored as **packed FP4** at two nibbles per byte.

So the masters are:

- **Attention projections, shared experts, DSpark `main_proj`, Engram `embed`/`wkv`:
  FP8 E4M3** with `F8_E8M0` block scales.
- **Routed experts (backbone and MTP): FP4 E2M1**, packed along K at two
  values per byte, scaled per 32 along K by an E8M0 power-of-two exponent.
- **`wo_a` is BF16** in the published checkpoint even though the reference code
  treats it as the BF16 path — `convert.py` dequantizes it back.
- Router (`ffn.gate.weight`) BF16, `attn_sink` and all `hc_*` F32, every norm
  BF16.

Three consequences, all of which belong in the document rather than in a
surprise at the end of a 510 GB download:

1. **"16-bit" is a reconstruction, not a source.** Any `--bits 16` path means
   dequantizing FP8/FP4 back to BF16 — producing a *larger* artifact than the
   checkpoint it came from, at 748–763 B × 2 bytes ≈ 1.5 TB. That is not
   achievable on this host and is not worth building.
2. **The averaging matters for what "8-bit" means.** The card is tagged
   "8-bit precision", and its FP8 half really is 8-bit, but 61% of the
   parameters are FP4. Weighted across the file the published checkpoint
   averages ≈ 5.9 bits per parameter (510.3 GB over 763.2 B). A TinyTitan
   8-bit build at affine group 64 (8.25 effective bits) is therefore **not**
   "the same 8-bit" — it is roughly 40% larger than the checkpoint it converts.
3. **FP4 experts do not fit the affine scheme at all.** TinyTitan's `.gturbo`
   quant slots are affine (`weightBits`/`scheme`/`scaleType`/`biasType`/
   `groupSize`), and its converters emit affine group-64 snapshots. FP8
   E4M3 + E8M0 per-32×32 and packed FP4 E2M1 + E8M0 per-32 are different
   formats. Either the converter dequantizes both to BF16 first and then
   quantizes affinely — the simple, expensive path — or the runtime grows
   block-FP8 and FP4 kernels — the cheap-to-run, expensive-to-build path. §6
   takes a position.

---

## 3. What the port actually has to build

In dependency order. Each of these is a subsystem, not a config flag.

### 3.1 No chat template — a hard blocker, and the cheapest to fix

TinyTitan's runtime renders prompts from the model's own `chat_template.jinja`
and errors with "installed tokenizer is missing chat_template.jinja" without it.
This release ships **no Jinja template at all**; prompt encoding lives in
`encoding/encoding.py` (a self-contained Python reference with tests) and the
external `deepseek-recipe` library.

Supplying one is a prerequisite for *any* install, at any width, and it is the
one piece of work here that is genuinely small — but it is also the one that
must be exact, because the template is simultaneously the prompt format, the
tool-call dialect and the reasoning-marker system. `encoding/README.md` gives
the pieces a template has to reproduce:

- roles `system`, `user`, `assistant`, `tool`, `latest_reminder`;
- tokens `<｜begin▁of▁sentence｜>` (0), `<｜end▁of▁sentence｜>` (1, also pad),
  `<｜User｜>`, `<｜Assistant｜>`, `<｜System｜>`, `<｜latest_reminder｜>`,
  `<think>`/`</think>`, `｜DSML｜`, `<｜deepseek_image｜>`;
- **thinking mode**: `<think>…</think>` before the answer, plus a one-time
  `<｜System｜>Reasoning Effort: {budget} (range 1-100…)` injection at index 0;
  chat mode emits `</think>` immediately after `<｜Assistant｜>`;
- **tool calls, changed in V4.1**: `<｜DSML｜ calls>` (leading space),
  `<｜DSML｜ invoke name="…">`, `<｜DSML｜ parameter name="…" string="true|false">`
  — V4 used `<｜DSML｜tool_calls>` with no leading space, so a template copied
  from a V4 sibling would be wrong in a way that still parses sometimes;
- tool results as `<｜User｜><tool_result>…</tool_result>`;
- `drop_thinking` (default true) strips earlier-turn reasoning but is
  auto-disabled when tools are present.

`reasoning_effort` is an integer 1–100 with aliases low→50, high→75 (default),
max→100. TinyTitan's existing thinking levels must be mapped onto that, and the
mapping recorded as a deviation if it cannot be exact.

There is also **no `generation_config.json`**, so the sampling defaults come
from the card: temperature 1.0, top_p 0.95 or 1.0, max_tokens ≥ 256K,
context 1M. TinyTitan supports presence penalty `0.0` only; nothing here asks
for otherwise, which is one of the few things that goes smoothly.

### 3.2 Compressed Sparse Attention 2 (CSA2)

The card names it CSA2; the mechanism in `inference/model.py` is index-based
selection over two KV sources concatenated into one `sparse_attn` call.

**Sliding window (every layer, per-layer cache).** A ring buffer of 128 raw KV
slots per layer, `window_kv_cache [B, 128, 512]`. Prefill builds one causal
window per query; decode gives the single query the whole ring oldest-first.

**Compressed KV (only where `compress_ratios[layer] > 0`).** A `Compressor`
pools `compress_ratio` consecutive tokens into **one** 512-d latent through a
learned softmax gate: `kv = wkv(x)`, `score = wgate(x)` (both fp32), pooled as
`Σ kv·softmax(score over the group)`, then RMSNorm. `ratio == 1` degenerates to
`norm(wkv(x))` with no gate and no fp32. Incomplete groups persist in
`kv_state`/`score_state` across decode steps, and the compressor returns
**pre-RoPE** latents because the indexer needs them unrotated. Cache shape
`[B, max_seq_len // ratio, 512]`.

The layer schedule is `[0, 0, 18×2 (layers 2–19), 20×1 (layers 20–39), 0, 0, 0]`:
layers 0–1 and the three MTP layers are window-only.

**Hierarchical lightning indexer**, on `index_source_layer_ids`
[2,8,14,20,24,28,32,36] only: 32 heads of dim 128, `index_topk` 512,
scale 128^−0.5. `wq_b` derives its query from the same `qr` as attention Q;
`weights_proj` is 5120→32; `wk` (owners only) is 512→128 plus an RMSNorm.
Score is `einsum("bshd,btd->bsht")` → **relu** → weighted by head → summed.
Unreachable compressed positions are masked to −inf, `topk(min(512, end_pos//ratio))`
is taken, indices are re-sorted into position order, invalid entries become −1,
valid ones shift by the window length, returned as int32.

**Two-level candidate pre-filter:** `candidate_source_layer_id` 20 scores each
8-token block by its max position logit, pins the partially-filled newest block,
keeps the top 2048 blocks; layers 21–39 mask their own index scores to that
block set before top-k. A negative source id disables the level.

**Cross-layer sharing** is the part with no analogue in this tree. A
`SharedAttentionRuntime` singleton carries `compress_kv`, `index_k`, `topk_idxs`
and `candidates` down the stack: only the four `kv_source_layer_ids` own a
compressor cache (2→layers 3–7, 8→9–13, 14→15–19, 20→21–39); only the
kv-source subset of index sources owns an indexer K cache; only index sources
run an indexer and publish `topk_idxs`; **every other layer reads the last
published object.** Window KV stays per-layer. MTP layers are excluded
(`is_backbone = layer_id < n_layers`). The card's "Full / Reindex / Reuse"
modes are, **inferred**, exactly this partition: Full = {2,8,14,20},
Reindex = {24,28,32,36}, Reuse = the remaining layers.

Consequence for the runtime: the KV cache is no longer per-layer. It becomes a
small set of shared, ratio-scaled caches plus 40 per-layer windows, and the
decode loop acquires an inter-layer dependency — a layer cannot attend until an
earlier source layer has published. That reaches into the runner's command
graph, not just a kernel.

**Cache precision.** The card states ≈ **890 bytes per token** globally (≈ 1/4
of V4-Flash; ≈ 1/8 persistent with SWA Bounded Replay; ≈ 437× better than V1).
The mechanism is FP4 E2M1 main KV with one E4M3 scale per 16 channels, FP4
indexer Q/K with E8M0 per 32, and FP8 window KV, all as fused quant+dequant
(`inplace=True`). TinyTitan already has 4-bit/8-bit KV quantization, but this is
a different layout and a different granularity.

Note "SWA Bounded Replay" appears only in the card prose — **no code for it in
`inference/`** — so it is not something that can be lifted, only re-derived.

### 3.3 Engram — the decisive subsystem

Two tables at **layers 1 and 14**, `engram.embed.weight` FP8 E4M3 with shapes
`[384006168, 256]` and `[384016682, 256]` — **98.3 B rows, 196.6 B parameters,
202.8 GB as stored**, versus a card claim of 196 B parameters. The two tables
ship as shards 47 and 48 on their own, 101.5 GB each.

`engram_vocab_size` = 16,000,000 is *not* the row count; it is the starting
point of a prime-bucket search. **Inferred** from `inference/engram.py`: per
layer the table is partitioned into `(max_ngram_size − 1) × engram_n_heads`
= 3 × 8 = 24 prime-sized buckets, 48 primes across the two layers, drawn in
order and never reused, each ≈ 16.0 M rows (`384006168 / 24 ≈ 16,000,257`).

The lookup, per `inference/engram.py`:

1. Every token id maps to a **compressed** id via `build_compressed_token_map`
   (NFKC → NFD → strip accents → lowercase → collapse whitespace → strip;
   partial-UTF8 tokens keyed raw), asserted to be exactly
   `engram_compressed_vocab_size` 99092 entries. This is derived from the
   tokenizer and is **runtime state**, not weights.
2. Image spans become `DEAD` (−1); look-back stops at the sequence start or any
   DEAD token; blocked slots take `pad_id` 2.
3. For shifts 0–3, `token = cache[pos − shift]`; per (layer, shift) **odd**
   multipliers come from a fixed numpy RNG seeded `10007·layer_id`, bounded by
   `int64max / (compressed_vocab·2)`.
4. `rolling = t0·m0; for i in 1..3: rolling ^= ti·mi; hash_i = rolling % prime_i`
   → 3 n-gram sizes × 8 heads = 24 hash ids, offset by the bucket cumsum.
   Output `[B, L, 2, 24]`.
5. Injection happens **before** the block body:
   `kv = wkv(embed(hash_ids).flatten(-2))` → key `[B,L,4,5120]` + value
   `[B,L,5120]`; `weight = q_weight · k_weight`;
   `rstd = rsqrt(mean(h²)+eps)·rsqrt(mean(key²)+eps)`;
   `dot = Σ(h·weight·key)·rstd·dim^−0.5`;
   `gate = sigmoid(copysign(sqrt(max(|dot|,1e−6)), dot))`;
   output `h + gate[...,None]·value[...,None,:]` — one shared 5120-d value added
   to all four hc copies, gated per (token, hc copy). Embedding rows are FP8,
   dequantized per 32-block on lookup.

So Engram is not an embedding table that can sit in the resident file. It is
14.6 M rows *per output token* of a 203 GB table, whose indices depend on a
tokenizer-derived map and on a rolling hash across the four preceding tokens.

**In `prepare_agentworld.py`'s loader: no analogue.** `convert.py` in the
checkpoint repo special-cases two checkpoint name components, `tie2eid` and
`tid2eid`, that do not appear in `inference/model.py` at all; their role is an
open unknown (§12).

**Sizing reality**, computed from the verified shapes and TinyTitan's own
effective bits per weight (4.25 at 4-bit, 8.25 at 8-bit, affine group 64):

| Engram precision | Stored size |
| --- | ---: |
| 16-bit (what "convert from 16-bit" would mean) | **393 GB** |
| 8-bit affine | **203 GB** |
| 4-bit affine | **105 GB** |
| its own native FP8 E4M3 + E8M0/32 | **203 GB** |

Keeping Engram at 16-bit costs more than the entire published checkpoint
(510 GB) minus the experts. This is why §6 recommends leaving it at native FP8:
it costs exactly what the checkpoint already spends, it is the precision the
model was trained and evaluated at, and 8-bit affine buys nothing over it while
4-bit affine halves it at an unknown quality cost on a table whose rows are
lookup keys, not a smooth weight matrix.

### 3.4 Attention and MoE details that are new even without CSA2

- **Not MLA in the V3 sense.** Q *is* low-rank (`wq_a` 5120→1280, `q_norm`,
  `wq_b` 1280→64×512) but **KV is not**: a single `wkv` 5120→512 plus
  `kv_norm(512)`, one KV head shared by all 64 query heads. There are **no
  separate qk_nope/qk_rope projection tensors** — `nope_head_dim` is computed in
  the reference and never used. The split is purely positional: the **last 64**
  of the 512 dims are RoPE-rotated, and the attention output gets the inverse
  rotation on those dims so the cache can stay in one rotated form.
- **`o_groups` = 8.** `wo_a` is a grouped, block-diagonal projection
  (`[8192, 4096]`, 8 groups of 8 contiguous heads → 1024 each), then `wo_b`
  `[5120, 8192]`. Group *g* sees only its own eight heads.
- **`attn_sink`** is a learnable per-head fp32 bias `[64]` added into the
  softmax denominator. `softmax_scale = head_dim^−0.5` = 512^−0.5, not the
  rope-dim scale.
- **Router.** `scores = softplus(linear(x)/gate_temp).sqrt()`. Selection is
  `topk(scores + bias)` with the **unbiased** scores gathered as the weights,
  normalized when `norm_topk_prob`, then scaled by 1.5. The selection bias
  never scales the weights. `topk_method: noaux_tc` is not a field in the
  reference; the semantics above are what it implements. There is a second
  `gate.bias_vl` of the same shape used when vision is enabled — semantics of
  when it applies are an open unknown (§12), but a text-only build must decide
  which bias to use and say so.
- **`swiglu_limit` = 10.0**: `up = clamp(up, −10, +10)` both sides,
  `gate = clamp(gate, max=10)` upper only, then `silu(gate)·up`. Not optional —
  the reference comment ties it to keeping fp8/fp4 activations in range.
- **Hyper-connections are Sinkhorn-normalized** (as in the Qwen3.8 port, but
  with this model's constants `hc_mult` 4, 20 iterations, eps 1e-6), with a
  **scheduling quirk**: a sub-block's coefficients are consumed by the *next*
  one. Attention collapses with the previous FFN's `pre_mix`; the FFN returns
  the next block's. The stream starts as identity one-hot on copy 0. Whatever
  the Qwen3.8 port built must be checked against this ordering before reuse.
- **MTP/DSpark** is a 3-layer draft with 128 experts top-3, `dspark_block_size`
  5, a Markov bigram correction head and a confidence head, reading the
  **attention input** of target layers 37/38/39 (not their output). The
  reference repo implements only the forward path; its own README says
  "Generation itself is plain autoregressive sampling", and the
  confidence-scheduled verification loop is absent. So there is no reference
  accept/reject algorithm to port — only a forward one.

### 3.5 Vision — deferred, per decision

The vision tower is genuinely present in this repo (unlike some Qwen
checkpoints, which declare a `vision_config` and ship language weights only):
`vision.*` and `aligner.*` tensors exist, ≈ 0.26 GB BF16. Tower: 32 layers,
dim 1024, 16 heads of 64, intermediate 2816, patch 14, `downsample_ratio` 3,
`max_image_tokens` 1024, `min_pixels` 295936. `PatchEmbed.proj` is
`Linear(3·14·14 = 588 → 1024)`; 2D RoPE splits 1024/16/2 = 32 dims per axis;
blocks are **full bidirectional** attention (no mask); the aligner is a 3×3
pixel-unshuffle (`1024·9 = 9216`) → 5120 → GELU → 5120, i.e. it **does** map to
the text hidden size.

Image tokens are emitted as
`[IMAGE_START] + ([IMAGE]×w + [IMAGE_NEW_LINE])×h + [IMAGE_END]`, with
`n_llm_h·(n_llm_w+1) + 2` positions, **every one carrying `image_token_id`
129264** in `input_ids` and distinguished only by `token_type`
(TEXT = −1, START/IMAGE/NEW_LINE/END = 0..3). START/END/NEW_LINE take learned
`image_start`/`image_end`/`image_newline` [5120] embeddings; the IMAGE slots take
aligner rows in reading order.

**Decision: text-only first, vision deferred** — the Qwen3.8-Flash-Next
precedent. The consequence to state honestly is that a deferred vision path is
not a bolt-on here: the Engram hash map treats image spans as DEAD, the router
has a separate `bias_vl`, and the tokenizer's placeholder id is entangled with
the input pipeline. Deferring vision defers that coupling; it does not avoid it.

---

## 4. What this tree already has that the port can reuse

Recorded because it is the difference between "months" and "never", and because
`adding-a-model.md`'s first question is whether this is a wiring job.

| Need | Existing asset | Fit |
| --- | --- | --- |
| 4-bit/8-bit affine conversion | `tools/prepare_agentworld.py`, `prepare_qwen38.py` — streaming shard-at-a-time, group-64 affine, bf16 keep list, `--plan` mode | **Partial.** The pipeline is right; the *input* is FP8/FP4 and the tensor namespaces do not match any it knows |
| Streaming + bounded cache | the v4.1 expert streaming engine (`docs/v4.1-expert-streaming-engine.md`) — per-layer expert blobs, 16 KiB alignment, hit/fixup schedule, `F_NOCACHE` preads | **Strong.** This is the mechanism that makes a 763 B model conceivable at all |
| Sparse attention | `Kernels/Attention/QSAIndexer.swift`, `Runtime/Family/QSAExactness.swift` (Qwen3.8-Flash-Next) | **Partial.** Global, per-layer, dense-over-context indexer; CSA2 needs per-source-layer sharing, ratio-scaled compressed caches and a two-level candidate pre-filter |
| Hyper-connections | `Runtime/Family/Qwen38FlashFamily.swift`, `ModelProfile.hcFused` | **Partial.** Same idea, different constants and a different sub-block ordering |
| KV quantization | 4-bit/8-bit KV paths (`kvCachePrecision`, `KVCacheQuantizer`) | **Partial.** Different block layout and granularity |
| Dense FP8 / FP4 kernels | none | **Missing** |
| Engram | none | **Missing** |
| Chat template | renderer requires one | **Missing** |

---

## 5. Tensor mapping (checkpoint → resident index)

The checkpoint uses bare names — `layers.N.*`, `embed.weight`, `head.weight` —
which match **none** of the namespaces `prepare_agentworld.py` knows
(`model.language_model.*`, `lm_head.weight`, `model.visual.*`, `mtp.*`). This is
a new converter with a new rename table, not a new `MODELS` row.

| Checkpoint name | Resident stem | Slot |
| --- | --- | --- |
| `embed.weight` | `language_model.model.embed_tokens.weight` | `embedding` |
| `head.weight` | `language_model.lm_head.weight` | `embedding`/head |
| `norm.weight` | `language_model.model.norm.weight` | bf16 keep |
| `layers.N.attn.wq_a` / `wq_b` / `wkv` / `wo_b` | `language_model.model.layers.N.self_attn.*` | `attention` |
| `layers.N.attn.wo_a` | same | `attention`, **bf16 keep** (published bf16) |
| `layers.N.attn.q_norm` / `kv_norm` | same | bf16 keep |
| `layers.N.attn.attn_sink` | same | f32 keep |
| `layers.N.attn_norm` / `ffn_norm` | same | bf16 keep |
| `layers.N.ffn.gate.weight` | `language_model.model.layers.N.mlp.gate.weight` | `router`, bf16 keep |
| `layers.N.ffn.gate.bias` / `bias_vl` | same | f32 keep |
| `layers.N.ffn.shared_experts.w1/w2/w3` | `…mlp.shared_expert.*` | `sharedExpert` |
| `layers.N.ffn.experts.E.w1/w2/w3` | `…mlp.experts.E.*` | `routedExpert` (per-layer files) |
| `layers.N.hc_attn_*` / `hc_ffn_*` | `language_model.model.layers.N.hc_*` | f32 keep |
| `layers.{1,14}.engram.embed` | **new streaming section** | see §6.4 |
| `layers.{1,14}.engram.wkv` | new | `engram` |
| `layers.{1,14}.engram.q_weight` / `k_weight` | new | bf16 keep |
| `mtp.{0,1,2}.*` | `language_model.mtp.N.*` | new `dsparkMTP` family |
| `vision.*`, `aligner.*`, `image_start/end/newline` | — | **excluded** (text-only) |

The router also needs the derived Engram constants — the 99092-entry
compressed-token map, the 48 bucket primes and sizes, and the per-(layer, shift)
odd multipliers — which are **not weights** and must be produced by the
converter into a sidecar the runtime reads. Nothing in `.gturbo` carries
non-tensor constants today.

---

## 6. The 4-bit and 8-bit policy

### 6.0 "Convert" and "re-quantize" are two different jobs

They are easy to conflate, and the difference decides both the byte count and
the amount of kernel work, so it is stated before the policy table.

TinyTitan has exactly **one** weight format today. `dequant_affine.metal` binds
`kAffineGroupSize = 64` and reads `uint` packed weights plus a `bfloat` scale
**and a `bfloat` bias** per 64-wide group; its inner loop is
`fma(scale, q0·x0 + q1·x1, fma(bias, x0 + x1, acc))`. Int4 and int8 share that
kernel, and `Quantization.swift` records `scheme`, `scaleType`, `biasType` and
`groupSize` per tensor. There is **no block-scaled FP8 decode and no FP4 E2M1
decode anywhere in the runtime.**

This checkpoint, however, is stored as FP8 E4M3 with an E8M0 power-of-two
exponent per 32×32 block, and FP4 E2M1 packed two-per-byte with an E8M0 scale
per 32 along K (§2). Neither is affine, and neither is a group-of-64 with a
zero-point bias. So:

| | **Path A — re-quantize** | **Path B — preserve the checkpoint's own quants** |
| --- | --- | --- |
| What the converter writes | affine int4/int8, group 64, scale+bias | the checkpoint's FP8 E4M3 + E8M0/32 blocks and packed FP4 E2M1 + E8M0/32, byte-for-byte as published |
| Are the quants changed? | **Yes** — round-trip through BF16, then affine | **No** — the stored quantized values and scales are the model's own |
| New runtime work | none beyond this port's non-quant parts; the existing GEMV kernels apply | **new decode/GEMV kernels** per format (block-FP8, packed-FP4), plus manifest `scheme` values and a per-tensor `scaleType` meaning "E8M0 exponent" |
| Text-only size | ≈ **373 GB** (4-bit) / ≈ **532 GB** (8-bit) | ≈ **510 GB** — the checkpoint's own size, because nothing is re-encoded |
| Yields the two-width pair? | yes: `…_4-Bit` and `…_8-Bit` | **no** — one install, at the model's own precision |
| Parity with `inference/` | approximate; the gap mixes TinyTitan bugs with quantization loss | **exact** — same weights the reference reads, so a logit mismatch is a TinyTitan bug |
| Fidelity ceiling | 4.25 / 8.25 effective bits | 8 bits dense, 4 bits experts, exactly as trained and evaluated |

**Recommendation: Path B for the first build, for verifiability rather than for
fidelity.** This project's documented worst failure is a silent format
misread — `docs/gturbo-format.md`'s 8-bit tensors unpacked as 4-bit, where
"every shape check passes, and the model answers fluently and wrongly". On a
753 B model whose forward is already four new subsystems, adding an unmeasured
re-quantization on top makes every debugging session ambiguous: a wrong logit
could be the indexer, the engram gate, the shared KV publication, or the
quantizer, and nothing distinguishes them. Preserving the quants removes one
variable completely and makes the reference comparison meaningful. It also
presumably answers the request as literally written — "converted but not
changed in terms of quants" is Path B, and Path A is a re-quantization *to*
4-bit and 8-bit rather than a conversion *from* something.

The cost of Path B is real and should not be understated: two new weight-decode
kernels, a manifest extension for non-affine schemes, and the loss of the
per-width pair. If the intent was the pair — that every TinyTitan model is
installed at both widths — then Path A is the answer and §6.0's table is the
price. This is the decision §11 asks the owner to make.

### 6.1 The re-quantized policy (Path A)

TinyTitan's convention is that "k-bit" means the **routed-expert slot** is
k-bit affine group 64, that every other tensor has a stated per-tensor width,
and that the manifest records all of it (`docs/gturbo-format.md`, "slots *and*
per-tensor widths"). Applied to this checkpoint:

| Tensor group | 4-bit build | 8-bit build | Rationale |
| --- | --- | --- | --- |
| routed experts (288.8 GB of the file) | affine 4-bit, group 64 | affine 8-bit, group 64 | the definition of the width |
| Engram `embed` + `wkv` | **native FP8 E4M3 + E8M0/32** | **native FP8 E4M3 + E8M0/32** | §3.3: 16-bit costs 393 GB, 4-bit affine is 105 GB with unmeasured quality risk on a lookup table |
| `attn_sink`, all norms, all `hc_*`, gate biases, `q_weight`, `k_weight`, `DSparkConfidenceHead.proj` | f32/bf16 keep | f32/bf16 keep | they are decisions and normalizers |
| `ffn.gate.weight` (router) | bf16 keep | bf16 keep | a routing decision either matches the reference or it does not |
| `wo_a` | bf16 keep | bf16 keep | published bf16; part of the grouped output projection |
| attention `wq_a`/`wq_b`/`wkv`/`wo_b` | 8-bit affine | 8-bit affine | smallest tensors after Engram; keep them precise |
| shared experts | 8-bit | 8-bit | one expert, ~0.9 GB per width |
| `embed.weight` / `head.weight` | 8-bit | 8-bit | matches the dense-install precedent |
| MTP/DSpark experts | 4-bit | 8-bit | follows the width |

The FP8→affine bridge is the design decision §2 flagged. Recommended for a first
attempt: **dequantize FP8 and FP4 to BF16 inside the converter, then quantize
affinely**, because the existing converters already do exactly that shape of
work and the runtime needs no new GEMM. The cost is that a 4-bit build's
routed experts pass through a lossy FP4→BF16→affine chain — FP4 E2M1 has a
6.0 range and a floor of `6·2⁻⁹`, so information was already lost before
TinyTitan touches it. A faithful path would add block-FP8 and FP4 E2M1 kernels,
which is a kernel project of its own; §9 sequences it as a later phase rather
than pretending it is free.

An alternative worth one experiment before committing: **restrict the first
surrogate (a small synthetic checkpoint, §8) to the uniform-BF16 path** and
prove the architecture end-to-end with no quantization in the way. That
separates "the runtime is wrong" from "the quantization is wrong", which is the
failure mode this project has hit before (`docs/gturbo-format.md`: 8-bit
tensors unpacked as 4-bit, "the model answers fluently and wrongly").

### 6.2 Group alignment

`GROUP_SIZE = 64`, so every quantized last dimension must be a multiple of 64.
The known hazard: `experts.*.w2` is stored `[5120, 1152]` as packed FP4, i.e.
2304 real columns, and **2304 is not a multiple of 64**. The converter must
expand the packed nibbles and, if affine group 64 is used for that tensor, pad
or regroup explicitly rather than reshape and divide — `prepare_agentworld.py`
raises `last dimension N is not group-aligned` exactly to catch this, and it
will.

### 6.3 Effective sizes, and the fact that neither width fits

Bytes computed from the verified sources: 271.8 B routed-expert weights,
196.6 B Engram values (plus 100.7 B scale elements), everything else as tabled.
Effective bits per weight are 4.25 (4-bit) and 8.25 (8-bit) at group 64.

| Component | 4-bit | 8-bit |
| --- | ---: | ---: |
| resident core (attention, router, shared experts, hc, embed/head, MTP core) | ≈ 22 GB | ≈ 42 GB |
| routed experts (40 × 384) | ≈ 144 GB | ≈ 280 GB |
| MTP/DSpark experts (3 × 128) | ≈ 3.6 GB | ≈ 7.0 GB |
| Engram at native FP8 (recommended) | ≈ 203 GB | ≈ 203 GB |
| **text-only total** | **≈ 373 GB** | **≈ 532 GB** |
| Engram at 16-bit instead (if the request's premise is honoured literally) | ≈ 563 GB | ≈ 722 GB |
| with vision deferred | — | — |

Against this host: **292 GiB free**, largest install today 162 GB
(`qwen3.8-flash-next_125B_A6B_4Bit`). **Neither width fits, and the 4-bit and
8-bit builds cannot coexist.** Even the 4-bit build's *snapshot* — the
intermediate `.build/<key>-affine-*` the conversion writes before the install —
needs its own ≈ 373 GB on top of the 510 GB source, so a local conversion needs
roughly 1.2 TB of free space at peak, not counting the second width.

This is not a tuning problem; it is a storage and staging problem, and it should
be settled by the operator before any download begins, exactly as
`adding-a-model.md` insists for a 35B model.

### 6.4 Runtime residency — the harder number

TinyTitan's GPU path holds a **resident** `model_weights.bin` mapped and streams
only the routed experts through a bounded cache. Applying that split here:

- resident core 22 GB (4-bit) or 42 GB (8-bit) — plausible on a 24–128 GB Mac;
- routed-expert cache 10–12 GiB today against 144–280 GB of expert bytes — the
  existing streaming engine already contemplates more experts than fit, so this
  is a scale question, not a new mechanism;
- **Engram has no home.** It is not resident-sized, and it is not expert-shaped:
  it is a single 203 GB table read at 14.6 M random rows per token.

So the port needs a **third streaming section** in `.gturbo` (a new band with its
own width slot and per-layer layout, analogous to `packed_experts/` but for
lookup rows), plus a cache sized to the n-gram working set, plus a way to
prefetch it — the four preceding tokens are known one step ahead during decode,
which is a favourable prefetch pattern the existing predictive-prefetch work can
probably be extended to. `docs/gturbo-format.md` currently describes exactly two
regions (`index` + resident payload) and per-layer expert files; adding a third
is a format change and must go through `GTurboBinary` as the single writer, as
the format doc requires.

### 6.5 What "4-bit and 8-bit" should mean in the catalog

Both builds share the same Engram policy, so the `routedExpert` slot carries the
width distinction and `ManifestIdentity.weightBits` reads it, giving the API ids
`deepseek-v4.1-flash_4-Bit` and `deepseek-v4.1-flash_8-Bit`. The manifest's
per-tensor entries must carry the Engram tensors' **own** width so a reader does
not unpack a 203 GB FP8 table as affine — the exact class of silent failure the
format doc calls out.

---

## 7. The eight wiring points

Same eight as `adding-a-model.md`, with what each one costs here.

| # | Where | What changes |
| --- | --- | --- |
| 1 | `tools/prepare_agentworld.py` — `MODELS` | Not this file. A **new** `tools/prepare_dsv41.py` (namespaces differ), with the pinned sha `dba1be0a…` and its own rename table |
| 2 | `tools/install_models.sh` — `CATALOGUE` | Two rows and the preset→served-id `case` |
| 3 | `tools/tinytitan_models.sh` | key/stem/label `case` plus `ENGINES`, `THINKING`, `FAMILY`; unknown-model help; `TINYTITAN_ALL_MODELS` |
| 4 | `tools/server_launcher.sh` | model-key list in the header comment and the unknown-model error |
| 5 | `ModelProfile.swift` | One row per width; expert-cache budget and chunk must be *measured*, not inherited — this geometry matches nothing shipped |
| 6 | `ModelCatalog.swift` — `displayNames` | served id → human name |
| 7 | `tests/` | `ModelProfileTests.shipped` and the table count |
| 8 | ANE prefill sidecar | Likely **skip**: for a model this size the exporter has no graph for the new attention, and the Qwen3.8 precedent already shows the ANE losing where the GPU path attends sparsely (0.72×). Export explicitly to re-measure; never install by default |

Beyond the eight: `ArchInfo.swift` needs a `loadDeepseekV41` branch and a
`RepackModelFamily` case (`deepseekV41`), a new `ModelFamily` case, a new
`TensorSchema` mapping, and a new `Runtime/Family/DeepseekV41Family.swift`.
`ArchInfo`'s `crossCheckProduction*` pattern means the new branch either matches
a shipped geometry exactly or is a runtime question answered *before*
conversion — here there is no shipped sibling, so the cross-check has to be
written fresh from the published config (there is precedent: `loadQwen4Exp`
does exactly this for a first-of-family model).

---

## 8. Verification — building a surrogate, not downloading 510 GB

`adding-a-model.md`'s bar (continuations, golden baseline, receipt, catalog,
first measured row) is the right gate but is unaffordable at the front of this
project: nothing can be installed before the storage question is answered, and a
510 GB snapshot behind every iteration is not a test loop.

The cheap path this tree already supports in spirit — `tools/testdata/`,
`TinyTitanValidation`'s reference kernels, `qwen38_full_forward.py` and
`qwen38_parity.py` — is a **synthetic surrogate**:

1. Generate a tiny checkpoint with the *same tensor names, dtypes and config
   keys* but 4 layers and 8 experts, using the official `inference/model.py` as
   the reference forward. Random weights, real plumbing.
2. Prove: window ring buffer, compressor grouping at ratios 1 and 2,
   cross-layer KV publication order, the indexer's top-k + −1 masking, the
   two-level candidate filter, grouped `wo_a`, sink, `swiglu_limit`,
   Sinkhorn convergence to doubly stochastic, the Engram hash and gate.
3. Only then convert a real width.

Additional gates the standard checklist does not cover and this model needs:

- **Layer-20 boundary.** Layers 21–39 read a KV projected from the final
  *encoder* hidden state; a test that crosses from layer 19 to 21 is the natural
  place for this to be silently wrong.
- **Ratio crossing.** A decode sequence that completes a compression group
  (`end_pos % ratio == 0`) and one that does not.
- **Window boundary.** Sequences shorter than 128 and longer than 128, since the
  ring's "oldest-first" ordering differs between prefill and decode.
- **Engram hash parity** against `encoding/`'s reference for the same token
  stream, including a DEAD (image-span) interruption and a `pad_id` fill.
- **Quantization cross-check.** The `gturbo-format` lesson: compare a `.gturbo`
  install's logits against its own snapshot, so a per-tensor width that was
  written but not read is caught numerically rather than by inspection.

---

## 9. Phased plan

Each phase has an exit condition; none of them is "it answers".

- **Phase 0 — unblock the front door.** Derive `chat_template.jinja` from
  `encoding/` and prove it against the reference's own test cases. Nothing else
  can be installed without it. Small, exacting, and independent of the model.
- **Phase 1 — cheap checks, no download.** A new `prepare_dsv41.py` with a
  `--plan` mode that fetches only `config.json` and the index, classifies every
  tensor into slots, prints the split per width, the bf16 keeps and the output
  size, and refuses on any last dimension that is not group-aligned. Also decide
  and record the FP8/FP4→affine bridge here if Path A was chosen, because it
  determines the runtime work. If Path B was chosen, this phase instead writes
  the checkpoint's own FP8/FP4 blocks through unchanged, and the new decode
  kernels move onto the critical path.
- **Phase 2 — surrogate parity.** §8's synthetic checkpoint through the full
  forward, against the official reference. This is where the real schedule risk
  lives.
- **Phase 3 — runtime attention.** `SharedAttentionRuntime` equivalents: per-
  layer windows, four shared compressed caches, indexer publication order, the
  candidate filter, and a third streaming band for the caches.
- **Phase 4 — Engram.** New `.gturbo` band, the tokenizer-derived constants
  sidecar, the lookup cache, and its prefetch.
- **Phase 5 — a real width, storage first.** Operator decision on ≥ 1.2 TB of
  staging space, then `install_models.sh <key>` and `<key>-8bit`, snapshots
  deleted after each, one width at a time.
- **Phase 6 — optional fidelity.** Block-FP8 and FP4 E2M1 kernels, so the
  routed experts stop round-tripping through BF16.
- **Deferred — vision.** Per the decision in §3.5.

---

## 10. Deviations to state in user-facing docs

- **No 16-bit source.** The conversion master is FP8/FP4; "16-bit" is a
  reconstruction. State it wherever "4-bit and 8-bit, converted from 16-bit"
  would otherwise be claimed.
- **Engram is not 4-bit or 8-bit.** It stays at the checkpoint's own FP8, so
  neither build is uniformly k-bit, and the manifest's per-tensor widths are the
  only truth.
- **An 8-bit build is larger than the published checkpoint** (≈ 532 GB vs
  510 GB) because affine group 64 is less efficient than the FP4 experts it
  replaces. This is a real deviation from "8-bit is the more faithful build".
- **Chat template is ours, not the model's.** This release ships none, so the
  template is a TinyTitan artifact and must be versioned and tested accordingly.
- **No `generation_config.json`**; sampling comes from the card (temperature
  1.0, top_p 0.95) and is a documented choice, not the checkpoint's.
- **Presence penalty 0.0 only**, as everywhere in this runtime.
- **Thinking levels map onto `reasoning_effort` 1–100** with aliases
  low→50 / high→75 / max→100; any lossy mapping is stated.
- **`bias_vl` is unused in a text-only build**; which bias the reference applies
  is an open unknown (§12), so the choice is a recorded deviation.
- **Vision is excluded**, and the image-span/DEAD-token coupling is deferred
  rather than absent.

---

## 11. Open questions for the owner

1. **Path A or Path B (§6.0).** Does "convert but do not change the quants"
   mean preserve the checkpoint's FP8/FP4 format (one install, ≈ 510 GB, two new
   decode kernels), or re-quantize into the affine 4-bit/8-bit pair the rest of
   the catalog uses (≈ 373 / 532 GB, no new kernels, lossy round-trip)? The
   document recommends Path B first for verifiability; the pair is lost if so.
2. **Storage.** Neither width fits in 292 GiB free, and peak conversion needs
   ≈ 1.2 TB. Expand storage, convert on a different host, or descope?
3. **Which width first** if spacing forces a choice. 4-bit is ≈ 373 GB against
   8-bit's ≈ 532 GB. (Path B has no widths to choose between.)
4. **Engram precision.** The recommendation is native FP8 (203 GB). Halving it
   to 105 GB with 4-bit affine is possible and unmeasured; the owner's call.
5. **Is a ≥ 1 TFLOP-scale model the intended target at all** on 24–128 GB
   machines, given that this model's *resident* core plus Engram is already
   beyond the smaller end even with perfect expert streaming?

---

## 12. Open unknowns (not to be guessed at implementation time)

- **The tech report is unreadable**: `DeepSeek_V41_Tech_Report.pdf` is a
  Git-LFS pointer (`sha256 ba68e2e4…`, 1,809,802 bytes). Anything only in it —
  including any reconciliation of 748 B vs 763.2 B — is unknown.
- **`bias_vl` semantics**: when the vision-gate bias is applied, and whether a
  text-only forward should use it, is not stated in anything read.
- **"SWA Bounded Replay"** appears only in card prose; no reference code.
- **The confidence-scheduled verification loop** for DSpark is not in the repo;
  only the forward path is.
- **`tie2eid` / `tid2eid`**: checkpoint name components special-cased in
  `convert.py` that do not appear in `inference/model.py`.
- **`dspark_noise_token_id` 128799**'s token string is not identified.
- **`Full`/`Reindex`/`Reuse`** naming is prose; the mapping in §3.2 is inferred
  from the source-layer lists.
- **No hardware requirement is stated** anywhere: no minimum memory, no GPU
  count, no vLLM/SGLang version. The only quantity is tensor-parallel examples
  (`MP=8`, `MP=4` as an override) for a CUDA-only reference stack.
- **Community quantizations exist** (many FP8 mirrors, NVFP4 from NVIDIA
  ModelOpt, EXL3/GPTQ/GGUF/MLX 2–4 bit variants, and a mixed 4/8-bit MLX
  checkpoint) — but none is an official MLX release, and this document takes no
  position on borrowing from them, consistent with the Qwen3.8-Flash-Next
  record's "wait for an official release" decision.

---

## Checklist

Modelled on `adding-a-model.md`, with every box unticked and the blockers named.

- [ ] Chat template derived from `encoding/` and proven against its tests —
      **blocker for every other item**
- [ ] Storage and staging settled (≥ 1.2 TB peak, or a different host)
- [ ] **Path A or Path B decided (§6.0)** — decide before Phase 1, because it
      determines whether Phase 6 (decode kernels) is the critical path or is
      absent entirely
- [ ] Gating, pinned sha, geometry, rope block, tie-embeddings and EOS ids read
      from the source — **done, §1**
- [ ] `--plan` classifies every tensor, no last dimension fails group alignment
- [ ] `ArchInfo.loadDeepseekV41` + `RepackModelFamily.deepseekV41` + a
      `ModelFamily` case + `TensorSchema` mapping
- [ ] `SharedAttentionRuntime` equivalent: per-layer windows, shared compressed
      caches, publication order, candidate filter
- [ ] A third `.gturbo` band for Engram plus its constants sidecar
- [ ] The eight wiring points
- [ ] Surrogate parity against `inference/model.py`, including the layer-20 and
      ratio boundaries
- [ ] Conversion and install, one width at a time, snapshots deleted after
- [ ] Continuations, golden target, receipt, catalog, launcher keys
- [ ] First measured row (TTFT, decode) with machine and commit stated
- [ ] README, wiki pages, tracker, roadmap — deviations and status stated
- [ ] Vision: deferred by decision, recorded as such
