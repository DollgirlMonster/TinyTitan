/**
 * The shipped bundle patch must not set a field that documents an environment
 * fallback.
 *
 * `resolveConfig` reads a row config value *before* the environment, so writing one
 * into `cordis.patch.yml` silently disables its documented fallback. That is what
 * `basePath: /dsh-lan` and `discoveryIntervalSeconds: 60` did until TT-031: the
 * README and the config table both promise `DSH_LAN_BASE_PATH` and
 * `DSH_LAN_DISCOVERY_SECONDS`, and neither could ever take effect. The values are
 * commented now, so the code's defaults apply and the environment works.
 *
 * The guard is a text check on purpose: the failure is a *line in a shipped file*,
 * not anything the code can see.
 */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { resolveConfig } from "../src/config.js";

const PATCH = readFileSync(new URL("../cordis.patch.yml", import.meta.url), "utf8");

/** Fields whose documented fallback is an environment variable. */
const ENV_BACKED = [
  "basePath",
  "discoveryIntervalSeconds",
  "groupKey",
  "peers",
  "resolveConcurrency",
  "allowAddresses",
  "probeTimeoutMs",
];

test("the shipped patch sets no field whose fallback is an environment variable", () => {
  for (const field of ENV_BACKED) {
    const written = new RegExp(`^\\s+${field}:`, "m").test(PATCH);
    assert.equal(
      written,
      false,
      `${field} is written into cordis.patch.yml, which beats its environment fallback`,
    );
  }
});

test("both pinned fields now resolve from the environment", () => {
  const resolved = resolveConfig(
    {},
    { DSH_LAN_BASE_PATH: "/fleet", DSH_LAN_DISCOVERY_SECONDS: "9" },
  );
  assert.equal(resolved.basePath, "/fleet");
  assert.equal(resolved.discoveryIntervalSeconds, 9);
});

test("the code's defaults are the values the patch used to write", () => {
  // Commenting the lines out must not change behaviour for anyone who never sets
  // the environment: these were the shipped values.
  const resolved = resolveConfig({}, {});
  assert.equal(resolved.basePath, "/dsh-lan");
  assert.equal(resolved.discoveryIntervalSeconds, 60);
});
