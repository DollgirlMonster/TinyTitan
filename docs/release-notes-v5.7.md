## TinyTitan 5.7 — one command installs a built engine, and the app is gone

The install no longer builds anything: `tools/install_tinytitan.sh` downloads the
published arm64 executables, verifies the checksum, unpacks them under
`~/.tinytitan` and asks one question — which model — so a Mac with no Xcode,
Homebrew, Python or Node can go from nothing to a served model. The Mac app is
removed, leaving the engine and its loopback server as the whole product, with an
optional browser window as a client of it. And every script now runs on
`/bin/bash` **3.2.57**, which is the shell a factory Mac actually has — the
launcher did not even parse there before this release. Everything here was
already on `main`.

### The installer downloads the engine instead of compiling it

It cloned the source and ran `swift build`, so a new Mac needed Xcode and ten
minutes of compiling before anything worked — while the release already publishes
the same four executables, built for `arm64`, in a 25 MB tarball. It now: checks the Mac; downloads the newest release's tarball,
verifies its published sha256 and unpacks it into `~/.tinytitan/bin`; downloads
the matching tag's source for the tools, the DSH plugin and the docs into
`~/.tinytitan/src`; asks which model; writes `~/.local/bin/tinytitan` and
`~/.local/bin/tinytitan-web`; offers to start, and opens the page. `--version TAG`
pins a release instead of taking the newest and `--from-source` keeps the
clone-and-build path for contributors. The launcher, the model installer and the
route writer all take `TINYTITAN_BIN_DIR` and `TINYTITAN_MODELS_DIR`, so an
installed `~/.tinytitan/bin` and a checkout's `.build/release` are the same code
path; checkout defaults are unchanged.

Verified against the real published artifact — v5.6, because a tag cannot name
the release it is in — in an isolated `HOME`: download, checksum, unpack, tools,
wrappers, and the installed `TinyTitanServer --catalog` against real installs.
Then the launcher from this checkout, pointed at that `bin`, started the
installed binary on a real model and answered a completion with `42` and
`finish: stop` — a release install serving with no `.build` anywhere.
**Not verified: the model download itself**, a 20–37 GB fetch that must never be
run to satisfy a check.

### The model is a menu, not a yes/no about one default

The installer asked a yes/no about exactly one model, so anything else meant
knowing the target name and finding `install_models.sh --help` first. It now lists all 16 builds with
their **installed** size and what each is for; Enter takes the verified default, so
the shortest path is still one keypress. `--model NAME` skips the menu, and
through a pipe the installer takes the default and says so instead of hanging —
`--choose` refuses a pipe with a usable message. The list lives in
`TINYTITAN_MODEL_CHOICES` next to the client catalogue so the two installers
cannot disagree about what exists or how big it is.

### Every script runs on the shell a factory Mac has

`#!/usr/bin/env bash` finds Homebrew's 5.x on a development machine and
`/bin/bash` **3.2.57** on a new one, and these scripts had only ever run under
5.x. Three classes of defect were found and closed, each verified by running it:

- **Parse.** 3.2 cannot parse a single-quoted heredoc holding an apostrophe inside
  `$( )`. The launcher's expert-cache warm-up did exactly that, so
  `/bin/bash -n tools/server_launcher.sh` failed with
  `unexpected EOF while looking for matching '` — on a new Mac not one line would
  have run. The warm-up is built with `printf` now, which also drops a `python3`
  requirement from a path that must work without one.
- **Run time.** `${v^^}` and `mapfile` are bash 4; 3.2 parses them and then dies
  mid-menu, in the launcher's engine column, in `dsh_route.sh --from-server` and
  in `repack_dense.sh`. All three use `tr` and a `while read` loop.
- **Empty arrays.** Under `set -u`, `"${a[@]}"` on an empty array is
  `a[@]: unbound variable` on 3.2 and fine on 5.x. The shipped `--web` path had
  two — the default browser window died before `dsh` was exec'd. All 62
  whole-array expansions in the tree are now `${a[@]+"${a[@]}"}`, which means the
  same thing for a non-empty array on both shells.

`tools/lint.sh shell` fails on any of the three shapes now, and scans every shell
script in the tree (including `docs/`). It was validated by injection: a bare
array expansion and a `${v^^}` each produce a FAIL and exit 1.

Verified by running the paths under `/bin/bash` 3.2.57, not by reading them: every
script parses under both shells; the installer completes a real release install
(download, checksum, unpack, wrappers) under 3.2 in an isolated `HOME`; the
launcher dry run, the model menu, the status table, the DSH status and the engine
column all run under it; and `tools/lint.sh all` is clean under 3.2.57 and 5.3.20
alike.

### An optional browser chat window, isolated from any dsh you run

A user who wants a window now gets one already pointed at their model: TinyTitan's
own DeepSeek Harness, opened in the default browser by the launcher's `--web`.
Nothing is built or forked — it is upstream's MIT harness plus the
`plugins/dsh-tinytitan` bundle this repository already ships, installed under
`~/.tinytitan` with its own `DSH_HOME`, npm prefix, pnpm store and port (7788,
stepping up to the first free one). The user's `~/.dsh`, a `dsh` on `PATH` and a
stock UI on 3080 are never read, written or stopped; Node is reused when the Mac
has one and fetched privately only when it does not. The harness version is
**pinned** to `0.1.5-rc.2`, because DSH is a developer preview that says outright
it will break compatibility between releases.

Driving the real page in a headless browser found what a `curl` cannot: the
plugin rewrote the route's port at every boot; the route forced thinking on
against a server started with it off (the page sat on "Deep diving..." while the
model spent 32768 tokens reasoning and answered nothing); and a fresh home has no
workspace, which disables the composer. The private home now seeds one, marks the
harness's developer-preview notice as seen, and points the harness default at our
route instead of DeepSeek's hosted one (`MISSING_CREDENTIAL: llm-deepseek`).

Three tunings make the window usable on the intended 35B MoE, measured on
Qwen-AgentWorld 35B-A3B 4-bit:

- the chat preset drops the three injected-context rows a prompt box does not
  want: **4222 → 124** prompt tokens for a nine-word question;
- `--web` warms the expert cache before opening the window — **89 s at startup**,
  so the person's first question does not pay the cold sweep (161 s cold against
  72 s warm);
- together, the first answer through the real page lands in **8.3 s** of engine
  time and the smoke test passes in **16 s** wall clock, against 161.5 s and
  2 m 53 s before.

### The Mac app is removed

The app, its out-of-process decode service, its library and test targets and its
icon generator are gone. A second front end is a second surface to build, keep in
step with every engine feature, and support: the supported way to use a model is
the loopback OpenAI-compatible server with a client you already have — Zed, Codex,
Claude Code, DeepSeek Harness, `curl` — and `--web` is a client we merely install
and configure. Removing it also removed the tree's only other version literal,
`CFBundleVersion`; `ServerVersion.current` is the single one, and `release.sh`
refuses a tag that disagrees with it.

### Server: `POST /v1/responses/compact`

The Open Responses compaction endpoint, implemented as the value endpoint it is —
a conversation in, a compacted input window out, nothing stored and no session
started. The note is metered with the server's own tokenizer and one over budget
is **compressed by a second pass rather than truncated**, because truncation drops
the end of a session, which a continuation needs most. Three guards keep a bad
pass out of the caller's history: instruction lines the model copied back are
stripped, a repetition loop is recognised as a failed pass, and a pass that says
nothing usable falls back to the newest text trimmed to budget; `mode` reports
which path produced the note. The summariser runs at temperature 0 with thinking
**off**, since a model that reasons inside its own output cap returns an empty
note. Verified on the 4B and 9B installs at 4-bit: an eight-turn session compacted
in 16.5 s and 39.7 s, both notes keeping all four load-bearing facts, and the
model answering from the replayed window.

### Server: the concurrent width is any power of two

`--max-concurrent-sequences` was capped at 4, a policy limit rather than an
engineering one; it takes any power of two up to 256 now, and the launcher offers
1 / 2 / 4 / 8 / 16 or a custom entry. The default stays 1, the warning above 1
stays, and two lines were added above 16 saying the clamp is likely to bind.
`KVCacheManager.maximumSlots` moved with it (8 → 256), so a large request is
served or clamped rather than tripping a precondition; what a machine can really
hold is still decided per load by `BatchedMemoryBudget`. Verified against the 2B
at a 32k context on a 24 GB Mac: `32` builds 32 slots and serves 16 concurrent
requests with no 429, and `256` is accepted and clamped — "per-slot 223 MiB,
budget 12288 MiB; serving 54 at once".

### Also in this release

- **The build floor is Swift 6.4 (Xcode 27)** for source builds; the published
  binaries need none of it.
- **`AGENTS.md`** now says ad-hoc model runs use the 4B or 9B, not the 2B — the
  2B fails instruction-following in ways that read as defects in the code under
  test.
- **The forum article series is removed** with the forum; the wiki is the user
  documentation, and every live reference was repointed.
- **Repository cleanup.** `docs/adding-a-model.md` drops the app-descriptor
  wiring point, so adding a model is eight points now.

### Performance

The README's benchmark table was **not** re-measured for this release, and the
published rows are quoted as they stand. Measured on this range: the
Qwen-AgentWorld 35B-A3B 4-bit window figures above; compaction on the 4B and 9B
at 4-bit, 16.5 s and 39.7 s for an eight-turn session; and the 2B concurrency
result — 32 slots serving 16 concurrent requests, 256 clamping to 54.

### Verification

Measured on this commit, by the release dry run:

- six lint gates clean, **1,877 functions** scanned, the shell gate covering 18
  scripts on bash 3.2.57;
- **1,361 tests in 204 suites**, all passing;
- **9 golden baselines byte-identical**: the 125B at both widths, AgentWorld
  4-bit, and the dense 2B/4B/9B at both widths;
- a clean scratch release build with the compiler-warning scan clean, and the
  archive staged and packaged from that tree;
- the engine's speeds recorded against the 5.6 baseline and committed
  (`benchmark/internal-speeds/v5.7{,-rerun}.json`). The first pass measured every
  kernel and rate low (`gpu.qkv_gemv` 64.6 GB/s against 74.3, decode −17.6 %),
  which blocks a release; a quiet re-measure came back inside the threshold
  (75.3 GB/s, +1.3 %; decode −3.6 %), so it was machine state — nothing here
  touched a GEMV kernel. The quiet pass is the release record.

**Seven golden targets are not checked**, because their install is not under
`models/` and nothing may be fetched to change that: `ornith-8`, `ornith-4`,
`qwen36-4`, `qwen36-8`, `agentworld-8`, `katcoder-4`, `katcoder-8`.

### Checksum

`tinytitan-5.7-macos-arm64.tar.gz` sha256: `SHA256_PENDING`
`tinytitan-5.7-macos-arm64.tar.gz` size: `ARCHIVE_BYTES_PENDING` bytes
