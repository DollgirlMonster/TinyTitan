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

## Found in the code, then measured in spike 2

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

## Spike 2 (commit 83b019b, two rounds)

Every arm produced the same output as base, `coalesce` included (it is
bit-identical by construction and `GEMVRowsTests` says so), and so did
`TINYTITAN_HC_FUSED=1` and `TINYTITAN_QSA_GPU_SELECT=1`, which were off only until
that was shown. The M1 compiles the Metal 4 tensor-op QMM: every attention and
GDN projection already takes it (`prefill paths: mpp_int4=available attn_q=mpp/4b
gdn_in=mpp/4b kv=mpp/4b o=mpp/4b`), so the per-token q GEMV never runs here and
`qqmm` is a second base.

| arm | prefill s (r1, r2) | GPU busy s (r1, r2) |
| --- | --- | --- |
| base | 197.7, 205.7 | 141.8, 146.3 |
| coalesce | 242.6, 206.3 | 183.9, 145.6 |
| qqmm (= base) | 222.7, 199.5 | 170.7, 145.5 |
| hcfused | 213.2, 209.2 | 158.6, 148.1 |
| qsagpu | 199.3, 210.8 | 145.6, 142.6 |
| combo | 195.0, 194.9 | 141.1, 141.8 |

The spread is the clock, not the arms: an unchanged binary ran 12.6% apart, and
in the slow runs every role -- including ones the flag never touches -- slowed
together. `powermetrics` during prefill showed 93-98% GPU residency at
1.10-1.22 GHz average, 23-57% of the time on the 972 MHz step. Nothing here is
separable from that; `m1_spike.sh --gpu-clock` now reports busy x clock
(Gcycles) so the next comparison is.

Where the GPU time goes (`TINYTITAN_PREFILL_SPLIT=1`, mean of two rounds, s):

| stage | s | share | note |
| --- | ---: | ---: | --- |
| `attn_core` (QSA sparse attention, 12 layers x 2 chunks) | 54.2 | 38% | one kernel, ~2.3 s per layer-chunk |
| `routed_tile` | 30.6 | 21% | one-output-per-thread expert GEMV |
| `hc_in` + `hc_out` (hyper-connections) | 17.5 | 12% | projections on the scalar `prefillQMM`, not MPP |
| `shared_expert` | 12.9 | 9% | unchanged by coalescing: the MLP, not dispatch |
| routers (`attn_router` + `gdn_router` remainders) | 7.2 | 5% | |
| `gdn_in_proj` + `gdn_out_proj` | 8.4 | 6% | already MPP |
| `gdn_scan` (conv, norms, delta rule, gated norm) | 5.1 | 4% | the sequential recurrence is *not* a hotspot |
| `qsa_index` | 4.3 | 3% | |
| `attn_qkv_proj` + `attn_o_proj` + `attn_rope_kv` | 2.9 | 2% | already MPP |

Outside the GPU: ~55-60 s of each ~200 s prefill, of which ~15 s precedes the
first kernel. `TURBO_FIELDFARE_PHASES` (now on stderr, and on in every spike
arm) splits the host side per chunk.
