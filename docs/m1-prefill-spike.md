# Prefill on an M1 Max: what the spikes measured

Qwen3.8-Flash-Next 125B-A6B 4-bit on an M1 Max (32-core GPU, 64 GB), macOS 27.0,
model on an external Thunderbolt NVMe (`Device Location: External`, PCI-Express).
Every Qwen3.8 verdict elsewhere in `docs/` was measured on a 24 GiB base M3 with an
internal SSD; this is the first record from an M1. Driver: `tools/m1_spike.sh`
(7,879-token prompt, greedy, seed 1, chunk 4096, arms interleaved).

## Spike 1 (commit 85e104a, two rounds)

| arm | prefill s (r1, r2) | vs base | note |
| --- | --- | --- | --- |
| base | 199.23, 202.44 | -- | **39 tok/s** |
| s128 (128 expert slots) | 209.42, 194.46 | +0.6% | noise |
| s256 (256 slots, ~34 GiB) | 211.58, 197.34 | +1.8% | swapped 8 GB, 2x sys time |
| nobound (`TINYTITAN_BOUNDED_IO=0`) | 199.91, 199.01 | -0.7% | noise |
| s256nobound | 217.60, 214.86 | +7.7% | decode collapsed (0.1 tok/s) |
| c2048 (half chunk) | 221.93, 234.36 | +13.6% | ~13 s per extra chunk |

Base, GPU time by role (r1 / r2):

| role | ms | share of GPU |
| --- | ---: | ---: |
| `prefill_attn_router` (12 full-attention layers x 2 chunks) | 59,953 / 59,821 | 42% |
| `prefill_gdn_router` (36 GDN layers x 2) | 31,665 / 31,717 | 22% |
| `prefill_routed_tile` | 29,845 / 31,181 | 21% |
| `prefill_shared_expert` | 12,938 / 12,747 | 9% |
| `prefill_qsa_index` | 6,212 / 6,208 | 4% |
| GPU busy of span | 141,484 of 184,539 / 142,292 of 186,680 | 77% / 76% |

Read: expert cache and page cache do nothing for prefill here (each chunk touches
nearly every expert), and prefill is mostly GPU compute. The chunk-count cost is
real: going 4096 -> 2048 added ~8 s of GPU and ~19 s of non-GPU time.

## Found in the code, measured by spike 2

- **One compute encoder per token.** The shared-expert scalar gate (and its
  sigmoid) runs one GEMV plus one elementwise dispatch per token, each in its own
  encoder: 8,192 encoders per layer-chunk. The per-token GEMV fallback for a
  q-family projection (attention `q_proj`, GDN `in_proj_qkv`) and for
  bf16-promoted projections does the same. `TINYTITAN_PREFILL_COALESCE=1` keeps
  every kernel, argument and grid and puts a loop's dispatches in one encoder
  (`GEMVRows`); `GEMVRowsTests` requires the result to be byte-identical.
- **Which projection path an M1 takes was never logged.** The Metal 4 tensor-op
  QMM (`MPPPrefillInt4QMM`) is optional; when it does not compile, `.q` falls to
  one GEMV per token. With `TINYTITAN_KERNEL_STATS` the runner now prints a
  `prefill paths:` line naming the path per family and the MPP state.
- **`TINYTITAN_PREFILL_Q_QMM=1`** serves `.q` with the batched QMM instead. It sums
  in a different order, so it can change the output and needs a quality check
  (`benchmark/quant_perplexity_ab.py`) before it could become a default.
- **`TINYTITAN_PREFILL_SPLIT=1`** (diagnostic) commits and times each stage of a
  prefill layer as `prefill_split_*` roles: `hc_in`, `attn_qkv_proj`,
  `attn_rope_kv`, `attn_core`, `attn_o_proj`, `gdn_in_proj`, `gdn_scan`,
  `gdn_out_proj`, `hc_out`. The waits serialize stages; read the roles, not
  the wall clock.
- Two existing switches, off by default pending proof of identical output, are
  spike arms: `TINYTITAN_HC_FUSED=1` and `TINYTITAN_QSA_GPU_SELECT=1` (QSA key
  selection otherwise runs on the CPU between the indexer and attention).

## Not pursued, with the reason

- **Neural Engine attention.** Measured on the M3 for this model
  (`benchmark/ane-prefill/ane-correctness-v5.6-ane-38-4bit.json`): 439 s against
  184 s on the GPU. On an M1 Max the GPU is larger and the ANE older, so it would
  lose by more.
- **Bigger expert cache for prefill.** Spike 1 above.
