# Handover: leave Dropbox, then finish cutting 5.3

**Paste this into the next session:**

> Continue the NVMAI work in this checkout, which is being moved out of the
> Dropbox folder. Read `AGENTS.md`, then `docs/handover-dropbox-exit.md`, then
> the wiki `Project-Tracker` section "Release 5.3 is prepared, tagged and
> unpublished". **Hydrate every online-only model file before anything moves** —
> a file that Dropbox has made online-only has no local content, so moving it
> out of the sync root loses it. Then re-issue the 19 install receipts, rebuild
> `.build` from scratch, and finish the 5.3 gate. Report measurements, not
> assurances.

## Where the work stands

Pushed and in sync: tag `v5.3` → `8d3055f`, which is the commit the release is
cut from. `main` sits ahead of it with documentation only — this handover, the
`AGENTS.md` pointer to it, and the KAT handover's superseded note; the wiki's
`master` carries the tracker's pointer to this file — so `git log --oneline
v5.3..main` shows no code change and `HEAD is not v5.3` is expected until you
check the tag out. **No GitHub Release exists**, and none should be created until
the gate record in `docs/release-notes-v5.3.md` can be completed.

Nothing was left running: no server, no CLI, no conversion, no hydration retry,
no stray `cat`. Disk at handover: 398 GB checkout, 143 GB free; machine macOS
26.6.2, Swift 6.3.3, base M3 with 24 GB.

| Piece | State |
| --- | --- |
| Version literal, README `## New in 5.3`, `docs/release-notes-v5.3.md`, wiki `Changelog.md` | committed |
| `docs/release-notes-v5.3.md` `### Verification` | **incomplete, and says so** — read it before touching it |
| Dry run, attempt 1 | refused before the goldens: a foreign `swiftpm-testing-helper` (another project's scratch tests) tripped the model-process guard |
| Dry run, attempt 2 | `tools/lint.sh` clean, **1470 tests in 228 suites passed** (122.6 s), Ornith 1.5 8-bit golden byte-identical, then `ornith-4` failed with `parallel expert read failed: Operation timed out` |
| Golden phase | **not complete**; 8 of 10 installs are fully local, `qwen38-4` is missing 4 files (5.67 GB), `qwen38-8` is missing 49 files (133.82 GB) |
| Clean scratch build, staged archive, publish | not run |
| KAT-Coder-V2.5-Dev | supported at both widths, installed, goldens captured, measured 17.86 / 6.91 tok/s |

That read failure is the reason for this handover. Dropbox had made seven of the
installs **online-only** — full size listed, zero blocks allocated — and then
refused to fetch them. Every expert read failed, and `release.sh` reports it as
`golden baseline mismatch (<target>)`, which looks like a model bug and is not
one. The diagnosis and the check are in `docs/release-process.md` §5 and in the
wiki tracker's "Traps that have already cost time". Leaving Dropbox removes the
cause permanently: it is Dropbox's `speculative disk management` that evicts
local copies from a nearly-full volume, and its sync engine then refuses to
bring them back (`FP -1004 "Sync paused" … domain: serverUnreachable`).

## Step 0 — hydrate first, then move (order is not optional)

**A dataless file has no local bytes.** Its content exists only in Dropbox's
cloud, reachable through the FileProvider, so moving it out of the sync root
loses it: what lands at the new path is a file with the right size and no
content. There is no backup of `models/` — it is gitignored and 398 GB — so the
verify step below is what stands between the move and a multi-hundred-gigabyte
re-download.

**0a. Find what is online-only** (empty output means everything is local):

```bash
cd /Users/andreborchert/Library/CloudStorage/Dropbox/Coding/NVMAI
find models -type f -size +1M -exec stat -f "%b %z %N" {} \; |
  awk '$1*512 < $2*0.9 {print $3, $2}'
```

At handover that prints 53 files: 49 in `qwen3.8-flash-next_125B_A6B_8Bit`
(133.82 GB) and 4 in `qwen3.8-flash-next_125B_A6B_4Bit` (5.67 GB).

**0b. Hydrate them.** Reading the file is what makes the provider fetch it:

```bash
find models -type f -size +1M -exec stat -f "%b %z %N" {} \; |
  awk '$1*512 < $2*0.9 {print $3}' |
  while read -r f; do
    cat "$f" > /dev/null || echo "FAILED $f"
  done
```

Notes measured on this machine: hydration runs at **2–15 MB/s**, so 139 GB is
hours; three files in flight was faster than one until the provider stalled with
three at once (kill the stalled `cat`, retry it alone); a fetch that fails
instantly with `Operation timed out` means the sync engine is paused — check
`fileproviderctl dump com.getdropbox.dropbox.fileprovider --limit-dump-size |
grep -i -A2 "sync paused"` and ask the human to resume Dropbox. **A volume with
too little free space also makes the provider refuse**, with the same
timeout-shaped error and no disk-space message.

**Free space is the constraint.** Hydrating everything needs 139.5 GB and the
volume has 143 GB, which is not enough headroom for a long run; either free
~40 GB first (candidates measured in the tracker — `~/Downloads/Movies` 28 GB,
`~/Library/Caches` 17 GB, games 21 GB, MetaTrader 10 GB; Docker's 23 GB is in
use by another session) or accept that `qwen38-8` is not hydrated before the
move and must be rebuilt afterwards from source, which is the far more expensive
option.

**0c. Re-check, and only then move.** The command from 0a must print nothing.
Then:

```bash
mv /Users/andreborchert/Library/CloudStorage/Dropbox/Coding/NVMAI \
   /Users/andreborchert/Coding/NVMAI          # create ~/Coding first
```

`~/Library/CloudStorage/Dropbox` and `~` are on the same volume, so this is a
rename: instant, no extra space, no copy. To another volume it is a 398 GB copy
with its own free-space needs. `.qwen/wiki` is a nested clone of the wiki repo
and moves with the tree.

**Two consequences to state out loud before the move:**

1. **Dropbox treats the move as a deletion.** The project leaves the cloud copy
   too, which is the point (and frees ~400 GB of the Dropbox quota), but the
   models then exist on exactly one disk. The code and docs are safe on GitHub;
   `models/` is not in git and has no second copy.
2. **The path change is what invalidates every install receipt** (step 1). This
   is expected and repairable in place, not corruption.

## Step 1 — after the move: rebuild and re-issue

```bash
cd /Users/andreborchert/Coding/NVMAI
rm -rf .build                     # build products carry the old absolute path
swift build -c release
for d in models/*/; do
  [ -f "$d/verified-install.json" ] || continue
  .build/release/NVMAIRepack --verify-install --input-gturbo "$d"
done
```

- **19 installs** carry a `verified-install.json`; each must be re-issued, or it
  refuses to load with `trusted receipt invalid: model directory mismatch`.
- **The re-issue is also the check that the move did not lose content.** A file
  that arrived without its bytes keeps its size, so the runtime would read zeros
  and answer confidently from them — the silent-wrongness class this project has
  shipped once. `--verify-install` re-hashes the payload against the manifest and
  fails on such a file, which turns that into an error the operator can act on:
  reinstall that model. If the re-issue suite comes back clean, nothing was lost.
- Re-issuing re-hashes the payload in place (no re-download) and **drops
  `sourceRepoID`**; provenance survives in `sourceRevision` and the manifest's
  `sourceSnapshotHash`. Do not read `sourceRepoID` as evidence of origin
  (tracker §5a).
- `.build` must go: leaving the stale tree behind produces SwiftPM module errors
  that read as failed compiles for a build that reports success, which cost a
  session once. `~/Library/Caches/org.swift.swiftpm` is safe to leave.
- No tracked file hardcodes the Dropbox path — `tools/*.sh` derive their root
  from the script location, and `sources/`, `tests/`, `benchmark/` and `docs/`
  contain no absolute checkout path. The only path-bound artifacts are the
  install receipts and build products.
- Start the next session with the new directory as its working directory, and
  confirm with `pwd` before running anything.

## Step 2 — finish the 5.3 gate

The stored baselines are valid for one (machine, build, model) triple and are
**not** affected by the move. Capture nothing new.

If step 0b hydrated everything before the move, run the gate with **no skip** —
that is the outcome worth the trouble, and the notes' `### Verification`
paragraph then needs its skip wording removed:

```bash
git checkout v5.3                      # HEAD must BE the tag, tree clean
tools/release.sh v5.3
```

If `qwen38-8` could not be hydrated, the release can still be cut, with the
baseline skipped **by name** rather than deleted from the gate's list:

```bash
git checkout v5.3
NVMAI_RELEASE_SKIP_GOLDENS=qwen38-8 \
NVMAI_RELEASE_SKIP_GOLDENS_REASON="install was online-only; never hydrated before the move" \
  tools/release.sh v5.3
```

This handover document and the tracker entry landed on `main` **after** the tag,
so `HEAD is not v5.3` is the expected first failure until you check the tag out —
that is the runbook's case, not a problem: the binaries are built from the
tagged commit either way. `--publish` refuses unless the notes name the skipped
target; update the reason to whatever is true at the time. Then:

1. Fill `### Verification` in `docs/release-notes-v5.3.md` from the dry run's
   real output — the golden count, the archive size, the clean-build result —
   and keep the honest paragraph about what was not checked, if anything.
2. Inspect `.build/releases/nvmai-release-5.3/` before publishing.
3. Commit the notes on `main`, then publish **from the tag** with a copy of them
   (the notes file inside a detached checkout is the tagged version):

   ```bash
   cp docs/release-notes-v5.3.md /tmp/notes-5.3.md   # read outside the checkout
   git checkout v5.3                                 # HEAD must BE the tag
   tools/release.sh v5.3 --publish --notes /tmp/notes-5.3.md
   git checkout main
   gh release view v5.3 --repo Pummelchen/NVMAI --json url,assets
   ```
4. Then the standing post-push checks: README, wiki, tracker in sync; no model
   process left running.

Filling in the notes does **not** require moving the tag: the binaries are built
from the tagged commit and the notes are passed by path, so `git tag -f` is only
for a change that must live in the tagged tree. `v5.3` has already been
force-moved three times while unpublished; check `gh release view v5.3` first and
never move a tag that has a Release.

## Traps worth carrying forward

- **A refused golden is not a mismatch.** `release.sh` prints
  `golden baseline mismatch (<target>)` for both. Read the line above: a real
  mismatch prints an output diff; a refusal names the process guard (another
  project's `swiftpm-testing-helper` — never kill it, wait or ask). §5 of
  `docs/release-process.md`, and the online-only case is in the same section.
- **The guard is machine-wide.** This Mac runs other agents' Xcode/SwiftPM work;
  the golden phase needs a quiet window of ~90 s *per golden*, so verify silence
  before spending an attempt.
- **`--publish` re-runs every gate**, including all goldens and a clean scratch
  build. Budget for two full passes.
- **The 125B installs are 162 GB (4-bit) and 220 GB (8-bit) on disk** — the
  "125B" is the parameter count, not the footprint.
- **Never delete a model or an install to make room** without asking; and never
  drop a target from `check_golden`'s list — that is what the skip mechanism is
  for.
- The measured KAT rows (17.86 / 6.91 tok/s) came from
  `benchmark/nvmai_maxthroughput.py` on this machine; the dense GPU-versus-CPU
  README rows are quoted from the wiki page and were not re-measured for 5.3.
  The notes say so and must keep saying so.
