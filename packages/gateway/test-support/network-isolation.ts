import net from "node:net";
import { afterEach } from "vitest";

// Gateway tests own every remote boundary through injected fetchers, resolvers
// and HTTP stubs. An unstubbed path that reaches the real network passes or
// fails by host network (#295: a pinned public address hung for the 15 s
// capture deadline on hosted runners and failed fast locally). Refuse every
// non-loopback TCP connection immediately and fail the test that made it, even
// when product error handling would otherwise absorb the refused connection.
const violations: string[] = [];
const connect = net.Socket.prototype.connect;

function loopback(host: string | undefined): boolean {
  if (!host || host === "localhost") return true;
  const address = host.startsWith("::ffff:") ? host.slice(7) : host;
  if (net.isIPv4(address)) return address.startsWith("127.") || address === "0.0.0.0";
  return address === "::1" || address === "::";
}

net.Socket.prototype.connect = function (this: net.Socket, ...args: unknown[]) {
  // net.connect passes normalized [options, listener]; direct calls pass
  // (options | port | path, host?, listener?).
  const first = Array.isArray(args[0]) ? args[0][0] : args[0];
  const host = typeof first === "number" || (typeof first === "string" && /^\d+$/.test(first))
    ? (typeof args[1] === "string" ? args[1] : undefined)
    : typeof first === "object" && first !== null && !("path" in first && (first as { path?: unknown }).path)
      ? (first as { host?: string }).host
      : undefined;
  if (!loopback(host)) {
    const message = `Gateway tests must not open real network connections (attempted ${host}); inject the owning fetcher or stub`;
    violations.push(message);
    process.nextTick(() => this.destroy(new Error(message)));
    return this;
  }
  return (connect as (...values: unknown[]) => net.Socket).apply(this, args);
} as typeof net.Socket.prototype.connect;

afterEach(() => {
  if (violations.length === 0) return;
  const found = violations.splice(0);
  throw new Error(found.join("\n"));
});
