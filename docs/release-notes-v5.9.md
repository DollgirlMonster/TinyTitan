## TinyTitan 5.9 — the GDN pair loads at the slot's width, and memory's value is measured

One runtime fix carries this release: an install whose manifest names the GDN
`linear_attn.in_proj_a`/`in_proj_b` pair explicitly at the attention slot's own
width is honoured again instead of refused on load, which is what stopped a
`qwen38flash` 4-bit install from serving at all (issue #16). Beside it is a
one-line ordering fix the thread-sanitizer gate caught on this release's own
commit, and the rest of what landed since 5.8 is measurement: the ten master
prompts are runnable end to end, and which model judges the side-engine's tasks
— the resident 4B on the CPU or the model already on the engine — is now a
number instead of a belief.

### A GDN a/b override at the attention slot's width is honoured

`Model.validateRoleUniformity` refused **every** quantized override on the GDN
`in_proj_a`/`in_proj_b` pair, comparing only against 16, because the kernel that
reads the pair takes a *bf16-or-slot* flag rather than a fixed width. That is
correct for an override at some third width and wrong for one that names the
attention slot's own width: the runtime already reads the pair at that width, so
refusing it is refusing the width the kernel is using.

A `qwen38flash` 4-bit install that spells the pair out at 4 bits therefore failed
on load with `in_proj_a.weight size N does not match expected M`, which reads
like corruption rather than a limit (issue #16, reported against `c20f688`). The
check now takes `attentionBits` and honours an override that is either the slot's
width or bf16, naming the accepted width in the refusal it still makes for any
other (`sources/TinyTitan/Runtime/Inference/Model+Loading.swift`).

Verified on this checkout by adding that override to the shipped 125B manifest
and its receipt: the reported error fired verbatim, and with the fix the same
install answered. `RoleUniformityTests` pins the regression, and the qwen38 4-bit
golden passes unchanged.

### A T7 hint is queued before the search returns

The T7 background caller's registration was fire-and-forget: `memory_search`
scheduled the question in an unstructured task and returned, so the question
could still be unqueued when the search's answer was. Nothing on the request
path waits on a judgement either way, but the thread-sanitizer gate widened that
window until `MemoryRetrievalTests` failed on the release commit — a caller that
awaits the hint right after a search could arrive before the question was
registered. Registration is now awaited and only enqueues; the sweep still runs
on its own task in the idle window (`sources/TinyTitanMemory/MemoryService.swift`).

### The ten master prompts are runnable, and memory has a baseline that is not "off"

`benchmark/master_scenarios.py` holds the ten long-session worlds as data — a
session-1 brief that fixes the facts, per-session instructions, the sessions that
change one, and a quiz scored against what is true *by then* — with `foundation`
(never changes) and `carryable` (changes at least once) **derived** from the
truth rather than authored beside it (`benchmark/test_memory_scenarios.py`).
`benchmark/memory_master.py` scores the stored answers, and
`benchmark/memval_master.sh` runs all ten, one invocation per scenario.

Four of the ten are complete and recorded in `docs/master-benchmark-results.md`
(`photograph`, `pong`, `ledger`, `pigeon`). The result that matters is the
baseline: a client's own 200-word summary — what a compaction does — wins or ties
on three of the four, so memory has to be argued against *that*, not against
memory-off. Memory's win appears exactly where the design predicts, a dense,
arbitrary, revised fact set: on `pigeon` it carries the carryable keys **20/20**
against the summary's **14/20**, and the summary is the arm that goes stale.

### Which judge: the 4B on the CPU, or the model already loaded

The side-engine's decisions had a default judge — a dense 4B on the CPU — chosen
for what it does *not* cost. `benchmark/side_engine_judges.py` runs the same
prepared case file through either judge (`cpu:<install>` or
`server:<url>:<model>`) and scores both with the task scorer, so the choice is
measured. Bigger is not uniformly better: the served 35B is **worse** on
duplication (75% against the 4B's 100%, reading
`characters/marcus/eyes = grey` and `notes/marcus = marcus's eyes are grey` as
different facts) and **better** on the reply check the 4B cannot do at all (100%
against 62%). Split by task the pair beats either alone. Three more worlds (`ops`,
`lab`, `contract`) were added for diversity, producing 53 cases; the full matrix
and what it does not change yet are in `docs/side-engine-tasks.md`.

### Also in this release

- **The plugin is catalogued.** `dsh-tinytitan` is listed in
  `awesome-dsh-plugin` — PR #5396 merged 2026-09-19 — so only the npm publish
  remains, and that is an operator action. `docs/dsh-plugin-publication.md` says
  what is left.
- **The harness asks are answered and recorded**, with the correction the replies
  forced (`docs/dsh-upstream-asks.md`): the auxiliary-reasoning failure is
  plugin-side (dsh #7109), the LAN manager's remote reach is blocked by the
  webserver schema's two host literals rather than the startup guard (#7111), and
  a bind would also have to fold the bound address into `resolveLanTrust`.
- **The handover brief** now starts from 5.8 (`docs/handover-tinytitan.md`).

### Performance

The README's benchmark table was **not** re-measured for this release; its rows
are quoted as they stand. Measured on this commit for this release against the
5.8 record (`benchmark/internal-speeds/v5.9.json`):

- routed MoE **43.6 GB/s** (−1.4%), CPU int8 GEMV **47.5 GB/s** (−3.5%), prefill
  **24.1 tok/s** (−6.9%), decode **25.0 tok/s** (−6.4%), first token **0.29 s**
  (+7.4%), effective decode **67.8 GB/s** (−6.4%), ANE prefill **48.4 tok/s**
  (−1.9%) — every one inside the 10% gate;
- the greedy response is byte-identical to 5.8 (`quality.response_sha256`
  unchanged), so no arithmetic moved;
- the two synthetic kernel metrics read low — QKV GEMV **63.5 GB/s** (−19.2%)
  and GDN in-projection **67.9 GB/s** (−12.3%) — and `### Verification` records
  why: the machine was under system-maintenance load, and those metrics have
  ranged 55.4–78.6 and 66.8–77.4 GB/s across the v5.5–v5.8 records here.

### Verification

Measured on this commit by the release dry run:

- six lint gates clean, **2,035 functions** scanned, the shell gate over 20
  scripts on bash 3.2.57;
- **1,484 tests in 222 suites**, all passing; and 7 `MemoryRetrievalTests`
  under `--sanitize=thread`, 15 runs in a row, after the ordering fix above;
- **11 golden baselines byte-identical**;
- a clean scratch release build with the compiler-warning scan clean, and the
  archive staged and packaged from that tree;
- the engine's speeds recorded against the 5.8 baseline and committed
  (`benchmark/internal-speeds/v5.9.json`): every generation metric and the
  quality proxy inside the gate, with the greedy response hash unchanged.

**Two synthetic kernel metrics are past the 10% speed gate and are not a code
regression.** QKV GEMV measured **63.5 GB/s against 78.6** (−19.2%) and GDN
in-projection **67.9 against 77.4 GB/s** (−12.3%). The measurement ran while
macOS's Duet Activity Scheduler held a core at ~95% and Chrome was active
(`dasd` sampled at 93–97% throughout, load average ≈6); the same synthetic
metrics have ranged **55.4–78.6 GB/s** (QKV) and **66.8–77.4 GB/s** (GDN) across
the v5.5–v5.8 records on this machine, with 5.8 the series' high-water mark —
each earlier release shows the same first-run-low, re-run-high pattern the 5.9
re-run repeated. Nothing in this release touches those kernels (the runtime
changes are a load-time validation and a memory-path ordering fix), every
generation metric came back inside the gate on the re-run, and the greedy
response is byte-identical to 5.8. The record is committed as measured rather
than re-rolled to flatter it.

**Five golden targets are not checked**, because their install is not under
`models/` and nothing may be fetched to change that: `ornith-8`, `ornith-4`,
`qwen38-8`, `katcoder-4`, `katcoder-8`.

### Checksum

`tinytitan-5.9-macos-arm64.tar.gz` sha256: `SHA256_PENDING`
`tinytitan-5.9-macos-arm64.tar.gz` size: `ARCHIVE_BYTES_PENDING` bytes
