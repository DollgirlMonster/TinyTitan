# Verdict: speculation, placement and compression for Qwen3.8 4-bit on this M3

Written 2026-09-21 after testing the three concepts against the *installed*
configuration. The proposal they came from was written for an FP8 install on an
8-16 GB device; this machine runs the 4-bit affine install, and several of its
premises do not hold here. Everything below is measured on this build unless
labelled otherwise.

## Premise corrections

| proposal assumes | this install |
| --- | --- |
| FP8, ~6B activated FP8 parameters | **4-bit affine**, group 64, BF16 scales/biases |
| ~2.36 GB routed experts | **63 GB** packed experts (512 experts x 48 layers x 2.77 MB) |
| 51 GB n-gram table | **102.4 GB** (`ngram_table.bin`) |
| 8-16 GB device, cache absorbs 15-35% of expert reads | 24 GiB device; measured **75.7%** hit rate at the shipped 64 slots |
| pin the dense backbone in RAM | **already the design**: `model_weights.bin` is mapped resident; only `packed_experts` stream |

## Concept 1 — MTP speculation: unreachable by default, and it loses when forced

**It cannot engage on the shipped sampling configuration.** The decode loop picks
the draft producer only when the request is pure greedy
(`RawCompletion.swift`: `temperature == 0 && presencePenalty == 0 &&
repetitionPenalty == 1`). Since the 2026-09-21 sampling change, every
thinking-off Qwen3.8 request resolves to the instruct row with **presence penalty
1.5**, so `isPureGreedy` is false and the draft path is skipped. Evidence: with
the sidecar attached (`mtp=on:384MiB`) and shipped sampling, both arms of a
256-token A/B ran **256 scalar passes** (`sample count=256`,
`head_logits count=255`) — the head was loaded and never used.

Forced reachable with `presence_penalty: 0` on **both** arms, `--ram-budget 8G`,
256 tokens, temperature 0, two paired rounds:

| round | scalar | MTP | delta |
| ---: | ---: | ---: | ---: |
| 1 | 4.611 | 3.121 | -32.3% |
| 2 | 4.612 | 2.448 | -46.9% |

The verify path was genuinely running: `verify_routed_pair` 7,872 dispatches,
`verify_head` 164 passes, i.e. ~1.56 emitted tokens per pass.

**And the output was not identical.** Two pure-greedy arms (same target profile
echo, same sampling echo, only the draft attached) diverged at character 553:
scalar "*...safety, and modern UI/UX patterns*" against MTP "*...safety, and ease
of use within the Apple ecosystem*", 1,254 against 1,258 characters. The target's
profile line is identical in both arms; the only extra profile line is the
sidecar's own. So this is the verify path, not a configuration difference.

The repo's own Track B3 gate requires **byte-identical greedy output and >=10%
median gain** (`benchmark/tinytitan_mtp_b3_qualification.py`). This measurement
fails both halves. I did not run the B3 harness itself; the A/B above is the
evidence. Prior art agrees on the loss and explains it: the 2026-09-18
measurement put a pair pass at 2.238x a scalar token for 1.869 emitted tokens
(86.9-92.6% acceptance), concluding "the lever is the verify path, not
acceptance" — and the scalar arm has since gained prefetch depth 1, so the same
per-pass cost now reads worse.

The n-gram/prompt-lookup half is **not implemented**: the 102 GB `ngram_table.bin`
is the model's own PLE gather (deterministic lookups from token ids), not a draft
source, and adding a draft source does not change the verify-side cost that is
the recorded cause.

**Cross-feature finding:** the presence-penalty change silently disabled the
speculative path for every default Qwen3.8 chat request, and nothing caught it
because the two features were never exercised together. Whoever revisits MTP
should start with the B3 harness at `presence_penalty: 0`, and must explain the
output mismatch above before quoting any speed number.

## Concept 2 — placement rebuild: half of it is already done, and the rest is low-value here

The dense backbone, embeddings and head are already **resident** (mapped, not
streamed); only the 63 GB expert corpus is streamed. The remaining ideas (hot/cold
expert pin file, co-activation-sorted disk layout, draft-driven prefetch) face a
machine where the SSD is **not saturated** — 109 GiB of device traffic per
256-token run, ~1.4-2 GB/s average against ~3.6 GB/s — and where the cache is at
its measured optimum (64 slots; 96 and 128 are 12% and 50% slower, telemetry
Lever 3 and 7). The binding constraint here is the wait, not bandwidth, so a
layout permutation has little to win. It would need an offline routing-frequency
profile per workload plus a 63 GB repack; worth doing only if the wait analysis
ever shows bandwidth-bound behaviour.

## Concept 3 — lossless compression: ~10% ceiling, and 0% with a codec fast enough for the hot path

Measured on 128 MiB samples of the real files (ratio = compressed / original):

| sample | lz4 -1 | zstd -1 | zstd -3 | zstd -12 | xz -6 |
| --- | ---: | ---: | ---: | ---: | ---: |
| `packed_experts/layer_00.bin` | 100.00% | 90.87% | 89.76% | **89.56%** | 89.16% |
| same, even/odd byte planes | 95.96% | 89.19% | 88.83% | 89.08% | 89.09% |
| `ngram_table.bin` | 100.00% | 76.91% | 76.91% | 76.26% | **71.12%** |

The expert bytes are 4-bit affine — already dense — so ~10% is the ceiling, and
the de-interleaved plane split only improves it by ~1 point. **lz4, the only
codec fast enough to sit in a ~3.6 GB/s read path, achieves 0%.** zstd -12 costs
single-digit MB/s per core, orders of magnitude below the device. The n-gram
table does compress 23-29%, but it carries ~5 KB per token, so that is disk
occupancy rather than throughput. Roughly 6 GB of disk saved on 63 GB, paid for
with a decompression core per unit of read bandwidth, is a bad trade for a decode
path that is wait-bound rather than bandwidth-bound.

## Summary

| concept | measured outcome |
| --- | --- |
| MTP speculation | not reachable on shipped sampling (presence 1.5); forced reachable it is 32-47% slower **and** changes greedy output |
| n-gram drafting | not implemented; does not address the recorded verify-path cost |
| placement rebuild | dense backbone already resident; SSD unsaturated; cache at optimum -> low value here |
| lossless compression | ~10% limit on experts, 0% with a fast codec; n-gram table 23-29% for negligible traffic |
