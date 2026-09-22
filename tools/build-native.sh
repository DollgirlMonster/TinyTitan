#!/usr/bin/env bash
# Release build tuned for this Mac's own CPU core, instead of the portable
# Apple-Silicon baseline.
#
# `swift build -c release` passes no `-mcpu`, so clang and swiftc fall back to
# the default CPU for `arm64-apple-macos*`, which is **apple-m1**. On an M3 that
# leaves the chip's FEAT_BF16 and FEAT_I8MM unused (verified 2026-09-22: the
# Release response files contain no -mcpu/-march, and a probe built with the
# project's flags defines neither `__ARM_FEATURE_BF16` nor
# `__ARM_FEATURE_MATMUL_INT8`, where `-mcpu=apple-m3` defines both).
#
# The C `-O2` that matters for the kernels is a package default now
# (`Package.swift` sets it for `TinyTitanKernelsC`, because `swiftbuild`
# otherwise compiles C at `-Os`); this script only adds the CPU selection on top.
#
#   tools/build-native.sh                 # detect this Mac's CPU
#   tools/build-native.sh --cpu apple-m3  # name it explicitly
#   tools/build-native.sh --dry-run       # print the command, build nothing
#
# The artifact is **not portable**: it may use instructions an older core does
# not have (M3 adds BF16/I8MM over M1; M4 adds more). For a portable release use
# plain `swift build -c release`, which is what tools/release.sh does. Measured
# 2026-09-22: the CPU selection itself is worth about 1% on the CPU GEMV, inside
# the noise -- the 1.24x the first native build showed came from the C `-O2`,
# which is a package default now.
set -euo pipefail

cd "$(dirname "$0")/.."

CPU=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpu) CPU="${2:?--cpu needs a value such as apple-m3}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$CPU" ]]; then
  brand="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo)"
  case "$brand" in
    "Apple M1"*) CPU="apple-m1" ;;
    "Apple M2"*) CPU="apple-m2" ;;
    "Apple M3"*) CPU="apple-m3" ;;
    "Apple M4"*) CPU="apple-m4" ;;
    *) CPU="" ;;
  esac
  if [[ -z "$CPU" ]]; then
    echo "cannot name this CPU ('${brand:-unknown}'); pass --cpu apple-mN to override" >&2
    exit 2
  fi
  echo "detected: ${brand} -> -mcpu=${CPU}"
fi

# Swift names the CPU with the driver's hidden `-target-cpu` (it takes a value,
# so it needs two -Xswiftc arguments; `-mcpu` is a clang-frontend flag and swiftc
# rejects it: "Driver threw unknown argument: '-mcpu=apple-m3'"). C takes
# `-mcpu`. No fast-math: these are the paths whose floats a golden baseline pins.
SWIFT_FLAGS=(-Xswiftc -target-cpu -Xswiftc "${CPU}")
CLANG_FLAGS=(-Xcc "-mcpu=${CPU}")
# The `[@]+` guards are the project's bash-3.2 rule: with `set -u`, expanding an
# empty array is an error on the system bash, so the lint gate requires the guard
# even where the arrays are never empty.
COMMAND=(swift build -c release "${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}" \
  "${CLANG_FLAGS[@]+"${CLANG_FLAGS[@]}"}")

echo "flags: CPU ${CPU} for Swift and C (portable default is apple-m1; C is -O2 in both)"
if (( DRY_RUN )); then
  printf 'command:'; printf ' %q' "${COMMAND[@]+"${COMMAND[@]}"}"; echo
  exit 0
fi

"${COMMAND[@]+"${COMMAND[@]}"}"

echo
echo "built:"
for binary in TinyTitanServer TinyTitanCLI TinyTitanBench; do
  path=".build/release/${binary}"
  [[ -f "$path" ]] || continue
  printf '  %-16s %s  %s\n' "$binary" "$(shasum -a 256 "$path" | cut -c1-16)" \
    "$(stat -f '%Sm' "$path")"
done

# Prove the artifact actually executes here: it may use this core's
# instructions, so a build that links is not enough.
echo
echo "smoke:"
.build/release/TinyTitanBench cpugemv 4 2>&1 | tail -6
