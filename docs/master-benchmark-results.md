# Master-prompt benchmark results

The ten scenarios in `docs/benchmark-master-prompts.md`, run end to end through
the memory arms by `benchmark/memory_master.py`. **Four of ten are complete**;
the run was stopped on request after `pigeon` on 2026-09-19. One run per arm, no
repeats, so every number is single-sample.

**Setup.** `qwen36` 4-bit (Qwen 3.6 35B-A3B). `summary` = memory off with a
200-word note the harness carries forward at each boundary — what a client's own
compaction does. `auto` = memory on, tools off, the engine writing by
consolidation. Each session is a new conversation; the quiz is scored against
what is true by then.

**Scores.** *Foundation* is keys that never change (a no-regression check);
*carryable* is keys that change at least once; *stale* counts an answer that is
an older value of a key, given after it changed — the memory-specific failure.
All three are recomputed from the stored answers.

## Complete

| scenario | arm | foundation | carryable | stale | seconds |
| --- | --- | ---: | ---: | ---: | ---: |
| photograph (fiction) | summary | 81/81 100% | 44/45 98% | 1 | 616 |
| photograph | auto (memory) | 81/81 100% | 41/45 91% | 2 | 2,580 |
| pong (code port) | summary | 8/8 100% | 6/6 100% | 0 | 476 |
| pong | auto (memory) | 8/8 100% | 6/6 100% | 0 | 504 |
| ledger (code migration) | summary | 21/21 100% | 21/21 100% | 0 | 118 |
| ledger | auto (memory) | 21/21 100% | 20/21 95% | 1 | 3,619 |
| pigeon (operations) | summary | 3/5 60% | 14/20 70% | 1 | 236 |
| pigeon | auto (memory) | 5/5 100% | 20/20 100% | 0 | 1,071 |

Misses: photograph/summary `ferry_running`@9; photograph/auto
`marcus_knows_photo`@4, `halvorsen_confessed`@4, `inn_status`@5,
`ferry_running`@10; ledger/auto `id_scheme`@7; pigeon/summary every key at
session 5 (`gateway_port`, `worker_port`, `worker_owner`, `rollback_hours`,
`scheduler_state`) and three of them again at session 6.

## What the benchmark has told us so far

**1. The client's own summary is a much stronger baseline than "no memory".**
It wins or ties on three of four scenarios. Any claim that memory helps has to be
made against this arm, not against memory-off — which is what the earlier S1–S5
suite compared on its code scenarios.

**2. Memory's win appears exactly where the design predicted: a dense,
arbitrary, revised fact set.** On `pigeon` — an ops runbook of ports, owners, a
rollback window and a decommission — memory carried the carryable set **20/20
against the summary's 14/20**, with the summary holding a stale value and, for
the first time, losing a *foundation* key. The summary's failure is a
late-session collapse: at session 5 it answered none of the five keys, and three
were still wrong at session 6. Nothing about those facts is prose-shaped or
derivable, which is the shape a summary is worst at.

**3. Memory's loss appears on prose.** On `photograph` the summary carried 44/45
against memory's 41/45, with half the stale values. This confirms the earlier
audit: on a novel, memory faithfully preserves the model's own drift, and the
guard only partially closes that. The four misses are events (an inn burning, a
character found, a confession), not attributes.

**4. Cost is the tax on every session.** Memory's wall clock is 4.2× the
summary's on photograph (2,580 s vs 616 s), 4.5× on pigeon, and **30×** on ledger
(3,619 s vs 118 s), because memory pays a consolidation generation per session
that the summary does not. On pigeon it bought 30 carryable points; on ledger it
bought nothing.

**5. Foundation held everywhere for memory; the summary lost it on pigeon.**
Memory was 100% on the no-regression set in all four scenarios. The summary's
60% on pigeon is the only foundation failure measured — a blunt summary drops
facts it has no reason to drop.

## What this does and does not say

- **Does:** the benchmark discriminates. Across four worlds the arms separate in
  both directions, and the separation follows the fact density and the
  arbitrariness of the carried set, not the domain.
- **Does not:** support a general "memory is better". On two of four it is worse
  or equal, and the six unmeasured worlds — `contract`, `compound_k`, `vantage`,
  `kitchen`, `cohort`, `filing` — are the transition-dense ones where the
  `pigeon` result predicts memory's advantage. They must be run before any
  summary of the feature.
- **Caveats.** One run per arm, one model, no repeats. *Carryable* conflates a
  memory failure with a model reasoning error (photograph/auto's
  `marcus_knows_photo`@4 is a hallucination, not a stale value); *stale* is the
  memory-specific signal. A scenario's `seconds` includes consolidation waits.

## Remaining

`contract` (7 sessions), `compound_k` (6), `vantage` (8), `kitchen` (7),
`cohort` (8), `filing` (7). Pigeon was re-run to completion after an earlier
partial run.

## Resume

```bash
TINYTITAN_MEMVAL_MODEL=qwen36 TINYTITAN_MEMVAL_QUANT=4 TINYTITAN_MEMVAL_RUNS=1 \
  benchmark/memval_master.sh contract compound_k vantage kitchen cohort filing
python3 benchmark/memory_master.py report-all
```

A finished scenario can be reported on its own without re-running:

```bash
TINYTITAN_MASTER_SCENARIO=pigeon \
TINYTITAN_MEMVAL_RESULTS=.build/benchmark-logs/memory-pigeon-qwen36-4bit \
  python3 benchmark/memory_master.py report
```

Results live under `.build/benchmark-logs/memory-<scenario>-qwen36-4bit/` and are
not committed; this file is the durable record.
