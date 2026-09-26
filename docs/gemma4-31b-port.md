# Gemma 4 31B (dense): port research

Status: **research only; nothing is wired.** Written 2026-09-26 from the
`transformers` source (`src/transformers/models/gemma4/`, `main`) and this
repository's own history. The checkpoint's `config.json` was *not* read --
huggingface.co is outside this session's network policy -- so every 31B number
below marked *unverified* has to be read from the source before anything is
converted (`docs/adding-a-model.md` §0).

## Why this is not a greenfield port

This tree served **Gemma 4 26B-A4B** before commit 19aafd8 ("Production
hardening: audit fixes, Qwen-only") removed the family: the arch config, the
Gemma tool-call parser and schema, the repack sources and the FFN sandwich.
The 26B baseline it carried, checked then against an installed manifest:

| field | 26B-A4B |
| --- | --- |
| hidden / layers | 2816 / 30 (every 6th full attention) |
| heads / KV heads (sliding / full) | 16 / 8 / 2 |
| head dim (sliding / full) | 256 / 512 |
| sliding window | 1024 |
| rope theta (sliding / full), partial factor | 10k / 1M, 0.25 |
| experts / top-k / expert width | 128 / 8 / 704 |
| vocab, tied, softcap | 262,144, tied, 30.0 |
| K = V on full layers, GELU-tanh, sqrt(hidden) embed scale | yes |

The 31B shares the attention, norm and embedding design and replaces the
two-branch FFN (dense MLP + routed experts) with the dense MLP alone.

## What the current runtime still has

- K = V on full-attention layers (`attentionKEqV`), decode and prefill.
- Embedding scaled by sqrt(hidden), final logit softcap.
- Gemma's RoPE convention (`ropeNeoxSubdim: false`): full layers rotate
  `fullHeadDim * partialRotaryFactor / 2` pairs, sliding layers all of them;
  the prefill epilogue carries it, and the V-norm epilogue with it.
- Sliding-window layers and their KV ring; per-layer head dim and KV heads.
- GELU kernels (the shared-expert and prefill paths); `silu` is a flag.
- A GPU dense-FFN prefill path (`encodeDenseFFNPrefill`, used by Qwen 3.5).

## What has to be (re)built

1. **Family and schema.** A `gemma4` family (manifest `arch.family`) and a
   `TensorSchema` for `model.language_model.layers.N.*`; the vision and audio
   towers are never repacked (text-only, as for Qwen3.8).
2. **The FFN sandwich, dense form.** Gemma's `post_attention_layernorm`
   normalises the *attention output* before the residual add (Qwen's same-named
   tensor is the pre-FFN norm), then `pre_feedforward_layernorm` -> MLP ->
   `post_feedforward_layernorm` -> residual, then `hidden *= layer_scalar`. The
   removed runner implemented the two-branch version with all of these
   (`git show 19aafd8^:sources/NVMAI/Runtime/Inference/RealForwardRunner.swift`,
   the `ffnSandwichNorms` sites); the dense form drops branch 2.
3. **GELU-tanh dense MLP** (`act(gate(x)) * up(x)` then down) in decode and
   prefill, and `ManifestReader` accepting `gelu_pytorch_tanh` for this family
   (it refuses anything but `silu` today).
4. **V norm without scale** on non-shared layers, and Q/K norms per head:
   check the surviving epilogue against `Gemma4TextAttention` rather than
   assume.
5. **Attention scale 1.0** (`self.scaling = 1.0`; the Q/K norms carry it).
6. **Converter.** A dense Gemma converter modelled on `tools/prepare_qwen35.py`
   / `tools/repack_dense.sh`, mapping the `model.language_model.*` namespace.
7. **Tool calls.** Gemma 4 emits
   `<|tool_call>call:name{arg:<|"|>value<|"|>}<tool_call|>`. Restore
   `GemmaToolCallParser` and `GemmaToolSchema` from 19aafd8^ and select the
   dialect by family; diff the checkpoint's `chat_template.jinja` against what
   that parser expects before trusting it.
8. The eight wiring points and the §4 verification bar of
   `docs/adding-a-model.md`, and the scope line in `AGENTS.md`, which says
   Qwen-family only.

## Features the config decides (read them from the 31B's `config.json`)

`transformers` defines these for every Gemma 4; which ones the 31B turns on is
*unverified*:

- `hidden_size`, `num_hidden_layers`, `num_attention_heads`,
  `num_key_value_heads`, `num_global_key_value_heads`, `head_dim`,
  `global_head_dim`, `sliding_window`, `layer_types`, `rope_parameters`.
- `attention_k_eq_v` (the 26B had it).
- `num_kv_shared_layers`: the last N layers reuse the K/V of the last
  non-shared layer of the same type -- a KV-cache aliasing feature this runtime
  does not have. Expected 0 on the large models; if not, it is new work.
- `hidden_size_per_layer_input` (per-layer embeddings, PLE): the blog calls it
  a feature of the *smaller* models; if the 31B sets it, it is new work (the
  Qwen3.8 PLE block is a different design).
- `use_double_wide_mlp` (only on KV-shared layers), `final_logit_softcapping`,
  `tie_word_embeddings`, `vocab_size`.
- `generation_config.json`: sampling and EOS ids; `chat_template.jinja`:
  thinking markers and the tool-call dialect.

## What to expect on an M1 Max 64 GB (estimates, not measurements)

- 4-bit (g64 affine, ~4.5 bits/weight): ~17-18 GB of weights, 8-bit ~33 GB.
  Both fit in RAM: nothing streams from the SSD, so the external drive that
  bounds Qwen3.8's prefill does not matter here.
- Decode reads every weight per token: at ~300-380 GB/s effective, a ceiling of
  roughly 17-22 tok/s at 4-bit and 9-11 at 8-bit.
- Prefill is compute: ~62 GFLOP per token against ~10 TFLOPS fp16 peak; at the
  40-60% the MPP path reaches, roughly 65-100 tok/s before attention cost.
