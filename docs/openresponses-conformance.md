# Open Responses conformance

What the [Open Responses](https://www.openresponses.org/specification) acceptance
suite says about this server's `/v1/responses` surface, run once as a scorecard on
2026-09-14. Open Responses is an open, vendor-neutral formalisation of the OpenAI
Responses API — schema, items, semantic streaming events, state machines — plus
three things this server does not have (`/v1/responses/compact`, WebSocket
transport, `allowed_tools`).

The point of running it was to turn "we implement the Responses API" into a
number with named failures. It did, and it corrected a guess: the most valuable
fix is **not** one of the three missing features.

## Scorecard

**1 passed, 16 failed, 0 skipped — 17 total.**

| Test | Result | Cause |
| --- | --- | --- |
| `response-output-phase-schema` | **pass** | — |
| `basic-response` | fail | required sampling fields |
| `assistant-phase` | fail | required sampling fields |
| `streaming-response` | fail | required sampling fields |
| `system-prompt` | fail | required sampling fields |
| `tool-calling` | fail | required sampling fields |
| `compact-response` | fail | no `/v1/responses/compact` (405) |
| `compact-missing-model` | fail | no `/v1/responses/compact` (405) |
| `websocket-compact-new-chain` | fail | no `/v1/responses/compact` (405) |
| `websocket-response` | fail | no WebSocket transport |
| `websocket-sequential-responses` | fail | no WebSocket transport |
| `websocket-continuation` | fail | no WebSocket transport |
| `websocket-reconnect-store-false-recovery` | fail | no WebSocket transport |
| `websocket-previous-response-not-found` | fail | no WebSocket transport |
| `websocket-failed-continuation-evicts-cache` | fail | no WebSocket transport |
| `image-input` | fail | **by design** — this server is text-only |
| `multi-turn` | fail | **suite artifact** — 429 `queueFull` |

### What is a real conformance failure, and what is not

| Cause | Tests | Nature |
| --- | --- | --- |
| Required sampling fields absent | **5** | real, and cheap |
| No compaction endpoint | 3 | missing feature |
| No WebSocket transport | 6 | missing feature |
| Text-only refuses `input_image` | 1 | deliberate limitation, not a bug |
| 429 `queueFull` | 1 | artifact of the suite, not the server |

## The finding that matters: five tests, three fields

Five tests — every test that validates the `Response` object — fail on the same
three fields:

```
top_p: Expected number, received null
presence_penalty: Required
frequency_penalty: Required
```

`responseResourceSchema` marks all three **required**. This server emits `top_p`
as `null` and omits the two penalties, so nothing that reads a `Response` object
can validate it.

This is worth separating into two concerns that are currently one:

- **Validation** wants the request's fields to stay nil when the client named
  none, so the served model's own profile supplies them. `docs/audit-2026-09-11-findings.md`
  C11 fixed exactly that, and the mapper tests pin it.
- **Echo** wants the `Response` object to report the values the server actually
  used. A client cannot tell what `top_p` was applied otherwise, and the spec
  requires the number.

Keeping the fields nil satisfies the first and breaks the second. Three fields in
the `Response` builder — resolved from the same profile the sampler uses — is the
single highest-value change on this page: **5 of the 16 failures**, for a change
far smaller than either missing feature.

## `[DONE]`: a specification MUST this server should not follow

The specification says, under *Streaming HTTP Responses*:

> "The terminal event **MUST** be the literal string `[DONE]`."

This server deliberately does not send it, and says so in two places:

- `HTTPServerHandler+Responses.swift` — *"The Responses API has no `[DONE]`
  terminator; the final event is it."*
- `HTTPServerHandler+Chat.swift` — *"chat sends an error object then `[DONE]`; the
  Responses API and the Messages API send a typed `error` event and no
  terminator."*

**OpenAI's Responses API ends with `response.completed`, not `[DONE]`.** Following
the MUST would make this server *less* compatible with the API it imitates.

The suite agrees with this server, not with its own specification:

- `src/lib/sse-parser.ts` treats `[DONE]` on HTTP as a sentinel to **skip** —
  `// Skip the [DONE] sentinel - it's not a real event` — so it is neither
  required nor rejected there.
- On WebSocket the same suite **rejects** it: `"Received [DONE] before a terminal
  WebSocket event"` is recorded as an error.

So the normative MUST is unenforced on one transport and contradicted on the
other. That belongs upstream as a specification bug, not in this server as a
compliance fix.

## The three missing features, judged on merit

**`allowed_tools`** — still the best of the three, and *not* exercised by this
suite (no test covers it). Its stated purpose is to narrow the executable tool set
without changing `tools`, because mutating `tools` invalidates prompt and schema
caches. This server has a real prompt cache (`--prompt-cache-mode multi-prefix`,
256 MiB), which is exactly the deployment the field was designed for. Not urgent,
but the fit is unusually good.

**WebSocket transport** — six tests, and the largest piece of work. It is not
merely a second binding: it needs `response.create`, connection-local
`previous_response_id` so `store=false` can continue without persisted state, a
60-minute connection limit, `previous_response_not_found`, and eviction of a
referenced response when a continuation fails. The payoff beyond compliance is
that a persistent socket with connection-local state addresses the cold-prefill
problem 5.5's notes describe — a client can continue a turn without resending and
re-prefilling the whole context.

**`/v1/responses/compact`** — three tests, and the least attractive. This server
already has compaction machinery for DeepSeek Harness; the endpoint is a
different shape around it (`response.compaction` with `encrypted_content`), and
the spec's own rationale is to avoid asserting provider-specific compression. Worth
doing only alongside the WebSocket work, since `websocket-compact-new-chain`
depends on both.

## One caveat about the scorecard itself

The suite runs **all 17 tests in parallel** (`runAllTests` maps over
`testTemplates` with `Promise.all`). This server admits one generation at a time
with four queued — `queueLimit + 1`, default 5 — and sheds the rest with 429
(`ServerInference.swift`; the run's log shows
`status=429 error=ServerRequestError.queueFull`).

So at least one failure is the suite's concurrency colliding with a
single-model server, not a conformance defect. A re-run that separates the two:
raise the server's queue for the run, or filter the suite to one test at a time:

```bash
tools/server_launcher.sh --client server --model qwen35-2b --bits 4
# then, against the running server:
bun run test:compliance -u http://127.0.0.1:8080/v1 -k any -m qwen3.5-2b_4-Bit \
  --filter basic-response
```

`image-input` will still fail whatever the concurrency: the models are text-only
and the Responses mapper refuses image parts by design
(`ResponsesAPIModels.swift`: *"Text-only: image and …"*).

## Reproducing

```bash
# 1. the server, on an installed model (2B 4-bit is enough and loads in seconds)
tools/server_launcher.sh --client server --model qwen35-2b --bits 4 --dry-run   # prints the exact command
# ... run the printed command

# 2. the suite, from a checkout of openresponses/openresponses
git clone --depth 1 https://github.com/openresponses/openresponses.git
cd openresponses
node -e "const d=require('./package.json');require('fs').writeFileSync('package.json',JSON.stringify({name:'or',private:true,dependencies:{zod:d.dependencies.zod}},null,2))"
npm install                      # zod only; the generated schemas are committed under src/generated
npx tsx bin/compliance-test.ts -u http://127.0.0.1:8080/v1 -k any -m qwen3.5-2b_4-Bit --json
```

Node alone cannot run the suite: its resolver rejects the extensionless relative
imports (`from "../src/lib/compliance-tests"`), so `tsx` (or the repo's own Bun)
is required. The generated zod schemas are committed, so `kubb generate` is not
needed — only `zod` is.

## Verified

- Server: `qwen3.5-2b_4-Bit` on the GPU, `--reasoning off`, port 8080, macOS
  26.6.2, Swift 6.3.3, Apple M3. No performance claim here — this is a protocol
  check, not a measurement.
- Suite: `openresponses/openresponses` at `master`, 17 tests, run once.
- The scorecard is one run. Nothing on this page changes server code; the
  `[DONE]` item is an upstream report, not a work item.
