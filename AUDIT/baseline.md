# Baseline (primary host mac-mini-m3, commit e952b43 + audit artifacts)

Recorded once, on the primary host, before any fix. No later state may be worse
on any metric here without a justified numbered task.

## Build

| Metric | Value | Command |
| --- | --- | --- |
| Clean release build | **success, 0 warnings** | `swift build -c release --scratch-path /tmp/tt-audit-scratch` (log `/tmp/audit-release-build.log`) |
| Clean release build time | 131.05 s (dry run, release.sh); 85.77 s (publish pass) | `tools/release.sh v5.11` |
| Debug/test build warnings | 1 (see below) | `swift test` build |
| Swift language mode | Swift 6 (`swiftLanguageModes: [.v6]`) | `Package.swift:246` |
| Swift strict concurrency | complete (enforced; probe fails) | AUDIT/tool-coverage.md |
| Swift warnings-as-errors | **not enforced** (AUD-002) | probe built with exit 0 |
| C standard in force | none declared (`-O2` only) (AUD-003) | `Package.swift:68` |

Known test-target warning:

```
tests/TinyTitanServer/CompactionTests.swift:328:96: warning: result of call to 'contains' is unused [#NoUsage]
```

## Tests

| Metric | Value | Command |
| --- | --- | --- |
| Swift tests | **1,493 passed in 223 suites, 0 failures** | `swift test --no-parallel` (release dry run + publish pass) |
| Swift tests under TSan | memory targets green (1 + 59 + 162 + 24 tests) | `swift test --sanitize=thread --filter Memory` |
| Python benchmark suite | **299 passed, 52 skipped, 0 failures** | `cd benchmark && python3 -m unittest discover -p "test_*.py"` |
| Plugin tests | dsh-tinytitan 66 (65 pass, 1 skip), dsh-lan-manager 107 pass | CI "Plugin tests (harness-version pins)" |
| Coverage | **not measured** | — (see AUD-014) |

## Linters / analysers

| Tool | Scope | Baseline |
| --- | --- | --- |
| `tools/lint.sh` (6 gates) | repo | clean: force-cast, func-length (2,031 functions, 0 new), unchecked-sendable, converter-expert-order, arch-path, shell-portability (20 scripts, bash 3.2.57) |
| swiftlint 0.65.1 `--strict` (no config) | repo | 168,918 total; `.build/` vendored 164,440; **project: sources 2,788, tests 1,660, other 30** (AUD-005) |
| swift-format 603.0.0 | repo | no config committed (AUD-004) |
| ruff 0.16.7 check | benchmark, tools | **386** findings (131 auto-fixable); includes F821 x4, F841 x6, DTZ005 x8, S110 x1, PLW1508 x4 (AUD-006) |
| ruff format --check | benchmark, tools | 104 of 108 files would be reformatted |
| shellcheck 0.11.0 `-S warning` | tools/*.sh | **14** warnings: SC2034 x9, SC2115 x2, SC2088 x2, SC2194, SC2164, SC2155, SC2120 (AUD-010) |
| eslint / prettier | plugins | not configured (AUD-012) |

## Dependencies (CVE scan)

`osv-scanner 2.6.0 scan source -L Package.resolved`: 11 Swift packages scanned,
**1 affected package, 3 vulnerabilities** — `github.com/apple/swift-nio` 2.99.0
(GHSA-rj37-6j9x-74q6 8.7, GHSA-r3rc-9hpw-54v9 8.3, GHSA-cq87-8r7h-962v 6.3; all
fixed in 2.100.0) → **AUD-001**.

Plugin packages declare zero runtime dependencies (`dependencies: None`), so npm
audit has nothing to report today; no lockfile exists to pin that (AUD-012).
Python scripts have no requirements/lock file; `pip-audit` is therefore not
applicable at baseline.

## Secret scan (full history, once)

`gitleaks 8.30.1 detect --log-opts="--all"`: 1,035 commits, ~14.3 MB scanned,
**3 findings, all confirmed false positives** (memory-key strings and a model
identifier matched by `generic-api-key`); no live-looking credential in any
commit → AUD-011 (config/suppression), and no S0 security finding from this pass.

## Repository hygiene (L0, first pass)

- `models/` (244 GB) and `.build/` are gitignored; `git ls-files models` is empty.
- `Package.resolved` is committed (11 pins) — good; `swift-nio` is an exact pin.
- CI runs two third-party actions (`actions/checkout@v4`, `actions/setup-node@v4`)
  at major-version tags, not commit SHAs (supply-chain note, reviewed in Phase B).
- CodeQL (Swift) fails in CI on a known extractor error unrelated to the tree.
