/**
 * Harness operations behind the LAN API.
 *
 * Every capability is expressed against a host service rather than by reaching
 * into dsh's internals:
 *
 * | Capability | Service | Method |
 * |---|---|---|
 * | active workspaces | `workspaceRegistry` | `list()` |
 * | visible sessions | `workspaceRegistry` | `Workspace.sessionIds` minus the archive set |
 * | prompt one session | `agents` | `get(id)` → `followup(createUserMessage(...))` |
 * | prompt all sessions | `agents` | the same, fanned out |
 * | archive a session | `workspaceRegistry` | `archiveSession(id)` |
 * | delete a workspace | `workspaceRegistry` | `delete(id)` |
 *
 * Services are read lazily through `ctx.get(...)` on each call, never captured at
 * load time: the plugin may be composed before the registry has started, and a
 * captured `undefined` would look like a permanent capability loss.
 *
 * **"Active" means what the web page shows.** A workspace is active when the
 * registry lists it *and* it has at least one non-archived session; a session is
 * visible when the workspace accounts for it and it is not in the registry-global
 * `archivedSessionIds` set. Archiving keeps the `sessionIds` slot — it hides the
 * row without deleting history — which is exactly the semantics the UI renders.
 *
 * @module dsh-lan-manager/api
 */
import { readFileSync, readdirSync } from "node:fs";

/** Reasons an operation can fail, mapped to HTTP status by the router. */
export const Failure = Object.freeze({
  NO_REGISTRY: "workspace-registry-unavailable",
  NO_AGENTS: "agent-service-unavailable",
  NO_MESSAGE_FACTORY: "user-message-factory-unavailable",
  NOT_FOUND: "not-found",
  BAD_REQUEST: "bad-request",
  BUSY: "session-busy",
});

/**
 * Test/caller seams, keyed by ctx.
 *
 * Deliberately a WeakMap rather than a property on the context: Cordis guards
 * property access on its context object, so reading `ctx.somethingUndeclared`
 * throws "cannot get property ... without inject". A seam that can trip the
 * guard is worse than no seam.
 */
const ctxOverrides = new WeakMap();

/**
 * Attach overrides to a context without mutating it.
 * @param ctx - harness context (or a plain object in tests).
 * @param values - `{ sessionCacheDir, archivedSessionIds }`.
 * @returns the same ctx, for chaining.
 */
export function setContextOverrides(ctx, values) {
  const existing = ctxOverrides.get(ctx) ?? {};
  ctxOverrides.set(ctx, { ...existing, ...values });
  return ctx;
}

/** An operation error carrying an HTTP status and a stable code. */
export class ApiError extends Error {
  /**
   * @param code - one of {@link Failure}.
   * @param message - human-readable detail.
   * @param status - HTTP status to answer with.
   */
  constructor(code, message, status = 400) {
    super(message);
    this.name = "ApiError";
    this.code = code;
    this.status = status;
  }
}

/**
 * Build the user-message factory, tolerating an older harness that does not
 * export `createUserMessage` from `dsh-llm`.
 *
 * The primary path is upstream's own factory — it stamps the source and id the
 * agent loop expects. The fallback mirrors the shape the SDK server builds
 * (`{ role: 'user', content, source: { kind: 'user' } }`) so the plugin still
 * works, and reports which path was taken so a mismatch is visible rather than
 * silent.
 *
 * @param load - injectable dynamic importer, for tests.
 * @returns `{ create, strategy }`.
 */
export async function resolveMessageFactory(load = (specifier) => import(specifier)) {
  try {
    const mod = await load("@deepseek-ai/dsh-llm");
    if (typeof mod?.createUserMessage === "function") {
      return { create: mod.createUserMessage, strategy: "dsh-llm:createUserMessage" };
    }
  } catch {
    // Not resolvable from this profile; fall through to the literal shape.
  }
  let counter = 0;
  const create = ({ content }) => ({
    id: `lan-manager-${Date.now()}-${++counter}`,
    role: "user",
    content,
    source: { kind: "user" },
  });
  return { create, strategy: "inline-user-message" };
}

/**
 * Normalize a prompt into model content blocks.
 * @param prompt - a string, or an array of already-shaped content blocks.
 * @returns content blocks.
 */
export function toContent(prompt) {
  if (typeof prompt === "string") {
    const text = prompt.trim();
    if (!text) throw new ApiError(Failure.BAD_REQUEST, "prompt must be a non-empty string", 400);
    return [{ type: "text", text }];
  }
  if (Array.isArray(prompt) && prompt.length > 0) return prompt;
  throw new ApiError(Failure.BAD_REQUEST, "prompt must be a string or a non-empty block array", 400);
}

/**
 * The workspace registry, or a typed failure.
 * @param ctx - harness context.
 * @returns the registry service.
 */
export function registry(ctx) {
  const service = ctx?.get?.("workspaceRegistry");
  if (!service || typeof service.list !== "function") {
    throw new ApiError(Failure.NO_REGISTRY, "workspaceRegistry service is not composed in this profile", 503);
  }
  return service;
}

/**
 * The agent registry, or a typed failure.
 * @param ctx - harness context.
 * @returns the agent service.
 */
export function agents(ctx) {
  const service = ctx?.get?.("agents");
  if (!service || typeof service.get !== "function") {
    throw new ApiError(Failure.NO_AGENTS, "agents service is not composed in this profile", 503);
  }
  return service;
}

/**
 * Read the registry-global archive set as plain strings.
 *
 * The durable state lives beside the `workspaces` table; the public
 * `Workspace.sessionIds` does not subtract archives, so the UI's notion of a
 * visible row is reconstructed here.
 *
 * @param ctx - harness context.
 * @returns a `Set<string>` of archived session ids (possibly empty).
 */
export function archivedSet(ctx) {
  // `ctx.get(...)` only: reading an undeclared service as a property throws
  // "cannot get property ... without inject" and fails the whole request.
  const seam = ctxOverrides.get(ctx);
  if (seam?.archivedSessionIds instanceof Set) return new Set(seam.archivedSessionIds);
  if (Array.isArray(seam?.archivedSessionIds)) return new Set(seam.archivedSessionIds.map(String));
  const state = ctx?.get?.("workspaceDomainState");
  const ids = state?.archivedSessionIds;
  if (Array.isArray(ids)) return new Set(ids.map(String));

  // Fall back to the durable registry file when the state row is not exposed.
  try {
    const home = process.env.DSH_HOME || `${process.env.HOME}/.dsh`;
    const raw = readFileSync(`${home}/storages/workspace.json`, "utf8");
    const parsed = JSON.parse(raw)?.global?.archivedSessionIds;
    if (Array.isArray(parsed)) return new Set(parsed.map(String));
  } catch {
    // No readable state: treat nothing as archived rather than hiding rows.
  }
  return new Set();
}

/**
 * Project one workspace to its API shape.
 * @param workspace - a registry `Workspace`.
 * @param archived - the archive set.
 * @returns the workspace with its visible sessions.
 */
export function projectWorkspace(workspace, archived) {
  const sessionIds = Array.isArray(workspace?.sessionIds) ? workspace.sessionIds.map(String) : [];
  const visible = sessionIds.filter((id) => !archived.has(id));
  return {
    id: String(workspace?.id ?? ""),
    path: String(workspace?.path ?? ""),
    title: String(workspace?.title ?? ""),
    createdAt: workspace?.createdAt ?? null,
    updatedAt: workspace?.updatedAt ?? null,
    sessionCount: visible.length,
    hiddenSessionCount: sessionIds.length - visible.length,
    sessionIds: visible,
  };
}

/**
 * List active workspaces — those the web page shows — newest display order kept.
 * @param ctx - harness context.
 * @param options - `{ includeEmpty?: boolean }`; empty workspaces are hidden by
 *   default because the page shows a workspace only once it owns a session.
 * @returns `{ workspaces, archivedCount, strategy }`.
 */
/**
 * The registry's workspaces, or an empty list when the service is absent.
 *
 * The page's grouping is derived from sessions, not from the registry, so a
 * profile without `workspaceRegistry` can still answer "what is active" — it
 * just loses the pinned title, explicit order and stable id. Failing the whole
 * route over missing *metadata* would be wrong.
 *
 * @param ctx - harness context.
 * @returns the registry workspaces, possibly empty.
 */
function tryRegistryList(ctx) {
  try {
    return registry(ctx).list() ?? [];
  } catch {
    return [];
  }
}

/**
 * The set of visible sessions, grouped the way the web page groups them.
 *
 * **This is the correction that matters.** The UI's workspace list is not the
 * registry's: `workspaceRegistry` holds only the workspaces a user explicitly
 * added (on this machine: two), while the page's groups are derived from the
 * sessions themselves — each session's `cwd` is its workspace. So the source of
 * truth for "what the page shows" is the session projection, and the registry is
 * metadata layered on top (a pinned title, an explicit order, an id).
 *
 * @param ctx - harness context.
 * @returns `{ groups, archived }` where `groups` is a `Map<path, {sessions}>`.
 */
function groupVisibleSessions(ctx) {
  const archived = archivedSet(ctx);
  const registryEntries = tryRegistryList(ctx);
  const registryIds = new Set(registryEntries.map((w) => String(w.path)));
  // `sessionCacheDir` is an override for tests and for a caller that keeps the
  // projection somewhere other than the default home.
  const home = process.env.DSH_HOME || `${process.env.HOME}/.dsh`;
  const dir = ctxOverrides.get(ctx)?.sessionCacheDir ?? `${home}/storages/session_projcache/sessions`;
  const groups = new Map();

  let entries = [];
  try {
    entries = readdirSync(dir).filter((name) => name.endsWith(".json"));
  } catch {
    entries = [];
  }

  for (const name of entries) {
    const sessionId = name.slice(0, -5);
    if (archived.has(sessionId)) continue;
    let doc;
    try {
      doc = JSON.parse(readFileSync(`${dir}/${name}`, "utf8"));
    } catch {
      continue; // A half-written projection row is skipped, never fatal.
    }
    const identity = doc?.record?.identity ?? {};
    const path = String(identity.cwd ?? "") || "(unknown)";
    const rows = doc?.record?.rows ?? {};
    const title = rows?.title?.val ?? null;
    const stats = rows?.sessionStats?.val ?? {};
    if (!groups.has(path)) groups.set(path, []);
    groups.get(path).push({
      sessionId,
      workspacePath: path,
      title: typeof title === "string" ? title : null,
      createdAt: Number(identity.createdAt) || 0,
      turns: Number(stats.turns) || 0,
      steps: Number(stats.steps) || 0,
    });
  }

  for (const sessions of groups.values()) sessions.sort((a, b) => b.createdAt - a.createdAt);
  return { groups, archived, registryPaths: registryIds };
}

/**
 * List active workspaces — the ones the web page shows.
 * @param ctx - harness context.
 * @param options - `{ includeEmpty?: boolean }`.
 * @returns `{ workspaces, archivedCount, strategy }`.
 */
export function listActiveWorkspaces(ctx, options = {}) {
  const { groups, archived, registryPaths } = groupVisibleSessions(ctx);
  const byPath = new Map(tryRegistryList(ctx).map((w) => [String(w.path), w]));

  const workspaces = [];
  for (const [path, sessions] of groups) {
    const registered = byPath.get(path);
    workspaces.push({
      id: registered ? String(registered.id) : null,
      path,
      title: registered?.title ?? path.split("/").filter(Boolean).pop() ?? path,
      registered: Boolean(registered),
      createdAt: registered?.createdAt ?? null,
      updatedAt: registered?.updatedAt ?? null,
      sessionCount: sessions.length,
      hiddenSessionCount: 0,
      newestSessionAt: sessions[0]?.createdAt ?? 0,
      sessionIds: sessions.map((s) => s.sessionId),
    });
  }

  // A registered workspace with no visible session is still a real workspace; the
  // page shows it as an empty group. It is included only when asked for, so the
  // default answer stays "what has activity".
  if (options.includeEmpty) {
    for (const [path, w] of byPath) {
      if (groups.has(path)) continue;
      workspaces.push({
        id: String(w.id),
        path,
        title: w.title ?? path,
        registered: true,
        createdAt: w.createdAt ?? null,
        updatedAt: w.updatedAt ?? null,
        sessionCount: 0,
        hiddenSessionCount: 0,
        newestSessionAt: 0,
        sessionIds: [],
      });
    }
  }

  workspaces.sort((a, b) => b.newestSessionAt - a.newestSessionAt);
  return {
    workspaces,
    archivedCount: archived.size,
    totalWorkspaces: workspaces.length,
    registryWorkspaces: registryPaths.size,
    strategy: "session-projection",
  };
}

/**
 * Every visible session across every active workspace, newest first per workspace.
 * @param ctx - harness context.
 * @returns `{ sessions, count }`.
 */
export function listAllActiveSessions(ctx) {
  const { groups } = groupVisibleSessions(ctx);
  const byPath = new Map(tryRegistryList(ctx).map((w) => [String(w.path), w]));
  const sessions = [];
  for (const [path, list] of groups) {
    const registered = byPath.get(path);
    for (const s of list) {
      sessions.push({
        ...s,
        workspaceId: registered ? String(registered.id) : null,
        workspaceTitle: registered?.title ?? path.split("/").filter(Boolean).pop() ?? path,
      });
    }
  }
  return { sessions, count: sessions.length };
}

export function findWorkspace(ctx, selector = {}) {
  const reg = registry(ctx);
  if (selector.workspaceId) {
    const found = reg.get(selector.workspaceId);
    if (!found) throw new ApiError(Failure.NOT_FOUND, `no workspace ${selector.workspaceId}`, 404);
    return found;
  }
  if (selector.path) {
    const wanted = String(selector.path);
    const found = reg.list().find((w) => String(w.path) === wanted);
    if (!found) throw new ApiError(Failure.NOT_FOUND, `no workspace at ${wanted}`, 404);
    return found;
  }
  throw new ApiError(Failure.BAD_REQUEST, "workspaceId or path is required", 400);
}

/**
 * List the visible sessions of one workspace.
 * @param ctx - harness context.
 * @param selector - `{ workspaceId }` or `{ path }`.
 * @returns the projected workspace.
 */
export function listWorkspaceSessions(ctx, selector) {
  // Resolve in order of specificity: a registry id, then an exact session-derived
  // path, then a path suffix. The page's groups can have no registry id at all
  // (a folder that was never explicitly added), so a suffix has to work.
  const { groups } = groupVisibleSessions(ctx);
  const raw = String(selector.workspaceId ?? selector.path ?? "").replace(/\/+$/, "");
  if (!raw) throw new ApiError(Failure.BAD_REQUEST, "workspaceId or path is required", 400);

  let path;
  let registered;
  try {
    registered = findWorkspace(ctx, { workspaceId: raw });
    path = String(registered.path);
  } catch {
    registered = undefined;
  }
  if (!path) {
    if (groups.has(raw)) path = raw;
    else path = [...groups.keys()].find((p) => p === raw || p.endsWith(`/${raw}`));
  }
  if (!path) {
    const known = [...groups.keys()];
    throw new ApiError(
      Failure.NOT_FOUND,
      `no active workspace matching "${raw}"${known.length ? ` (known: ${known.join(", ")})` : ""}`,
      404,
    );
  }

  const sessions = groups.get(path) ?? [];
  const meta = registered ?? tryRegistryList(ctx).find((w) => String(w.path) === path);
  return {
    id: meta ? String(meta.id) : null,
    path,
    title: meta?.title ?? path.split("/").filter(Boolean).pop() ?? path,
    registered: Boolean(meta),
    createdAt: meta?.createdAt ?? null,
    updatedAt: meta?.updatedAt ?? null,
    sessionCount: sessions.length,
    hiddenSessionCount: 0,
    sessionIds: sessions.map((s) => s.sessionId),
  };
}

/**
 * Every visible session across every active workspace, de-duplicated.
 * @param ctx - harness context.
 * @returns `{ sessions: [{sessionId, workspaceId, workspacePath, title}] }`.
 */
/**
 * Enqueue a prompt on one session.
 *
 * `followup` is the same entry point the SDK server uses for a queued user
 * message, so a prompt sent here is a normal turn, not a side channel.
 *
 * @param ctx - harness context.
 * @param sessionId - target session.
 * @param prompt - string or content blocks.
 * @param factory - a resolved message factory.
 * @param options - `{ wakeup?: boolean }`.
 * @returns a delivery receipt.
 */
export function promptSession(ctx, sessionId, prompt, factory, options = {}) {
  const service = agents(ctx);
  const agent = service.get(sessionId);
  if (!agent) {
    throw new ApiError(
      Failure.NOT_FOUND,
      `session ${sessionId} has no live agent (start it in the UI, then retry)`,
      404,
    );
  }
  if (typeof agent.followup !== "function") {
    throw new ApiError(Failure.NO_AGENTS, "agent does not accept follow-up input", 503);
  }
  const message = factory.create({ content: toContent(prompt) });
  agent.followup(message);
  return {
    sessionId,
    delivered: true,
    messageId: message?.id ?? null,
    wakeup: options.wakeup !== false,
  };
}

/**
 * Fan a prompt out to every active session, or to a chosen subset.
 *
 * Delivery is per-session and never all-or-nothing: one session without a live
 * agent must not stop the rest of the fleet, so failures are reported beside
 * successes instead of aborting the request.
 *
 * @param ctx - harness context.
 * @param prompt - string or content blocks.
 * @param factory - a resolved message factory.
 * @param options - `{ sessionIds?: string[], limit?: number, wakeup?: boolean }`.
 * @returns `{ delivered, failed, total }`.
 */
export function promptAllActive(ctx, prompt, factory, options = {}) {
  const { sessions } = listAllActiveSessions(ctx);
  const wanted = Array.isArray(options.sessionIds) && options.sessionIds.length > 0
    ? sessions.filter((s) => options.sessionIds.includes(s.sessionId))
    : sessions;
  const capped = Number.isInteger(options.limit) && options.limit > 0
    ? wanted.slice(0, options.limit)
    : wanted;

  const delivered = [];
  const failed = [];
  for (const session of capped) {
    try {
      delivered.push(promptSession(ctx, session.sessionId, prompt, factory, options));
    } catch (error) {
      failed.push({
        sessionId: session.sessionId,
        code: error?.code ?? "error",
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }
  return { delivered, failed, total: capped.length, considered: sessions.length };
}

/**
 * Archive one session (hide it from the UI, keep its history and its slot).
 * @param ctx - harness context.
 * @param sessionId - target session.
 * @returns `{ sessionId, archived: true }`.
 */
export async function archiveSession(ctx, sessionId) {
  const reg = registry(ctx);
  if (typeof reg.archiveSession !== "function") {
    throw new ApiError(Failure.NO_REGISTRY, "this harness does not expose archiveSession", 503);
  }
  const exists = reg.list().some((w) => (w.sessionIds ?? []).map(String).includes(String(sessionId)));
  if (!exists) throw new ApiError(Failure.NOT_FOUND, `no session ${sessionId} in any workspace`, 404);
  await reg.archiveSession(sessionId);
  return { sessionId, archived: true };
}

/**
 * Delete a workspace. With `archiveSessions: true` (the default) the sessions are
 * archived first so a stray delete does not silently drop history; the registry
 * itself never touches the folder or the session logs.
 * @param ctx - harness context.
 * @param workspaceId - target workspace.
 * @param options - `{ archiveSessions?: boolean }`.
 * @returns a deletion receipt.
 */
export async function deleteWorkspace(ctx, workspaceId, options = {}) {
  const reg = registry(ctx);
  const workspace = findWorkspace(ctx, { workspaceId });
  const sessionIds = (workspace.sessionIds ?? []).map(String);
  const archiveFirst = options.archiveSessions !== false;
  const archived = [];
  const archiveFailures = [];
  if (archiveFirst && typeof reg.archiveSession === "function") {
    for (const id of sessionIds) {
      try {
        await reg.archiveSession(id);
        archived.push(id);
      } catch (error) {
        archiveFailures.push({ sessionId: id, message: error instanceof Error ? error.message : String(error) });
      }
    }
  }
  const removed = await reg.delete(workspaceId);
  if (!removed) throw new ApiError(Failure.NOT_FOUND, `no workspace ${workspaceId}`, 404);
  return {
    workspaceId: String(workspaceId),
    path: workspace.path,
    deleted: true,
    archivedSessionIds: archived,
    archiveFailures,
  };
}
