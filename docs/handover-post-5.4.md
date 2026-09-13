# Handover: after 5.4

**Paste this into the next session:**

> Continue the NVMAI work in this checkout. Read `AGENTS.md`, then
> `docs/handover-post-5.4.md`, then the wiki `Project-Tracker`. 5.4 is published
> and `main` carries one docs commit on top of it. **Verification uses only the
> installs already under `models/`** — never download, convert, repack or
> re-install a model to make a gate pass, and never fetch one of the installs the
> operator deleted. Report measurements, not assurances.

## Where the work stands

5.4 is cut and **published** (`v5.4` → `41efbc5`;
[release](https://github.com/Pummelchen/NVMAI/releases/tag/v5.4), archive
24,770,200 bytes, sha256 `def50d3e…`). It first shipped the 5.3 content to users,
because 5.3 was tagged and never published. `main` is one docs commit past the
tag: the README rework that removed the release callout (see below).

| Piece | State |
| --- | --- |
| Checkout | `~/Downloads/NVMAI`, a real git repo bound to `origin/main`, tree clean |
| Models | **11 installs, 461 GB.** Four of the ten golden targets: `qwen38-4/8`, `katcoder-4/8` |
| Receipts | all 11 re-issued on 2026-09-14 — they had been bound to the dead Dropbox path, so **none loaded** before that |
| `.build` | a working release build; a from-scratch rebuild is not needed unless the checkout moves again |
| Wiki | `.qwen/wiki` on `master`, in sync (`0e3b287` at handover) |

**The pruned installs are intentional and stay pruned.** Ornith 1.5, Qwen 3.6 and
Qwen-AgentWorld 35B (6 of the 10 golden targets, plus sidecars) were deleted to
save disk. `release.sh` names every target it could not check and refuses to
publish unless the release notes repeat the list, so their absence is recorded,
not hidden.

## The rule that now governs verification

`models/` is not the full supported set, so a gate verifies **only what is
installed there** and says what it could not check. `tools/release.sh`
implements it: absence is reported and collected; `--publish` requires the notes
to name every unchecked target; an installed model that no `check_golden` line
covers is a hard error unless declared in `NON_GOLDEN_INSTALLS` with a reason;
and the phase fingerprints the install set under `models/` — every top-level
entry by name, type, size and mtime, plus every receipt's bytes — before and
after, and **fails if any of it changed**. `docs/release-process.md` §5 is the
prose. Note what that does *not* claim: it is not a payload hash, and the receipt
the runtime verifies is what attests the payload.

**A release announcement lives in the wiki `Changelog.md`, not the README.** The
README was reworked on 2026-09-14: one merged GPU/CPU benchmark table, a
names-only supported list, and no `## New in X.Y` callout. `release-process.md`,
`CONTRIBUTING.md` and `AGENTS.md` were updated to match — do not reintroduce a
README callout.

## What is open

Everything below is in the wiki tracker; this is the short list.

1. **The six dense installs have no golden baseline at all** — the biggest
   verification gap, and the one this release's new coverage guard surfaced.
   `benchmark/golden/` holds ten files, all for the MoE families, so a release
   verifies **none** of the dense Qwen 3.5 2B/4B/9B. They are covered by the
   opt-in `NVMAI_DENSE_EQUIV` / `NVMAI_DENSE_GPU_EQUIV` tests, which no release
   runs. Closing it means capturing six baselines, adding the targets to
   `tools/golden-baseline.sh` and `release.sh`, and removing the six from
   `NON_GOLDEN_INSTALLS`. That is a deliberate new baseline, not a re-capture.
2. **The CPU side-engine as memory's resident helper** — store and guard ship;
   the resident service, the in-flight scheduler and T2–T5 are designed but
   unmeasured.
3. **From the Qwen 3.8 port** — move the QSA indexer selections to the GPU, raise
   the expert slot budget, issue the n-gram gather a token ahead.
4. **Requested app features from issue #5** — image upload (a runtime feature:
   every supported model is text-only today), conversation history, LaTeX
   rendering.

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
- **A wrapped shell list is not a space-delimited list.** `NON_GOLDEN_INSTALLS`
  spans several lines, and the coverage guard matched `*" $name "*`, so a name
  ending a line had no trailing space and did not match. That cost a full dry run
  before `NON_GOLDEN_SET` folded the whitespace. The focused harness
  (`gate-test` in the session scratch) now reproduces this in seconds.
- **`main` is being pushed to concurrently.** Three upstream commits landed
  during the 5.4 session (badges, `NOTICE`, traffic workflow) and each one forced
  a fetch + rebase + tag move. `release.sh` needs `HEAD` to *be* the tag, so
  check `git fetch` before tagging, and expect to force-move an unpublished tag.
- **The golden gate drives `.build/release/NVMAICLI`**, and it runs before the
  clean scratch build, so a release needs a normal `swift build -c release`
  first. `release.sh` now fails fast with that message instead of reporting it as
  a per-target "mismatch".
- **`release.sh --publish` re-runs every gate**, including all goldens and the
  clean build. Budget two full passes.
- **A release note value that is only known at publish time must be a
  placeholder.** `--publish` rebuilds from scratch, so the archive differs from
  any dry run: 5.4's notes quoted the dry run's 24,770,128 bytes for an archive
  that shipped at 24,770,200. Both the digest (`SHA256_PENDING`) and the size
  (`ARCHIVE_BYTES_PENDING`) are now filled in by `--publish`, which refuses to
  publish unless the notes carry the placeholder or the real value.
- **Say what a guard actually reads.** The immutability guard was described as
  catching any change to `models/` while it only hashed receipts; a stray
  `*.install.lock` left by an aborted install sat inside that blind spot. It now
  fingerprints the top-level entries too. When you describe a gate, describe its
  scope, not its intent.
- **Another session may be working in this checkout.** During 5.4 three upstream
  commits landed (badges, `NOTICE`, a traffic workflow), each forcing a fetch +
  rebase + tag move, and an installer was invoked against a pruned model (it
  aborted with no bytes fetched, leaving a stale lock). `git fetch` before
  tagging, and do not assume `models/` is yours alone.
- Report measurements, not assurances.
