# Master-prompt benchmark results

The ten scenarios in `docs/benchmark-master-prompts.md`, run end to end through
the memory arms by `benchmark/memory_master.py`. **This is a partial run,
paused on 2026-09-19 to restart DSH**: three scenarios are complete, one was in
flight, six had not started. One run per arm, no repeats, so every number below
is single-sample.

**Setup.** `qwen36` 4-bit (Qwen 3.6 35B-A3B), `summary` = memory off with a
200-word note carried by the harness (what a client's own compaction does),
`auto` = memory on with the engine writing by consolidation. Each session is a
new conversation; the quiz is scored against what is true by then.

**Scores.** *Foundation* is keys that never change (a no-regression check);
*carryable* is keys that change at least once; *stale* counts an answer that is
an older value of a key, given after it changed — the memory-specific failure.
All three are recomputed from the stored answers, not from what the run wrote
down.

## Complete

| scenario | arm | foundation | carryable | stale | seconds |
| --- | --- | ---: | ---: | ---: | ---: |
| photograph (fiction) | summary | 81/81 100% | 44/45 98% | 1 | 616 |
| photograph | auto (memory) | 81/81 100% | 41/45 91% | 2 | 2,580 |
| pong (code port) | summary | 8/8 100% | 6/6 100% | 0 | 476 |
| pong | auto (memory) | 8/8 100% | 6/6 100% | 0 | 504 |
| ledger (code migration) | summary | 21/21 100% | 21/21 100% | 0 | 118 |
| ledger | auto (memory) | 21/21 100% | 20/21 95% | 1 | 3,619 |

Misses: photograph/summary `ferry_running`@9; photograph/auto
`marcus_knows_photo`@4, `halvorsen_confessed`@4, `inn_status`@5,
`ferry_running`@10; ledger/auto `id_scheme`@7.

## Preliminary read — and it is not in memory's favour

**Three scenarios in, the client's own 200-word summary has matched or beaten
TinyTitan's memory on every one.** Pong ties exactly. On photograph the summary
carried 44/45 against memory's 41/45 with half the stale values; on ledger it
carried 21/21 against 20/21. Both arms carried the foundation set perfectly
everywhere, so nothing regressed — the difference is entirely in the carryable
set, which is the part memory exists for.

**And memory costs far more.** The auto arm's wall clock is 4× the summary's on
photograph (2,580 s against 616 s) and **30×** on ledger (3,619 s against
118 s) — every session pays a consolidation generation the summary arm does not.

This agrees with the earlier audit of the book scenario: memory's advantage is
concentrated where a summary structurally cannot help (a *reversed* or
*corrected* value), and those worlds — `contract`, `cohort`, `compound_k`,
`kitchen`, `filing` — are exactly the ones this pause interrupted. No conclusion
about the feature should be drawn from three scenarios, and none should be drawn
against it from the two the summary happened to win.

## Remaining

| scenario | status |
| --- | --- |
| pigeon | in flight (auto at 3 of 6) when paused; will be re-run from the start |
| contract, compound_k, vantage, kitchen, cohort, filing | not started |

## Resume

```bash
TINYTITAN_MEMVAL_MODEL=qwen36 TINYTITAN_MEMVAL_QUANT=4 TINYTITAN_MEMVAL_RUNS=1 \
  benchmark/memval_master.sh pigeon contract compound_k vantage kitchen cohort filing
python3 benchmark/memory_master.py report-all
```

A finished scenario can be reported on its own without re-running:

```bash
TINYTITAN_MASTER_SCENARIO=ledger \
TINYTITAN_MEMVAL_RESULTS=.build/benchmark-logs/memory-ledger-qwen36-4bit \
  python3 benchmark/memory_master.py report
```

Results live under `.build/benchmark-logs/memory-<scenario>-qwen36-4bit/` and are
not committed; this file is the durable record.
