/**
 * Source-address fencing for the LAN management API.
 *
 * The API mutates workspaces and sessions and enqueues model prompts, so who may
 * call it is the plugin's primary security property. The fence is a **source-IP
 * allowlist** evaluated on every request, before any handler runs:
 *
 * | Range | Why |
 * |---|---|
 * | `127.0.0.0/8`, `::1` | loopback — the CLI on the same machine |
 * | `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` | RFC 1918 private LAN |
 * | `169.254.0.0/16` | link-local |
 * | `100.64.0.0/10` | Tailscale / carrier-grade NAT (100.64–100.127) |
 * | `fc00::/7`, `fe80::/10` | IPv6 unique-local and link-local |
 *
 * `100.64.0.0/10` is included deliberately: Tailscale hands peers `100.x.y.z`
 * addresses out of the CGNAT block, and a fleet of Macs reached over Tailscale
 * is the shape this plugin is built for. It is *not* a general "100.*" match —
 * the mask is /10, so only 100.64.0.0–100.127.255.255 pass.
 *
 * Everything else — public addresses, and any address the parser cannot make
 * sense of — is refused. The default is deny.
 *
 * @module dsh-lan-manager/net
 */

/** Minimal IPv4 pattern check; the numeric work is done on the 32-bit value. */
const IPV4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;

/**
 * Networks allowed by default, as `[network, prefixLength]` IPv4 tuples plus
 * IPv6 prefixes handled separately.
 */
export const DEFAULT_IPV4_NETWORKS = Object.freeze([
  ["127.0.0.0", 8], // loopback
  ["10.0.0.0", 8], // RFC 1918
  ["172.16.0.0", 12], // RFC 1918
  ["192.168.0.0", 16], // RFC 1918
  ["169.254.0.0", 16], // link-local
  ["100.64.0.0", 10], // CGNAT / Tailscale 100.x
]);

/** IPv6 prefixes allowed by default, as `[network, prefixLength]`. */
export const DEFAULT_IPV6_NETWORKS = Object.freeze([
  ["::1", 128], // loopback
  ["fc00::", 7], // unique local (fc00::/7)
  ["fe80::", 10], // link-local (fe80::/10)
]);

/**
 * Parse a dotted-quad IPv4 address into an unsigned 32-bit integer.
 * @param value - candidate address.
 * @returns the numeric value, or `undefined` when it is not a valid IPv4 literal.
 */
export function ipv4ToInt(value) {
  const match = IPV4.exec(String(value ?? "").trim());
  if (!match) return undefined;
  const octets = match.slice(1).map((part) => Number(part));
  if (octets.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return undefined;
  // `<< 24` on the first octet would go negative for values >= 128; multiply.
  return ((octets[0] * 256 + octets[1]) * 256 + octets[2]) * 256 + octets[3];
}

/**
 * Does an IPv4 address fall inside a `network/prefix`?
 * @param address - dotted-quad address.
 * @param network - dotted-quad network base.
 * @param prefix - prefix length in bits (0-32).
 * @returns true when the address is inside the network.
 */
export function ipv4InNetwork(address, network, prefix) {
  const a = ipv4ToInt(address);
  const n = ipv4ToInt(network);
  if (a === undefined || n === undefined) return false;
  const bits = Number(prefix);
  if (!Number.isInteger(bits) || bits < 0 || bits > 32) return false;
  if (bits === 0) return true;
  // >>> keeps the shift unsigned; << 32 is not representable, so guard bits===0.
  const mask = (0xffffffff << (32 - bits)) >>> 0;
  return ((a & mask) >>> 0) === ((n & mask) >>> 0);
}

/**
 * Normalize an IPv6 literal for prefix comparison: lowercase, strip brackets,
 * drop a zone id (`%en0`), and shorten the longest run of zero groups to `::`.
 * @param value - candidate address.
 * @returns the normalized form, or `undefined` when it is not IPv6.
 */
export function normalizeIpv6(value) {
  let text = String(value ?? "").trim().toLowerCase();
  if (!text) return undefined;
  if (text.startsWith("[") && text.endsWith("]")) text = text.slice(1, -1);
  const zone = text.indexOf("%");
  if (zone !== -1) text = text.slice(0, zone);
  if (!text.includes(":")) return undefined;

  // Expand `::` in place: head groups, then the zeros the gap stands for, then
  // the tail. Putting the padding at the front would move the network bits and
  // make a correct `fe80::/10` test fail on an expanded address.
  const collapsed = text.includes("::");
  if (collapsed) {
    const at = text.indexOf("::");
    const head = text.slice(0, at);
    const tail = text.slice(at + 2);
    const headGroups = head ? head.split(":").filter((g) => g !== "") : [];
    const tailGroups = tail ? tail.split(":").filter((g) => g !== "") : [];
    const missing = 8 - headGroups.length - tailGroups.length;
    if (missing < 0) return undefined;
    return [...headGroups, ...Array(missing).fill("0"), ...tailGroups]
      .map((g) => g.replace(/^0+(?=.)/, ""))
      .join(":");
  }
  const groups = text.split(":");
  if (groups.length !== 8) return undefined;
  return groups.map((g) => g.replace(/^0+(?=.)/, "")).join(":");
}

/**
 * Parse an IPv6 literal into its 16 bytes.
 * @param value - candidate address (zone id and brackets tolerated).
 * @returns a 16-byte `Uint8Array`, or `undefined` when it is not IPv6.
 */
export function ipv6ToBytes(value) {
  const normalized = normalizeIpv6(value);
  if (normalized === undefined) return undefined;
  const groups = normalized.split(":");
  if (groups.length !== 8) return undefined;
  const bytes = new Uint8Array(16);
  for (let i = 0; i < 8; i += 1) {
    const group = groups[i] === "" ? "0" : groups[i];
    if (!/^[0-9a-f]{1,4}$/.test(group)) return undefined;
    const value16 = Number.parseInt(group, 16);
    bytes[i * 2] = (value16 >> 8) & 0xff;
    bytes[i * 2 + 1] = value16 & 0xff;
  }
  return bytes;
}

/**
 * Is an IPv6 address inside a `network/prefix`?
 * @param address - candidate address.
 * @param network - network base.
 * @param prefix - prefix length in bits (0-128).
 * @returns true when inside.
 */
export function ipv6InNetwork(address, network, prefix) {
  const a = ipv6ToBytes(address);
  const n = ipv6ToBytes(network);
  if (!a || !n) return false;
  const bits = Number(prefix);
  if (!Number.isInteger(bits) || bits < 0 || bits > 128) return false;
  const wholeBytes = Math.floor(bits / 8);
  for (let i = 0; i < wholeBytes; i += 1) {
    if (a[i] !== n[i]) return false;
  }
  const remainder = bits % 8;
  if (remainder === 0) return true;
  // Compare only the high `remainder` bits of the next byte.
  const mask = (0xff << (8 - remainder)) & 0xff;
  return (a[wholeBytes] & mask) === (n[wholeBytes] & mask);
}

/**
 * Strip the IPv4-mapped IPv6 prefix so `::ffff:192.168.1.5` is judged as IPv4.
 * @param address - remote address from the socket.
 * @returns `{family, address}` with the mapped form unwrapped.
 */
export function unwrapAddress(address) {
  const text = String(address ?? "").trim();
  const mapped = /^::ffff:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/i.exec(text);
  if (mapped) return { family: "ipv4", address: mapped[1] };
  if (ipv4ToInt(text) !== undefined) return { family: "ipv4", address: text };
  const v6 = normalizeIpv6(text);
  if (v6 !== undefined) return { family: "ipv6", address: v6 };
  return { family: "unknown", address: text };
}

/**
 * Is one source address permitted?
 * @param address - the socket's `remoteAddress`.
 * @param options - optional `ipv4Networks` / `ipv6Networks` / `allow` overrides.
 * @returns a decision with the reason, suitable for logging and for the 403 body.
 */
export function checkAddress(address, options = {}) {
  const networks = options.ipv4Networks ?? DEFAULT_IPV4_NETWORKS;
  const prefixes = options.ipv6Networks ?? DEFAULT_IPV6_NETWORKS;
  const extra = options.allow ?? [];
  const { family, address: normalized } = unwrapAddress(address);

  if (family === "unknown") {
    return { allowed: false, reason: "unparseable-source-address", address: String(address ?? "") };
  }

  // Explicit extra allowances run first, so an operator can open one host without
  // widening a whole range.
  for (const entry of extra) {
    const { family: ef, address: ea } = unwrapAddress(String(entry).split("/")[0]);
    if (ef === family && ea === normalized) {
      return { allowed: true, reason: "explicit-allow", address: normalized, family };
    }
    const slash = String(entry).indexOf("/");
    if (ef === "ipv4" && slash !== -1) {
      const [base, bits] = String(entry).split("/");
      if (ipv4InNetwork(normalized, base, bits)) {
        return { allowed: true, reason: "explicit-allow-network", address: normalized, family };
      }
    }
  }

  if (family === "ipv4") {
    for (const [network, prefix] of networks) {
      if (ipv4InNetwork(normalized, network, prefix)) {
        return {
          allowed: true,
          reason: `ipv4 ${network}/${prefix}`,
          address: normalized,
          family,
        };
      }
    }
    return { allowed: false, reason: "source-not-in-allowlist", address: normalized, family };
  }

  for (const [network, prefix] of prefixes) {
    if (ipv6InNetwork(normalized, network, prefix)) {
      return {
        allowed: true,
        reason: `ipv6 ${network}/${prefix}`,
        address: normalized,
        family,
      };
    }
  }
  return { allowed: false, reason: "source-not-in-allowlist", address: normalized, family };
}

/**
 * Resolve the peer address for a request. Uses the socket address, deliberately
 * **not** `X-Forwarded-For`: a forwarded header is attacker-controlled unless a
 * trusted proxy rewrote it, and trusting it here would let any caller claim
 * loopback.
 * @param req - the Node request.
 * @returns the peer address string.
 */
export function peerAddress(req) {
  return req?.socket?.remoteAddress ?? req?.connection?.remoteAddress ?? "";
}
