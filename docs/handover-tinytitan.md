# Handover: after release 5.7, the engine and its loopback server

**Paste this into the next session:**

> Continue the TinyTitan work in this checkout. Read `AGENTS.md`, then
> `docs/handover-tinytitan.md`, then the wiki `Project-Tracker`. **5.7 is cut and
> published** (`v5.7` → `44e1ae9`; `tinytitan-5.7-macos-arm64.tar.gz`, 15,303,284
> bytes, 2026-09-17) and **`main` sits ten commits past it**; the release notes are
> `docs/release-notes-v5.7.md`. The product is the engine plus its loopback server
> — the Mac app is gone — and `tools/install_tinytitan.sh` now downloads a built
> release instead of compiling one. The twelve installs under `models/` have
> receipts **valid for this folder**, because a rename invalidates them; re-issue
> with `--verify-install` if the folder moves again. **Verification uses only the
> installs already under `models/`** — never download, convert, repack or re-install
> a model to make a gate pass, and never fetch one of the installs the operator
> deleted. Report measurements, not assurances.

This is the only current brief; the 5.5 handover it replaces is superseded. The
traps that one named still bite and are folded in below.

> **The product shape changed: the GUI is gone.** The Mac app, the out-of-process
> decode service, the app's library and test targets and `tools/make_app_icon.py`
> were all removed. TinyTitan is an **LLM engine plus its loopback server**:
> `tools/install_tinytitan.sh` downloads the published executables, optionally
> downloads a model, installs `~/.local/bin/tinytitan`, and offers to start the
> server; that command runs `tools/server_launcher.sh`, which prints the base URL a
> client is pointed at. **Do not add a GUI, a desktop front end, or any work that
> only one needs** — `AGENTS.md` states the policy and the reason, and this is not
> a pause. The app's `Info.plist` was also the tree's only version literal; that
> literal now lives in `ServerVersion.current`
> (`sources/TinyTitanServer/Core/ServerVersion.swift`), is printed in the server's
> ready banner, and is checked against the release tag by `tools/release.sh`.

> **The replacement window is DeepSeek Harness, installed not built.**
> `tools/dsh_local.sh` installs a **pinned** `@deepseek-ai/dsh` (`0.1.6-alpha.2`,
> into `~/.tinytitan/dsh`, with our `plugins/dsh-tinytitan` bundle from this
> checkout, and the launcher's `--web` starts the server and opens it in the
> browser. Two things are load-bearing. **Isolation:** our copy uses its own
> `DSH_HOME`, npm prefix, pnpm store, and port (7788, stepping up when taken), so a
> DeepSeek Harness the user already runs — their `~/.dsh`, their `dsh` on PATH,
> their 3080 UI — is never read, written or stopped. **No fork:** it is upstream's
> code plus our plugin; the harness is in developer preview and says it will break
> compatibility, which is exactly why the version is pinned and why nothing here
> may start depending on a window existing. Two traps cost time and are recorded in
> the script: a fresh `DSH_HOME` has no `settings.yaml`, so we create it before
> `tools/dsh_route.sh --write` will touch it; and pnpm's npm-installed shim has no
> shebang, which macOS refuses to `exec` (`spawnSync pnpm ENOEXEC`) — the private
> shim execs `@pnpm/exe.darwin-arm64` instead. `tools/dsh_local.sh status` says what
> is installed.
>
> **Since 5.7 the pin is enforced rather than declared.** Both plugins support
> exactly `0.1.6-alpha.2` — `dsh-tinytitan`'s peers are exact, not ranges — and
> **refuse to run** on any other harness, including one whose version cannot be
> read. A refusal never throws: it writes one line to stderr and returns, so DSH
> boots, every other plugin loads, and removing ours leaves nothing to undo. stderr
> is not a preference — the harness prints a plugin's log records only when the boot
> itself fails, so a host-logger line would be invisible (tracker, plugins section).

## Where the work stands

| Piece | State |
| --- | --- |
| Repository | `Pummelchen/TinyTitan` (renamed 2026-09-14; the old URL redirects) |
| Checkout folder | `~/Downloads/TinyTitan` — **renamed from `~/Downloads/NVMAI`**, which invalidated every receipt and `.build`'s debug half |
| `main` | `ab98829`, level with `origin/main`; the release tag is `v5.7` at `44e1ae9`, so **ten commits sit past it** |
| Release | **5.7 published** 2026-09-17 — `tinytitan-5.7-macos-arm64.tar.gz`, 15,303,284 bytes, checksum beside it |
| Models | **12 installs, 488 GB**; every receipt re-checked on 2026-09-18 as bound to this path, so all load |
| Goldens stored | 16 (ten MoE + six dense); **11 checked here** (agentworld-4bit, qwen35-{2b,4b,9b}-{4,8}, qwen36-{4,8}, qwen38-125b-{4,8}); the five with no install — katcoder-{4,8}, ornith-{4,8}, agentworld-8bit — are reported *not checked* |
| `.build` | release rebuilt after the rename; a clean scratch release build is part of the 5.7 dry run |
| Wiki | `.qwen/wiki`, remote `TinyTitan.wiki.git`, level with `origin/master` at `3c0d5fc` |
| DeepSeek Harness | pinned `0.1.6-alpha.2` and **enforced**; both plugins refuse any other version; the global harness runs the gate, the private one is refreshed but idle until its next start |
| CI | the last completed `main` run (`da5dcba`) is **green on both jobs, including `thread-sanitizer`**; runs after it were cancelled by concurrency or still in flight, not failed |

## What has landed since the 5.5 handover

1. **5.6** (`2a06c1c`) — the three reported bugs, and an ANE answer of "no". The
   app could not change models ([#9](https://github.com/Pummelchen/TinyTitan/issues/9));
   the model installer looked for its binary at a SwiftPM target-triple path
   ([#8](https://github.com/Pummelchen/TinyTitan/issues/8)); and the ANE exporter
   wrote a sidecar the Neural Engine had refused and then ran the whole prefill on
   the CPU. Also raised the build floor to Swift 6.4, gave the server per-session KV
   and GDN state, and turned the wiki into a user guide with a Cookbook. Dry-run
   gates: five lint gates clean (2,108 functions), **1,566 tests in 237 suites**,
   nine goldens byte-identical.
2. **5.7** (`44e1ae9`) — one command installs a built engine, and the app is gone.
   `tools/install_tinytitan.sh` downloads the published arm64 executables, verifies
   the checksum, unpacks them under `~/.tinytitan` and asks one question — which
   model — so a Mac with no Xcode, Homebrew, Python or Node can go from nothing to a
   served model; `--version TAG` pins a release and `--from-source` keeps the
   build path. Every script now runs on `/bin/bash` **3.2.57**, which the launcher
   did not even parse under before this release. Dry-run gates: six lint gates clean
   (1,877 functions, 18 scripts), **1,361 tests in 204 suites**, nine goldens
   byte-identical, and speeds recorded against the 5.6 baseline after a kernel-wide
   low first pass forced a quiet re-measure.
3. **The ten commits past the tag** — `plugins/dsh-lan-manager`, a LAN-scoped
   control plane for a DSH fleet (four commits); the DSH harness pinned to
   `0.1.6-alpha.2` with **both plugins refusing to run on any other version**
   (`da5dcba`, `a0ad069`, `ab98829`), which is also what put the plugin suites into
   CI; a README pass and a badge refresh; and a post-tag 5.7 prep commit carrying
   the dry run's verification record and the committed speed record.

## What is open

1. **The `thread-sanitizer` CI job is red on some commits and green on others —
   an intermittent report in `SSEOutbox.next()`.** The last completed `main` run
   passed it, and both local instrumented runs are clean
   (`--filter ResponsesAPIHTTPTests`, 9 tests; and the full
   `swift test --no-parallel --sanitize=thread`, exit 0), which is what an
   intermittent report looks like. **For benign:** `SSEOutbox`'s state is fully
   lock-guarded (`frames`, `pendingDrain`, `closed`, `overflowed`, `abandoned`,
   `closeAfterDrain`, `drainCancelled` are only touched under `NSLock`) and the read
   frame is compiler-generated/NIO, not this project's code. **Against dismissing
   it:** an intermittent race is exactly what the gate exists to catch, and a flaky
   gate reddens unrelated pushes. Repeat the instrumented suite under load (or with
   `TSAN_OPTIONS=halt_on_error=0` to collect every report) until it reproduces, then
   decide between a fix, a documented suppression, and a narrowed scope. Do not make
   CI green by deleting the job. See tracker section 1.
2. **Publishing `plugins/dsh-tinytitan`** — still a decision, not code. The code
   half is closed: the route refresh no longer needs a checkout
   (`src/generate.js` runs the discovered `TinyTitanServer --catalog` and its output
   is pinned byte-for-byte to `tools/dsh_route.sh --print`). **The catalogue PR is
   still closed** — [#5094](https://github.com/awesome-dsh-plugin/awesome-dsh-plugin/pull/5094)
   was closed 2026-09-15 with no comment and no entry in the catalogue — so the
   choice is resubmit, npm, or a git host; ask why it closed before repeating it.
   `docs/dsh-plugin-publication.md` carries the research and the ready-to-copy
   entry. The licence is MIT on purpose. The two upstream asks in
   `docs/dsh-upstream-asks.md` are still unposted.
3. **The expert cache cannot be unwired on the models that wire it.**
   `TINYTITAN_KEEP_WIRED` can only turn it *on*, and the Qwen3.8/35B profile rows
   already set it, so on a 24 GB Mac the 12 GiB cache cannot be paged out
   (measured: 14.72 GB RSS, 11% system memory free). A `TINYTITAN_KEEP_WIRED=0`
   path trades the TTFT win for a pageable cache.
4. Carried forward unchanged: the Qwen 3.8 port items (QSA indexer selections to
   the GPU, a higher expert slot budget, the n-gram gather a token ahead), and the
   hardware blockers in tracker section 2 (validation on M1/M2/M4/M5/M6, ANE across
   generations, long-context parity past the exactness window).

## Traps worth carrying forward

- **A hand-set `baseURL` can 404 every model call.** `dsh-llm-deepseek` defaults to
  `protocol: messages`, whose root is `https://api.deepseek.com/anthropic`;
  `https://api.deepseek.com/v1` is the chat-completions root, and every request then
  goes to a path DeepSeek does not serve. All four fleet nodes were failing every
  turn this way until 2026-09-18. The generated route (`tools/dsh_route.sh`) does
  not make this mistake; config typed by hand does. Full entry in tracker section 4.
- **A version gate must be visible, not merely correct.** The harness collects a
  plugin's log records and prints them **only when the boot itself fails**, so a
  refusal reported through the host logger is invisible on a healthy boot. Both
  plugins write to stderr for that reason. Found by booting a throwaway harness in a
  temporary `DSH_HOME`, not by reading — do that again for any boot-time claim.
- **Renaming the checkout invalidates every install receipt and `.build`'s debug
  half.** Receipts bind absolute paths; re-issue with
  `swift run -c release TinyTitanRepack --verify-install --input-gturbo <dir>`
  and never hand-edit one. The debug tree is compiled against absolute paths too
  — after the rename, 7,312 files named the old path and `swift test` died with
  `precompiled file …_Builtin_stdbool….pcm was compiled with module cache path
  '/Users/andreborchert/Downloads/NVMAI/…'` **before a single test ran**;
  `release.sh` reports that as `swift test did not report a passing run`, which
  reads like a failing test. Remove `.build/debug` and let it rebuild.
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
  This bit on 2026-09-18: both installed copies were a week of edits behind, and
  only a re-install plus a harness restart put the current code in service.
- **The wiki is a second repository with its own history.** Pull `.qwen/wiki`
  before editing it; the tracker and the Changelog are separate commits; the
  fine-grained PAT can read it but was rejected for push, so use the `gh`
  credential helper (`gh auth setup-git`). A push means **both** repositories.
- **Verification is what is installed.** `models/` is pruned for disk on purpose;
  a target with no install is reported *not checked* and named in the notes, and
  nothing is fetched to change that. A stored baseline is never deleted because
  its model is currently absent.
- **`release.sh` needs `HEAD` to *be* the tag** and a release build at
  `.build/release/TinyTitanCLI` to exist **before** it starts.
  The golden phase refuses to run beside any model process.
- **Say what a guard actually reads, not what it intends**, and **test a claim
  rather than trusting it** — both defects that reached a release in this project
  were claims broader or more specific than the code.
