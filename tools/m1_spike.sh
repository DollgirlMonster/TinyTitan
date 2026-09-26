#!/usr/bin/env bash
# Build this checkout, run the model-free tests, then measure which prefill
# levers matter on *this* Mac. Written for an M1 Max with 64 GB running
# Qwen3.8-Flash-Next 4-bit, but nothing in it is specific to that pair.
#
#   tools/m1_spike.sh                          # build, tests, 2 rounds of every arm
#   tools/m1_spike.sh --model <dir> --rounds 3
#   tools/m1_spike.sh --skip-build --skip-tests --arms "base s256 c2048"
#   tools/m1_spike.sh --dry-run                # print what would run, run nothing
#
# Why these arms. Every Qwen3.8 tuning verdict in docs/ was measured on a 24 GiB
# M3, where prefill ran at 90% GPU occupancy, so cutting expert reads could win
# at most ~10% and the read levers were closed. A 64 GB M1 Max has ~2.5x the GPU
# and ~4x the memory bandwidth but a similar SSD, and room for half the expert
# corpus in RAM. The arms test whether that moves the balance:
#
#   base         the install's profile defaults
#   s128, s256   more routed-expert cache (256 slots ~ 34 GiB, half the corpus)
#   nobound      TINYTITAN_BOUNDED_IO=0: let the page cache hold experts too
#   s256nobound  both
#   c2048        half the prefill chunk: if this is much slower than base, the
#                cost tracks the chunk count and a >4096 chunk is worth building
#
# Arms are interleaved (the order rotates each round), greedy with a fixed seed,
# one model process at a time. Results land in benchmark/m1-spike/<stamp>/:
# every raw log, results.tsv, and summary.txt. Nothing here downloads, converts
# or re-installs a model, and nothing is purged or killed: a failed precondition
# stops the script with the reason.
set -Eeuo pipefail
# Under -e a failed command ends the script; say where, rather than vanishing.
trap 'echo "m1_spike: stopped at line $LINENO: $BASH_COMMAND (exit $?)" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODEL="$ROOT/models/qwen3.8-flash-next_125B_A6B_4Bit"
ROUNDS=2
PROMPT_CHARS=28000
MAX_NEW=64
COOLDOWN=20
ARMS="base s128 s256 nobound s256nobound c2048"
SKIP_BUILD=0
SKIP_TESTS=0
FULL_TESTS=0
DRY_RUN=0
MIN_FREE_PCT=20
OUT=""

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'USAGE'
Options:
  --model <dir>        installed .gturbo model (default models/qwen3.8-flash-next_125B_A6B_4Bit)
  --rounds <n>         interleaved rounds per arm (default 2)
  --arms "<list>"      subset of: base s128 s256 nobound s256nobound c2048
  --prompt-chars <n>   prompt size in characters (default 28000, ~7-8K tokens)
  --max-new <n>        generated tokens per run (default 64)
  --cooldown <s>       pause between runs (default 20)
  --out <dir>          results directory (default benchmark/m1-spike/<stamp>)
  --skip-build         reuse the existing release build
  --skip-tests         skip the model-free tests
  --full-tests         run the whole suite instead of the suites this branch touched
  --dry-run            print the plan and the commands, run nothing
USAGE
}

die() {
  echo "m1_spike: $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --rounds) ROUNDS="$2"; shift 2 ;;
    --arms) ARMS="$2"; shift 2 ;;
    --prompt-chars) PROMPT_CHARS="$2"; shift 2 ;;
    --max-new) MAX_NEW="$2"; shift 2 ;;
    --cooldown) COOLDOWN="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-tests) SKIP_TESTS=1; shift ;;
    --full-tests) FULL_TESTS=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# The script changes into the checkout before running anything, so a relative
# --model has to be anchored to where it was typed. No symlink resolution: the
# install receipt is bound to the exact path the model was installed at.
case "$MODEL" in
  /*) ;;
  *) MODEL="$PWD/$MODEL" ;;
esac
MODEL="${MODEL%/}"

case "$ROUNDS$PROMPT_CHARS$MAX_NEW$COOLDOWN" in
  *[!0-9]*) die "--rounds, --prompt-chars, --max-new and --cooldown take whole numbers" ;;
esac
[ "$ROUNDS" -ge 1 ] || die "--rounds must be at least 1"

# name|environment|extra CLI arguments
arm_spec() {
  case "$1" in
    base) echo "base||" ;;
    s128) echo "s128||--expert-cache-slots 128" ;;
    s256) echo "s256||--expert-cache-slots 256" ;;
    nobound) echo "nobound|TINYTITAN_BOUNDED_IO=0|" ;;
    s256nobound) echo "s256nobound|TINYTITAN_BOUNDED_IO=0|--expert-cache-slots 256" ;;
    c2048) echo "c2048||--prefill-chunk 2048" ;;
    *) return 1 ;;
  esac
}

arm_list=()
for arm in $ARMS; do
  arm_spec "$arm" >/dev/null || die "unknown arm '$arm' (base s128 s256 nobound s256nobound c2048)"
  arm_list+=("$arm")
done
[ "${#arm_list[@]}" -gt 0 ] || die "--arms is empty"

run() {
  echo "+ $*"
  if [ "$DRY_RUN" -eq 0 ]; then "$@"; fi
}

# --- preconditions (AGENTS.md "Test rules") ---------------------------------
[ "$(uname -s)" = "Darwin" ] || die "needs macOS on Apple Silicon"
[ "$(uname -m)" = "arm64" ] || die "needs an arm64 (Apple Silicon) shell, not Rosetta"
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$macos_major" -ge 26 ] || die "needs macOS 26 or newer (found $(sw_vers -productVersion))"
swift_version="$( (swift --version 2>&1 || true) | sed -n 's/.*Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)"
[ -n "$swift_version" ] || die "swift not found; install Xcode 27 (Swift 6.4+) and run xcode-select"
swift_major="${swift_version%%.*}"
swift_minor="${swift_version#*.}"
if [ "$swift_major" -lt 6 ] || { [ "$swift_major" -eq 6 ] && [ "$swift_minor" -lt 4 ]; }; then
  die "needs Swift 6.4+ (found $swift_version)"
fi

free_pct() {
  (memory_pressure -Q 2>/dev/null || true) | sed -n 's/.*free percentage: \([0-9]*\)%.*/\1/p'
}

check_quiet_machine() {
  local busy
  busy="$(pgrep -fl 'TinyTitanServer|TinyTitanCLI|TinyTitanPackageTests|swiftpm-testing-helper|mlx_lm|mlx-lm' || true)"
  [ -z "$busy" ] || die "another model or test process is running; stop it first:
$busy"
  local free
  free="$(free_pct)"
  if [ -n "$free" ] && [ "$free" -lt "$MIN_FREE_PCT" ]; then
    die "memory is under pressure (${free}% free, need ${MIN_FREE_PCT}%); close apps and retry"
  fi
}

cd "$ROOT"
stamp="$(date +%Y%m%d-%H%M%S)"
[ -n "$OUT" ] || OUT="$ROOT/benchmark/m1-spike/$stamp"
[ "$DRY_RUN" -eq 1 ] || mkdir -p "$OUT"

# --- machine record ---------------------------------------------------------
record_machine() {
  echo "commit      $(git rev-parse --short HEAD)$(git diff --quiet || echo ' (dirty)') on $(git rev-parse --abbrev-ref HEAD)"
  echo "chip        $(sysctl -n machdep.cpu.brand_string)"
  echo "memory      $(($(sysctl -n hw.memsize) / 1073741824)) GiB"
  echo "gpu cores   $(system_profiler SPDisplaysDataType 2>/dev/null | sed -n 's/.*Total Number of Cores: *//p' | head -1)"
  echo "macOS       $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "swift       $swift_version"
  echo "model       $MODEL"
  echo "arms        ${arm_list[*]+"${arm_list[*]}"}"
  echo "rounds      $ROUNDS, prompt ${PROMPT_CHARS} chars, max-new $MAX_NEW, cooldown ${COOLDOWN}s"
}
if [ "$DRY_RUN" -eq 1 ]; then record_machine; else record_machine | tee "$OUT/machine.txt"; fi

# --- build -----------------------------------------------------------------
if [ "$SKIP_BUILD" -eq 0 ]; then
  echo
  echo "== build (release) =="
  run swift build -c release
fi
BIN_DIR="$(swift build -c release --show-bin-path)"
CLI="$BIN_DIR/TinyTitanCLI"
if [ "$DRY_RUN" -eq 0 ]; then
  [ -x "$CLI" ] || die "no release TinyTitanCLI at $CLI; run without --skip-build"
  archs="$(lipo -archs "$CLI")"
  [ "$archs" = "arm64" ] || die "release binary is '$archs', expected exactly arm64"
fi

# --- tests (never load a model) ---------------------------------------------
if [ "$SKIP_TESTS" -eq 0 ]; then
  echo
  check_quiet_machine
  if [ "$FULL_TESTS" -eq 1 ]; then
    echo "== tests: full suite, serial =="
    run swift test --no-parallel
  else
    echo "== tests: the suites this branch touched, serial =="
    run swift test --no-parallel --filter \
      'FrontierTracker|PrefillProgress|RawCompletionCapture|ServerPromptStateStore|ServerArgument|HTTPServer'
  fi
fi

# --- model precondition -----------------------------------------------------
[ -d "$MODEL" ] || die "no model at $MODEL (pass --model <dir>; this script never installs one)"
[ -f "$MODEL/verified-install.json" ] \
  || die "$MODEL has no verified-install.json; it is not a completed install"

# --- the prompt: fixed repository prose, ASCII only --------------------------
prompt_file="$OUT/prompt.txt"
if [ "$DRY_RUN" -eq 0 ]; then
  # Filter to a whole file first, then cut it. Piping straight into `head -c`
  # lets head exit early, the writer die of SIGPIPE, and pipefail end the
  # script -- depending on timing, so it only fails some of the time.
  # shellcheck disable=SC2046 # the doc list is word-split on purpose
  cat $(ls "$ROOT"/docs/qwen38-*.md "$ROOT"/docs/adding-a-model.md | sort) \
    | LC_ALL=C tr -cd '\11\12\15\40-\176' >"$prompt_file.full"
  head -c "$PROMPT_CHARS" "$prompt_file.full" >"$prompt_file"
  rm -f "$prompt_file.full"
fi

results="$OUT/results.tsv"
[ "$DRY_RUN" -eq 1 ] \
  || printf 'round\tarm\tprefill_tok\tprefill_s\tprefill_tps\tdecode_tps\toccupancy_pct\tdecode_hit_pct\tdecode_gib\tmax_rss_gib\tswap_mb_delta\toutput_sha\texit\n' >"$results"

swap_used_mb() {
  (sysctl -n vm.swapusage || true) | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p'
}

run_arm() {
  local round="$1" arm="$2" spec env_part args_part log out code
  spec="$(arm_spec "$arm")"
  env_part="$(echo "$spec" | cut -d'|' -f2)"
  args_part="$(echo "$spec" | cut -d'|' -f3)"
  log="$OUT/r${round}-${arm}.log"
  out="$OUT/r${round}-${arm}.out"

  local envs=(TINYTITAN_KERNEL_STATS=1 TINYTITAN_RUNNER_STATS=1)
  if [ -n "$env_part" ]; then envs+=("$env_part"); fi
  local extra=()
  # shellcheck disable=SC2206 # arm arguments are simple words
  if [ -n "$args_part" ]; then extra=($args_part); fi

  echo
  echo "== round $round, arm $arm =="
  echo "+ env ${envs[*]+"${envs[*]}"} TinyTitanCLI --model $MODEL --prompt <prompt.txt> --max-new $MAX_NEW --temperature 0 --seed 1 --max-context 65536 ${extra[*]+"${extra[*]}"}"
  [ "$DRY_RUN" -eq 0 ] || return 0

  check_quiet_machine
  local swap_before swap_after
  swap_before="$(swap_used_mb)"
  # A failed run is recorded, not fatal; `|| code=$?` keeps both -e and the
  # ERR trap out of it.
  code=0
  /usr/bin/time -l env ${envs[@]+"${envs[@]}"} "$CLI" \
    --model "$MODEL" --prompt "$(cat "$prompt_file")" \
    --max-new "$MAX_NEW" --temperature 0 --seed 1 --max-context 65536 \
    ${extra[@]+"${extra[@]}"} >"$out" 2>"$log" || code=$?
  swap_after="$(swap_used_mb)"

  # The loader says "trusted install receipt invalid: model directory
  # mismatch"; match the part that names the cause, not the exact wording.
  if grep -q 'model directory mismatch' "$log"; then
    die "the model's install receipt names a different path (the model was moved).
$(grep -m1 '^error:' "$log" || true)
Either move it back to the path above, or re-issue the receipt in place:
  swift run -c release TinyTitanRepack --verify-install --input-gturbo \"$MODEL\""
  fi

  local footer prefill_tok prefill_s decode_tps prefill_tps occ hit gib rss sha swap_delta
  footer="$(grep -o '\[stop=[^]]*\]' "$log" | tail -1 || true)"
  prefill_tok="$(echo "$footer" | sed -n 's/.*prefill=\([0-9]*\)tok.*/\1/p')"
  prefill_s="$(echo "$footer" | sed -n 's/.*prefill=[0-9]*tok\/\([0-9.]*\)s.*/\1/p')"
  decode_tps="$(echo "$footer" | sed -n 's/.*tok\/s=\([0-9.]*\).*/\1/p')"
  prefill_tps="$(awk -v t="${prefill_tok:-0}" -v s="${prefill_s:-0}" 'BEGIN { if (s > 0) printf "%.1f", t / s; else print "" }')"
  occ="$(sed -n 's/.*(\([0-9]*\)% occupied).*/\1/p' "$log" | tail -1)"
  hit="$(sed -n 's/.*\[decode expert io\].*(\([0-9.]*\)% hit).*/\1/p' "$log" | tail -1)"
  gib="$(sed -n 's/.*\[decode expert io\].*hit) \([0-9.]*\) GiB.*/\1/p' "$log" | tail -1)"
  rss="$(awk '/maximum resident set size/ { printf "%.1f", $1 / 1073741824 }' "$log")"
  sha="$(shasum -a 256 "$out" | cut -c1-12)"
  swap_delta="$(awk -v a="${swap_before:-0}" -v b="${swap_after:-0}" 'BEGIN { printf "%.0f", b - a }')"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$round" "$arm" "${prefill_tok:--}" "${prefill_s:--}" "${prefill_tps:--}" \
    "${decode_tps:--}" "${occ:--}" "${hit:--}" "${gib:--}" "${rss:--}" \
    "$swap_delta" "$sha" "$code" >>"$results"
  echo "   exit $code  ${footer:-no footer (see $log)}  occupancy ${occ:-?}%  rss ${rss:-?} GiB  swap +${swap_delta} MB"
  if [ "$code" -ne 0 ]; then
    echo "   arm failed: $(grep -m1 '^error:' "$log" || echo "no error line; see $log")" >&2
    # The first run failing means the model or the binary is the problem, and
    # every later run would fail the same way.
    [ "$RUNS_DONE" -gt 0 ] || die "the first run failed, so the matrix stops here. Log: $log"
  fi
  RUNS_DONE=$((RUNS_DONE + 1))
}

# --- the matrix: arms interleaved, the order rotating each round -------------
RUNS_DONE=0
count="${#arm_list[@]}"
round=1
while [ "$round" -le "$ROUNDS" ]; do
  i=0
  while [ "$i" -lt "$count" ]; do
    arm="${arm_list[$(((i + round - 1) % count))]}"
    run_arm "$round" "$arm"
    if [ "$DRY_RUN" -eq 0 ] && [ "$COOLDOWN" -gt 0 ]; then sleep "$COOLDOWN"; fi
    i=$((i + 1))
  done
  round=$((round + 1))
done

[ "$DRY_RUN" -eq 0 ] || exit 0

# --- the golden check, informational ----------------------------------------
golden="not checked (model is not under models/)"
if [ "$MODEL" = "$ROOT/models/qwen3.8-flash-next_125B_A6B_4Bit" ]; then
  check_quiet_machine
  if tools/golden-baseline.sh --check qwen38-4 >"$OUT/golden.log" 2>&1; then
    golden="matches benchmark/golden"
  else
    golden="differs (see golden.log). The stored baseline is from another machine, so a
             difference is expected until one is captured here; it is not by itself a bug"
  fi
fi

# --- summary ----------------------------------------------------------------
{
  cat "$OUT/machine.txt"
  echo "golden      $golden"
  echo
  awk -F'\t' '
    NR == 1 { next }
    {
      arm = $2
      if (!(arm in seen)) { seen[arm] = 1; order[++n] = arm }
      ps[arm] = ps[arm] (ps[arm] == "" ? "" : " ") $4
      pt[arm] = pt[arm] (pt[arm] == "" ? "" : " ") $5
      dt[arm] = dt[arm] (dt[arm] == "" ? "" : " ") $6
      oc[arm] = oc[arm] (oc[arm] == "" ? "" : " ") $7
      hr[arm] = hr[arm] (hr[arm] == "" ? "" : " ") $8
      rs[arm] = rs[arm] (rs[arm] == "" ? "" : " ") $10
      sw[arm] = sw[arm] (sw[arm] == "" ? "" : " ") $11
      sh[arm] = sh[arm] (sh[arm] == "" ? "" : " ") $12
      if ($13 != 0) failed[arm]++
      if ($4 + 0 > 0) { sum[arm] += $4; k[arm]++ }
    }
    END {
      printf "%-12s %-18s %-14s %-13s %-9s %-11s %-10s %-9s %s\n", \
        "arm", "prefill s", "prefill tok/s", "decode tok/s", "occ %", "dec hit %", "rss GiB", "swap MB", "output"
      for (i = 1; i <= n; i++) {
        a = order[i]
        split(sh[a], hs, " "); split(sh["base"], bs, " ")
        same = (a == "base") ? "reference" : ((hs[1] == bs[1]) ? "same as base" : "DIFFERS from base")
        if (failed[a]) same = same ", " failed[a] " failed"
        printf "%-12s %-18s %-14s %-13s %-9s %-11s %-10s %-9s %s\n", \
          a, ps[a], pt[a], dt[a], oc[a], hr[a], rs[a], sw[a], same
      }
      print ""
      print "Values are per round, in round order; read the spread before the mean."
      if (k["base"] > 0) {
        b = sum["base"] / k["base"]
        for (i = 1; i <= n; i++) {
          a = order[i]
          if (a == "base" || k[a] == 0) continue
          printf "  %-12s prefill %+.1f%% vs base\n", a, 100 * (sum[a] / k[a] - b) / b
        }
      }
      print ""
      print "How to read it:"
      print "  occ % on base well under 90 -> prefill is waiting on the SSD here, unlike the M3;"
      print "     s256 and a >4096 chunk are the levers to build on."
      print "  c2048 much slower than base -> prefill cost tracks the chunk count;"
      print "     an 8K/16K chunk (needs code: PrefillRuntimeConfig.maxChunkTokens) should pay."
      print "  s256 faster with swap +0 -> run with --expert-cache-slots 256 (or --ram-budget) now."
      print "  nobound faster -> the page-cache trade pays on this machine (TINYTITAN_BOUNDED_IO=0)."
      print "  c2048 may legitimately differ in output (different chunking); the others should not."
    }' "$results"
} | tee "$OUT/summary.txt"

echo
echo "results: $OUT"
