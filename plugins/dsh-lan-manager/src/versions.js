/**
 * Version reporting for the group view.
 *
 * A manager listing a fleet wants to know *which harness* each member runs, so a
 * mixed group is visible rather than inferred. Both numbers are read best-effort
 * and are `null` when they cannot be resolved — a missing version must never stop
 * a plugin from mounting, and the manager prints "unknown" rather than a guess.
 *
 * @module dsh-lan-manager/versions
 */

import { createRequire } from "node:module";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, parse } from "node:path";
import { fileURLToPath } from "node:url";

/** Read and parse one package.json, or `undefined`. */
function readPackage(path) {
  if (!existsSync(path)) return undefined;
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    return parsed?.name ? parsed : undefined;
  } catch {
    return undefined;
  }
}

/**
 * Walk up from a file looking for the package that owns it.
 *
 * `require.resolve` on a `package.json` is refused whenever a package declares
 * `exports` — the harness does — so the walk is the reliable route.
 *
 * @param start - file to start from.
 * @param wanted - the package name to match, or `undefined` for any.
 * @returns the parsed package.json, or `undefined`.
 */
export function packageFrom(start, wanted) {
  let directory = dirname(start);
  for (let depth = 0; depth < 10; depth += 1) {
    const found = readPackage(join(directory, "package.json"));
    if (found && (!wanted || found.name === wanted)) return found;
    const parent = dirname(directory);
    if (parent === directory || parent === parse(directory).root) return undefined;
    directory = parent;
  }
  return undefined;
}

/**
 * Find `@deepseek-ai/<shortName>` beside an already-resolved sibling.
 *
 * A pnpm layout resolves `@deepseek-ai/dsh-llm` to a real path inside `.pnpm`,
 * where walking up never reaches `dsh`; but the two packages are installed side
 * by side in the same scope directory, which is what this looks for.
 *
 * @param from - a resolved file inside the sibling.
 * @param shortName - the package to find, e.g. `dsh`.
 * @returns the parsed package.json, or `undefined`.
 */
export function siblingPackage(from, shortName) {
  let directory = dirname(from);
  for (let depth = 0; depth < 10; depth += 1) {
    const found = readPackage(join(directory, "@deepseek-ai", shortName, "package.json"));
    if (found) return found;
    const parent = dirname(directory);
    if (parent === directory || parent === parse(directory).root) return undefined;
    directory = parent;
  }
  return undefined;
}

/**
 * The harness version the plugin is running inside.
 *
 * There is no host service that carries it, so this tries several anchors and
 * accepts `null`.
 *
 * @param options - `{ require, argv, env }` for tests.
 * @returns the version string, or `null`.
 */
export function dshVersion({ require: load, argv = process.argv, env = process.env } = {}) {
  if (env.DSH_VERSION) return String(env.DSH_VERSION);

  let resolver;
  try {
    resolver = load ?? createRequire(import.meta.url);
  } catch {
    return null;
  }

  // The surest anchor: a resolved harness entry point.
  try {
    const found = packageFrom(resolver.resolve("@deepseek-ai/dsh"), "@deepseek-ai/dsh");
    if (found?.version) return found.version;
  } catch {
    // Not resolvable from the plugin's own location, which pnpm layouts often
    // make true.
  }

  // Then the sibling scope directory, which usually *is* resolvable.
  try {
    const found = siblingPackage(resolver.resolve("@deepseek-ai/dsh-llm"), "dsh");
    if (found?.version) return found.version;
  } catch {
    // No sibling either.
  }

  // Finally the running harness's own entry point, when it is a file we can walk.
  const entry = argv?.[1];
  if (entry) {
    const found = packageFrom(entry, "@deepseek-ai/dsh");
    if (found?.version) return found.version;
  }
  return null;
}

/**
 * This plugin's own version, so a manager can tell an old member from a new one.
 * @param options - `{ moduleUrl }` for tests.
 * @returns the version string, or `null`.
 */
export function pluginVersion({ moduleUrl } = {}) {
  try {
    const here = dirname(fileURLToPath(moduleUrl ?? import.meta.url));
    return packageFrom(join(here, "index.js"), "dsh-lan-manager")?.version ?? null;
  } catch {
    return null;
  }
}
