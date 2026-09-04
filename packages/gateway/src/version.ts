import { lstatSync, readFileSync } from "node:fs";

export const GATEWAY_VERSION = "0.1.0-beta.7";
// Protocol v4 makes chat invocation/context semantics explicit. There is no
// v3 runtime path: every mobile peer must understand the typed projection.
export const PROTOCOL_VERSION = 4;
export const MIN_PROTOCOL_VERSION = 4;

// package.json is the sole Pi SDK version authority. Keep this runtime check
// strict so a malformed or partially updated package cannot report a false
// Gateway identity to clients.
const gatewayPackageURL = new URL("../package.json", import.meta.url);
const gatewayPackageInfo = lstatSync(gatewayPackageURL);
if (!gatewayPackageInfo.isFile() || gatewayPackageInfo.isSymbolicLink() || gatewayPackageInfo.size > 64 * 1024) {
  throw new Error("Gateway package.json is missing, substituted, or oversized");
}
const gatewayPackage = JSON.parse(readFileSync(gatewayPackageURL, "utf8")) as {
  dependencies?: Record<string, unknown>;
};
const piDependencies = [
  "@earendil-works/pi-agent-core",
  "@earendil-works/pi-ai",
  "@earendil-works/pi-coding-agent",
  "@earendil-works/pi-tui",
].map((name) => gatewayPackage.dependencies?.[name]);
if (piDependencies.some((value) => typeof value !== "string" || !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(value))
  || new Set(piDependencies).size !== 1) {
  throw new Error("Gateway package.json must declare one exact, coherent Pi SDK release");
}
export const PI_VERSION = piDependencies[0] as string;
