/**
 * Configuration resolution for `dsh-lan-manager`.
 *
 * Every field is optional and resolved once at apply time. Environment variables
 * are read as a fallback so a deployment can inject the token without writing it
 * into a patch file that ends up in a repository.
 *
 * | Key | Env fallback | Default |
 * |---|---|---|
 * | `basePath` | `DSH_LAN_BASE_PATH` | `/dsh-lan` |
 * | `token` | `DSH_LAN_TOKEN` | none (no token required) |
 * | `allowedHosts` | — | the machine's own LAN + Tailscale addresses |
 * | `allowAddresses` | `DSH_LAN_ALLOW` (comma separated) | `[]` |
 * | `includeEmptyWorkspaces` | — | `false` |
 * | `enforceOrigin` | — | `true` |
 *
 * @module dsh-lan-manager/config
 */

import { networkInterfaces } from "node:os";

/** The route prefix an unconfigured install mounts. */
export const DEFAULT_BASE_PATH = "/dsh-lan";

/**
 * Describe this host's own candidate addresses, for the `/health` banner.
 * @returns `[{ iface, address, family }]` excluding loopback and link-local.
 */
export function localAddresses() {
  const out = [];
  const nets = networkInterfaces();
  for (const [iface, entries] of Object.entries(nets)) {
    for (const entry of entries ?? []) {
      if (!entry?.address) continue;
      const family = entry.family === "IPv4" || entry.family === 4 ? "ipv4" : "ipv6";
      if (family === "ipv4" && entry.address.startsWith("127.")) continue;
      if (family === "ipv6" && entry.address === "::1") continue;
      out.push({ iface, address: entry.address, family });
    }
  }
  return out;
}

/**
 * Split a comma/space separated list, dropping empties.
 * @param value - raw string.
 * @returns trimmed entries.
 */
export function parseList(value) {
  if (Array.isArray(value)) return value.map((v) => String(v).trim()).filter(Boolean);
  if (typeof value !== "string") return [];
  return value.split(/[,\s]+/).map((v) => v.trim()).filter(Boolean);
}

/**
 * Resolve plugin configuration.
 * @param raw - the row's `config` object.
 * @param env - environment source (injectable for tests).
 * @returns the resolved config consumed by the router and plugin.
 */
export function resolveConfig(raw = {}, env = process.env) {
  const basePathRaw = raw.basePath ?? env.DSH_LAN_BASE_PATH ?? DEFAULT_BASE_PATH;
  let basePath = String(basePathRaw).trim();
  if (!basePath.startsWith("/")) basePath = `/${basePath}`;
  basePath = basePath.replace(/\/+$/, "") || DEFAULT_BASE_PATH;

  const token = raw.token ?? env.DSH_LAN_TOKEN ?? "";
  const allowAddresses = [
    ...parseList(raw.allowAddresses ?? env.DSH_LAN_ALLOW ?? ""),
  ];

  return {
    version: raw.version ?? null,
    basePath,
    token: token ? String(token) : "",
    allowAddresses,
    ipv4Networks: Array.isArray(raw.ipv4Networks) ? raw.ipv4Networks : undefined,
    ipv6Networks: Array.isArray(raw.ipv6Networks) ? raw.ipv6Networks : undefined,
    originNetworks: Array.isArray(raw.originNetworks) ? raw.originNetworks : undefined,
    trustedOrigins: parseList(raw.trustedOrigins ?? ""),
    allowPrivateOrigins: raw.allowPrivateOrigins !== false,
    enforceOrigin: raw.enforceOrigin !== false,
    includeEmptyWorkspaces: raw.includeEmptyWorkspaces === true,
    maxBodyBytes: Number.isInteger(raw.maxBodyBytes) && raw.maxBodyBytes > 0
      ? raw.maxBodyBytes
      : undefined,
    logToHost: raw.logToHost !== false,
  };
}
