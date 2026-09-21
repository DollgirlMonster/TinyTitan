# Qwen3.8-Flash-Next 4-bit on the 24 GiB M3: what is left, and in what order

Written 2026-09-21, after the tuning round that closed the knob space
(`benchmark/internal-speeds/v2-qwen38-4bit-telemetry.txt`, Levers 1-6). **Status:
plan. No code has been written for anything below.** Every claim is either a
measurement from this session or a labelled prediction.

The short version: kernel tuning is closed, more cache is closed, the page-cache
trade is closed by decision, and the one measurement that does not fit the
existing model says the next work is on the **wait**, not on bytes or kernels.

## 1. Closed — do not re-open without a new mechanism

| avenue | how it was closed |
| --- | --- |
| Attention kernel tuning | `docs/qwen38-decode-20tps-concept.md`: `attn_norm_qkv` runs at 26.2 GB/s against 100 GB/s peak because 48 dependent small GEMVs cannot be fused without changing the dependency chain; three attempts measured and reverted ("do not re-open it as a kernel-tuning problem") |
| CPU expert co-execution | `docs/cpu-coexecution-plan.md`: 8 threads of real dequant work raised GPU-busy 44.9% and cut throughput 22.6%; no split ratio wins |
| ANE offload | Same doc: unreachable (Core ML only, no forced placement, per-token routing not expressible) |
| More expert cache / more RAM | This session, 3 paired rounds: 96 slots gives hit 0.757 -> 0.827 and 29% fewer expert bytes, and is **15% slower** (4.96 -> 4.07 tok/s) with exposed wait rising 81 -> 135 ms. Also excluded by the standing rule that the RAM budget must stay enforced |
| The page-cache trade (`BOUNDED_IO=0`) | Rejected by decision: it is worth +4-5% decode but makes the footprint undeclared |
| Knob families (prefetch quality, retention, I/O sync/submission/advice, parallel I/O) | Levers 1-6 of the telemetry file: shipped defaults are the measured optimum or inside noise |
| MTP, chunk size, QSA trio, fused head, compression, weight reshaping, command-buffer consolidation | Recorded closed in the respective docs |

## 2. The one number that does not fit, and it points at the wait

The 2026-09-05 concept doc models decode as `bytes / 3.6 GB/s`, giving a 12.3
tok/s ceiling at the shipped geometry, and lists as a falsifier "exposed expert
I/O measuring well under 100 ms/token at 96 slots". Neither holds here:

| shipped 64 slots, prefetch 1 | 96 slots, prefetch 1 |
| ---: | ---: |
| 4.52-5.00 tok/s | 4.07-4.14 tok/s |
| hit 0.757, 315 MiB/token | hit **0.827**, **225 MiB/token** |
| `wait_ms` 79-85 | `wait_ms` **134-139** |
| `io_ms` 86-99 | `io_ms` **68-69** |
| `io_hidden_pct` 13.8-15.5 | `io_hidden_pct` **32-34** |
| `io_host_waits` 9,064 | **7,425** |
| `cache_plan_ms` 2.91 | 4.49 |

Fewer bytes, fewer host waits, a third of the wait hidden — and the token gets
half again as slow, because each wait is longer. `bytes / bandwidth` cannot
explain that. The measured decode split says where the time sits: the largest
decode gap is `moe_phase1_hit -> moe_phase1_miss_fixup_phase2` at **110.2 ms per
token** (against ~130 ms of total decode GPU busy), so essentially all of the
exposed wait is that one hand-off inside the routed-MoE phase.

Three hypotheses, each with the run that separates it (all ~85 s per arm, paired
against the shipped arm):

1. **Resident/ring budget competition.** The prefetch ring's slot count is
   `top-M x ahead` inside the same budget; a larger resident set changes what
   the ring can hold or how often an adopted read is still in flight
   (`io_hidden_pct` tripling while `wait` rises is the signature). Checks:
   96 slots with `PREDICTIVE_PREFETCH=0`; 80 slots; `TINYTITAN_PREFETCH_TRACE=1`
   on both sizes.
2. **Slot-search and lease cost scaling with resident slots.** `cache_plan_ms`
   rose 2.91 -> 4.49, but that is 1.6 ms of a 54 ms regression, so this is at
   most a contributor. Check: 80/128 slots to fit the scaling.
3. **Wired-memory pressure.** 12 GiB wired against 8 GiB. Weakened already: swap
   held 3.3-3.4 GB in both arms and did not move. Check: the same A/B with the
   cache wired off (`KEEP_WIRED=0`), which changes only the wiring.

Order matters: run (1) first, because if the ring is the cause the fix is the
adaptive resident/ring split already proposed as tracker Items 11-12, and if it
is not, the only remaining route is section 3.

## 3. The only route with real headroom that fits the rules: read fewer experts

At the shipped hit rate and 3.6 GB/s, the concept doc's arithmetic puts 20 tok/s
behind a 86.5% hit rate (route A, needs RAM we cannot spend) or a 7.2 GB/s
device (route B, not this machine). The third route is arithmetic that works
here today: **dropping the two lowest-weighted of the ten experts cuts expert
traffic 20%; six of ten cuts it 40%**, which puts the floor inside the current
bandwidth and hit rate.

This is not a knob. It needs:

1. A routing hook (the expert count comes from `config.topKExperts`, with no
   override today) plus weight renormalisation, behind an env flag.
2. A quality gate, because it changes the output by construction. The repo has
   the pieces: the golden text gate, `benchmark/quant_perplexity_ab.py`, and the
   `cpu35ppl` path for a reference NLL.
3. An honest report of the trade: decode and expert bytes per arm, plus the
   quality delta, so the choice is the user's rather than a silent default.

Prediction to falsify: at 40% fewer expert bytes the I/O term falls by ~40 ms of
the 110 ms MoE gap, so ~+1.3-1.8 tok/s at unchanged GPU work. If it does not,
the wait is not proportional to bytes — which is exactly what section 2 already
suggests, and would make this route smaller than the arithmetic claims.

## 4. Method (non-negotiable, learned the hard way)

- Interleave arms, pair them within a round, and carry a shipped arm in every
  batch: this machine moved 4.37-5.00 tok/s on the *same* configuration within
  one session, which is wider than most of the effects above.
- Quote counters (`expert_read_mib`, `wait_ms`, `io_hidden_pct`, `cache_plan_ms`,
  gap lines) next to wall clock. Wall clock alone has a ±15% spread here.
- Two paired rounds minimum for a direction, more for a magnitude, and state the
  round-to-round values rather than a mean alone.
- Any arm that changes bytes gets a quality gate before it is called a win.

## 5. First three things I would do

1. (Free) Mine the existing 64/96-slot logs for the per-layer gap distribution
   and the prefetch ring's issued/adopted counts at both sizes — the data is
   already on disk in `/tmp/qwen38-cache2-*.log`.
2. (~15 min) The hypothesis-1 matrix: 96 slots with prefetch off, 96 with
   `KEEP_WIRED=0`, 80 slots, each paired against shipped.
3. (~30 min, only if 2 points at the ring) Prototype the adaptive resident/ring
   split as an env-gated experiment, and measure it against the shipped arm
   before any default changes.

Anything that changes what is read (section 3) is a product decision and should
come back to the user before implementation.
