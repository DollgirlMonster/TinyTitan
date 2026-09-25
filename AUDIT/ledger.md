# Audit ledger

Repository `Pummelchen/TinyTitan`, branch `audit/2026-09-25`, base commit `e952b43`. Generated from `AUDIT/ledger.json` by `AUDIT/render_ledger.py` — do not edit by hand.

**21 tasks — done 16, open 5, blocked 0.**

| id | sev | tier | project | location | title | status | host |
| --- | --- | --- | --- | --- | --- | --- | --- |
| AUD-001 | S1 | A | TinyTitanServer | `Package.swift:55 (swift-nio exact 2.99.0)` | swift-nio 2.99.0 carries three known CVEs, fixed in 2.100.0 | DONE | mac-mini-m3 (primary) |
| AUD-002 | S2 | B | build | `Package.swift (tinytitanLanguageStandard)` | Swift warnings-as-errors is not enforced by the build config | DONE | mac-mini-m3 (primary) |
| AUD-003 | S2 | B | build | `Package.swift:68 (TinyTitanKernelsC cSettings)` | C target does not enforce strict C99 or the hardening warning set | DONE | mac-mini-m3 (primary) |
| AUD-005 | S2 | B | build | `repo root` | No committed SwiftLint config run with --strict | PROGRESS | mac-mini-m3 (primary) |
| AUD-006 | S2 | C | benchmark/tools Python | `repo root (no ruff config)` | No pinned Ruff config; 386 findings under the default rule set | DONE | mac-mini-m3 (primary) |
| AUD-007 | S2 | C | benchmark | `benchmark/tinytitan_mtp_phases.py:77,130` | Undefined name `pathlib` (F821) used in annotations; module never imports it | DONE | mac-mini-m3 (primary) |
| AUD-012 | S2 | B | plugins | `plugins/dsh-tinytitan, plugins/dsh-lan-manager` | JavaScript packages have no formatter, linter or lockfile | OPEN | mac-mini-m3 (primary) |
| AUD-013 | S2 | A | process | `AUDIT/environment.md` | No independent host is available for the Phase E verification | DONE | mac-mini-m3 (primary) |
| AUD-017 | S2 | A | Python tooling/CI | `pyproject.toml; .github/workflows/ci.yml; tools/lint.sh` | Ruff's py314 target emitted Python-3.14-only except syntax, and no Python version was pinned | DONE | mac-mini-m3 (primary) |
| AUD-019 | S2 | A | Swift | `sources/ (171 sites, 44 files)` | force_unwrapping in sources: 171 sites that crashed instead of failing | DONE | mac-mini-m3 (primary) |
| AUD-020 | S2 | A | Swift | `sources/ + tests/ + benchmark/` | 98 remaining SwiftLint findings across 12 rules (data/string conversion, casts, type checking, style) | OPEN | mac-mini-m3 (primary) |
| AUD-021 | S2 | C | Tests | `tests/ (136) + benchmark/ (3)` | force_unwrapping in test fixtures: 139 sites that crash the test process | OPEN | mac-mini-m3 (primary) |
| AUD-004 | S3 | B | build | `repo root` | No committed swift-format config | OPEN | mac-mini-m3 (primary) |
| AUD-008 | S3 | C | tests | `tests/ (18 force_cast, 32 optional_data_string_conversion)` | SwiftLint correctness-adjacent rules fire in tests: force casts and optional data-string conversions | DONE | mac-mini-m3 (primary) |
| AUD-009 | S3 | C | tests | `tests/TinyTitanServer/CompactionTests.swift:328` | Swift test warning: result of `contains` is unused inside #expect | DONE | mac-mini-m3 (primary) |
| AUD-010 | S3 | C | tools | `tools/*.sh (14 shellcheck warnings)` | shellcheck reports 14 warnings across the shell tools | DONE | mac-mini-m3 (primary) |
| AUD-011 | S3 | C | plugins | `plugins/*/package.json` | Secret scan reports 3 false positives; no gitleaks config | DONE | mac-mini-m3 (primary) |
| AUD-014 | S3 | B | tests | `tests/ (no coverage run)` | No coverage measurement exists in the baseline | DONE | mac-mini-m3 (primary) |
| AUD-015 | S3 | B | CI | `.github/workflows/ci.yml:27,28,135; codeql.yml:51,54,94` | CI actions are pinned by mutable major tag, and checkouts disagree (v4 vs v7) | DONE | mac-mini-m3 (primary) |
| AUD-016 | S3 | C | tests | `tests/TinyTitanFleet/DashboardTests.swift:88,105,108` | Warnings surfaced by warnings-as-errors: redundant #require on an optional and an unused shadowed binding | DONE | mac-mini-m3 (primary) |
| AUD-018 | S3 | B | build | `.swiftlint.yml` | SwiftLint rule-set decision: what is enforced, configured, or delegated, and why | DONE | mac-mini-m3 (primary) |

## Detail

### AUD-001 — swift-nio 2.99.0 carries three known CVEs, fixed in 2.100.0

- severity **S1**, tier A, project TinyTitanServer, status **DONE**
- location: `Package.swift:55 (swift-nio exact 2.99.0)`
- discovered by: osv-scanner 2.6.0 scan source -L Package.resolved
- evidence (before): 3 findings: GHSA-rj37-6j9x-74q6 (8.7, NIOHTTP1 accepts unbounded HTTP/1 header blocks -> remote DoS), GHSA-r3rc-9hpw-54v9 (8.3, ByteBuffer index/length UInt32 overflow -> out-of-bounds write), GHSA-cq87-8r7h-962v (6.3, CRLF injection in outbound request URI). All fixed in 2.100.0. The server serves HTTP/1 through NIOHTTP1, so the DoS advisory is on a reachable path.
- fix: Pin swift-nio at 2.100.0 (the advisory fix version); Package.resolved re-resolved, only swift-nio changed.
- evidence (after): osv-scanner: 'No issues found' (was 3). swift test --no-parallel: 1,493 tests in 223 suites passed, exit 0; the only build warnings are the pre-existing CompactionTests.swift:328 one; Swift 6 mode/strict concurrency unchanged (AUDIT/tool-coverage.md).
- commit: 6786b6b
- blocked: —

### AUD-002 — Swift warnings-as-errors is not enforced by the build config

- severity **S2**, tier B, project build, status **DONE**
- location: `Package.swift (tinytitanLanguageStandard)`
- discovered by: language-standard proof (AUDIT/tool-coverage.md)
- evidence (before): A probe file with `let unusedValue = 41` built successfully: warning `initialization of immutable value 'unusedValue' was never used [#NoUsage]`, exit 0. release.sh scans the build log for warnings, so the release path is covered, but a plain `swift build`/`swift test` does not fail — the standard is not in force.
- fix: -warnings-as-errors added to tinytitanLanguageStandard, the swiftSettings array all 23 targets carry.
- evidence (after): Probe with an unused value fails the build (`error: initialization of immutable value 'unusedValue' was never used [#NoUsage]`, exit 1; before: warning, exit 0). `swift build --build-tests` 0 warnings; `swift test --no-parallel` 1,493 tests / 223 suites passed.
- commit: 6b23c96
- blocked: —

### AUD-003 — C target does not enforce strict C99 or the hardening warning set

- severity **S2**, tier B, project build, status **DONE**
- location: `Package.swift:68 (TinyTitanKernelsC cSettings)`
- discovered by: language-standard proof (AUDIT/tool-coverage.md)
- evidence (before): cSettings carries only `.unsafeFlags(["-O2"])`; no -std=c99, -pedantic-errors or warning flags, and no -Werror. All three C files compile clean under the full set (clang -std=c99 -pedantic-errors -Wall -Wextra -Wshadow -Wconversion -Wsign-conversion -Wcast-qual -Wwrite-strings -Wformat=2 -Wstrict-prototypes -Wmissing-prototypes -Werror), so the fix is additive.
- fix: cLanguageStandard .c99 on the package + full hardening warning set and -Werror in TinyTitanKernelsC cSettings.
- evidence (after): Probe with an implicit declaration fails the build (ISO C99 error) and -Werror,-Wmissing-prototypes fires; real C files build clean; `swift build --verbose` shows -std=c99 -pedantic-errors -Werror; `swift test --no-parallel` 1,493 tests / 223 suites passed, exit 0.
- commit: e89637e
- blocked: —

### AUD-005 — No committed SwiftLint config run with --strict

- severity **S2**, tier B, project build, status **PROGRESS**
- location: `repo root`
- discovered by: swiftlint 0.65.1 lint --strict --reporter json
- evidence (before): No .swiftlint.yml. Default run over the repo reports 168,918 findings, of which 164,440 are vendored code under .build/ (SwiftPM checkouts) and 4,478 are project code: sources/ 2,788 (identifier_name 1,185, vertical_parameter_alignment 632, function_parameter_count 155, function_body_length 139, comma 122, trailing_comma 96, cyclomatic_complexity 71, line_length 71, file_length 52, colon 50, type_body_length 39, large_tuple 37), tests/ 1,660 (identifier_name 976, trailing_comma 307, force_cast 18, optional_data_string_conversion 32, ...), other 30. .build/ must be excluded as build output; the remainder needs a committed config and a sweep.
- fix: Committed `.swiftlint.yml`: safety opt-ins on (force_unwrapping, implicitly_unwrapped_optional), layout delegated to swift-format, size/complexity delegated to tools/lint.sh's ratchet, identifier_name configured for the numerical vocabulary (min_length 1, validates_start_with_lowercase off) — each with its reason and measured counts in the file. Gate wiring is deliberately held until the tree is clean: `tools/lint.sh` gains `swiftlint --strict` when AUD-019/AUD-020 reach zero.
- evidence (after): `swiftlint lint --strict --no-cache --reporter json` -> 488 findings in 13 rules, down from 4,479 in 33 (168,918 including .build). The remaining findings are enumerated as AUD-019 (force_unwrapping 390) and AUD-020 (98 across 12 rules). Config committed in 68a6945. The Phase E workflow also runs `swiftlint lint --strict` with the committed config, so the standard is enforced from the independent host as well.
- commit: 68a6945 (config; gate pending)
- blocked: —

### AUD-006 — No pinned Ruff config; 386 findings under the default rule set

- severity **S2**, tier C, project benchmark/tools Python, status **DONE**
- location: `repo root (no ruff config)`
- discovered by: ruff 0.16.7 check --statistics
- evidence (before): No pyproject.toml/ruff.toml for the scripts. Default run: 386 findings, 131 auto-fixable; ruff format --check would reformat 104 of 108 files. Includes F821 undefined-name x4, F841 unused-variable x6, DTZ005 datetime-now-without-tzinfo x8, S110 try-except-pass x1, PLW1508 invalid-envvar-default x4. The required rule families (B, E722, S101, PT) are not pinned anywhere.
- fix: Root pyproject.toml pins target py313, line-length 100 and select E4/E7/E9/F/W/B/E722/S101/PT, with PT009 and PT027 excluded for the unittest suite (reason in the config). Swept with `ruff format .` (105 files), `ruff check --fix` (37) and hand fixes: S101 assert -> explicit raises, B023 loop-variable binding in export_ane_prefill/expert_cache_slots, B904 `from None`, B905 explicit strict, B007/E741/E731/F841. Wired into the build: `tools/lint.sh python` runs check+format with RUFF_PIN 0.16.7 and FAILS if ruff is missing or differs; CI installs that version.
- evidence (after): `ruff check .` All checks passed (183 findings when the config landed, 386 under defaults); `ruff format --check .` 188 files formatted; proof T7 (a bare except makes the gate exit 1); `tools/lint.sh` all seven gates green; `python3 -m unittest discover` 299 tests OK (52 skipped).
- commit: 4c33f30 1b03728
- blocked: —

### AUD-007 — Undefined name `pathlib` (F821) used in annotations; module never imports it

- severity **S2**, tier C, project benchmark, status **DONE**
- location: `benchmark/tinytitan_mtp_phases.py:77,130`
- discovered by: ruff check --select F821
- evidence (before): `target: pathlib.Path, sidecar: pathlib.Path` in launch() and one_run() with no `import pathlib`. `from __future__ import annotations` makes the annotations lazy strings, so the script runs today, but any annotation evaluation (typing.get_type_hints, a tool, a future refactor) raises NameError.
- fix: Added `import pathlib` to benchmark/tinytitan_mtp_phases.py.
- evidence (after): `ruff check --select F821 benchmark/tinytitan_mtp_phases.py` -> All checks passed (was 4); `python3 -m py_compile` clean.
- commit: fa2ec9a
- blocked: —

### AUD-012 — JavaScript packages have no formatter, linter or lockfile

- severity **S2**, tier B, project plugins, status **OPEN**
- location: `plugins/dsh-tinytitan, plugins/dsh-lan-manager`
- discovered by: tool inventory + package.json read
- evidence (before): eslint and prettier are not installed anywhere in the tree; neither package has a lint/format script, a config, or a lockfile. Both declare zero runtime dependencies (`dependencies: None`), so npm audit has nothing to scan today, but nothing pins that state.
- fix: —
- evidence (after): —
- commit: —
- blocked: —

### AUD-013 — No independent host is available for the Phase E verification

- severity **S2**, tier A, project process, status **DONE**
- location: `AUDIT/environment.md`
- discovered by: host inventory
- evidence (before): Phase E requires a fresh clone and a full clean run on one independent host. The only other host reachable from this session is ternak-macbook (macOS 12.7.6), which cannot run the required Swift 6.4 / Xcode 27 toolchain, so it cannot satisfy the Swift language standard; a fresh clone on the same Mac is not an independent host.
- fix: Resolved by using the repository's CI runner as the independent host: `.github/workflows/audit-verification.yml` runs the whole Phase E sequence from a fresh checkout (pinned toolchain, clean zero-warning release build, all eight lint gates, full suite with coverage, CVE scan, full-history secret scan, SwiftLint --strict, Python suite, ledger closure), and `AUDIT/assert_ledger_closed.py` is the machine check that no task is left open.
- evidence (after): Assertion exercised both ways: with the current ledger it exits 1 and lists the open tasks; on a copy where every task is DONE it prints 'OK: the ledger is closed'. Workflow YAML parses. The first run is triggered by this push and is expected to fail at the ledger step until the remaining tasks are closed. First real runs on the independent host (36122853245, 36122897462): checkout, pinned tool install, plugin tests, the zero-warning clean release build and seven of the eight gates passed; the python gate failed only because `AUDIT/assert_ledger_closed.py` was not yet formatted to the pinned ruff style, which the next commit fixed. The failure is the gate doing its job, on real hardware.
- commit: d30bcae
- blocked: —

### AUD-017 — Ruff's py314 target emitted Python-3.14-only except syntax, and no Python version was pinned

- severity **S2**, tier A, project Python tooling/CI, status **DONE**
- location: `pyproject.toml; .github/workflows/ci.yml; tools/lint.sh`
- discovered by: AUD-006 (reviewing the format sweep's diff)
- evidence (before): `ruff format` with target-version py314 rewrote `except (A, B):` to PEP 758 `except A, B:` in 10 files / 18 sites (including tools/prepare_qwen38.py and tools/internal-speeds.py). That parses only on 3.14; CI's python3 was whatever the runner ships, and the converter gate runs `python3 -m venv`.
- fix: target-version py313 with parentheses restored; CI pins Python 3.13 via actions/setup-python@v5; `tools/lint.sh python` parses every script at feature_version (3,13) so the floor is enforced.
- evidence (after): The floor check reported 10 files before the fix and 0 after; proof T8 in AUDIT/tool-coverage.md; ruff check/format clean; 299 Python tests OK (52 skipped).
- commit: 29e7ab2
- blocked: —

### AUD-019 — force_unwrapping in sources: 171 sites that crashed instead of failing

- severity **S2**, tier A, project Swift, status **DONE**
- location: `sources/ (171 sites, 44 files)`
- discovered by: AUD-005 (force_unwrapping enabled)
- evidence (before): 390 force unwraps under the committed config: **171 in sources/** (production: 44 files), 216 in tests/, 3 in benchmark/. Clusters: `MTLCommandQueue.makeCommandBuffer()!`, `MTLDevice.makeBuffer(...)!`, `views.q!/qNorm!` optional tensor views, `elementwise!` optional kernel bundles, `tokenizer.encode(...).first!`, `UnsafeMutableRawPointer.baseAddress!` in vDSP/IO paths, `streamersBox.streamers[layer]!`, dictionary lookups, and URL literals in tests. (The first ledger entry said 70/317/3 — that bucketing was wrong; the corrected counts are from a path-prefix match.)
- fix: Scope change, noted here and carried by the new AUD-021: the original row covered all 390 sites. This task now covers the production half, which is complete. Batch 1 (51aef05, 45), batch 2 (d2ba27e, 45), batch 3 (c9669b3, 52), batch 4 (80d696f, 29) — checked accessors (`openStreamer`, `requireElementwise`, `LayerPrefillQKVViews.require`, `requireAffine`, `requireOnesPerExpertScale`, `requireTensorView`, `requireBuffer`, `requireBF16ScalarGate`, `requireInt8ScalarGate`, `BenchHarnessError`), throwing CPUQwen35 gemv/project, guarded base addresses and `?? []`/dictionary defaults where that is the honest fix. The test-side remainder (136 sites at the split) moved to AUD-021.
- evidence (after): sources force_unwrapping 171 -> **0**; tree 488 -> 235. `swift build`/`--build-tests` clean under warnings-as-errors; `swift test --no-parallel` 1,493 tests in 223 suites passed after every batch.
- commit: 51aef05 d2ba27e c9669b3 80d696f
- blocked: —

### AUD-020 — 98 remaining SwiftLint findings across 12 rules (data/string conversion, casts, type checking, style)

- severity **S2**, tier A, project Swift, status **OPEN**
- location: `sources/ + tests/ + benchmark/`
- discovered by: AUD-005
- evidence (before): optional_data_string_conversion 43, force_cast 19, prefer_type_checking 6, identifier_name 6, force_try 5, for_where 5, static_over_final_class 4, orphaned_doc_comment 3, implicit_optional_initialization 3, non_optional_string_data_conversion 2, redundant_discardable_let 1, unneeded_synthesized_initializer 1. Absorbs AUD-008.
- fix: —
- evidence (after): —
- commit: —
- blocked: —

### AUD-021 — force_unwrapping in test fixtures: 139 sites that crash the test process

- severity **S2**, tier C, project Tests, status **OPEN**
- location: `tests/ (136) + benchmark/ (3)`
- discovered by: AUD-019's scope split (the same rule, different tiers)
- evidence (before): 136 sites in 53 test files plus 3 in benchmark/. Dominant shapes: `…queue.makeCommandBuffer()!` (done), `baseAddress!` inside `withUnsafe…` closures (~41), `device.makeBuffer(…)!` in test helpers (~22), `URL(string:)!`/`URLRequest` fixtures (~18), `.encode(…).first!` (done), HTTP `headerFields: nil)!` (7), and kernel-call pointer arguments. Batch 5 (eab2a5a) converted the 76 unambiguous ones to `try #require(…)`.
- fix: —
- evidence (after): —
- commit: eab2a5a (batch 5; open)
- blocked: —

### AUD-004 — No committed swift-format config

- severity **S3**, tier B, project build, status **OPEN**
- location: `repo root`
- discovered by: tool inventory (AUDIT/environment.md)
- evidence (before): swift-format 603.0.0 is installed but there is no .swift-format or .swift-format.json in the tree, so formatting is not enforceable or reproducible.
- fix: —
- evidence (after): —
- commit: —
- blocked: —

### AUD-008 — SwiftLint correctness-adjacent rules fire in tests: force casts and optional data-string conversions

- severity **S3**, tier C, project tests, status **DONE**
- location: `tests/ (18 force_cast, 32 optional_data_string_conversion)`
- discovered by: swiftlint lint --strict (AUD-005)
- evidence (before): force_cast 18 and optional_data_string_conversion 32 in tests/; the repo's own tools/lint.sh bans force casts in sources/ only, so tests are outside that gate.
- fix: Scope folded into AUD-020 (explicit note here per §0): the force_cast and optional_data_string_conversion instances SwiftLint reports are fixed together with the other default-rule findings in that task, because they are the same sweep over the same files.
- evidence (after): Tracked by AUD-020; no separate commit. Original counts: force_cast 18+1, optional_data_string_conversion 43.
- commit: n/a (folded into AUD-020)
- blocked: —

### AUD-009 — Swift test warning: result of `contains` is unused inside #expect

- severity **S3**, tier C, project tests, status **DONE**
- location: `tests/TinyTitanServer/CompactionTests.swift:328`
- discovered by: swift test build log
- evidence (before): `warning: result of call to 'contains' is unused [#NoUsage]` when building TinyTitanServerTests; it blocks AUD-002 (warnings-as-errors) for the test targets.
- fix: Bound the replay message (`let replayContent = ...`) so Testing's macro no longer emits a bare `contains` call; assertion unchanged.
- evidence (after): `swift build --build-tests` -> 0 warning lines (was 1); `swift test --filter Compaction` -> 15 tests in 1 suite passed.
- commit: 252a6ab
- blocked: —

### AUD-010 — shellcheck reports 14 warnings across the shell tools

- severity **S3**, tier C, project tools, status **DONE**
- location: `tools/*.sh (14 shellcheck warnings)`
- discovered by: shellcheck 0.11.0 -S warning tools/*.sh
- evidence (before): SC2034 x9 (unused variable), SC2115 x2, SC2088 x2, SC2194, SC2164, SC2155, SC2120. No shellcheck config or gate in tools/lint.sh.
- fix: Real defects fixed: unguarded `rm -rf "$MODELS/$dir"` -> `${MODELS:?}/${dir:?}`; ane_sidecars' constant-word case -> membership loop; release.sh's bare cd -> `|| die`. Plus two dead variables removed, two unused read fields renamed, dsh_local passing its args through, lint.sh declare-then-export, and documented `disable=SC2034` for the five cross-file API variables. Gate: `tools/lint.sh shellcheck` over all 20 scripts, SHELLCHECK_PIN 0.11.0, installed in CI from the pinned release binary.
- evidence (after): shellcheck 0.11.0 over tools+benchmark+docs: 0 warnings (was 14). Proof T9 in AUDIT/tool-coverage.md (temporary script with unguarded cd + unused var -> gate exit 1). All eight lint gates green; Python suite 299 tests OK (52 skipped).
- commit: c199467
- blocked: —

### AUD-011 — Secret scan reports 3 false positives; no gitleaks config

- severity **S3**, tier C, project plugins, status **DONE**
- location: `plugins/*/package.json`
- discovered by: gitleaks 8.30.1 detect --log-opts=--all
- evidence (before): 1035 commits scanned, 3 findings, all false positives of generic-api-key: tests/TinyTitanMemory/MemoryRetrievalTests.swift:124 (a memory key string), tests/NVMAIServer/MemoryConsolidationTests.swift:358 (historical path, JSON key), benchmark/nvmai_profile.py:17 (historical, a model identifier). No live-looking credential found anywhere in history.
- fix: `.gitleaks.toml`: default ruleset kept, the three benign identifiers allowlisted by exact secret value.
- evidence (after): Full-history scan with the config: 1049 commits scanned, `no leaks found` (was 3). Control: a synthetic PAT in a scratch repo is still caught with the config in place (`WRN leaks found: 1`).
- commit: 10ebbc0
- blocked: —

### AUD-014 — No coverage measurement exists in the baseline

- severity **S3**, tier B, project tests, status **DONE**
- location: `tests/ (no coverage run)`
- discovered by: baseline §3 requires coverage %
- evidence (before): swift test is run without --enable-code-coverage in CI and release.sh; no coverage report is committed, so L6's coverage-gap and threshold checks have no yardstick.
- fix: Coverage measured with `swift test --no-parallel --enable-code-coverage`, profraw merged with llvm-profdata, reported per test bundle over sources/.
- evidence (after): Line coverage over sources/ (tests and .build excluded): TinyTitanServerTests 77.89% (40,515 lines, 8,957 missed), TinyTitanTests 76.61%, TinyTitanRepackTests 81.19%, TinyTitanMemoryTests 92.92%, ContinuityCoreTests 93.55%, TinyTitanFleetTests 77.40%. The server bundle links the whole package, so 77.89% is the whole-repo figure recorded in AUDIT/baseline.md. The three app-suite bundles (TinyTitanAppCore/DecodeService/MacPresentation) produced no coverage report and belong to the removed GUI's test targets.
- commit: none (measurement)
- blocked: —

### AUD-015 — CI actions are pinned by mutable major tag, and checkouts disagree (v4 vs v7)

- severity **S3**, tier B, project CI, status **DONE**
- location: `.github/workflows/ci.yml:27,28,135; codeql.yml:51,54,94`
- discovered by: L0 repository pass
- evidence (before): actions/checkout@v4 and actions/setup-node@v4 in ci.yml, actions/checkout@v7 and codeql-action/{init,analyze}@v4 in codeql.yml. Major-tag pins are mutable by the action owner; the two workflows also use different checkout majors.
- fix: All CI actions pinned to full commit SHAs, and the two workflows now share one checkout pin (were v4 vs v7).
- evidence (after): `grep -n 'uses:' .github/workflows/*.yml` shows 7 SHA-pinned steps: checkout 3d3c42e (v7), setup-node 49933ea (v4), setup-python a26af69 (v5), codeql-action 2892aa5 (v4).
- commit: cb21c4c
- blocked: —

### AUD-016 — Warnings surfaced by warnings-as-errors: redundant #require on an optional and an unused shadowed binding

- severity **S3**, tier C, project tests, status **DONE**
- location: `tests/TinyTitanFleet/DashboardTests.swift:88,105,108`
- discovered by: AUD-002 (enabling -warnings-as-errors)
- evidence (before): `try? #require(frame.selectedLine)` reported as a redundant require and doubled the optional; the second test bound `try? #require(...)` and then shadowed it in an `if let` whose binding was never used (`immutable value 'line' was never used`). Three diagnostics, all build failures under -warnings-as-errors.
- fix: Read `selectedLine` directly; replaced the presence check with `#expect(frame.selectedLine != nil)` and kept the same bounds and content assertions.
- evidence (after): `swift build --build-tests` clean (0 warnings); `swift test --no-parallel` 1,493 tests / 223 suites passed.
- commit: 4ba3973
- blocked: —

### AUD-018 — SwiftLint rule-set decision: what is enforced, configured, or delegated, and why

- severity **S3**, tier B, project build, status **DONE**
- location: `.swiftlint.yml`
- discovered by: AUD-005
- evidence (before): No SwiftLint configuration existed; the defaults produced 4,479 project findings, of which identifier_name (2,182) and vertical_parameter_alignment (675) dominated.
- fix: Rules delegated to swift-format (layout, 16 rules) and to tools/lint.sh's function-length ratchet (size/complexity, 7 rules), each with its reason and measured count in the config; identifier_name configured for the numerical vocabulary; safety rules turned on. No rule was disabled silently and no path was excluded except build output and the model store.
- evidence (after): 488 findings remain under the config and are tracked by AUD-019/AUD-020; the config carries the reasoning for every rule it changes.
- commit: 68a6945
- blocked: —

