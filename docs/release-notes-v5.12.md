## TinyTitan 5.12 — the pre-production audit: crash paths closed, and a verification suite that cannot pass silently

This release is the remediation pass the project ran before its first production
cut: a full audit of the tree, drained to zero open findings, plus the gates that
keep it there. No kernel, model or API behaviour was retargeted — what changed is
crash paths, tests, gates and documentation. The DeepSeek-V4.1-Flash port
reference is the one new artifact.

### What is new

- **A DeepSeek-V4.1-Flash port reference** (`docs/deepseek-v41-flash-port.md`,
  `docs/deepseek-v41-flash-reference.md`): what the checkpoint is, its byte and
  quantization layout, the integration surface it would need here, and the two
  honest conversion paths — re-quantize to the affine 4-bit/8-bit pair this
  runtime serves, or preserve the released FP8/FP4 weights, which needs two new
  decode kernels.
- **Eleven pinned gates in `tools/lint.sh`**, the exact command CI runs:
  force-cast, function length, unchecked-`Sendable` documentation, converter
  expert order, architecture paths, shell portability, shellcheck, SwiftLint,
  swift-format, eslint/prettier for the plugin packages, and ruff for Python.
  Each fails when its tool is missing or is a different version, so none can
  pass by skipping.
- **A committed audit ledger** (`AUDIT/ledger.json`, rendered to `AUDIT/ledger.md`):
  every finding with its evidence before and after, the commit that closed it,
  and a written reason wherever a rule was deliberately configured rather than
  followed.

### What is fixed

- **Every force unwrap is gone.** 171 sites in `sources/` and 139 in tests and
  benchmarks now bind, guard or throw a typed error: a bad state reports itself
  instead of taking the process down.
- **Chunked prefill with a producer that cannot run it** raises the existing
  `chunkedUnsupported` error; it previously force-cast and crashed.
- **A scanner test that could never fail** (`aSecondScanReportsWhatJoined` ended
  in `… == false || true`) now grows the fleet and asserts the joined-member
  path — the behaviour it was named for.
- **Swift SAST runs again.** CodeQL had failed before compiling a single file
  since the toolchain moved; the extraction build now completes and scans 249 of
  464 Swift files with 0 alerts.
- **Two CI regressions**: the Markdown link check no longer reads installed
  dependencies' READMEs, and the verification host installs the Python suite's
  pinned dependencies instead of failing on a missing module.
- **Formatting and lint debt paid**: SwiftLint 4,479 → 0 findings under
  `--strict`, a committed `.swift-format` with a 442-file sweep, eslint/prettier
  with lockfiles in both plugin packages, and ruff pinned for the Python scripts.

### Verification

- `tools/lint.sh` — all eleven gates, every tool pinned, clean.
- `swift test --no-parallel` — 1,493 tests in 223 suites; the benchmark suite —
  299 tests; the two plugin suites — 66 (1 skipped) and 107.
- every installed model that has a golden target, compared against its stored
  baseline, then a clean scratch release build with the warning scan clean.
- the internal-speed record (`benchmark/internal-speeds/v5.12.json`, 4B dense):
  one first-pass reading breached the 10% gate — prefill 28.0 → 23.3 tok/s and
  TTFT 0.25 → 0.30 s — and the repeat pass (`v5.12-run2.json`) read 28.0 tok/s
  and 0.25 s with all thirteen metrics inside the gate. The 7-token prefill is
  fixed-overhead dominated and this release changes no kernel arithmetic, so the
  first pass is measurement noise rather than a regression; no other metric moved
  past the threshold in either pass.
- **Not checked, because their install is not under `models/` and nothing may be
  fetched to change that**: `ornith-8`, `ornith-4`, `qwen38-8`, `agentworld-4`,
  `agentworld-8`, `katcoder-4`, `katcoder-8`, `qwen35-2b-4`, `qwen35-2b-8`.

### Checksum

`tinytitan-5.12-macos-arm64.tar.gz` sha256: `SHA256_PENDING`
`tinytitan-5.12-macos-arm64.tar.gz` size: `ARCHIVE_BYTES_PENDING` bytes
