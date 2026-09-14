## TinyTitan 5.5 — the name, structured output, and a harness route

This is the first release published under the project's own name. It carries the
two features that landed after 5.4 — JSON the sampler is not allowed to leave,
and a thinking switch that belongs to the request instead of to load time — plus
the launcher, client and DeepSeek Harness work around them. Everything here was
already on `main`; 5.5 is the version that makes it downloadable.

### The project is TinyTitan

The package, all 28 SwiftPM targets and their 581 paths, the executables, the
environment variables, the launcher, the benchmark scripts, the DeepSeek Harness
bundle, the documentation, the wiki and the repository are renamed by one
mechanical rule (`NVMAI_` → `TINYTITAN_`, `NVMAI` → `TinyTitan`, `nvmai` →
`tinytitan`). The old repository URL redirects, so existing links keep working.

What that changes for a user:

- **The binaries have new names** — `TinyTitanServer`, `TinyTitanMac`,
  `TinyTitanCLI`, `TinyTitanRepack`, `TinyTitanDecodeService`, `TinyTitanBench`.
  An existing `.build/` may still hold the old `NVMAI*` executables beside them;
  they are stale and nothing updates them.
- **The environment variables are `TINYTITAN_*`** (`TINYTITAN_PORT`,
  `TINYTITAN_MODELS_DIR`, `TINYTITAN_CLIENTS`, …).
- **The app installs as `TinyTitan.app`**, and the release archive is
  `tinytitan-5.5-macos-arm64.tar.gz`.

The published release notes and the wiki Changelog keep the name each earlier
version shipped under, on purpose.

Two things the mechanical pass could not do, both fixed by hand: the wordmarks
split the name across two coloured spans, so they now read `Tiny` + `Titan` with
a widened canvas, and the app icon is the project's brand image clipped to the
macOS rounded square (`tools/make_app_icon.py`). One defect the pass introduced —
a SwiftPM resource-bundle glob turned into `TINYTITAN_*.bundle`, which matches
nothing, because resource bundles are named after the *package* plus the target
(`TinyTitan_TinyTitanMac.bundle`) — was found and fixed before release.

### Structured output is enforced by a grammar

`response_format` on Chat Completions, `text.format` on the Responses API and
`output_config.format` on Messages used to be refused by name, because the
decoder had no grammar constraint and a "JSON mode" that answered prose would be
a client-visible lie. A named JSON format now compiles into a **byte-level
grammar that masks the sampler on both engines**, so every token is drawn from
the set that keeps the document inside the schema. The schema picks nothing: it
removes what is forbidden, and among the remaining tokens the model's
distribution still decides.

The supported subset is explicit — `type`, `properties`, `required`,
`additionalProperties`, `items`, `enum`, `const` — and everything outside it
(`$ref`, `anyOf`, `pattern`, numeric bounds, tuple `items`, …) is refused by name
at request time, because accepting a constraint and not enforcing it is worse
than refusing it. Unsatisfiable shapes are refused with the reason. Special
tokens carry no bytes and are never allowed. Thinking is off for a constrained
request, since the grammar constrains every token; MTP is skipped, because a
draft ahead of the sampler never writes the logits a mask would edit.

Two behaviours worth knowing: one whitespace-only token is allowed between
structural tokens and a second in a row is not (pretty-printing survives, an
indent being one token), and a response truncated by `max_tokens` is a truncated
document — content correctness is still the model's. Verified on a real install
on both engines and through all three surfaces; see
[`docs/structured-output.md`](structured-output.md).

### Thinking belongs to the request, on all three surfaces

The Anthropic surface was the last place thinking was fixed at load time. On
`/v1/messages`, `thinking.disabled` is a real off, `adaptive` keeps meaning "you
decide", and `thinking.enabled` maps Anthropic's `budget_tokens` onto the ladder
the OpenAI path already uses (under 4k `low`, under 16k `medium`, else `xhigh`);
Anthropic's own budget rules stay refusals, because a budget outside them is a
malformed request rather than a mapping choice this server could make. Chat
Completions gained the same per-request control through
`chat_template_kwargs.enable_thinking` and `reasoning_effort`, and reports
reasoning tokens in usage.

A server loaded with thinking on can now be told to think less — or not at all —
for one turn, without a restart.

### `developer` is the system turn, not an HTTP 500

A leading `developer` message — the OpenAI role that replaced `system` — was
validated as leading guidance and then handed to the chat template as its own raw
value, and every template this project ships defines only
`system`/`user`/`assistant`/`tool`, so the template's
`raise_exception('Unexpected message role.')` surfaced as HTTP 500. Harnesses that
switch to `developer` once a model reasons hit it. The role now renders as
`system` in both prompt paths (the manual ChatML renderer and the Jinja tool
path), and a leading `developer` message takes the effort instruction into
itself.

### The launcher offers only what is installed, and warns above 40% of RAM

The launcher's menu is what someone is about to load, so a model or width that is
not under `models/` is no longer a choice: the built-in fallback filters itself
against the install directories (and the same check applies to a stale
`TINYTITAN_CATALOG_JSON`), the families and widths left out are named in one
line, an empty `models/` is a hard error with the install runbook instead of a
menu, and asking for a width that is not installed answers with the widths that
are.

The expert cache is wired and cannot be paged out, so the recommendation moved
from half to **40% of physical memory** (floored to whole GB). An explicit `--ram`
above that line is warned about in bold red — naming swapping, system
instability and slower tokens — and then used anyway, because it is the
operator's call; the default path keeps the install's measured profile, which the
runtime still clamps to half of physical memory.

### One client catalogue for the launcher and the coder harness

`TINYTITAN_CLIENTS` in `tools/tinytitan_models.sh` is now the single list, and
both the launcher's menu and `benchmark/coder_cli_benchmark.py` build themselves
from it, so the two cannot disagree about which clients exist. Four entries are
`coder` clients — Codex, Claude Code, Qwen Code, OpenCode — and Zed is an
`editor`: the harness refuses `--clients zed` and points at the new
`--round clients`, which checks every client's wiring — binary, version, the
launcher's own setup line, and the config the harness writes for it — **without
loading a model**.

### DeepSeek Harness: a generated route, and a thin bundle

A local model is reachable from the harness through its own `llm-pi-ai` adapter;
what was missing was the configuration. `tools/dsh_route.sh` generates that route
block from the server's own catalog — the served ids, each template's thinking
ladder, and the three switches that are easy to get wrong by hand
(`thinkingFormat: chat-template`, the keyless-route auth header, a stream idle
timeout that outlives a cold local prefill) — and `--write` replaces just that
section of `~/.dsh/settings.yaml` after a timestamped backup, line-based so
comments survive.

`plugins/dsh-tinytitan/` is the thin bundle for people who would rather not
remember to run it: at boot it refreshes the route and generates a compaction
preset whose backend forces thinking off for compaction and session titles only,
leaving ordinary turns at the route's level. It registers no adapter and copies
no protocol implementation — the harness's own route does the serving — so a
harness upgrade cannot leave a stale copy behind. Twenty `node --test` tests.

### Also in this release

- **The six dense Qwen 3.5 installs have golden baselines of their own.** They
  were the one supported shape a release never verified: `benchmark/golden/` held
  ten files, all for the MoE families, so 2B/4B/9B at either width had no target
  and were declared exceptions. They have targets now, and the gate checks them.
- **A route refresh no longer orphans its own header.** The plugin refreshes the
  route at every boot, and the generated block's three comment lines sit above
  `llm-pi-ai:`, so a section replacement left the previous header behind and
  every boot added three more stale lines. The writer removes its own header, a
  rewrite is now byte-identical, and a regression test pins it.
- **CI scans the Swift runtime.** CodeQL had never analysed it — the default
  setup covered `actions`, `c-cpp` and `python`, and open alerts were zero, which
  is exactly why the gap was invisible. Swift is scanned by an advanced-setup
  workflow, weekly and on demand, building outside the checkout on `arm64`
  because these sources use `Float16` and a `paths-ignore` does not filter a
  compiled language.
- **The coder harness can finish a round against a local model.** A cold prefill
  pays minutes before the first token, Codex abandons an idle stream after five
  and retries — and a retry is another cold prefill, so the round never finished.
  The harness sets the stream idle timeout and disables retries for Codex.
- **Every benchmark starts its server through `tools/server_launcher.sh`**, so a
  stored baseline and a live measurement cannot diverge through a different
  launch, and `--round features` refuses the dense installs by name because they
  have no routed experts.
- **The README is one benchmark table** with a reproducible GPU-versus-CPU column
  for the dense Qwen 3.5 models, a names-only supported-model list, and no
  per-release callout — a release is announced in the wiki Changelog.
- **The plugin package is publishable metadata-wise**: a `repository` field
  pointing at this checkout's `plugins/dsh-tinytitan`, and peer ranges widened to
  `^0.1.5-rc.2 || ^0.1.6-rc.1`.

### Performance

No performance number was re-measured for this release, and the README table is
unchanged from 5.4's: this release renames, constrains the sampler, fixes request
handling and adds configuration. The grammar masks the sampler with a host-side
pass over the logits buffer that the repetition penalty already made, and a
request with no format named generates byte-identically to before — which the
golden baselines re-check rather than a benchmark.

### Verification

Cut from tag `v5.5` on the base M3 with 24 GB this project measures on —
macOS 26.6.2, Swift 6.3.3, Apple M3, 24 GB.

- **`tools/lint.sh`** — all four gates clean: force-cast, func-length (0
  baselined, 0 new, 2059 functions scanned), unchecked-Sendable, and the
  converter expert-order probe.
- **`swift test --no-parallel`** — **1523 tests in 234 suites passed**
  (119.6 s).
- **Clean scratch release build** — warning-free, 107.9 s, staging the six
  executables and the `.bundle` resources the runtime loads its kernels from.
- **Golden baselines, byte-identical** — all ten targets installed here:
  `katcoder-4`, `katcoder-8`, `qwen38-4`, `qwen38-8`, `qwen35-2b-4`,
  `qwen35-2b-8`, `qwen35-4b-4`, `qwen35-4b-8`, `qwen35-9b-4` and `qwen35-9b-8`.

Those results are from the dry run of this commit; `--publish` repeats every gate
from scratch and rebuilds the archive, which is why the digest and size below are
filled in only at publish time.

`models/` holds eleven installs. The gate checked the ten that have a golden
target: **katcoder-4**, **katcoder-8**, **qwen38-4**, **qwen38-8**,
**qwen35-2b-4**, **qwen35-2b-8**, **qwen35-4b-4**, **qwen35-4b-8**,
**qwen35-9b-4** and **qwen35-9b-8**. Six targets have no install here and are
**not checked**: **ornith-4**, **ornith-8**, **qwen36-4**, **qwen36-8**,
**agentworld-4** and **agentworld-8**. They are absent because the operator
deleted those installs to save disk. None was downloaded, converted, repacked or
re-installed to satisfy this gate, and none may be: the gate names every
unchecked target, refuses to publish unless these notes repeat the list, and
fails if the golden phase changed the install set under `models/`.

The eleventh install, `qwen3.8-flash-next_125B_A6B_MTP_4Bit`, is the MTP draft
head — a sidecar the covered `qwen38` targets exercise — and is declared in
`NON_GOLDEN_INSTALLS` with that reason rather than silently unchecked.

**Not re-measured for this release:** every performance number in the README,
including the dense GPU-versus-CPU rows, which are quoted from the wiki's
[One Prompt, Every Model](https://github.com/Pummelchen/TinyTitan/wiki/Capital-of-Paris-Smartness)
page.

### Checksum

`tinytitan-5.5-macos-arm64.tar.gz` sha256: `SHA256_PENDING`
`tinytitan-5.5-macos-arm64.tar.gz` size: `ARCHIVE_BYTES_PENDING` bytes
