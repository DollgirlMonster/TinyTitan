# Audit environment

Pre-production audit of `Pummelchen/TinyTitan`, branch `audit/2026-09-25`, base
commit `e952b43`. One primary host runs the baseline and every fix; §1b's single
independent host for Phase E is recorded as a blocked item (AUD-013).

## Hosts

| Host | Role | OS | Notes |
| --- | --- | --- | --- |
| mac-mini-m3 (this machine) | primary host | macOS 27.x, Apple Silicon (M3), 24 GiB | Apple-platform work belongs here; only host with the required toolchain |
| ternak-macbook | none | macOS 12.7.6 | cannot run Swift 6.4 / Xcode 27; not usable for Phase E (AUD-013) |

Everything installed for this audit is listed below; nothing was installed on a
remote host.

## Language toolchains

| Language | Tool | Version | Install method | Purpose |
| --- | --- | --- | --- | --- |
| Swift | swift (swift-driver 1.168.6) | Apple Swift 6.4 (swiftlang-6.4.0.34.1) | Xcode 27.0 (27A266a) at /Applications/Xcode.app | compiler |
| Swift | xcodebuild | Xcode 27.0, build 27A266a | — | verified `xcode-select -p` = /Applications/Xcode.app/Contents/Developer |
| Swift | swift-format | 603.0.0 | Homebrew (`/opt/homebrew/bin/swift-format`) | formatter |
| Swift | swiftlint | 0.65.1 | Homebrew | linter (to be run with `--strict`) |
| Swift/C | clang (Apple) | Xcode 27.0 toolchain | — | C compiler for the strict-C99 gate |
| Python | python3 | 3.14.7 | system | scripts |
| Python | ruff | 0.16.7 | Homebrew | formatter + linter (`--fix`) |
| Python | pip-audit | missing | — | required only if a requirements/lock file exists; none does (AUDIT/baseline.md) |
| JavaScript | node | v26.8.2 | system | plugin tests |
| JavaScript | npm | 12.0.2 | system | — |
| C/Swift deps | osv-scanner | 2.6.0 (osv-scalibr 0.5.2) | Homebrew | dependency/CVE scan |
| all | gitleaks | 8.30.1 | Homebrew | secret scan, full history |
| all | trufflehog | present | Homebrew | second secret scanner (not required; gitleaks used) |
| shell | shellcheck | 0.11.0 | Homebrew | shell linter |
| shell | shfmt | present | Homebrew | shell formatter (not yet wired) |

Not installed, and why: `eslint`/`prettier` (the JS packages have zero
dependencies and no lint configuration — AUD-012 records the gap rather than
installing a toolchain with no config to run); `pip-audit` (no requirements or
lock file exists for the Python scripts; recorded in the baseline).

## Language standards actually in force

| Language | Standard | In force? | Evidence |
| --- | --- | --- | --- |
| Swift | Swift 6.4 (Xcode 27) | yes | `swift --version`, `xcodebuild -version` above |
| Swift | Swift 6 language mode | yes | `Package.swift` `swiftLanguageModes: [.v6]`; probe fails the build |
| Swift | complete strict concurrency | yes | probe: non-Sendable capture in a `@Sendable` closure fails `swift build` with `[#SendableClosureCaptures]` (AUDIT/tool-coverage.md) |
| Swift | warnings-as-errors | **no** | a probe with an unused-value warning built with exit 0 (AUD-002) |
| Swift | swift-format config, SwiftLint `--strict` config | **no** | no config committed (AUD-004, AUD-005) |
| C | strict C99 + hardening warnings + -Werror | **no** | `cSettings` carries only `-O2` (AUD-003); the code itself is clean under the full flag set |
| Python | Ruff with B/E722/S101/PT, formatter | **no config** | rules exist in ruff 0.16.7 and are proven to fire (AUDIT/tool-coverage.md), but nothing pins them (AUD-006) |

A standard with "no" above is not enforced and is carried as an open ledger task;
none of them was relaxed to make anything compile.

## Commands used (reproducible)

```bash
swift build -c release --scratch-path /tmp/tt-audit-scratch   # clean-build baseline
osv-scanner scan source -L Package.resolved --format json
gitleaks detect --source . --log-opts="--all" --report-format json --report-path /tmp/audit-gitleaks.json
ruff check benchmark tools --statistics
ruff format --check benchmark tools
swiftlint lint --strict --quiet --reporter json
shellcheck -S warning tools/*.sh
```
