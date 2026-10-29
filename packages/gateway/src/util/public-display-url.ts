import { isIP } from "node:net";

function blockedIPv4(host: string): boolean {
  const octets = host.split(".").map(Number);
  if (octets.length !== 4 || octets.some((value) => !Number.isInteger(value) || value < 0 || value > 255)) return true;
  const [a, b, c] = octets as [number, number, number, number];
  return a === 0 || a === 10 || a === 127 || a >= 224
    || (a === 100 && b >= 64 && b <= 127)
    || (a === 169 && b === 254)
    || (a === 172 && b >= 16 && b <= 31)
    || (a === 192 && (b === 0 || b === 168))
    || (a === 198 && (b === 18 || b === 19))
    || (a === 198 && b === 51 && c === 100)
    || (a === 203 && b === 0 && c === 113);
}

function blockedIPv6(host: string): boolean {
  const normalized = host.toLowerCase().replace(/^\[|\]$/g, "");
  if (normalized === "::" || normalized === "::1") return true;
  const first = Number.parseInt(normalized.split(":", 1)[0] || "0", 16);
  if (!Number.isFinite(first) || first < 0x2000 || first > 0x3fff
    || normalized.startsWith("2001:db8:")) return true;
  if (normalized.startsWith("::ffff:")) {
    const tail = normalized.slice("::ffff:".length).split(":");
    if (tail.length !== 2) return true;
    const high = Number.parseInt(tail[0]!, 16);
    const low = Number.parseInt(tail[1]!, 16);
    if (!Number.isFinite(high) || !Number.isFinite(low)) return true;
    return blockedIPv4(`${high >> 8}.${high & 0xff}.${low >> 8}.${low & 0xff}`);
  }
  return false;
}

/** Canonical public-URL admission shared by tool creation and projection.
 * Remote content is gesture-gated in Safari, but persisted descriptors still
 * reject local/reserved literals, local DNS suffixes, query credentials, and
 * fragments. */
export function normalizePublicDisplayURL(input: string): string | undefined {
  if (Buffer.byteLength(input) < 1 || Buffer.byteLength(input) > 8_192) return undefined;
  let url: URL;
  try { url = new URL(input); } catch { return undefined; }
  if (url.protocol !== "https:" || url.username || url.password || url.href.includes("?") || url.href.includes("#")) return undefined;
  const host = url.hostname.toLowerCase().replace(/^\[|\]$/g, "").replace(/\.+$/g, "");
  if (!host || host === "localhost" || host.endsWith(".localhost")
    || [".local", ".internal", ".home", ".lan"].some((suffix) => host.endsWith(suffix))) return undefined;
  const family = isIP(host);
  if ((family === 4 && blockedIPv4(host)) || (family === 6 && blockedIPv6(host))) return undefined;
  return url.toString();
}
