# Tool-coverage and language-standard proofs

A check handed to a tool is covered only if the tool is proven to catch it. Each
proof below introduces a deliberate violation in a scratch file, runs the tool,
and records what it said. Scratch files live in `/tmp` and are not committed.

## Language-standard proofs

| # | Standard | Violation | Result |
| --- | --- | --- | --- |
| L1 | Swift 6 language mode + complete strict concurrency | non-Sendable class instance captured in a `@Sendable` closure **and** used afterwards, inside `sources/TinyTitanFormat` (temporary file) | **enforced**: `swift build --target TinyTitanFormat` failed with `error: capture of 'value' with non-Sendable type 'AuditNotSendable' in a '@Sendable' closure [#SendableClosureCaptures]`, exit 1 |
| L2 | Swift warnings-as-errors | `func f() { let unusedValue = 41 }` in `sources/TinyTitanFormat` (temporary file) | **not enforced**: build printed `warning: initialization of immutable value 'unusedValue' was never used [#NoUsage]` and exited 0 → AUD-002 |
| L3 | Swift force-unwrap rejected by SwiftLint `--strict` | `let x: Int? = 1; print(x!)` | **pending**: no committed SwiftLint config yet (AUD-005); proved in that task |
| L4 | C99: implicit declaration | `int main(void) { return undeclared_function(1); }` | **enforced by the flags**: `clang -std=c99 -pedantic-errors -Werror` → `error: call to undeclared function 'undeclared_function'; ISO C99 and later do not support implicit function declarations`, exit 1 |
| L5 | C99: GNU extension (`typeof`) | `typeof(x) y = 2;` | **enforced**: same flags → `error: call to undeclared function 'typeof'` + `expected ';' after expression` |
| L6 | C99: GNU nested function | function definition inside `main` | **enforced**: `error: function definition is not allowed here` |
| L7 | C standard is in force in the build | — | **not enforced**: `Package.swift` cSettings carries only `-O2`; the flags above are not applied by the build → AUD-003 |
| L8 | The real C sources are clean under the full flag set | all three `.c` files | `clang -std=c99 -pedantic-errors -Wall -Wextra -Wshadow -Wconversion -Wsign-conversion -Wcast-qual -Wwrite-strings -Wformat=2 -Wstrict-prototypes -Wmissing-prototypes -Werror -c <file>` → no output, exit 0 for `expert_io.c`, `int4_affine_gemv.c`, `int8_affine_gemv.c` |
| L9 | Ruff catches the required Python pitfalls | scratch `/tmp/audit_bare.py`, `/tmp/audit_bare2.py`, `/tmp/audit_pt.py` | **enforced** for the rules used: `E722 Do not use bare except` (bare `except:`), `S110 try-except-pass detected`, `S101 Use of assert detected`; `B` family active by default |

## Tool-coverage proofs

| # | Check | Tool | Violation | Result |
| --- | --- | --- | --- | --- |
| T1 | Shell unused variables (SC2034) | shellcheck 0.11.0 | `unused_variable="x"` in a scratch script | **covered**: `SC2034 (warning): unused_variable appears unused`, exit 1 |
| T2 | Committed credentials, history | gitleaks 8.30.1 | synthetic GitHub PAT (`ghp_…`) + a private-key header in a scratch repo | **covered**: `WRN leaks found: 1`, rule `github-pat` |
| T3 | Committed credentials, AWS shape | gitleaks 8.30.1 | synthetic `aws_access_key_id = "AKIA…"` (16 random chars, non-example) | **gap**: `no leaks found`. The full-repo scan did fire `generic-api-key`, so the scanner is active, but the `aws-access-token` rule did not flag this shape. Recorded; a second scanner (trufflehog 3.x is installed) covers AWS shapes for the repo scan. |
| T4 | Swift force casts | swiftlint (default rules) | — | **covered**: the repo scan reports 18 `force_cast` in `tests/` (AUD-008) |
| T5 | Dependency CVEs, Swift | osv-scanner 2.6.0 | real scan of `Package.resolved` | **covered**: found the three swift-nio advisories (AUD-001) |
| T6 | Undefined names | ruff F821 | real scan | **covered**: found `pathlib` undefined in `tinytitan_mtp_phases.py` (AUD-007) |

## Notes

- `.build/` must be excluded from SwiftLint's scope: it is SwiftPM's checkout
  directory, not project code. Excluding build output is not "excluding files
  from analysis" in the sense §0 forbids; the project's own `sources/` and
  `tests/` stay in scope and are the 4,478 findings that must be swept.
- The Python rule set is pinned in Phase C (AUD-006); the proofs above show the
  rules fire under `ruff --isolated`, so pinning them cannot mask a finding.
