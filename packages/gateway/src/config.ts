import { homedir, hostname, networkInterfaces } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import { randomUUID } from "node:crypto";
import { atomicWriteJson, readJson } from "./util/json.js";
import { GatewayError } from "./errors.js";

export interface GatewayConfig {
  readonly host: string;
  readonly port: number;
  readonly tronHome: string;
  readonly agentDir: string;
  readonly machineId: string;
  readonly machineName: string;
  readonly maxFrameBytes: number;
  readonly maxUploadBytes: number;
  readonly terminalReplayBytes: number;
  readonly idleRuntimeMs: number;
}

interface StoredGatewayConfig {
  version: 1;
  machineId: string;
  machineName: string;
  defaultWorkspace?: string;
}

function valueAfter(args: string[], name: string): string | undefined {
  const equals = args.find((arg) => arg.startsWith(`${name}=`));
  if (equals) return equals.slice(name.length + 1);
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
}

function parsePort(raw: string | undefined): number {
  const port = Number(raw ?? "9847");
  if (!Number.isSafeInteger(port) || port < 1 || port > 65_535) {
    throw new GatewayError("invalid_request", "Gateway port must be between 1 and 65535");
  }
  return port;
}

export function isTailscaleAddress(address: string): boolean {
  if (address.toLowerCase().startsWith("fd7a:115c:a1e0:")) return true;
  const octets = address.split(".").map(Number);
  return octets.length === 4 && octets[0] === 100 && octets[1]! >= 64 && octets[1]! <= 127;
}

export function resolveBindHost(raw: string | undefined): string {
  const requested = raw?.trim() || "127.0.0.1";
  if (requested !== "tailscale") return requested;
  const candidates = Object.values(networkInterfaces())
    .flatMap((addresses) => addresses ?? [])
    .filter((candidate) => !candidate.internal && isTailscaleAddress(candidate.address));
  const ipv4 = candidates.find((candidate) => candidate.family === "IPv4");
  if (ipv4) return ipv4.address;
  if (candidates[0]) return candidates[0].address;
  throw new GatewayError("conflict", "Tailscale is not connected; Tron cannot expose the mobile gateway", true);
}

export function resolveTronHome(environment = process.env): string {
  const explicit = environment.TRON_DATA_DIR;
  if (explicit) {
    if (!isAbsolute(explicit)) throw new GatewayError("invalid_request", "TRON_DATA_DIR must be absolute");
    return resolve(explicit);
  }
  const homeName = environment.TRON_HOME_NAME;
  if (homeName) {
    if (homeName === "." || homeName === ".." || homeName.includes("/")) {
      throw new GatewayError("invalid_request", "TRON_HOME_NAME must be one home-relative directory name");
    }
    return join(homedir(), homeName);
  }
  return join(homedir(), ".tron");
}

export async function loadConfig(args = process.argv.slice(2)): Promise<GatewayConfig> {
  const tronHome = resolveTronHome();
  const configPath = join(tronHome, "gateway", "gateway.json");
  const stored = await readJson<StoredGatewayConfig | null>(configPath, null);
  const next: StoredGatewayConfig = stored ?? {
    version: 1,
    machineId: randomUUID(),
    machineName: hostname(),
  };
  if (!stored) await atomicWriteJson(configPath, next);

  const agentDir = resolve(process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".pi", "agent"));
  return {
    host: resolveBindHost(valueAfter(args, "--host") ?? process.env.TRON_GATEWAY_HOST),
    port: parsePort(valueAfter(args, "--port") ?? process.env.TRON_GATEWAY_PORT),
    tronHome,
    agentDir,
    machineId: next.machineId,
    machineName: next.machineName,
    maxFrameBytes: 1_048_576,
    maxUploadBytes: 25 * 1_048_576,
    terminalReplayBytes: 2 * 1_048_576,
    idleRuntimeMs: 10 * 60_000,
  };
}
