# Internal speeds

One record per release, measured with `tools/internal-speeds.py`, so a speed
regression is a diff rather than a feeling. The numbers are TinyTitan's own —
kernel bandwidth, prefill and decode rates, time to first token, and a small
quality proxy on a fixed prompt — measured on the same machine and the same
model the golden baselines use.

```bash
tools/internal-speeds.py --record --label v5.6     # measure and write v5.6.json
tools/internal-speeds.py --record --label v5.6 --baseline benchmark/internal-speeds/v5.5.json
tools/internal-speeds.py --compare benchmark/internal-speeds/v5.5.json \
                                 benchmark/internal-speeds/v5.6.json
```

`--record` compares against the newest previous record **for the same model and
prompt** (or the explicit `--baseline`), prints the diff, and exits non-zero when
a performance metric regressed by more than 10% (`--threshold`). That non-zero
exit is the release gate; see `docs/release-process.md`.

## What is measured

| Field | What it is |
| --- | --- |
| `gpu.qkv_gemv_gbps` | the gated QKV GEMV (the dominant decode kernel), synthetic buffers |
| `gpu.routed_moe_gbps` | the routed-MoE decode kernels at the real shapes |
| `gpu.gdn_inproj_gbps` | the gated-DeltaNet in-projection GEMV |
| `cpu.best_gbps` | int8 affine GEMV on the CPU at its best thread width, with the full table |
| `generation.prefill_tokens_per_second` | prompt tokens / prefill seconds |
| `generation.decode_tokens_per_second` | the CLI's own decode rate |
| `generation.ttft_seconds` | time to first token = prefill seconds (the first token is sampled at the end of prefill) |
| `generation.effective_decode_gbps` | weight bytes × decode tokens / decode seconds — every token re-reads the weights, so this is the model-level bandwidth |
| `ane.prefill_tokens_per_second` | only when the model ships an `ane_prefill` sidecar; otherwise recorded as not applicable, with the model's family and whether the exporter could serve it |
| `quality.*` | the response, its SHA-256, keyword coverage and trigram repetition |

The prompt is fixed — *"difference swift vs c++ in detail"* — and generation is
greedy, so the response is deterministic: if `quality.response_sha256` changes,
the output changed and the comparison says so. Coverage is a proxy, not a grade;
the response text is stored so a human can read the one release where it drops.

## Which model

The default is the dense Qwen 3.5 4B (`models/qwen3.5_4B_4Bit`) because it is
the smallest install that exercises every path, and it is what the release gate
records. Records are per (model, prompt), so other models can be recorded beside
it without becoming its baseline:

```bash
tools/internal-speeds.py --record --label v5.6-4b
tools/internal-speeds.py --record --label v5.6-agentworld \
  --model models/qwen-agentworld_35B_A3B_4Bit
```

**The ANE row needs a qwen36 install and a sidecar.** The sidecar exporter
(`tools/export_ane_prefill.py`) supports the qwen36 family only — its attention
geometry is that family's — so a dense install (2B/4B/9B, `qwen3_5_dense`) can
never show an ANE number, and its record says so. For an installed qwen36 model,
export first and then record:

```bash
~/.venvs/coreml-py311/bin/python tools/export_ane_prefill.py \
  --model models/qwen-agentworld_35B_A3B_4Bit --max-history 12288
tools/internal-speeds.py --record --label v5.6-agentworld \
  --model models/qwen-agentworld_35B_A3B_4Bit
```

The sidecar lives in the model directory (`<model>/ane_prefill/`) and is not in
the manifest, so it does not disturb the install receipt. Never download or
re-install a model to obtain a record — a target with no install is reported as
**not checked**.

## Reading a comparison

A metric moving by a few percent is noise (Metal timing varies run to run).
The gate fires at 10%: a drop in any `*_gbps` or `*_tokens_per_second`, or a
rise in `ttft_seconds`, `decode_seconds` or `total_seconds`. A changed response
hash is printed as a note rather than a failure, because a deliberate numerics
change legitimately changes it.

## Environment

A record is valid for one (machine, build, model) triple, like the golden
baselines. Record on the release machine, name the install in the `model`
field, and never compare a record from one Mac with one from another.
