# Handover: after release 5.5, the first release under the TinyTitan name

**Paste this into the next session:**

> Continue the TinyTitan work in this checkout. Read `AGENTS.md`, then
> `docs/handover-tinytitan.md`, then the wiki `Project-Tracker`. **5.5 is cut and
> published** (`v5.5` → `a1ad1be`); the project is TinyTitan everywhere, and the
> two features it ships — JSON enforced by a grammar and a per-request thinking
> switch — are described in `docs/release-notes-v5.5.md`. The eleven installs
> under `models/` have receipts **valid for this folder**, because a rename
> invalidates them; re-issue with `--verify-install` if the folder moves again.
> **Verification uses only the installs already under `models/`** — never
> download, convert, repack or re-install a model to make a gate pass, and never
> fetch one of the installs the operator deleted. Report measurements, not
> assurances.

This is the only current brief. It supersedes the handover that preceded it,
whose traps still bite and are folded in below.

## Where the work stands

| Piece | State |
| --- | --- |
| Repository | `Pummelchen/TinyTitan` (renamed 2026-09-14; the old URL redirects) |
| Checkout folder | `~/Downloads/TinyTitan` — **renamed from `~/Downloads/NVMAI`**, which invalidated every receipt and `.build`'s debug half |
| `main` | `a1ad1be`, level with `origin/main`, and `v5.5` is that commit |
| Release | **5.5 published** — `tinytitan-5.5-macos-arm64.tar.gz`, 26,094,346 bytes, sha256 `1e6f10bb…`; notes' digest matches the uploaded `.sha256` |
| Models | **11 installs, 461 GB**; receipts re-issued 2026-09-14, so all load again |
| Goldens stored | 16 (ten MoE + six dense); **10 checked here** (katcoder-4/8, qwen38-4/8, qwen35-{2b,4b,9b}-{4,8}); the six pruned MoE targets are reported not checked |
| `.build` | release rebuilt after the rename; the stale **debug** tree was removed and rebuilt during the 5.5 dry run |
| Wiki | `.qwen/wiki`, remote renamed to `TinyTitan.wiki.git`, level with `origin/master` at the 5.5 Changelog and tracker commits |
| DeepSeek Harness | `web` profile runs `dsh-tinytitan` from this checkout; route provider `tinytitan` (10 models); `qwen38` preset's compaction row points at `dsh-tinytitan/backend` |
| CI | the tagged commit's CI run is **green including `thread-sanitizer`**; the commit before it failed that job on an **intermittent** reported race at `HTTPServerSupport.swift:106` — see below |

## What this session landed

1. **5.5 is published** (`6f469e1` prep, `a1ad1be` notes). Gates on the tagged
   commit: four lint gates clean (2059 scanned), **1523 tests in 234 suites**,
   a warning-free clean scratch build, and **all ten installed golden baselines
   byte-identical**. The six absent baselines are named in the notes, and
   `models/` was fingerprinted before and after the golden phase.
2. **The rename's receipts are re-issued.** All eleven bound
   `/Users/andreborchert/Downloads/NVMAI/models/…`, so every install would have
   failed with `trusted receipt invalid: model directory mismatch`. Re-issued in
   place (461 GB re-hashed, no re-download), then proved by a real generation on
   `qwen3.5_2B_4Bit`.
3. **The DeepSeek Harness bundle is back, under the new name.** The `web`
   profile depended on the deleted
   `file:/Users/andreborchert/Downloads/NVMAI/plugins/dsh-nvmai`; it now runs
   `dsh-tinytitan` from this checkout, which refreshed the route to provider
   `tinytitan`, generated the `tinytitan` preset, re-pointed the `qwen38` preset's
   compaction row, and left no `NVMAI` reference in `~/.dsh/settings.yaml`.
4. **A route-writer defect found and fixed.** `tools/dsh_route.sh --write` left
   its own three-line generated header above the section it replaced, so a
   refresh — which the bundle does at **every harness boot** — added three stale
   comment lines each time. A rewrite is now byte-identical and
   `benchmark/test_dsh_route.py` pins it (11 tests).
5. **The route no longer needs a checkout.** `plugins/dsh-tinytitan/src/generate.js`
   discovers a `TinyTitanServer` binary and a `models/` directory, runs
   `--catalog`, and writes the same block and the same settings surgery as the
   shell tool — pinned byte-for-byte to `tools/dsh_route.sh --print` by its own
   tests. The shell tool still wins wherever it exists, so a checkout user has
   one source of truth; the generator is the catalogue case. `node --test` is 34
   tests, all passing, none skipped.

## What is open

1. **The `thread-sanitizer` CI job is red on some commits and green on others —
   an intermittent report in `SSEOutbox.next()`.** On `6f469e1` the job failed
   with `ThreadSanitizer: reported 1 warnings` — `SUMMARY: ThreadSanitizer: data
   race HTTPServerSupport.swift:106 in closure #1 in SSEOutbox.next()`, a write
   by a GCD worker racing a read by `UnsafeContinuation.resume` on the NIO event
   loop, on the `SSEOutbox` allocated at
   `HTTPServerHandler+Responses.swift:107` — while its own tests passed
   (`1523 tests in 234 suites`). On `a1ad1be`, which changes only
   `docs/release-notes-v5.5.md`, **the same job passed** (17 min), and both local
   instrumented runs are clean: `--filter ResponsesAPIHTTPTests` (9 tests) and
   the full `swift test --no-parallel --sanitize=thread` (1523 tests, 392 s,
   exit 0). So it is intermittent, not deterministic — which is what a real race
   looks like, and also what a Swift-concurrency continuation artifact looks
   like. **For benign:** `SSEOutbox`'s state is fully lock-guarded (`frames`,
   `pendingDrain`, `closed`, `overflowed`, `abandoned`, `closeAfterDrain`,
   `drainCancelled` are only touched under `NSLock`) and the read frame is
   compiler-generated/NIO, not this project's code. **Against dismissing it:** an
   intermittent race is exactly what the gate exists to catch, and a flaky gate
   reddens unrelated pushes. Repeat the instrumented suite under load (or with
   `TSAN_OPTIONS=halt_on_error=0` to collect every report) until it reproduces,
   then decide between a fix, a documented suppression, and a narrowed scope. Do
   not make CI green by deleting the job.
2. **Publishing `plugins/dsh-tinytitan` to the harness catalogue** (still held,
   but the code half is now done). The route refresh **no longer needs a
   checkout**: `plugins/dsh-tinytitan/src/generate.js` builds the same block
   in-process by running the discovered `TinyTitanServer --catalog`, and its
   output is pinned **byte-for-byte** to `tools/dsh_route.sh --print` by
   `test/generate.test.js` against the real catalog (and a synthetic one). The
   shell tool stays authoritative wherever a checkout exists; the generator is
   used only when it is absent or `selfContained: true`. What remains is
   operator-facing: **the catalogue file could not be located** in
   `deepseek-ai/deepseek-harness` (a tree search found no catalogue, marketplace
   or `screenshots.json`), **the licence is unsettled** (the package says MIT,
   the repository Apache-2.0), and the two upstream asks in
   `docs/dsh-upstream-asks.md` have not been posted.
3. **The expert cache cannot be unwired on the models that wire it.**
   `TINYTITAN_KEEP_WIRED` can only turn it *on*, and the Qwen3.8/35B profile rows
   already set it, so on a 24 GB Mac the 12 GiB cache cannot be paged out
   (measured: 14.72 GB RSS, 11% system memory free). A `TINYTITAN_KEEP_WIRED=0`
   path trades the TTFT win for a pageable cache.
4. Carried forward unchanged: the Qwen 3.8 port items (QSA indexer selections to
   the GPU, a higher expert slot budget, the n-gram gather a token ahead); the
   app features from issue #5 (image upload — every supported model is text-only,
   conversation history, LaTeX); and the hardware blockers in tracker section 3
   (validation on M1/M2/M4/M5/M6, ANE across generations, long-context parity
   past the exactness window).

## Traps worth carrying forward

- **Renaming the checkout invalidates every install receipt and `.build`'s debug
  half.** Receipts bind absolute paths; re-issue with
  `swift run -c release TinyTitanRepack --verify-install --input-gturbo <dir>`
  and never hand-edit one. The debug tree is compiled against absolute paths too
  — after the rename, 7,312 files named the old path and `swift test` died with
  `precompiled file …_Builtin_stdbool….pcm was compiled with module cache path
  '/Users/andreborchert/Downloads/NVMAI/…'` **before a single test ran**;
  `release.sh` reports that as `swift test did not report a passing run`, which
  reads like a failing test. Remove `.build/arm64-apple-macosx/debug` and let it
  rebuild.
- **A release tag that is not yet published may be force-moved.** The dry run's
  numbers must be in the notes, so the sequence is: commit prep → tag → dry run →
  fill in `### Verification` → commit → `git tag -f` → `git push --force origin
  vX.Y` → `--publish`. `--publish` re-runs every gate and rebuilds the archive,
  so **the published digest and size are never the dry run's** (5.5: 26,093,424
  bytes dry, 26,094,346 published) — that is what the placeholders are for.
- **A `file:` plugin install is a copy.** After editing
  `plugins/dsh-tinytitan/`, re-install it
  (`dsh plugin --profile web remove dsh-tinytitan`, then `add
  file:<checkout>/plugins/dsh-tinytitan`) or the harness keeps running the copy.
- **The wiki is a second repository with its own history.** Pull `.qwen/wiki`
  before editing it; the tracker and the Changelog are separate commits; the
  fine-grained PAT can read it but was rejected for push, so use the `gh`
  credential helper (`gh auth setup-git`).
- **Verification is what is installed.** `models/` is pruned for disk on purpose;
  a target with no install is reported *not checked* and named in the notes, and
  nothing is fetched to change that. A stored baseline is never deleted because
  its model is currently absent.
- **`release.sh` needs `HEAD` to *be* the tag** and a release build at
  `.build/arm64-apple-macosx/release/TinyTitanCLI` to exist **before** it starts.
  The golden phase refuses to run beside any model process.
- **Say what a guard actually reads, not what it intends**, and **test a claim
  rather than trusting it** — both defects that reached a release in this project
  were claims broader or more specific than the code.
