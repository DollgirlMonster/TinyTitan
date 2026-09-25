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
| Swift | swift-format | Xcode 27 toolchain build (reports `main`); a Homebrew copy 603.0.0 also exists and agrees on this tree | bundled with the pinned Xcode 27 / Swift 6.4 toolchain, invoked as `xcrun swift-format` | formatter, enforced as the eleventh gate under the committed `.swift-format` |
| Swift | swiftlint | 0.65.1 | Homebrew locally; the pinned `portable_swiftlint.zip` release binary in CI | linter, run with `--strict` under the committed `.swiftlint.yml` (`tools/lint.sh swiftlint`, SWIFTLINT_PIN) |
| Swift/C | clang (Apple) | Xcode 27.0 toolchain | — | C compiler for the strict-C99 gate |
| Python | python3 | 3.14.7 locally; **CI pinned to 3.13** (`actions/setup-python@v5`); the code floor is 3.13 | system locally, GitHub action in CI | the scripts; `tools/lint.sh python` parses every file at the floor so a 3.14-only construct cannot land (AUD-017) |
| Python | ruff | 0.16.7 | Homebrew (local), `python3 -m pip install --user ruff==0.16.7` in CI | formatter + linter (`--fix`); pinned by `tools/lint.sh`'s RUFF_PIN and installed by `.github/workflows/ci.yml` |
| Python | pip-audit | missing | — | required only if a requirements/lock file exists; none does (AUDIT/baseline.md) |
| JavaScript | node | v26.8.2 locally; **CI pinned to 22** (`actions/setup-node@49933ea`) | system locally, GitHub action in CI | the plugin packages declare `engines.node >=22`; `tools/lint.sh javascript` fails below that floor |
| JavaScript | npm | 12.0.2 | system | `npm ci` from each package's committed `package-lock.json` |
| JavaScript | eslint | 10.11.0 (with `@eslint/js` 10.0.1, `globals` 17.12.0) | per-package devDependency, exact-pinned, installed with `npm ci` | linter (`tools/lint.sh javascript`, ESLINT_PIN) |
| JavaScript | prettier | 3.9.9 | per-package devDependency, exact-pinned, installed with `npm ci` | formatter (`tools/lint.sh javascript`, PRETTIER_PIN) |
| C/Swift deps | osv-scanner | 2.6.0 (osv-scalibr 0.5.2) | Homebrew | dependency/CVE scan |
| all | gitleaks | 8.30.1 | Homebrew | secret scan, full history |
| all | trufflehog | present | Homebrew | second secret scanner (not required; gitleaks used) |
| shell | shellcheck | 0.11.0 | Homebrew locally; the pinned release binary in CI | linter; `tools/lint.sh shellcheck` pins SHELLCHECK_PIN and fails on a version mismatch |
| shell | shfmt | present | Homebrew | shell formatter (not yet wired) |

Not installed, and why: `pip-audit` (no requirements or lock file exists for the
Python scripts; recorded in the baseline). `shfmt` is present but not wired as a
gate — shellcheck plus the portability check cover the scripts' correctness, and
the formatter would be churn for 20 shell files with no reproducibility gain.
`eslint`/`prettier` are no longer in this list: AUD-012 pinned them per package
and wired them as the `javascript` gate.

## Language standards actually in force

| Language | Standard | In force? | Evidence |
| --- | --- | --- | --- |
| Swift | Swift 6.4 (Xcode 27) | yes | `swift --version`, `xcodebuild -version` above |
| Swift | Swift 6 language mode | yes | `Package.swift` `swiftLanguageModes: [.v6]`; probe fails the build |
| Swift | complete strict concurrency | yes | probe: non-Sendable capture in a `@Sendable` closure fails `swift build` with `[#SendableClosureCaptures]` (AUDIT/tool-coverage.md) |
| Swift | warnings-as-errors | yes | `-warnings-as-errors` in `tinytitanLanguageStandard` (AUD-002); a probe with an unused-value warning fails `swift build` |
| Swift | SwiftLint `--strict` under the committed config | yes | `.swiftlint.yml` committed (AUD-005/019/020/021); `tools/lint.sh swiftlint` runs it with SWIFTLINT_PIN 0.65.1 and the tree is at 0 findings |
| Swift | swift-format config | yes | `.swift-format` committed (4-space indentation; `AlwaysUseLowerCamelCase` off with the AUD-018 numerical-vocabulary reason, everything else default); `tools/lint.sh swift-format` runs `xcrun swift-format lint --strict` over sources/tests/benchmark/Package.swift and the tree is at 0 findings (AUD-004) |
| C | strict C99 + hardening warnings + -Werror | yes | `cSettings` carries `-std=c99 -pedantic-errors` plus the hardening set with `-Werror` (AUD-003); a probe with an implicit declaration fails the build |
| Python | Ruff with B/E722/S101/PT, formatter | yes | `pyproject.toml` pins the rule families and target; `tools/lint.sh python` runs `ruff check .` + `ruff format --check .` with RUFF_PIN 0.16.7 and FAILS if ruff is missing or a different version; CI installs that exact version. PT009/PT027 are excluded with the reason in the config (unittest suite) (AUD-006/017) |
| JavaScript | eslint + prettier over the plugin packages | yes | each package pins eslint 10.11.0 / prettier 3.9.9 exactly and locks them in `package-lock.json`; `tools/lint.sh javascript` runs both and FAILS when the installed version differs or the package has no toolchain (AUD-012) |

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
tools/lint.sh                       # all ten gates, the same command CI runs
(cd plugins/dsh-tinytitan && npm ci && npm run lint && npm run format:check && npm test)
(cd plugins/dsh-lan-manager && npm ci && npm run lint && npm run format:check && npm test)
```
