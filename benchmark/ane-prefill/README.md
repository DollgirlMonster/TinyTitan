# ANE prefill: off vs on

One record per sweep, measured with `benchmark/ane_prefill_ab_matrix.py`. The
question it answers is narrow and worth asking separately from
[internal speeds](../internal-speeds/README.md): **for each installed model, how
much does routing the full-attention prefill block to the Neural Engine save?**

```bash
python3 benchmark/ane_prefill_ab_matrix.py \
  --models qwen3.5_2B_4Bit qwen3.5_4B_4Bit qwen-agentworld_35B_A3B_4Bit \
  --pairs 1 --label v5.6 --record
```

The record is written **after every model**, so a run that is held or
interrupted keeps the rows it already earned. Resume it with the same command
plus `--skip-done`, which skips the models already stored (a model whose run
*failed* is not counted as done — a refusal stays re-attemptable).

## What it measures

One variable: `TINYTITAN_PREFILL_ANE`. Each model runs a discarded warm-up per
arm — the first ANE run pays the Core ML compile, which on AgentWorld 4-bit was
~68 s against an 86 s prefill — and then interleaved `off, on, on, off` blocks,
so thermal drift and page-cache state land on both arms rather than on whichever
ran second. The metric is **prefill seconds from the CLI's own footer**, on a
fixed ~6,000-token prompt, `--prefill-chunk 4096`, greedy, one new token.

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
2. the configured prefill chunk is exactly **4,096** — the sidecar is a fixed
   4,096-token program. The dense Qwen 3.5 family is on 4,096 by default for
   this reason; a family left on 128 can never reach the ANE at all;
3. the chunk is **full**, or a continuation of a long prompt. A short prompt is
   one partial chunk and deliberately stays on the GPU: padding it to 4,096
   costs ~2 s of ANE work against under a second of GPU work.

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
