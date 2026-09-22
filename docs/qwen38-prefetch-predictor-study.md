# Expert-prefetch predictor: what is achievable, and what actually limits it

Round-1 study for the goal "develop a better expert predictor so we get closer to
10 tok/s", 2026-09-22, all runs at `--ram-budget 8G` on the 24 GiB M3. Every
number here is measured; the method is reproducible from the trace facility.

## Method: ground truth instead of inference

`TINYTITAN_PREFETCH_TRACE=<path>` writes one JSON line per (layer, position) with
`experts` (the router's exact selection), `misses`, `resident` (both captured
before that layer's plan), `next_layer_prediction` and `next_weights` (the probe
for the next layer), and `next2_layer_prediction`. Two traces were captured: a
255-token prose decode and a 52-token code decode.

One subtlety had to be resolved before any scoring was meaningful: the recorded
`misses` are **post-adoption** (an expert the ring staged and the plan adopted is
resident by then, so it is not a miss). Scoring a prediction against `misses`
therefore reports ~1% for a predictor that is actually 55% right — the first
offline pass made exactly that mistake. The correct target is the *selection*
set, filtered by the residency the ring sees at issue time. Validated against the
engine's own footer: the simulation reproduces `prefetch_issued_per_token=43.0`
against the measured 42.74 and `prefetch_adopted_per_token=23.7` against 23.04.

## The probe is not the weak link

Selection precision by rank, after dropping experts already resident:

| ordering | P@1 | P@2 | P@3 | P@4 | adopted/token @1 / @2 / @3 |
| --- | ---: | ---: | ---: | ---: | --- |
| **probe (shipped)** | **0.552** | **0.450** | 0.379 | 0.328 | **23.7 / 16.3 / 10.8** |
| probe re-ranked by live per-layer frequency | 0.522 | 0.452 | 0.401 | 0.352 | 22.4 / 16.4 / 11.4 |
| per-layer frequency alone | 0.024 | 0.025 | 0.026 | 0.025 | 1.0 / 1.1 / 1.1 |
| previous token's selection at that layer | 0.000 | 0.000 | 0.000 | 0.000 | 0 / 0 / 0 |
| previous token's misses at that layer | 0.000 | 0.000 | 0.000 | 0.000 | 0 / 0 / 0 |
| probe then previous token (and the reverse) | 0.552 | 0.450 | 0.379 | 0.328 | 23.7 / 16.3 / 10.8 |

The code-shaped prompt gives the same picture (probe 0.554 / 0.428 / 0.364 /
0.305). Two findings:

- **The shipped probe is the best ordering available from the information on
  hand.** Re-ranking by frequency, by the previous token's routing, by an EMA of
  probe scores, or by unions of those, is neutral or worse. The previous token's
  experts are always already resident, which is why a temporal predictor stages
  nothing at all: the cache has already absorbed that reuse.
- **The probe's ranking is underused.** Ranks 2 and 3 are still 45% and 38%
  precise. Staging two reads per layer would adopt ~40/token instead of 23.7, and
  three would adopt ~51 — the largest measured headroom in the whole decode path.

## Why more staged reads did not pay

The ring staged only one read per layer because it submitted **one
`ExpertLoadOperation` for the whole batch** and assigned that single operation to
every slot it filled; `readyBuffers` adopts a slot only when its operation is
`.completed`, so a slow sibling gates a fast one. That is why the earlier
`PREFETCH_TOP_M=2` arm adopted just 15.8/token while issuing 76.1.

Fix (in this commit, opt-in `TINYTITAN_PREFETCH_PER_EXPERT=1`): submit one
operation per staged expert so readiness is per slot. Two interleaved rounds per
arm, 256-token prose prompt:

| arm | decode (r1 / r2) | vs shipped | issued/token | adopted/token | precision | expert read MiB | wait_ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| shipped (1 slot, batch op) | 4.626 / 4.472 | — | 42.8 | 23.3 | 0.54 | 80,639 | 83.0 |
| 1 slot, per-expert | 4.428 / 4.484 | -2.0% | 42.7 | 22.8 | 0.53 | 80,996 | 86.8 |
| 2 slots, per-expert | 4.498 / 4.300 | -3.3% | 76.2 | **26.0** | 0.34 | 78,812 | 85.4 |
| 3 slots, per-expert | 4.055 / 4.068 | -10.7% | 102.9 | **26.8** | 0.26 | 78,273 | 91.1 |
| *(earlier, for contrast)* 2 slots, batch op | 4.236 / 4.245 | -6.6% | 76.1 | 15.8 | 0.21 | 85,709 | — |

The fix does what it was designed to do: two-slot adoption rises 15.8 -> 26.0
(+65%), device reads fall to *below* the shipped arm, and every arm stays
byte-identical. It still loses throughput, for two reasons that the counters name:

1. **The device is saturated, so speculation taxes demand.** `wait_ms` climbs
   83.0 -> 85.4 -> 91.1 as slots rise, and the ~2.7 extra adopted reads/token
   (≈7 MiB ≈ 2 ms of device time) are outweighed by longer demand queues.
2. **One layer of lookahead is about one loaded read long.** The ring issues at
   layer L for L+1, giving roughly 4.5 ms of headroom; measured cold-device
   per-read latency is 1.2 ms idle but 3.4-6.5 ms with four or more reads
   outstanding, so a good share of staged reads are still in flight when the
   target plan runs. That is also why precision per issued read falls
   (0.54 -> 0.34 -> 0.26) even though the ranking's intrinsic precision does not.

## Conclusion and next step

At one-layer lookahead the shipped configuration is the optimum, and a *better
predictor by itself cannot reach 10 tok/s*: the ranking is already the best of
every candidate testable from the available information, and its unused tail
cannot be cashed in while the device is saturated.

The one predictor-side avenue left is **lookahead length**, not ranking quality:
two layers ahead gives about 9 ms of completion headroom instead of 4.5, which is
the measured difference between a staged read arriving and not. A trace captured
with `TINYTITAN_PROBE2_TRACE=1` scores the engine's two-layer-ahead prediction
against the same ground truth:

| prediction | issued/token | would-adopt/token | P@1 |
| --- | ---: | ---: | ---: |
| L+1 probe (shipped) | 43.0 | 23.7 | **0.552** |
| L+2 probe | 42.9 | 19.8 | **0.462** |

So the far-horizon prediction is nearly as good (46.2%), and the earlier
`TINYTITAN_PREFETCH_AHEAD=2` A/B adopted **19.0**/token — essentially all of what
the L+2 ranking offers, i.e. unlike the two-slot case the reads *did* arrive in
time with double the headroom. It still lost 3.7%.

That closes the question the way the byte accounting predicts. The ring's whole
benefit is *byte removal*: its 23.7 adopted reads/token are exactly the 62 MiB
per token by which device reads fall (measured 377 -> 315 MiB/token, 23.7 x
2.64 MiB = 62.6). Per-expert readiness shows the same identity in the other
direction: +2.7 adopted reads/token is -7 MiB/token of reads, measured. But every
extra speculative read is issued *into the same saturated device*, so it costs
demand-read queue time (wait_ms 83.0 -> 85.4 -> 91.1) that cancels — and at three
slots, exceeds — the bytes it saves.

**Where that leaves the goal.** A better predictor cannot reach 10 tok/s on this
machine. The ranking is already the best available at both horizons (55%/46%), its
unused tail is real, and the read that would cash it is issued into a queue the
device cannot drain faster than 3.0-3.3 GB/s. The remaining levers are the ones
already established elsewhere: fewer bytes per token (the cache is at its measured
optimum; precision cuts and expert dropping are excluded by the quality and RAM
rules), a faster device, or scheduling work that removes bytes *without* adding
queue pressure — the last of which is the only untested idea this study leaves,
and it is a scheduling question rather than a predictor one.
