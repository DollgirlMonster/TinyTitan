/**
 * The mount path: `apply()` with a web server present.
 *
 * The refusal path and the "no webServer in this profile" path are covered in
 * `support.test.js`. What was untested is the middle one — the plugin actually
 * attaching: that it registers exactly one `prefix` route at its base path, hands
 * the server a handler, announces what it mounted, and tears both the route and the
 * discovery timer down on disposal.
 *
 * Discovery is switched off here. The sources are real ones (Tailscale, Bonjour, a
 * subnet sweep) and this test must not touch a network.
 */
import assert from "node:assert/strict";
import test from "node:test";

import { apply, DEFAULT_BASE_PATH } from "../src/index.js";
import { SUPPORTED_DSH_VERSION } from "../src/versions.js";

/** A context with a web server, capturing what the plugin does to it. */
function mountingContext(lines) {
  const state = { registered: [], effectCleanup: null, disposeHandlers: [] };
  const ctx = {
    get: (name) => (name === "webServer"
      ? {
        port: 3080,
        register: (options) => {
          state.registered.push(options);
          return () => lines.push("route disposed");
        },
      }
      : undefined),
    effect: (register) => {
      state.effectCleanup = register();
    },
    on: (event, handler) => {
      if (event === "dispose") state.disposeHandlers.push(handler);
    },
    logger: {
      info: (message) => lines.push(String(message)),
      error: (message) => lines.push(String(message)),
    },
  };
  return { ctx, state };
}

/** Run `body` with the harness version pinned to the one the plugin supports. */
async function onSupportedHarness(body) {
  const previous = process.env.DSH_VERSION;
  process.env.DSH_VERSION = SUPPORTED_DSH_VERSION;
  try {
    return await body();
  } finally {
    if (previous === undefined) delete process.env.DSH_VERSION;
    else process.env.DSH_VERSION = previous;
  }
}

test("apply() mounts one prefix route, announces it, and disposes it", async () => {
  await onSupportedHarness(async () => {
    const lines = [];
    const { ctx, state } = mountingContext(lines);
    const result = apply(ctx, {
      discoverTailscale: false,
      discoverBonjour: false,
      discoverSubnet: false,
      logToHost: true,
    });

    assert.equal(result?.mounted, true, "a profile with a web server must mount");
    assert.equal(state.registered.length, 1, "exactly one route");
    const route = state.registered[0];
    assert.equal(route.kind, "prefix");
    assert.equal(route.path, DEFAULT_BASE_PATH);
    assert.equal(typeof route.handler, "function");

    // The banner names where it mounted and whether a key is required.
    assert.ok(
      lines.some((line) => line.includes(`API mounted at ${DEFAULT_BASE_PATH}`)),
      `expected a mount banner, got: ${lines.join(" | ")}`,
    );
    assert.ok(
      lines.some((line) => line.includes("token required")),
      "the default group key means a token is required",
    );
    // And it does not claim to be reachable from the network — the harness binds
    // loopback or nothing (TT-020).
    assert.ok(
      lines.some((line) => line.includes("loopback only")),
      `expected the loopback notice, got: ${lines.join(" | ")}`,
    );

    // The handler is usable: a public source is refused by the address fence, with
    // a JSON body — which is what proves `createHandler` was wired in and that the
    // fence runs before any parsing.
    const captured = { status: 0, body: "" };
    await route.handler(
      {
        method: "GET",
        url: `${DEFAULT_BASE_PATH}/health`,
        headers: {},
        socket: { remoteAddress: "8.8.8.8" },
      },
      {
        writeHead: (status) => { captured.status = status; },
        end: (chunk) => { if (chunk !== undefined) captured.body += String(chunk); },
      },
    );
    assert.equal(captured.status, 403, "a public source must be refused");
    assert.match(captured.body, /source-not-allowed/);

    await result.factoryPromise;

    // Disposal is registered on both seams, and running the effect's cleanup tears
    // the route down and stops the discovery timer.
    assert.equal(typeof state.effectCleanup, "function", "ctx.effect must be used");
    assert.equal(state.disposeHandlers.length, 1, "ctx.on('dispose') must be used");
    state.effectCleanup();
    assert.ok(lines.includes("route disposed"), "disposal must dispose the route");
  });
});

test("apply() reports an unmounted profile without throwing, and does not mount", async () => {
  await onSupportedHarness(async () => {
    const lines = [];
    const { ctx, state } = mountingContext(lines);
    // A headless profile: `get('webServer')` answers undefined.
    ctx.get = () => undefined;
    const result = apply(ctx, { logToHost: true });
    assert.equal(result?.mounted, false);
    assert.equal(state.registered.length, 0);
    assert.ok(
      lines.some((line) => line.includes("no webServer in this profile")),
      `expected the unmounted notice, got: ${lines.join(" | ")}`,
    );
  });
});
