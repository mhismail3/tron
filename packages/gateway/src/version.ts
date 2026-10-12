import { lstatSync, readFileSync } from "node:fs";

export const GATEWAY_VERSION = "0.1.0-beta.8";
// Protocol v5 makes fork-boundary gap metadata explicit. There is no
// v4 runtime path: every mobile peer must understand the typed projection.
export const PROTOCOL_VERSION = 7;
export const MIN_PROTOCOL_VERSION = 7;
// Application-defined close code for a hello whose protocol the peer cannot
// speak. The version range it names travels in the close reason, so every
// client that decodes the code can name the stale side (mirrors iOS
// `GatewayProtocolMismatchClose.closeCode`). It lives beside the protocol
// version because the Gateway transport and the terminal client both refuse and
// read it, and server.ts cannot be imported from a client process.
export const PROTOCOL_MISMATCH_CLOSE_CODE = 4006;

// package.json is the sole Pi SDK version authority. Keep this runtime check
// strict so a malformed or partially updated package cannot report a false
// Gateway identity to clients. The one exception is pi-coding-agent while
// pi-coding-agent-patch.json declares Tron's patched tarball of the same
// release; scripts/check-pi-sdk.mjs validates that tarball and its lock entry.
function boundedPackageJson(name: string): unknown {
  const url = new URL(`../${name}`, import.meta.url);
  const info = lstatSync(url);
  if (!info.isFile() || info.isSymbolicLink() || info.size > 64 * 1024) {
    throw new Error(`Gateway ${name} is missing, substituted, or oversized`);
  }
  return JSON.parse(readFileSync(url, "utf8"));
}
const gatewayPackage = boundedPackageJson("package.json") as { dependencies?: Record<string, unknown> };
const piDependencies = [
  "@earendil-works/pi-agent-core",
  "@earendil-works/pi-ai",
  "@earendil-works/pi-coding-agent",
  "@earendil-works/pi-tui",
].map((name) => {
  const value = gatewayPackage.dependencies?.[name];
  if (name !== "@earendil-works/pi-coding-agent" || typeof value !== "string" || !value.startsWith("file:")) return value;
  const patch = boundedPackageJson("pi-coding-agent-patch.json") as { artifact?: { path?: unknown }; version?: unknown };
  return value === `file:${String(patch.artifact?.path)}` ? patch.version : undefined;
});
if (piDependencies.some((value) => typeof value !== "string" || !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(value))
  || new Set(piDependencies).size !== 1) {
  throw new Error("Gateway package.json must declare one exact, coherent Pi SDK release");
}
export const PI_VERSION = piDependencies[0] as string;
