/**
 * `dsh-lan-manager` — a LAN-scoped management API for a DeepSeek Harness host.
 *
 * It registers one prefix route on the harness web server carrying the six
 * capabilities a fleet operator needs from another machine:
 *
 * 1. list active workspaces — the ones the web page shows
 * 2. list the visible sessions of any active workspace
 * 3. prompt one session, or fan a prompt across every active session
 * 4. delete a workspace (archiving its sessions first by default)
 * 5. archive a session — hidden in the UI, history and slot kept
 * 6. everything above reachable **only** from loopback, RFC 1918, and the
 *    Tailscale `100.64.0.0/10` range
 *
 * It reaches the harness through host services (`workspaceRegistry`, `agents`)
 * read lazily from the context — it does not import harness internals, patch the
 * tree, or own an adapter, so a harness upgrade cannot desynchronise it. The one
 * dynamic import is `@deepseek-ai/dsh-llm`'s `createUserMessage`, used to build a
 * prompt the same way the SDK server does; a fallback keeps the plugin working if
 * that export moves.
 *
 * The route is registered through `ctx.webServer.register` with a `prefix` kind,
 * and disposed through `ctx.effect` so an unload leaves no dangling handler.
 *
 * @module dsh-lan-manager
 */
import { resolveConfig, localAddresses, DEFAULT_BASE_PATH } from "./config.js";
import { resolveMessageFactory } from "./api.js";
import { createHandler } from "./router.js";

export { DEFAULT_BASE_PATH, localAddresses, parseList, resolveConfig } from "./config.js";
export {
  ApiError,
  Failure,
  agents,
  archiveSession,
  archivedSet,
  deleteWorkspace,
  findWorkspace,
  listActiveWorkspaces,
  listAllActiveSessions,
  listWorkspaceSessions,
  projectWorkspace,
  promptAllActive,
  promptSession,
  registry,
  resolveMessageFactory,
  toContent,
} from "./api.js";
export { createHandler, isAllowedOrigin, readJsonBody, sendJson, subPath } from "./router.js";
export {
  DEFAULT_IPV4_NETWORKS,
  DEFAULT_IPV6_NETWORKS,
  checkAddress,
  ipv4InNetwork,
  ipv4ToInt,
  normalizeIpv6,
  peerAddress,
  unwrapAddress,
} from "./net.js";

/** Plugin name, as the harness registry shows it. */
export const name = "dsh-lan-manager";

/**
 * Services that must exist before `apply` runs.
 *
 * `webServer` is required: the plugin exists to register a route on it, so Cordis
 * must wait for the host webserver rather than run `apply` against a missing
 * service.
 *
 * `workspaceRegistry` and `agents` are deliberately **not** injected. Injection
 * resolves before any session or workspace exists, and every operation here is
 * per-request; reading them lazily through `ctx.get(...)` keeps one missing
 * service a typed `503` on the routes that need it instead of a load failure that
 * would take the whole profile down.
 */
export const inject = ["webServer"];

/**
 * Run the plugin: resolve config, register the route, log where it listens.
 * @param ctx - the harness context; the `webServer` service is injected.
 * @param config - the row config; see {@link resolveConfig}.
 * @returns an object exposing the disposer and the resolved config (for tests).
 */
export function apply(ctx, config = {}) {
  const resolved = resolveConfig(config);
  const log = resolved.logToHost
    ? (message) => {
      if (typeof ctx?.logger?.info === "function") ctx.logger.info(message);
      else console.log(message);
    }
    : () => {};

  // Read through `ctx.get`: a plain `ctx.webServer` property access throws
  // "cannot get property ... without inject" for a service the row did not
  // declare, and a declared one is reached the same way.
  const webServer = ctx?.get?.("webServer");
  if (!webServer || typeof webServer.register !== "function") {
    // No browser host in this profile (headless, sdk, acp). Not an error: the
    // plugin simply has nothing to attach to, and taking the profile down here
    // would break a deployment that never wanted the web UI.
    log(`dsh-lan-manager: no webServer in this profile — API not mounted`);
    return { mounted: false, config: resolved };
  }

  const state = { messageFactory: undefined, mounted: false, error: undefined };
  // A message factory needs a dynamic import, which cannot be awaited from a
  // synchronous apply(); resolve it in the background and let the first request
  // that needs it await the same promise.
  const factoryPromise = resolveMessageFactory().then(
    (factory) => {
      state.messageFactory = factory;
      return factory;
    },
    (error) => {
      state.error = error;
      throw error;
    },
  );

  const provisionalFactory = {
    strategy: "pending",
    create: () => {
      throw new Error("dsh-lan-manager: message factory not ready yet; retry shortly");
    },
  };

  const handler = createHandler({
    ctx,
    config: resolved,
    // The handler closes over a live view: once the promise settles the real
    // factory is used for every subsequent request.
    get messageFactory() {
      return state.messageFactory ?? provisionalFactory;
    },
    log,
  });

  const dispose = webServer.register({
    kind: "prefix",
    path: resolved.basePath,
    handler,
  });

  if (typeof ctx?.effect === "function") ctx.effect(() => () => dispose?.());
  ctx.on?.("dispose", () => dispose?.());

  const addresses = localAddresses();
  const lanFacing = addresses.filter(
    (a) => a.family === "ipv4" && !a.address.startsWith("169.254."),
  );
  log(
    `dsh-lan-manager: API mounted at ${resolved.basePath} ` +
      `(token ${resolved.token ? "required" : "not set"})` +
      (lanFacing.length > 0
        ? ` — reachable at ${lanFacing.map((a) => `${a.address}:${webServer.port ?? "?"}${resolved.basePath}`).join(", ")}`
        : ""),
  );
  log(
    `dsh-lan-manager: the web server must bind 0.0.0.0 for LAN access; ` +
      `loopback-only binds are reachable from this machine alone`,
  );

  state.mounted = true;
  return { mounted: true, config: resolved, factoryPromise, dispose };
}

/**
 * The module's plugin declaration.
 *
 * This **must** be the default export: the Cordis loader reads `name` and
 * `inject` off the module's default value, so a named `inject` export is ignored
 * and a service declared there is still guarded on access — which fails the whole
 * profile with "cannot get property ... without inject".
 */
export default { name, inject, apply };
