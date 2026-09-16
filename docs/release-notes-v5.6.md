## TinyTitan 5.6 — the three reported bugs, and an ANE answer of "no"

Closes the three bug reports open against 5.5 — the app could not change models,
the model installer looked for its binary in the wrong directory, and the ANE
exporter would write a sidecar the Neural Engine had refused and then run the
whole prefill on the CPU — and records what a year of Neural Engine work
actually bought. Also raises the build floor to Swift 6.4, gives the server
per-session KV and GDN state, and turns the wiki into a user guide with a
Cookbook. Everything here was already on `main`.

### Change the model from the app ([#9](https://github.com/Pummelchen/TinyTitan/issues/9))

The app read a persisted model preference at launch and had no way to *write* it,
so the model could not be changed from the app at all. **Model → Change Model**
now lists every selectable build, records the choice and shows a banner saying
the app has to be reopened — the model directory, its settings file and the
decode-service process are bound at launch, and the runtime has no supported way
to rebind them under a running generation. A directory name is accepted as a
selector too, and the checkout is found on a case-sensitive volume.

Backed by `swift test --no-parallel --filter AppModelSelectionTests` (8 tests):
every recognizable build is selectable, the choice persists and round-trips, and
a change is refused while a generation or an install is in flight.

### The installer finds its own binary ([#8](https://github.com/Pummelchen/TinyTitan/issues/8))

`tools/install_models.sh` built its path from the target triple
(`.build/arm64-apple-macosx/release/TinyTitanRepack`). That directory exists only
when SwiftPM's triple happens to match the toolchain — macOS 26 and 27 differ —
and when it does exist it can point at a stale tree. It now uses the stable
product path, and `tools/lint.sh arch-path` fails if any build path hardcodes a
triple again.

### A sidecar the Neural Engine refused can no longer be written, or run ([#7](https://github.com/Pummelchen/TinyTitan/issues/7))

Exporting with a large `--max-history` produced `.mlpackage` files Core ML could
not compile for the ANE. The exporter exited 0 and wrote the sidecar, and the
runtime then ran the whole prefill on the CPU — measured at roughly **38×** the
GPU cost, with no error and no fallback line. Three layers now stand in the way,
each catching something the one before it cannot:

- **Compile markers** — Core ML reports an ANE refusal on the native stderr and
  still returns, so the exporter reads it back and refuses the export.
- **Load** — every function the metadata records must load under its
  `h<history>` name. A variant that loads but can never `predict()` is caught
  here.
- **Assignment** — the exporter asks `MLComputePlan` which device each operation
  is assigned to and fails on zero. Measured on the real 3.8 `h12288`: **0 of
  173 operations** on the Neural Engine, against 64–74 for a healthy variant.
  This is the layer that closes the silent case, because a CPU fallback prints
  nothing.

The runtime refuses a sidecar that does not record `aneCompileVerified`, so a
sidecar written by an older exporter is declined and the GPU path is used rather
than a 38× prefill. `tools/verify_ane_sidecar.py --record` keeps the graph check
that a wrong geometry cannot pass. 22 exporter tests, including the marker scan,
which had none.

### Sparse-indexed attention is now correct on the ANE — and still stays on the GPU

Qwen 3.8's full-attention layers choose keys with a QSA indexer, so a sidecar fed
the causal mask attended to keys the model drops past 2,051 visible keys. The
runtime now folds the indexer's compacted selection into the additive mask the
graph already takes — no graph change — and refuses to attend densely: a chunk
past the dense-exact window with no selection throws.

Correctness was measured, because the obvious check was not sensitive enough:

- the graph tracks an independent NumPy reference under a QSA-shaped mask to
  **0.47 %**, against **7.6 %** for the causal-only mask, on both widths;
- a 32-token greedy continuation is textually identical to the GPU — and so was
  the *causal-only* control, which is why the logits (13.6–17.8 % apart) are what
  separate them;
- lowering the QSA budget from 2,048 to 8 moves `L3_after` by 10.2 % and the
  logits by 69 %, so the mask demonstrably reaches the graph.

**Measured, the ANE loses on this model: 0.72× at 4-bit and 0.87× at 8-bit.** The
GPU path already gathers ~2,051 keys while the ANE scores the whole context and
masks the rest, and per-variant setup dominates — one variant loads in 6.7 s
(`h0`) / 13.6 s (`h4096`) / 37.5 s (`h8192`) against the ~0.5 s the runtime's own
note records for the 35B. So no sidecar is installed for 3.8 and
`tools/ane_sidecars.sh` skips it. The gather-graph variant that would remove the
extra arithmetic was sized and rejected: a gathered key must be materialised once
per query that selects it — 64× the dense score matrix, 103 GB at the real chunk
— and measured it is 5.70× slower where it runs and fails one chunk size up.
The full write-up is on the wiki:
[ANE Prefill Research](https://github.com/Pummelchen/TinyTitan/wiki/ANE-Prefill-Research).

### The build floor is Swift 6.4 (Xcode 27)

The manifest declared 6.3 while the tree already carried a Swift 6.4 workaround
(the generation decode state is boxed because 6.4 rejects sending the captured
mutable struct). The floor is now the toolchain this project builds and tests on.
Building from source needs Xcode 27 or a matching Swift 6.4 toolchain.

### The server has per-session state, and serves one session at a time

`KVCacheManager` and `GDNStateManager` gained slots, so each admitted session's
prefill and decode land in its own KV and GDN state, and the forward step is
serialized because the runner's scratch is not per-slot. Two wiring defects that
made four admitted requests serialize at the engine were fixed, and so were three
in the prefill path that made slots above zero decode the prompt to garbage.

**The batched width is deliberately held at 1.** Width > 1 produced degenerate
output on the real 2B and 4B installs, in both int8 and fp16 KV, while width 1 and
the CLI are coherent — so the server admits several sessions but serves them one
at a time until multi-session output is verified correct on the real models. The
Responses API also echoes the sampling the server actually used, instead of
`null` where the schema requires a number.

### The dense Qwen 3.5 family reaches the ANE

The dense installs were on the 128-token default prefill chunk, and the sidecar is
a fixed 4,096-token program that only engages when the configured chunk matches
it — so the family saw no ANE prefill even though the switch has been on by
default since 4.6. They now run the 4,096 chunk: **1.30×** faster prefill at
~2,500 tokens on the 2B.

### Also in this release

- **One instruction file.** `AGENTS.md` is the only agent instruction file (Claude
  Code reaches it through the committed `CLAUDE.md`), and `RELEASE.md` carries the
  release and build standard for this repository. Both are edited here; nothing is
  deployed from another repository.
- **The issue workflow is written down** in `AGENTS.md`: verify the report against
  the code, fix only what is true and unfixed, test the guard, verify again with
  the reporter's own reproduction, audit, reply with evidence, close.
- **A wiki user guide.** The wiki gained a
  [Cookbook](https://github.com/Pummelchen/TinyTitan/wiki/Cookbook) — a recipe per
  common task with the command and the output to expect — and a
  [Technical Articles](https://github.com/Pummelchen/TinyTitan/wiki/Technical-Articles)
  section for engineering write-ups that were previously nowhere.
- **Repository cleanup.** The processed deep-audit register was removed (nothing
  in it was open, and its references were followed and updated), the project
  tracker no longer carries a closure log, and three files were split as pure code
  motion: `ServerInference.swift` (1,897 → 1,664 lines),
  `RealForwardRunner+Decode.swift` (1,829 → 1,572) and
  `RealForwardRunner+Prefill.swift` (1,875 → 1,524).
- **Internal speeds are now a release gate** with a committed baseline, so a
  kernel or bandwidth regression fails a release rather than being noticed later.

### Performance

The README's benchmark table was **not** re-measured for this release, and the
previously published rows are quoted as they stand. What was measured on this
range:

- Qwen 3.8 125B-A6B prefill, ~4,333-token prompt, chunk 4,096: the ANE is
  **0.72×** the GPU at 4-bit and **0.87×** at 8-bit, so this model stays on the
  GPU (`benchmark/ane-prefill/v5.6-ane-38-{4,8}bit.json`).
- The dense 2B at ~2,500 tokens: 23.33 s → 17.88 s, **1.30×**, with the
  1,024-token sidecar (`benchmark/ane-prefill/ane-chunk1024-2b-4bit.json`).
- The gather-graph probe: the ANE accepts the gather but is **5.70×** slower where
  it runs and fails outright one chunk size up
  (`benchmark/ane-prefill/ane-gather-probe-v5.6-gather-*.json`).

### Verification

On this commit before the tag: five lint gates clean (2,108 functions scanned),
**1,566 tests in 237 suites**, 125 Python tests in `benchmark/`, and a clean
release build. The release dry run additionally verifies every installed model
that has a golden baseline — the 125B at both widths, AgentWorld 4-bit and the
dense 2B/4B/9B at both widths — builds a clean scratch tree with the warning scan,
and stages the archive. Golden targets with no install here (Ornith, Qwen 3.6,
KAT-Coder) are reported *not checked*, as always: nothing is fetched to make a
gate pass.

### Checksum

`tinytitan-5.6-macos-arm64.tar.gz` sha256: `SHA256_PENDING`
`tinytitan-5.6-macos-arm64.tar.gz` size: `ARCHIVE_BYTES_PENDING` bytes
