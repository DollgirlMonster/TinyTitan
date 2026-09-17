# `dsh-lan-manager`

A LAN-scoped management API for a DeepSeek Harness (`dsh`) host. It answers the
question *"what is running on that Mac, and can I drive it from here?"* for a
cluster of harness instances, without a GUI and without a third-party gateway.

```bash
curl http://192.168.18.27:3080/dsh-lan/workspaces
curl -X POST http://192.168.18.27:3080/dsh-lan/prompt-all \
     -H 'content-type: application/json' \
     -d '{"prompt":"report your current goal"}'
```

## What it does

| # | Capability | Endpoint |
|---|---|---|
| 1 | List active workspaces — the ones the web page shows | `GET /dsh-lan/workspaces` |
| 2 | List the visible sessions of a workspace | `GET /dsh-lan/workspaces/:id/sessions` · `GET /dsh-lan/sessions` |
| 3 | Prompt one session | `POST /dsh-lan/prompt` |
| 3a | Prompt **every** active session | `POST /dsh-lan/prompt-all` |
| 4 | Delete a workspace (archiving its sessions first) | `POST /dsh-lan/workspaces/:id/delete` |
| 5 | Archive a session | `POST /dsh-lan/sessions/:id/archive` |
| — | Liveness and the caller's fence verdict | `GET /dsh-lan/health` |

**"Active" means what the web page shows.** A workspace is active when the
registry lists it *and* it owns at least one non-archived session; a session is
visible when its workspace accounts for it and it is not in the registry-global
`archivedSessionIds` set. Archived sessions keep their slot and their history —
archiving hides a row, it does not delete anything.

**Archive ≠ delete.** `archive` hides a session. `delete` removes a workspace from
the registry and, by default, archives its sessions on the way out so a stray call
cannot silently drop history. Neither touches the folder on disk or the session
logs; pass `{"archiveSessions": false}` to delete a workspace without archiving.

## Security

The API mutates workspaces and enqueues model prompts, so access is fenced in three
layers, checked in this order:

1. **Source address**, before the body is read and before any handler runs. Allowed:
   loopback, RFC 1918 (`10/8`, `172.16/12`, `192.168/16`), link-local, and
   **`100.64.0.0/10`** — the Tailscale/CGNAT block. Everything else, including any
   unparseable address, is refused. The peer address is taken from the socket;
   `X-Forwarded-For` is deliberately **not** trusted, because a forwarded header is
   attacker-controlled and trusting it would let any caller claim loopback.
2. **Shared token** (`token` / `DSH_LAN_TOKEN`), compared in constant time. Optional
   — the right default for a single-user LAN, and the *only* thing separating two
   machines on the same private range.
3. **Origin**, on mutating verbs only: a foreign site in an allowlisted browser must
   not be usable as a confused deputy.

### Reaching it from another machine

`dsh web` binds loopback by default; the fence cannot help if nothing is listening
on the network interface. To serve the LAN, bind the harness web server to `0.0.0.0`
and allow the authority you will browse:

```bash
dsh --profile web --host 0.0.0.0 --trusted-host 192.168.18.27:3080
```

This is a deliberate exposure — the harness web server itself carries no TLS and no
authentication of its own, which is exactly why this plugin fences by source address
in front of its own routes. Do not port-forward it to the public internet.

## Install

```bash
dsh plugin --profile web add ./plugins/dsh-lan-manager        # from the checkout
dsh plugin --profile web add github:Pummelchen/TinyTitan#<commit>   # pinned
```

The bundle patch mounts the row; the next `dsh web` picks it up. No `--patch` flag
is needed.

## API

### `GET /dsh-lan/workspaces`

```json
{
  "ok": true,
  "archivedCount": 29,
  "totalWorkspaces": 12,
  "workspaces": [
    {
      "id": "a9832cc9-…",
      "path": "/Users/me/ProjectA",
      "title": "ProjectA",
      "createdAt": "2026-09-01T…",
      "updatedAt": "2026-09-02T…",
      "sessionCount": 2,
      "hiddenSessionCount": 1,
      "sessionIds": ["s-a1", "s-a2"]
    }
  ]
}
```

`sessionIds` holds only visible sessions; `hiddenSessionCount` is how many are
archived inside that workspace. Pass `?includeEmpty=true`-equivalent config
(`includeEmptyWorkspaces`) to keep workspaces the page would not show.

### `GET /dsh-lan/sessions`

Every visible session across every active workspace, de-duplicated, each tagged
with its workspace.

### `POST /dsh-lan/prompt`

```json
{ "sessionId": "s-a1", "prompt": "run the tests and summarise failures" }
```

`prompt` may also be an array of content blocks. The target session must have a
**live agent** — one the UI has open or is currently running — otherwise the call is
a `404`, because there is nothing to enqueue onto. Delivery uses the same
`followup` entry point the SDK server uses, so a prompt sent here is an ordinary
turn, not a side channel.

### `POST /dsh-lan/prompt-all`

```json
{ "prompt": "report status", "sessionIds": ["s-a1"], "limit": 10 }
```

`sessionIds` and `limit` are optional. Delivery is per-session and never
all-or-nothing: one session without a live agent is reported in `failed[]` while the
rest are delivered, so one stale session cannot stall a fleet-wide prompt.

```json
{ "ok": true, "delivered": [ … ], "failed": [ { "sessionId": "s-x", "code": "not-found" } ],
  "total": 3, "considered": 3 }
```

### `POST /dsh-lan/sessions/:id/archive`

Hides the session in the UI. Reversible; history and slot are kept.

### `POST /dsh-lan/workspaces/:id/delete`

```json
{ "archiveSessions": true }
```

Removes the workspace from the registry. With `archiveSessions` (the default) its
sessions are archived first; the response reports `archivedSessionIds` and any
`archiveFailures` individually, so a partial archive is visible rather than silent.

## Managing a cluster

Each harness instance is independent — there is no shared registry — so drive them
by address. A loop over the fleet:

```bash
for host in 192.168.18.27 192.168.18.25 192.168.18.29 192.168.18.26; do
  printf '%s: ' "$host"
  curl -fsS --max-time 5 "http://$host:3080/dsh-lan/workspaces" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["workspaces"]), "workspaces", sum(w["sessionCount"] for w in d["workspaces"]), "sessions")' \
    || echo unreachable
done
```

Broadcast a prompt across every active session on every instance:

```bash
for host in 192.168.18.27 192.168.18.25; do
  curl -fsS -X POST "http://$host:3080/dsh-lan/prompt-all" \
    -H 'content-type: application/json' -H "x-dsh-token: $DSH_LAN_TOKEN" \
    -d '{"prompt":"checkpoint: summarise your state in one line"}' | head -c 400; echo
done
```

## Configuration

| Key | Env | Default | Meaning |
|---|---|---|---|
| `basePath` | `DSH_LAN_BASE_PATH` | `/dsh-lan` | Route prefix |
| `token` | `DSH_LAN_TOKEN` | none | Shared secret, `x-dsh-token` |
| `allowAddresses` | `DSH_LAN_ALLOW` | `[]` | Extra single hosts or CIDRs to admit |
| `ipv4Networks` | — | loopback, RFC1918, link-local, CGNAT | Replace the IPv4 allowlist |
| `ipv6Networks` | — | `::1/128`, `fc00::/7`, `fe80::/10` | Replace the IPv6 allowlist |
| `trustedOrigins` | — | `[]` | Extra Origins accepted |
| `allowPrivateOrigins` | — | `true` | Accept LAN Origins on mutations |
| `enforceOrigin` | — | `true` | Check Origin on mutations at all |
| `includeEmptyWorkspaces` | — | `false` | Show workspaces with no visible session |
| `maxBodyBytes` | — | `262144` | Request body cap |

## How it hangs together

| File | Role |
|---|---|
| `src/index.js` | `apply()` — config, route registration, disposal, banner |
| `src/router.js` | the three guards, routing, JSON bodies and responses |
| `src/api.js` | the operations against `workspaceRegistry` / `agents` |
| `src/net.js` | the address fence (pure, no I/O) |
| `src/config.js` | config and environment resolution |

It reads harness services lazily through `ctx.get(...)` and imports no harness
internals, so a harness upgrade cannot desynchronise it. The single dynamic import
is `@deepseek-ai/dsh-llm`'s `createUserMessage`, used to build a prompt exactly as
the SDK server does; if that export moves, the plugin falls back to the equivalent
literal shape and reports which path it took in `/health`.

## Tests

```bash
npm test        # node --test 'test/*.test.js' — 46 cases
```

`test/net.test.js` is the important one: it pins every allowed range and, more to
the point, the addresses just outside each one, plus the spoofed-header case.
