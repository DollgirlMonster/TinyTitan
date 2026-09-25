# Audit scope, dependency graph and risk tiers

Repository: `Pummelchen/TinyTitan` at `e952b43` (branch `audit/2026-09-25`).
One product: a local LLM engine (Swift + Metal + a small C kernel layer) with a
loopback OpenAI-compatible server, a model converter/repacker, an opt-in memory
subsystem, two DeepSeek Harness plugins, and installer/release tooling.

## 2.1 Projects, languages, build systems, entry points, host

| Project | Language(s) | Build | Entry points | Primary host |
| --- | --- | --- | --- | --- |
| TinyTitan (engine) | Swift 6.4, Metal, C99 | SwiftPM (`Package.swift`, tools 6.4) | `TinyTitanCLI`, `TinyTitanBench`, `TinyTitanRepack`, library `TinyTitan` | mac-mini-m3 |
| TinyTitanServer | Swift 6.4 | SwiftPM (swift-nio) | `TinyTitanServer` binary; HTTP `/v1/chat/completions`, `/v1/responses`, `/v1/models`, `/health`, `/compact` | mac-mini-m3 |
| Continuity (memory) | Swift 6.4 | SwiftPM | library `ContinuityCore`, `tinytitan-memory` CLI | mac-mini-m3 |
| Fleet / LAN manager | Swift 6.4 + JS | SwiftPM + `node --test` | `ttlanmanager` binary; `plugins/dsh-lan-manager` plugin API | mac-mini-m3 |
| DSH plugins | JavaScript (ESM, node ≥22) | `node --test` (no bundler) | `plugins/dsh-tinytitan`, `plugins/dsh-lan-manager` | mac-mini-m3 |
| Model tooling | Python 3.14, bash 3.2 | plain scripts (`install_*.sh`, `prepare_*.py`) | `tools/install_tinytitan.sh`, `tools/install_models.sh`, `tools/prepare_*.py`, `tools/repack_dense.sh` | mac-mini-m3 |
| Benchmarks | Python 3.14, bash | plain scripts | `benchmark/*.py`, `benchmark/*.sh` | mac-mini-m3 |
| Docs/wiki | Markdown | — | `docs/`, `.qwen/wiki/` | n/a |

The Mac app and its test target (`tests/TinyTitanApp/`) are remnants of a removed
GUI; they are dead weight for this audit (Tier C) unless a build target still
references them (checked in Phase B).

## 2.2 Dependency graph (2 hops, direct deps only)

```
TinyTitanServer ──▶ TinyTitan (engine) ──▶ TinyTitanKernelsC (C, module map)
        │                 │                └▶ TinyTitanFormat ──▶ yyjson
        │                 └▶ swift-transformers ──▶ swift-huggingface, swift-jinja, swift-crypto …
        ├▶ TinyTitanMemory ──▶ ContinuityCore ──▶ swift-collections
        ├▶ swift-nio (NIOHTTP1, NIOCore, NIOPosix, NIOFoundationCompat)  ← 2-hop: swift-atomics, swift-system
        └▶ TinyTitanFormat
TinyTitanRepack ──▶ TinyTitanFormat, TinyTitan (writer path)
TinyTitanFleet (ttlanmanager) ──▶ HTTP contract with plugins/dsh-lan-manager
plugins/dsh-lan-manager ──▶ DeepSeek Harness host API + TinyTitanServer HTTP + (2-hop) DSH session/workspace store
plugins/dsh-tinytitan ──▶ DeepSeek Harness host API + TinyTitanServer HTTP + tools/dsh_route.sh (shell)
tools/*.sh ──▶ .build/release binaries, models/ layout, GitHub releases
```

Cross-project contracts (a change on either side breaks the others):

1. **HTTP API** — server ↔ plugins ↔ any OpenAI/Anthropic/Responses client. >1 consumer → Tier A.
2. **`settings.yaml` route block + agent preset** — `tools/dsh_route.sh` ↔ `plugins/dsh-tinytitan` (the generated block is pinned byte-for-byte by tests). >1 consumer → Tier A.
3. **Model directory contract** — `models/<install>/` + `verified-install.json` receipts read by the engine, `install_models.sh`, `dsh_route.sh`, the installer. >1 consumer → Tier A.
4. **DeepSeek Harness plugin ABI** — both plugins ↔ a pinned harness version (0.1.6-alpha.2). >1 consumer → Tier A.
5. **Environment-variable contract** — `TINYTITAN_*` names shared by launcher, route writer, installer, plugins, tests.

## 2.3 Trust boundaries

| Boundary | Input | Why it is a boundary |
| --- | --- | --- |
| B1 loopback HTTP server | HTTP/1 headers, JSON bodies, streaming requests, tool-call arguments | network-reachable (loopback by default, `0.0.0.0` allowed); **no authentication** by design; NIOHTTP1 parses untrusted bytes |
| B2 model files on disk | `.gturbo` manifests, safetensors shards, tokenizer JSON | parsed and, for conversion, written; malformed input reaches buffer arithmetic |
| B3 Swift↔C seam | pointers, lengths, thread pools | `TinyTitanKernelsC` via module map: `expert_io.c` owns pthreads and `pread`; kernels take raw pointers |
| B4 LLM output → privileged action | model-authored tool calls (memory writes, file paths) | the model can drive persistent memory writes and, in agent loops, client tool execution |
| B5 network downloads | release assets, source archive, HuggingFace shards/mirrors | installer/converters download and unpack archives to disk |
| B6 plugin filesystem writes | harness `settings.yaml`, agent presets | JS writes into the user's harness home (backed up, but still a write path) |
| B7 credentials | GitHub token (`release.sh` uses `gh`), any registry credentials | publishing is privileged and irreversible |

## 2.4 Tier table

Tier A = deep manual (security, untrusted parsing, persistence, native memory,
network surface, irreversible operations, multi-consumer contracts).
Tier B = tool-first production code. Tier C = tests/docs/measurement scripts.

| Module / area | Tier | Reason |
| --- | --- | --- |
| `sources/TinyTitanServer` | A | B1 network-facing HTTP endpoint, request validation, tool-call marshalling |
| `sources/TinyTitanKernelsC` | A | B3 native memory + pthreads (`expert_io.c`), buffer arithmetic |
| `sources/TinyTitan` (engine, Metal, model load) | A | B3 module-map seam, B2 model parsing, GPU resource lifetimes |
| `sources/TinyTitanFormat` | A | B2 untrusted on-disk format parsing/serialising |
| `sources/TinyTitanRepack` | A | B2 + writes hundreds of GB of model artifacts (irreversible-ish) |
| `sources/TinyTitanMemory` | A | persistence, model-authored writes (B4), guard/precedence logic |
| `sources/ContinuityCore` | A | persistent journal/engine, file locking, durability |
| `sources/TinyTitanFleet` | A | network-facing fleet control, mutating remote harnesses |
| `plugins/dsh-lan-manager` | A | B1-adjacent LAN API, prompts/archives/deletes remote workspaces |
| `plugins/dsh-tinytitan` | A | writes the user's harness files (B6), route contract (2.2 #2) |
| `sources/TinyTitanCLI` | B | production CLI front end, argv parsing |
| `sources/TinyTitanMemoryTool` | B | production CLI over memory |
| `tools/install_tinytitan.sh`, `install_models.sh` | A | B5 downloads + unpacking, irreversible writes to the user's system |
| `tools/dsh_local.sh`, `dsh_route.sh`, `server_launcher.sh` | A | installs code, writes harness config (B6), shared env contract |
| `tools/prepare_*.py`, `repack_dense.sh`, `ane_sidecars.sh` | A | convert/write model data (hundreds of GB), B5 |
| `tools/release.sh`, `golden-baseline.sh`, `lint.sh` | A | publish path (B7), release gates |
| `benchmark/**` | C | measurement scripts; no production path |
| `tests/**` | C | tests |
| `docs/**`, `.qwen/wiki/**` | C | documentation |
| `sources/ContinuityDemo`, `sources/TinyTitanBench` | C | demo/benchmark executables |
| `tests/TinyTitanApp` | C | remnant of the removed GUI |

Disclosure: tiering reduces how much surface is read by a human. Tier B modules
are gated by tools plus manual review of tool findings, coverage gaps and change
hotspots; Tier C by scanner only. Findings from every tier are enumerated and
closed; nothing is waived for being Tier C.
