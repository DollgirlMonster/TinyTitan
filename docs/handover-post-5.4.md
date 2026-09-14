# Handover: after 5.4

**Paste this into the next session:**

> Continue the NVMAI work in this checkout. Read `AGENTS.md`, then
> `docs/handover-post-5.4.md`, then the wiki `Project-Tracker`. 5.4 is published
> and `main` has moved well past it with tooling, server and test changes.
> **Verification uses only the installs already under `models/`** — never
> download, convert, repack or re-install a model to make a gate pass, and never
> fetch one of the installs the operator deleted. Rebuild `.build` before any
> golden or release run. Report measurements, not assurances.

## Where the work stands

5.4 is published (`v5.4` → `41efbc5`;
[release](https://github.com/Pummelchen/NVMAI/releases/tag/v5.4), archive
24,770,200 bytes, sha256 `def50d3e…`). It first shipped the 5.3 content to users,
because 5.3 was tagged and never published. `main` is **well past the tag** —
tooling, a server change, a test fix, and this handover — so the tag is not
`main`; `git log --oneline v5.4..HEAD` is the delta. (Deliberately no count or
HEAD hash here: this file's own commit changes both, which is how an earlier
handover came to state a number its commit had already invalidated.)

| Piece | State |
| --- | --- |
| Checkout | `~/Downloads/NVMAI`, a real git repo bound to `origin/main`, tree clean |
| Models | **11 installs, 461 GB.** **10 of the gate's 16 golden targets have an install**; the six absent are the pruned MoE families |
| Goldens stored | **16** — the ten MoE files plus the six dense `qwen3.5-*` files captured 2026-09-14 |
| Receipts | all 11 re-issued on 2026-09-14 — they had been bound to the dead Dropbox path, so **none loaded** before that |
| `.build` | **stale.** The release binaries predate the server change, so run `swift build -c release` before any golden or release run |
| Wiki | `.qwen/wiki` on `master`, clean and level with `origin/master` |
| CI | green on `5032f23`: **1474 tests in 228 suites**, both the `test` and `thread-sanitizer` jobs |

**The pruned installs are intentional and stay pruned.** Ornith 1.5, Qwen 3.6 and
Qwen-AgentWorld 35B (6 of the 16 golden targets, plus sidecars) were deleted to
save disk. `release.sh` names every target it could not check and refuses to
publish unless the release notes repeat the list, so their absence is recorded,
not hidden.

## The rules that govern verification

`models/` is not the full supported set, so a gate verifies **only what is
installed there** and says what it could not check. `tools/release.sh`
implements it: absence is reported and collected; `--publish` requires the notes
to name every unchecked target; an installed model that no `check_golden` line
covers is a hard error unless declared in `NON_GOLDEN_INSTALLS` (today that is
only the MTP sidecar); and the phase fingerprints the install set under `models/`
— every top-level entry by name, type, size and mtime, plus every receipt's bytes
— before and after, and **fails if any of it changed**. `docs/release-process.md`
§5 is the prose. Note what that does *not* claim: it is not a payload hash, and
the receipt the runtime verifies is what attests the payload.

**A baseline can only be captured while its model is installed**, and `models/`
is pruned for disk. So the checked set moves with whatever is on the machine: a
target with no install is reported as *not checked* and named in the release
notes, and its stored file stays in the repository for whenever the install
returns. Capture while an install is present — that is the only window — and
never delete a stored baseline because its model is currently absent. The six
dense baselines were captured that way, on the operator's instruction, in the
window their installs were present.

## The rules that govern the harnesses

**Every benchmark and test script starts its server through
`tools/server_launcher.sh`.** `benchmark/nvmai_profile.py:server_command()`
builds that invocation (`--client server …`), so the ~18 harnesses that share it
needed no change, and `tools/golden-baseline.sh` starts its server leg the same
way. A command names its install by **catalog id** (`<modelID>_<bits>-Bit`), read
from that install's manifest, which is what keeps a harness inside the
no-download policy. The launcher's two new knobs are `--prompt-cache
<multi-prefix|off>` and `--mtp-model <dir>` (+ `--mtp-memory-mib`, default 384);
`--ram` takes any positive GB, with or without the `G` suffix. The launcher's
pins (native 262,144 context, no YaRN, KV 8-bit, cache multi-prefix/256 MiB, MTP
off) **are the server's own defaults**, which is the only reason routing the
golden gate through it did not invalidate every stored baseline.

**A release announcement lives in the wiki `Changelog.md`, not the README.** The
README was reworked on 2026-09-14: one merged GPU/CPU benchmark table, a
names-only supported list, and no `## New in X.Y` callout. `release-process.md`,
`CONTRIBUTING.md` and `AGENTS.md` were updated to match — do not reintroduce a
README callout.

## What is open

Everything below is in the wiki tracker; this is the short list.

1. **The CPU side-engine as memory's resident helper** — store and guard ship;
   the resident service, the in-flight scheduler and T2–T5 are designed but
   unmeasured.
2. **From the Qwen 3.8 port** — move the QSA indexer selections to the GPU, raise
   the expert slot budget, issue the n-gram gather a token ahead.
3. **Requested app features from issue #5** — image upload (a runtime feature:
   every supported model is text-only today), conversation history, LaTeX
   rendering.

Closed since the first draft of this handover: the six dense installs now have
baselines (`a5b9ae2`), so the gate checks ten targets here instead of four.

Section 3 of the tracker still lists the hardware blockers (validation on M1/M2/
M4/M5/M6, ANE across generations, long-context parity past the exactness window),
and section 6 the things closed by measurement that must not be re-proposed.

## Traps worth carrying forward

- **The receipt is path-bound.** Another move invalidates all 11 again. Re-issue
  in place with `NVMAIRepack --verify-install`; never hand-edit the receipt.
- **This checkout had no `.git` at all** when the session started — it was a
  snapshot of `main` with `.github/` and `.gitignore` missing. Anyone handed a
  folder like that should compare content against the remote before trusting it,
  then `git init` + `remote add` + `fetch` + `reset --hard origin/main`.
- **A launcher a harness starts must own its server.** On the `--client server`
  path the launcher waited and exited *before* installing its cleanup trap, so a
  harness that signalled it orphaned the model process — and this project's own
  guard then refuses to run beside one. The trap is installed with the server now;
  measured before (`NVMAIServer` left running) and after (none).
- **The coder harness's clients pay a multi-minute cold prefill.** Codex
  abandons a stream that has produced nothing for five minutes and retries, and a
  retry is a cold prefill again — a request that never finished publishes no
  prompt-cache entry — so the round could never finish. Measured on KAT 4-bit: a
  short prompt answered in 2.4 s, a ~18k-token prompt produced no token after
  five minutes. The harness now sets `stream_idle_timeout_ms` and disables
  retries for codex, as it already did for qwen. Expect the coder round to take
  hours, not minutes.
- **A key read from a TOML file must sit before the table header.** The codex
  timeout keys first landed *inside* `[model_providers.nvmai]`, where they are
  scoped to that table and silently ignored (codex reports unknown fields only as
  warnings). Parse the generated file to prove the scoping.
- **A wrapped shell list is not a space-delimited list.** `NON_GOLDEN_INSTALLS`
  spans several lines, and the coverage guard matched `*" $name "*`, so a name
  ending a line had no trailing space and did not match. That cost a full dry run
  before `NON_GOLDEN_SET` folded the whitespace. The focused harness
  (`gate-test` in the session scratch) now reproduces this in seconds.
- **`main` is being pushed to concurrently.** Upstream commits keep landing
  (badges, `NOTICE`, a traffic workflow) and each one forces a fetch + rebase +
  tag move. `release.sh` needs `HEAD` to *be* the tag, so check `git fetch`
  before tagging, and expect to force-move an unpublished tag.
- **The golden gate drives `.build/release/NVMAICLI`**, and it runs before the
  clean scratch build, so a release needs a normal `swift build -c release`
  first — doubly so now that the server changed after the last one. `release.sh`
  fails fast with that message instead of reporting it as a per-target
  "mismatch".
- **`release.sh --publish` re-runs every gate**, including all goldens and the
  clean build. Budget two full passes.
- **A release note value that is only known at publish time must be a
  placeholder.** `--publish` rebuilds from scratch, so the archive differs from
  any dry run: 5.4's notes quoted the dry run's 24,770,128 bytes for an archive
  that shipped at 24,770,200. Both the digest (`SHA256_PENDING`) and the size
  (`ARCHIVE_BYTES_PENDING`) are filled in by `--publish`, which refuses to publish
  unless the notes carry the placeholder or the real value.
- **Say what a guard actually reads.** The immutability guard was described as
  catching any change to `models/` while it only hashed receipts; a stray
  `*.install.lock` left by an aborted install sat inside that blind spot. It now
  fingerprints the top-level entries too. When you describe a gate, describe its
  scope, not its intent.
- **Two workflows analysing the same language upload the same SARIF category.**
  A `codeql-swift.yml` added here was removed once `codeql.yml` (another
  session's, pinned to `--arch arm64` because these sources use `Float16`, which
  x86_64 refuses) already covered Swift. Check before adding one.
- **Another session may be working in this checkout.** During 5.4 three upstream
  commits landed, each forcing a fetch + rebase + tag move, an installer was
  invoked against a pruned model (it aborted with no bytes fetched, leaving a
  stale lock), and a second session owns the repo's CodeQL. `git fetch` before
  tagging, and do not assume `models/` or `.github/` is yours alone.
- Report measurements, not assurances.
