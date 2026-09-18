# Three asks for DeepSeek Harness, from running it against a local TinyTitan server

Date: 2026-09-14; **posted 2026-09-18**. Re-verified before posting against the
installed `@deepseek-ai/dsh` **0.1.6-alpha.2** and `@earendil-works/pi-ai` 0.85.1,
and the line numbers below are those versions' (the first draft was written
against 0.1.5-rc.2). Upstream (`deepseek-ai/deepseek-harness`) has **issues
disabled and discussions enabled**, so all three are Discussions in *Ideas*:

| # | Ask | Discussion |
| --- | --- | --- |
| 1 | Honor `purpose` when an auxiliary call names no reasoning level | [#7109](https://github.com/deepseek-ai/deepseek-harness/discussions/7109) |
| 2 | Map pi-ai's reasoning usage into `reasoningTokens` | [#7110](https://github.com/deepseek-ai/deepseek-harness/discussions/7110) |
| 3 | Allow `dsh web --host` to bind a specific LAN interface | [#7111](https://github.com/deepseek-ai/deepseek-harness/discussions/7111) |

The patches are small enough to apply locally meanwhile.

Both are about the *seam*, not about any one provider: they change what every
route gets, and both already hold on the first-party DeepSeek adapter.

---

## 1. Honor `purpose` when a call names no reasoning level

**What happens now.** The harness marks its auxiliary model calls with a
`purpose`, and they name no `reasoningEffort`:

- `@deepseek-ai/dsh-compaction-basic` — `summarizeWithLlm`
  (`lib/index.js:299`) streams with `purpose: "compaction"` and no
  `reasoningEffort`;
- `@deepseek-ai/dsh-session-title-llm` (`lib/index.js:216`) streams with
  `purpose: "session-title"` and no `reasoningEffort`.

`@deepseek-ai/dsh-llm` then fills the gap from the *route*:
`resolveCallWithInfo` (`lib/index.js:2136-2147`) takes
`const effective = requested ?? reasoning.defaultEffort`. So on any route whose
profile default level is a thinking level, compaction and session titles think.

**Why that is wrong rather than merely expensive.**

- Those calls exist to produce a *bounded* amount of visible text — a checkpoint
  or a title — inside an output cap the caller chose (`maxTokens`). Thinking
  spends that cap first, which is the failure the old Qwen plugin's author
  described: a summariser whose thinking eats the cap truncates the checkpoint.
- On a local model the cost is wall-clock, not quota. Measured here on a base M3
  with 24 GB and Qwen3.8-Flash-Next 4-bit: **~5.8 tok/s** decode, so a few
  hundred thinking tokens is minutes per compaction and tens of seconds per new
  session's title.
- The harness already decided this for its own route:
  `@deepseek-ai/dsh-llm-deepseek`'s `resolveThinking`
  (`lib/index.js:32`) returns `{ thinking: "disabled" }` for
  `purpose === "session-title"`, and the compaction call carries
  `x-deepseek-harness-compact: 1` (`lib/index.js:1276`) for the server to act on.
  A pi-ai-backed route has no equivalent, so the same harness behaves two ways
  depending on which adapter serves the model.

**Suggested patch** (one place, no schema change): treat an auxiliary purpose as
naming `off` when the call names no level, in whichever layer resolves the
default — e.g. in `dsh-llm`'s `resolveCallWithInfo`:

```js
const AUXILIARY_PURPOSES = new Set(["compaction", "session-title"]);
// …
const requested = defaulted.reasoningEffort
  ?? (AUXILIARY_PURPOSES.has(defaulted.purpose) ? "off" : undefined);
```

Every reasoning model the harness can route lists `off` among its efforts, so the
existing `UNSUPPORTED_REASONING_EFFORT` check stays the guard it is today.
Alternatively a profile field (`auxiliaryReasoning`, defaulting to `off`) would
let a deployment opt out; the seam-level default seems truer to the intent.

**Acceptance.** With a thinking route, a session's first prompt issues a
`purpose: "session-title"` request with no thinking (no `reasoning_content`, no
reasoning tokens in usage), and a compaction call behaves the same, while an
ordinary turn still thinks at the route's default.

**Local mitigation meanwhile.** TinyTitan ships `plugins/dsh-tinytitan`, a thin bundle
that mounts a compaction backend forcing `off` for those calls; the route's own
`reasoning` default still decides ordinary turns.

---

## 2. Map pi-ai's reasoning usage into `reasoningTokens`

**What happens now.** pi-ai parses the provider's split
(`@earendil-works/pi-ai/dist/api/openai-completions.js:1201`):

```js
reasoning: rawUsage.completion_tokens_details?.reasoning_tokens || 0,
```

`@deepseek-ai/dsh-llm-pi-ai`'s `mapUsage` (`lib/index.js:1403-1410`) then maps
`input`, `output`, `totalTokens`, `cacheRead` and `cacheWrite` — and drops
`reasoning`:

```js
function mapUsage(usage) {
  return {
    inputTokens: usage.input,
    outputTokens: usage.output,
    totalTokens: usage.totalTokens,
    ...usage.cacheRead > 0 ? { cacheReadTokens: usage.cacheRead } : {},
    ...usage.cacheWrite > 0 ? { cacheWriteTokens: usage.cacheWrite } : {}
  };
}
```

**Consequence.** The harness's `TokenUsage.reasoningTokens` is populated on the
DeepSeek route (visible in a session transcript as
`{"inputTokens": 9707, "outputTokens": 153, "totalTokens": 11140, "cacheReadTokens": 1280, "reasoningTokens": 132}`)
and never on a pi-ai route, so the context meter and any per-turn accounting
cannot separate thinking from answer there — exactly where local models spend
most of their output tokens. TinyTitan does report the field; the adapter discards
it. The doc comment ("reasoning folded into output by pi-ai") describes pi-ai's
*output* bucket, not the separate count pi-ai also returns.

**Suggested patch** (one line, mirroring the cache fields' "only when non-zero"
rule):

```js
...usage.reasoning > 0 ? { reasoningTokens: usage.reasoning } : {},
```

**Acceptance.** On a pi-ai route, a thinking turn's `assistant/message` record
carries `reasoningTokens` matching the provider's
`completion_tokens_details.reasoning_tokens`; a non-thinking turn omits it, as
the cache fields do.

---

## 3. Allow `dsh web --host` to bind a specific LAN interface

**What happens now.** The webserver schema takes two literals and no others:
`host: z.union([z.const("127.0.0.1"), z.const("0.0.0.0")]).required()`
(`@deepseek-ai/dsh-host-webserver` `lib/index.js:141`). The Web app then refuses
the all-interfaces one at startup (`@deepseek-ai/dsh-web-app` `lib/startup.js:40`):
*"error: --host 0.0.0.0 is intentionally not supported yet for safety: it would
expose remote code execution to the network; use 127.0.0.1 instead"*.

**Consequence.** Nothing built on the Web UI — a LAN manager for a small fleet of
harness instances, say — can be reached from another machine, and a specific
interface cannot be named at all.

**The fence it would need is already there.** `resolveLanTrust`
(`lib/index.js:83`) computes the machine's non-internal IPv4 addresses, folds
them into `trustedHosts` for the `/api` browser-trust fence, and the ready banner
announces a LAN candidate (`lib/index.js:199`) — every bit of it gated on
`bindHost === "0.0.0.0"`, which startup rejects, so on the CLI path it is
unreachable. A non-wildcard bind would also need the bound address added to the
fence: that function returns an empty `lanAddresses` for anything but the
wildcard.

**Suggested shape.** Accept an explicit interface literal — `--host 192.168.1.5`
— and keep rejecting the wildcard, or gate the wildcard behind an explicit
opt-in. One address exposes the listener only on the subnet that address is on.
If remote code execution is the concern, an opt-in that also requires a token or
an allowlist is the safer form than a silent wildcard bind.

**Acceptance.** The bound literal serves and is printed in the ready banner;
another machine on the same subnet can load it; and the `/api` fence still
rejects a Host header that is neither the bound address nor an explicit
`--trusted-host`.

---

## Applying these locally

The first two are small enough to carry as a patch against the installed package
while upstream decides — but an upgrade replaces `node_modules`, so re-apply
after one. The first is already worked around by `plugins/dsh-tinytitan` for
compaction; the second cannot be worked around from outside the adapter, which is
why it is the more valuable of the two. The third is a schema change in two
packages, so it is upstream or a fork rather than a patch.
