# Handover: after the rename, structured output and the thinking fix

**Paste this into the next session:**

> Continue the TinyTitan work in this checkout. Read `AGENTS.md`, then
> `docs/handover-tinytitan.md`, then the wiki `Project-Tracker`. The project is
> now called TinyTitan everywhere — package, targets, binaries, environment
> variables and the GitHub repository — and structured output is enforced by a
> grammar rather than refused; `main` is well past the published `v5.4`.
> **If the checkout folder has been renamed from `~/Downloads/NVMAI`, every one of
> the 11 install receipts is invalid**: re-issue them before any model run (the
> command is below). **Verification uses only the installs already under
> `models/`** — never download, convert, repack or re-install a model to make a
> gate pass, and never fetch one of the installs the operator deleted. Report
> measurements, not assurances.

This is the only current brief: the three earlier handovers
(`handover-post-5.4.md`, `handover-kat-coder.md`, `handover-dropbox-exit.md`)
were deleted on 2026-09-14 so nothing competes with it, and the traps from them
that still bite are folded in below.

## Where the work stands

| Piece | State |
| --- | --- |
| Repository | `Pummelchen/TinyTitan`, renamed 2026-09-14; the old URL redirects |
| Checkout folder | **still `~/Downloads/NVMAI`** until the operator renames it; `.git` is clean and level with `origin/main` |
| `main` | `549079a`; the last release is `v5.4` → `41efbc5`, so everything since is **unreleased** |
| Models | **11 installs, 461 GB.** 10 of the gate's 16 golden targets have an install; the six absent are the pruned MoE families |
| Goldens stored | 16 (ten MoE + six dense `qwen3.5-*`) |
| Receipts | path-bound to each `models/<dir>`; **a folder rename invalidates all 11** — none load until they are re-issued |
| `.build` | fresh release build, but it now produces **new binary names** (`TinyTitanServer`, `TinyTitanMac`, `TinyTitanCLI`, `TinyTitanRepack`, `TinyTitanDecodeService`, `TinyTitanBench`); stale `NVMAI*` binaries may still sit beside them |
| Wiki | renamed and pushed (`8fc5bd4`); its clone at `.qwen/wiki` is clean but **stale at `077137d`** — pull before editing |
| CodeQL | **clean.** The analysis on `a1b9e34` reports 0 results (`8a1def0`, before the scratch-path fix, reported 11); alerts open 0, fixed 11 |
| CI | run on `549079a` (the rename) — still in flight when this was written; earlier runs were cancelled by the next push, so check `gh run list --branch main` |

**The pruned installs stay pruned.** Ornith 1.5, Qwen 3.6 and Qwen-AgentWorld 35B
(6 targets plus sidecars) were deleted for disk, and `release.sh` names every
target it could not check rather than hiding it.

## What this session landed

1. **Thinking on the Messages API is the request's own** (`a8e7e65`).
   `requestedThinking` replaced the load-time `validateThinking`: `disabled` is a
   real off, `enabled` maps Anthropic's `budget_tokens` onto the OpenAI ladder
   (<4k low, <16k medium, else xhigh), `adaptive` still means "you decide". The
   dead `profile` parameter came off `chatRequest`/`chatRequest(counting:)`.
2. **Structured output is enforced, not refused** (`6b33000`; message fix
   `33c7ecb`). `response_format`, the Responses `text.format` and the Messages
   `output_config.format` compile into a byte-level JSON grammar that masks the
   sampler on both engines. Runtime pieces: `LogitMask`, `JSONGrammar`,
   `JSONSchemaNode`, `JSONTokenTable`, `JSONConstraint` under
   `sources/TinyTitan/Runtime/Generation/`. The schema subset is
   `type`/`properties`/`required`/`additionalProperties`/`items`/`enum`/`const`;
   everything else is refused by name at request time. Thinking is off for a
   constrained request, because the grammar constrains every token. Read
   `docs/structured-output.md` — including what it does **not** claim (a response
   truncated by `max_tokens` is a truncated document). Verified on the real
   install as well: `{"type":"boolean"}` → `false`, `{"enum":["HELLO"]}` →
   `"HELLO"`, `{"type":"json_object"}` → `{"name": "red", "hex": "#FF0000"}`,
   on the GPU engine and `--cpu`, and through `/v1/messages` and `/v1/responses`.
3. **The project is TinyTitan** (`d9313b9`, plus `549079a` for the one defect the
   mechanical pass introduced). 513 tracked files and 581 paths, by one rule
   (`NVMAI_` → `TINYTITAN_`, `NVMAI` → `TinyTitan`, `nvmai` → `tinytitan`). The
   published release notes (`docs/release-notes-v5.0` … `v5.4`) and the wiki
   `Changelog` entries keep the name they shipped under, on purpose. Brand
   assets: `assets/tinytitan-hero.png` (the README and the wiki Home lead with
   it) and `tinytitan-app-icon.png`, regenerated from it by
   `tools/make_app_icon.py`.

## Do this first if the folder was renamed

```bash
for d in models/*/; do
  swift run -c release TinyTitanRepack --verify-install --input-gturbo "$d"
done
```

Each receipt is bound to the absolute path it was installed to, so a renamed
checkout makes every install fail with `trusted receipt invalid: model directory
mismatch`. That is not corruption and needs no re-download; the command above
re-hashes the payload against the manifest and rebinds the receipt in place.
Never hand-edit a receipt — the path binding is what detects a moved or swapped
directory. All 11 re-issue cleanly (the MTP sidecar carries a receipt too).

## How verification works here

`models/` is deliberately smaller than the supported set, so a gate verifies
**only what is installed there** and says what it could not check.
`tools/release.sh` implements that: absence is reported and collected,
`--publish` requires the notes to name every unchecked target, an installed model
that no `check_golden` line covers is a hard error unless declared in
`NON_GOLDEN_INSTALLS` (only the MTP sidecar today), and the install set under
`models/` is fingerprinted before and after so a gate cannot install or rewrite a
model to pass. `docs/release-process.md` is the prose.

- `tools/golden-baseline.sh --check <target>` is the only check that exercises
  real inference. It counts as a model run: macOS 26+, no other model process,
  acceptable `memory_pressure -Q`, a completed `.gturbo` install. Run one
  model-using test at a time, and `swift test --no-parallel` for the suite.
- A baseline can only be **captured while its model is installed**, and the
  checked set moves with whatever is on the machine. Never delete a stored
  baseline because its model is currently absent, and never re-capture one to
  make a mismatch go away.
- The golden gate drives `.build/release/TinyTitanCLI`, so a release needs a
  normal `swift build -c release` **first** — `release.sh` says so explicitly
  rather than reporting it as a per-target "mismatch". `--publish` re-runs every
  gate from scratch, so budget two full passes.
- Every benchmark and test script starts its server through
  `tools/server_launcher.sh` (`benchmark/tinytitan_profile.py:server_command()`
  builds that invocation). The launcher's pins are the server's own defaults,
  which is the only reason the stored baselines survive the indirection.
- A release announcement lives in the wiki `Changelog.md`, **not** the README:
  there is no `## New in X.Y` callout in the README and one should not come back.

## What is open

1. **The DeepSeek Harness bundle — held, and now doubly stale.** The copy
   installed under `~/.dsh` is still the `dsh-nvmai` bundle, and its `file:`
   dependency points at the pre-rename folder. Re-install
   `plugins/dsh-tinytitan/` and regenerate the route
   (`tools/dsh_route.sh --write`, whose provider id is now `tinytitan`), then
   check that the `qwen38` preset's compaction row still names the bundle's
   backend. The plugin was deliberately not re-installed this session.
2. **Publishing the plugin to the DeepSeek Harness catalogue** (held): a
   self-contained route discovery so no checkout is needed, the peer range
   widened to `^0.1.5-rc.2 || ^0.1.6-rc.1`, a `repository` field, the licence
   settled (the repo is Apache-2.0, the plugin says MIT), `screenshots.json`,
   then the one-file catalogue PR.
3. **No release has been cut for any of this.** `main` carries two features and a
   rename past `v5.4`. A release means a version bump, notes, a golden gate over
   the ten installed targets, and the runbook in `docs/release-process.md`; the
   rename also changes the archive's own contents (binary names), which the notes
   must say.
4. Carried forward unchanged: the CPU side-engine as memory's resident helper
   (store and guard ship, the scheduler is designed but unmeasured); the Qwen 3.8
   port items (QSA indexer selections to the GPU, a higher expert slot budget,
   the n-gram gather a token ahead); the app features from issue #5 (image
   upload — every supported model is text-only, conversation history, LaTeX);
   and the hardware blockers in tracker section 3 (validation on M1/M2/M4/M5/M6,
   ANE across generations, long-context parity past the exactness window).

## Traps worth carrying forward

- **A folder rename invalidates every install receipt.** The first thing the next
  session will hit; see the loop above.
- **The rename's one real defect was a SwiftPM bundle prefix.** Resource bundles
  are named after the *package* plus the target, so they are
  `TinyTitan_TinyTitanMac.bundle`; the blanket `NVMAI_` → `TINYTITAN_` rule had
  turned the install script's glob into `TINYTITAN_*.bundle`, which matches
  nothing and would have shipped an app without its resources. When a mechanical
  rename meets a string that is both an acronym and a prefix, check it against
  the artefact that produces it.
- **The wordmarks were split across coloured spans**, so `NVMAI` never appeared as
  one string and the mechanical pass left them reading `NVM` + `AI`. Anything a
  grep says is renamed should be looked at, not trusted.
- **CI cancels the previous run when a new commit is pushed.** A big push (the
  rename) therefore erased the CI evidence for the commit before it.
- **Untracked leftovers still carry the old name**: `.pytest_cache/`,
  `benchmark/.pytest_cache/`, `benchmark/mock/` (regenerated by tests),
  `benchmark/benchmark-results/capital-of-paris-20260911T1935/README.md` (a local
  measurement record) and `.build/releases/nvmai-release-5.4/`. None are tracked
  and none need fixing, but a grep over the working tree will show them.
- **The checkout's `.qwen/wiki` is another session's clone and is stale.** The
  wiki was renamed and pushed from a separate clone; pull `.qwen/wiki` before
  editing it or the edits will collide with the rename.
- **`main` is pushed to concurrently, and `release.sh` needs `HEAD` to *be* the
  tag.** `git fetch` before tagging, and expect to force-move an unpublished tag.
  Do not assume `models/` or `.github/` is yours alone: during 5.4 another session
  landed three upstream commits mid-release and owns the repository's CodeQL.
- **A release-note value known only at publish time must be a placeholder**
  (`SHA256_PENDING`, `ARCHIVE_BYTES_PENDING`); `--publish` rebuilds from scratch
  and refuses to publish unless the notes carry the placeholder or the real value.
- **Say what a guard actually reads, not what it intends.** The immutability
  guard was described as catching any change to `models/` while it only hashed
  receipts — a stray `*.install.lock` from an aborted install sat inside that
  blind spot. It fingerprints the top-level entries too now.
- **A wrapped shell list is not a space-delimited list.** `NON_GOLDEN_INSTALLS`
  spans several lines; a guard matching `*" $name "*` misses a name that ends a
  line. That cost a full dry run before the check folded the whitespace.
- **A launcher a harness starts must own its server.** On the `--client server`
  path the launcher once waited and exited *before* installing its cleanup trap,
  so a signalled harness orphaned the model process — and this project's own
  guard then refuses to run beside one.
- **The coder harness's clients pay a multi-minute cold prefill.** Codex abandons
  a stream that has produced nothing for five minutes and retries, and a retry is
  another cold prefill, so the round could never finish. The harness sets
  `stream_idle_timeout_ms` and disables retries for codex. Expect the coder round
  to take hours, not minutes. Related: a key read from a TOML file must sit
  *before* the table header, or it is silently scoped to that table.
- **Two workflows analysing the same language upload the same SARIF category.**
  The repository has one `codeql.yml`, pinned to `--arch arm64` because these
  sources use `Float16`, which x86_64 refuses. Check before adding another.
- **A `paths-ignore` does not filter a compiled language**; the fix for the
  eleven `swift-huggingface` alerts was building outside the checkout
  (`--scratch-path`), not the config file.
- Report measurements, not assurances: commit, hardware and RAM, macOS, Swift
  version, the exact command, the exit code, the timing footer, and every
  protocol deviation.
