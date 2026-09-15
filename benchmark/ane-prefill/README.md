# ANE prefill: off vs on

One record per sweep, measured with `benchmark/ane_prefill_ab_matrix.py`. The
question it answers is narrow and worth asking separately from
[internal speeds](../internal-speeds/README.md): **for each installed model, how
much does routing the full-attention prefill block to the Neural Engine save?**

```bash
python3 benchmark/ane_prefill_ab_matrix.py \
  --models qwen3.5_2B_4Bit qwen3.5_4B_4Bit qwen-agentworld_35B_A3B_4Bit \
  --repeats 2 --label v5.6 --record
```

The record is written **after every model**, so a run that is held or
interrupted keeps the rows it already earned. Resume it with the same command
plus `--skip-done`, which skips the models already stored (a model whose run
*failed* is not counted as done — a refusal stays re-attemptable).

## What it measures

One variable: `TINYTITAN_PREFILL_ANE`. Each model runs a discarded warm-up per
arm — the first ANE run pays the Core ML compile, which on AgentWorld 4-bit was
~68 s against an 86 s prefill — and then `--repeats` measured runs per arm
(default 2), alternating so drift lands on both. The metric is **prefill seconds
from the CLI's own footer**, on a fixed prompt, `--prefill-chunk 4096`, greedy,
one new token.

**The prompt is deliberately just over one chunk** (~4,300 tokens, 23,000
characters of the fixed paragraph): the ANE serves only a full 4,096-token
chunk, so a shorter prompt measures two GPU arms and would report "1.0×" as if
it were a finding about the ANE. The sweep says `prompt_too_short` instead. The
prompt is the quadratic term, so shortening it is the main lever on run time —
but ~21,750 characters is the floor.

| Field | What it is |
| --- | --- |
| `off.prefill_seconds_median` | GPU prefill, median of the off arms |
| `on.prefill_seconds_median` | ANE prefill, median of the on arms |
| `on.used_ane` | every on arm ran without the runtime's GPU-fallback line |
| `speedup` | off / on, present **only** when `used_ane` is true |
| `digests` | the greedy response hashes per arm |
| `ane_unavailable` | the ANE cannot serve this model at all, with the reason |

**A speedup is never reported from an arm that fell back.** The runtime prints
`ane-prefill fallback … using the GPU path` when a chunk is not eligible; that
arm's seconds are a GPU time, and quoting a ratio from it is how a model that
never touched the ANE comes to look "tested".

## What the ANE covers, and when it engages

The ANE runs the **full-attention block** of a chunk, for the covered layers
only. GDN/linear-attention layers, the MoE and its expert streaming, the KV
cache, and all of decode stay on the GPU. Two consequences worth holding onto:

- the win scales with the **full-attention share** of the model. The 35B-A3B
  offloads 10 of 40 layers; the dense 2B offloads 6 of 24, so its ratio is
  smaller for the same attention speed-up;
- it grows with **prompt length**, because the offloaded share is the quadratic
  one.

Three conditions must hold or the chunk silently stays on the GPU:

1. a sidecar exists for the model and its recorded geometry matches (see below);
2. the configured prefill chunk **equals the sidecar's chunk** — the graph's
   shapes are fixed by it, so a nearer width cannot be fed. The dense Qwen 3.5
   family is on 4,096 by default; a family left on 128 can never reach the ANE
   at all. The harness reports `prompt_too_short` rather than a misleading
   "1.0×" when the prompt does not reach one full chunk;
3. the chunk is **full**, or a continuation of a long prompt. A prompt under one
   chunk has no shape to run and deliberately stays on the GPU.

## The band table

Which width to export is a function of the prompt, so a model can carry several
(see `tools/ane_sidecars.sh`, and the runbook's wiring point 9):

| Prompt | Sidecar to have | Measured |
| --- | --- | --- |
| under 1,024 tokens | none — the GPU wins | "hello" (5 tokens): GPU 0.11 s vs a padded chunk costing tens of seconds |
| 1,024 – 4,095 | **`ane_prefill-1024`** (this is what makes the band reachable) | dense 2B, ~2,500 tokens: GPU 23.33 s → ANE 17.88 s, **1.30×** |
| 4,096 – 16,384 | `ane_prefill` (4,096) | `v5.5-ane-matrix-3`, ~4,300 tokens, per model below |
| over 16,384 | a larger `--max-history` (coverage = max history + chunk) | — |

`v5.5-ane-matrix-3` — 23,000-character prompt (4,333 tokens), chunk 4,096,
two measured runs per arm after a discarded warm-up each, on an M3 24 GB:

| Model | ANE off | ANE on | Saved | Ratio |
| --- | ---: | ---: | ---: | ---: |
| qwen3.5 2B 4-bit | 49.8 s | 36.0 s | 13.8 s | 1.38× |
| qwen3.5 2B 8-bit | 104.1 s | 91.6 s | 12.4 s | 1.14× |
| qwen3.5 4B 4-bit | 140.6 s | 102.2 s | 38.5 s | 1.38× |
| qwen3.5 4B 8-bit | 275.6 s | 218.1 s | 57.5 s | 1.26× |
| qwen3.5 9B 4-bit | 210.7 s | 168.2 s | 42.5 s | 1.25× |
| qwen3.5 9B 8-bit | 442.4 s | 392.9 s | 49.5 s | 1.13× |
| AgentWorld 35B-A3B 4-bit | 106.5 s | 63.3 s | 43.2 s | **1.68×** |
| Qwen 3.8 125B-A6B 4-bit | 175.1 s | — | — | no sidecar (sparse indexer) |

Longer prompts move these ratios up: the same dense 2B at 6,027 tokens measured
1.61×, and AgentWorld at 6,027 tokens ~2.05×, because the offloaded share is the
quadratic one. Shorter prompts move them down, and the 8-bit rows are lower than
their 4-bit siblings at the same length because the non-attention prefill the
ANE never touches is heavier there.

The ANE's saving is a roughly **fixed amount of attention work**: on the dense
2B it was 30.0 s at 4-bit and 30.2 s at 8-bit, so the *ratio* falls as the
non-attention prefill (which the ANE never touches) grows.

None of this is a switch. `TINYTITAN_PREFILL_ANE` is on by default for every
GPU-path model; what varies is whether there is a sidecar the chunk can match.

## Which families can carry a sidecar

`tools/export_ane_prefill.py` reads the attention geometry from the model's own
manifest, so support is a property of the graph, not a list:

| Family | Installs | Sidecar | Why |
| --- | --- | --- | --- |
| `qwen36` | AgentWorld 35B-A3B | yes | the geometry the graph was written for |
| `qwen3_5_dense` | Qwen 3.5 2B / 4B / 9B | yes | same attention block, read from the manifest |
| `qwen38flash`, `qwen38flash_mtp` | Qwen 3.8 125B-A6B (+MTP) | **no** | structural — see below |

Qwen 3.8's exclusion is a correctness boundary, not a missing feature: its
full-attention layers select keys with a **QSA sparse indexer**, and dense
attention matches that selection only through `keptBlocks × compressRatio +
(compressRatio − 1)` = **2,051 visible keys** (`QSAExactness`). Past that, dense
attention attends to keys the model would have dropped, silently and plausibly.
The ANE pays only on long prompts, which is exactly where dense is wrong — so
the exporter refuses the family and the runtime keeps it on the GPU.

A sidecar also records the geometry it was built for, and the runtime refuses
one that disagrees with the model (family, hidden width, head split, chunk,
covered layers). The exporter resolves each tensor's **per-tensor** width rather
than its slot width: the dense installs declare a 4-bit attention slot over
8-bit `k_proj`/`v_proj`.

## Reading a record

A record is valid for one (machine, build, model, prompt) combination. The two
arms are **not** bit-identical by construction — the ANE computes attention in
fp16 with a different reduction order — so the digests are expected to differ;
what must hold is that each arm is internally stable, and that `on.used_ane` is
true. Compare a run only against another run of the same model and prompt.
