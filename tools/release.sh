#!/usr/bin/env bash
# Verify, clean-build, package, and optionally publish an NVMAI release.
# with a checksum, and publishes a GitHub Release from an existing tag.
#
#   tools/release.sh v4.0                  # dry run: verify, build, package, stop
#   tools/release.sh v4.0 --publish        # same, then create the Release
#   tools/release.sh v4.0 --publish --notes path/to/notes.md
#
# Dry run is the default on purpose: publishing is public and irreversible in
# the sense that watchers are notified immediately. Run it once without
# --publish, inspect the staged archive, then re-run with it.
#
# Two mistakes this script exists to prevent:
#
#   1. `gh` in a fork defaults to the PARENT repo. `gh release list` here shows
#      drumih/turbo-fieldfare, not this repo, and `gh release create` refuses
#      with a confusing message about an unpushed tag. Every gh call below pins
#      --repo.
#   2. An incremental `swift build` compiles nothing when the tree is unchanged,
#      so a warning gate over its output passes vacuously. The release build
#      always goes to a fresh scratch path.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO="${NVMAI_RELEASE_REPO:-Pummelchen/NVMAI}"
PRODUCTS=(NVMAIServer NVMAICLI NVMAIMac NVMAIDecodeService NVMAIRepack NVMAIBench)

die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

TAG="${1:-}"
[ -n "$TAG" ] || die "usage: tools/release.sh <tag> [--publish] [--notes <file>]"
shift
PUBLISH=0
NOTES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --publish) PUBLISH=1; shift ;;
    --notes)   NOTES="${2:-}"; [ -n "$NOTES" ] || die "--notes needs a file"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

VERSION="${TAG#v}"
STAGE_ROOT="$ROOT/.build/releases/nvmai-release-$VERSION"
STAGE="$STAGE_ROOT/nvmai-$VERSION-macos-arm64"
ARCHIVE="$STAGE_ROOT/nvmai-$VERSION-macos-arm64.tar.gz"
SCRATCH="$STAGE_ROOT/build"

cd "$ROOT"

# --- preconditions ----------------------------------------------------------
step "preconditions"
[ -z "$(git status --porcelain)" ] || die "working tree is dirty; commit or stash first"
# The golden gate runs before the clean scratch build and drives the release CLI
# in .build (golden-baseline.sh exits 2 without it), so a missing release build
# used to surface as per-target "golden baseline mismatch" lines. Demand it
# first, where the message can say what to actually run.
[ -x "$ROOT/.build/arm64-apple-macosx/release/NVMAICLI" ] \
  || die "no release build at .build/arm64-apple-macosx/release/NVMAICLI; run: swift build -c release (the golden gate drives that binary)"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "tag $TAG does not exist locally"
[ "$(git rev-parse "$TAG^{commit}")" = "$(git rev-parse HEAD)" ] \
  || die "HEAD is not $TAG; check out the tagged commit before releasing"
git ls-remote --tags origin 2>/dev/null | grep -q "refs/tags/$TAG$" \
  || die "$TAG is not pushed to origin; run: git push origin $TAG"
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 \
  && die "a Release for $TAG already exists on $REPO"
# A skipped baseline needs its reason before anything expensive starts, so a
# forgotten NVMAI_RELEASE_SKIP_GOLDENS_REASON fails here and not an hour later.
if [ -n "${NVMAI_RELEASE_SKIP_GOLDENS:-}" ] && [ -z "${NVMAI_RELEASE_SKIP_GOLDENS_REASON:-}" ]; then
  die "NVMAI_RELEASE_SKIP_GOLDENS=${NVMAI_RELEASE_SKIP_GOLDENS} without NVMAI_RELEASE_SKIP_GOLDENS_REASON; a skipped baseline must record why"
fi
echo "  tag $TAG at $(git rev-parse --short HEAD), tree clean, no existing Release"

rm -rf "$STAGE_ROOT"
mkdir -p "$STAGE_ROOT"

# --- gates ------------------------------------------------------------------
step "gates"
"$SCRIPT_DIR/lint.sh" || die "tools/lint.sh failed"
swift test --no-parallel 2>&1 | tee "$STAGE_ROOT.testlog" 2>/dev/null | grep -E 'Test run with' \
  || true
grep -q 'Test run with .* passed' "$STAGE_ROOT.testlog" 2>/dev/null \
  || die "swift test did not report a passing run"

# The golden baseline is the only check that exercises real inference.
#
# VERIFICATION USES ONLY THE MODELS ALREADY INSTALLED UNDER models/. That
# directory is deliberately kept below the full supported set to save disk, so a
# target with no install is *reported as not checked* -- here and in the release
# notes -- and is never resolved by downloading, converting, repacking or
# re-installing a model. Nothing in this script fetches a model, and the guard
# below re-checks that the golden phase left models/ exactly as it found it.
#
# A baseline the host can see but cannot *read* is a different case and stays a
# documented exception with a mandatory reason. 5.3 was cut on a machine where
# Dropbox had left seven installs online-only and the disk could not hold the
# 134 GB the largest one needed to materialize: every expert read failed, which
# this phase reports as `mismatch (4)` and which has nothing to do with the
# runtime. Deleting a target from the list below would hide that from every
# future reader of this file, so the skip is explicit, carries a reason, prints
# it beside the skip, and must be repeated in the release notes -- --publish
# refuses when it is not:
#
#   NVMAI_RELEASE_SKIP_GOLDENS=qwen38-8 \
#   NVMAI_RELEASE_SKIP_GOLDENS_REASON="install is Dropbox online-only; 134 GB
#     needed, 123 GB free" tools/release.sh v5.3
GOLDENS_CHECKED=0
GOLDEN_SKIPPED=""
GOLDEN_ABSENT=""
GOLDEN_DECLARED=""
SKIP_GOLDENS="${NVMAI_RELEASE_SKIP_GOLDENS:-}"
SKIP_GOLDENS_REASON="${NVMAI_RELEASE_SKIP_GOLDENS_REASON:-}"

# An install that is deliberately not a golden target: the MTP draft head is a
# sidecar to a target whose own baseline already covers it, not a served model.
AUXILIARY_INSTALLS=" qwen3.8-flash-next_125B_A6B_MTP_4Bit "

# The gate must not change the machine to pass. Fingerprint the install set and
# every receipt's bytes before the golden phase and require the same after, so
# installing, removing or rewriting a model inside the gate is a failure rather
# than a way through it. Receipts are small; this reads none of the payload.
install_fingerprint() {
  [ -d "$ROOT/models" ] || return 0
  find "$ROOT/models" -maxdepth 2 -name verified-install.json \
    | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s  %s\n' "$(shasum -a 256 "$f" | awk '{print $1}')" "${f#"$ROOT"/}"
      done
}
INSTALLS_BEFORE="$(install_fingerprint)"

check_golden() {  # <install dir> <golden target>
  GOLDEN_DECLARED="$GOLDEN_DECLARED $1"
  if [ ! -f "$ROOT/models/$1/verified-install.json" ]; then
    echo "  -- NOT CHECKED golden baseline $2 ($1): no install under models/"
    GOLDEN_ABSENT="$GOLDEN_ABSENT $2"
    return 0
  fi
  case " $SKIP_GOLDENS " in
    *" $2 "*)
      echo "  !! SKIPPED golden baseline $2 ($1)"
      echo "  !! reason: $SKIP_GOLDENS_REASON"
      GOLDEN_SKIPPED="$GOLDEN_SKIPPED $2"
      return 0 ;;
  esac
  "$SCRIPT_DIR/golden-baseline.sh" --check "$2" || die "golden baseline mismatch ($2)"
  GOLDENS_CHECKED=$((GOLDENS_CHECKED + 1))
}
# The canonical target names, not the bare `4`/`8` aliases golden-baseline.sh
# still accepts: these strings are what the absence report prints and what
# --publish greps the release notes for, so a bare `8` would match almost any
# notes and make the requirement meaningless.
check_golden ornith-1.5_35B_A3B_8Bit ornith-8
check_golden ornith-1.5_35B_A3B_4Bit ornith-4
check_golden qwen3.6_35B_A3B_4Bit qwen36-4
check_golden qwen3.6_35B_A3B_8Bit qwen36-8
check_golden qwen3.8-flash-next_125B_A6B_4Bit qwen38-4
check_golden qwen3.8-flash-next_125B_A6B_8Bit qwen38-8
check_golden qwen-agentworld_35B_A3B_4Bit agentworld-4
check_golden qwen-agentworld_35B_A3B_8Bit agentworld-8
# KAT-Coder-V2.5-Dev. Declared before its install existed so the first release
# that ships it cannot pass without its baseline.
check_golden kat-coder-v2.5_35B_A3B_4Bit katcoder-4
check_golden kat-coder-v2.5_35B_A3B_8Bit katcoder-8

# An installed model that no check_golden line covers would be silently
# unchecked. The old guard caught that only when *no* baseline had been checked
# at all, so it could not see a straggler beside a passing target.
for dir in "$ROOT"/models/*/; do
  [ -f "$dir/verified-install.json" ] || continue
  name="$(basename "$dir")"
  case " $GOLDEN_DECLARED $AUXILIARY_INSTALLS " in
    *" $name "*) continue ;;
  esac
  die "installed model $name has no golden target; add it to check_golden, or to AUXILIARY_INSTALLS when it is a sidecar"
done

INSTALLS_AFTER="$(install_fingerprint)"
[ "$INSTALLS_BEFORE" = "$INSTALLS_AFTER" ] \
  || die "the golden phase changed models/; a gate verifies what is installed and never installs, removes or rewrites a model"

if [ "$GOLDENS_CHECKED" = 0 ]; then
  echo "  no golden baseline could be checked on this machine (state this in the notes)"
else
  echo "  $GOLDENS_CHECKED golden baseline(s) identical"
fi
if [ -n "$GOLDEN_ABSENT" ]; then
  echo "  NOT CHECKED — no install in models/, and none may be fetched to fix that:$GOLDEN_ABSENT"
fi
if [ -n "$GOLDEN_SKIPPED" ]; then
  echo "  NOT CHECKED — documented skip:$GOLDEN_SKIPPED"
fi
if [ -n "$GOLDEN_ABSENT$GOLDEN_SKIPPED" ]; then
  echo "  the release notes must name every baseline that was not checked"
fi

# --- clean build ------------------------------------------------------------
step "clean release build"
rm -rf "$SCRATCH"
swift build -c release --scratch-path "$SCRATCH" 2>&1 | tee "$STAGE_ROOT.buildlog" | tail -1
grep -qE '^[^ ]+\.(swift|metal|c|h|m|mm):[0-9]+:[0-9]+: warning:' "$STAGE_ROOT.buildlog" \
  && die "release build emitted compiler warnings"
BIN="$SCRATCH/arm64-apple-macosx/release"
[ -x "$BIN/NVMAIServer" ] || die "build produced no NVMAIServer"

# --- stage ------------------------------------------------------------------
step "stage"
rm -rf "$STAGE" && mkdir -p "$STAGE"
for p in "${PRODUCTS[@]}"; do
  [ -x "$BIN/$p" ] || die "missing product: $p"
  cp "$BIN/$p" "$STAGE/"
done
# .bundle resources carry the Metal shader library; without them beside the
# executables the runtime cannot load its kernels.
find "$BIN" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$STAGE/" \;
# LICENSE and NOTICE are what Apache-2.0 requires to travel with a binary
# distribution; THIRD_PARTY_NOTICES.md carries the upstream attributions.
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGE/"

cat > "$STAGE/README-binaries.txt" <<TXT
NVMAI $VERSION — prebuilt binaries (macOS, Apple Silicon / arm64)

Built from tag $TAG with: swift build -c release
Requires macOS 26+. Apple Silicon only; there is no x86_64 build.

Contents
  NVMAIServer          OpenAI-compatible local server (binds 127.0.0.1 only)
  NVMAICLI             one-shot prompt CLI
  NVMAIMac             Mac app
  NVMAIDecodeService   out-of-process decode service used by the Mac app
  NVMAIRepack          model installer / repacker
  NVMAIBench           benchmark driver
  *.bundle             Metal shader library and other runtime resources — keep
                       these next to the executables or the runtime cannot
                       load its kernels
  LICENSE              Apache License 2.0
  NOTICE               copyright and upstream attribution
  THIRD_PARTY_NOTICES.md

These binaries are NOT code-signed or notarized. macOS Gatekeeper will refuse
them on first run. Either build from source, or clear the quarantine attribute
yourself after verifying the checksum published with this archive:

  xattr -dr com.apple.quarantine /path/to/nvmai-$VERSION-macos-arm64

No model weights are included. NVMAIRepack defaults to Ornith 1.5 8-bit (about
36.9 GB); 4-bit remains available explicitly. The runtime defaults to standard
answers with thinking off, as described in the README and Wiki.
TXT

step "package"
( cd "$STAGE_ROOT" && tar czf "$ARCHIVE" "$(basename "$STAGE")" )
shasum -a 256 "$ARCHIVE" | sed "s|$STAGE_ROOT/||" > "$ARCHIVE.sha256"
SHA="$(awk '{print $1}' "$ARCHIVE.sha256")"
echo "  $(basename "$ARCHIVE")  $(wc -c < "$ARCHIVE" | tr -d ' ') bytes"
echo "  sha256 $SHA"

# --- publish ----------------------------------------------------------------
if [ "$PUBLISH" -ne 1 ]; then
  step "dry run complete"
  echo "  staged: $STAGE"
  echo "  re-run with --publish to create the Release on $REPO"
  exit 0
fi

[ -n "$NOTES" ] || die "--publish needs --notes <file> (see the previous release for the shape)"
[ -f "$NOTES" ] || die "notes file not found: $NOTES"

# A baseline that was not checked -- skipped by name, or absent because its
# model is not installed under models/ -- is only acceptable when the notes name
# it: the point is that a reader of the Release learns what was not re-checked.
# Naming an absent target never means fetching it; the model stays absent.
for notchecked in $GOLDEN_SKIPPED $GOLDEN_ABSENT; do
  grep -q "$notchecked" "$NOTES" \
    || die "notes do not mention the unchecked baseline $notchecked; every baseline that was not checked must be named in the notes"
done

# A release whose notes quote the wrong SHA-256 is worse than one quoting none:
# it tells a careful user their download is corrupt. 3.7 shipped that way for a
# few minutes, which is why this is enforced.
#
# But the notes cannot hard-code the digest either. --publish rebuilds from
# scratch, so the binaries carry fresh mtimes and the archive hashes differently
# than any dry run -- the value is unknowable when the notes are written. So the
# notes carry the literal SHA256_PENDING and it is filled in here, which makes
# the invariant hold by construction instead of by a check nothing can satisfy.
RENDERED_NOTES="$STAGE_ROOT/notes-rendered.md"
if grep -q 'SHA256_PENDING' "$NOTES"; then
  sed "s/SHA256_PENDING/$SHA/g" "$NOTES" > "$RENDERED_NOTES" \
    || die "failed to render notes"
  echo "  filled SHA256_PENDING with $SHA"
else
  cp "$NOTES" "$RENDERED_NOTES"
fi
if ! grep -q "$SHA" "$RENDERED_NOTES"; then
  die "the notes neither contain SHA256_PENDING nor quote this archive's sha256 ($SHA)"
fi

step "publish"
gh release create "$TAG" "$ARCHIVE" "$ARCHIVE.sha256" \
  --repo "$REPO" \
  --title "NVMAI $VERSION" \
  --notes-file "$RENDERED_NOTES" \
  --latest || die "gh release create failed"
gh release view "$TAG" --repo "$REPO" --json url,assets \
  --jq '"  \(.url)\n  assets: \([.assets[].name] | join(", "))"'
