import { homedir, hostname, networkInterfaces } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { randomUUID } from "node:crypto";
import { isIP } from "node:net";
import { mkdir, stat, writeFile } from "node:fs/promises";
import lockfile from "proper-lockfile";
import { atomicWriteJson, readJson, updateJsonLocked } from "./util/json.js";
import { GatewayError } from "./errors.js";

export interface GatewayConfig {
  readonly host: string;
  readonly port: number;
  readonly tronHome: string;
  readonly agentDir: string;
  readonly machineId: string;
  readonly machineGroupID: string;
  readonly machineName: string;
  readonly maxFrameBytes: number;
  readonly maxUploadBytes: number;
  readonly terminalReplayBytes: number;
  readonly idleRuntimeMs: number;
  readonly maxConnections: number;
  readonly maxConnectionsPerIdentity: number;
  readonly maxSubscriptionsPerConnection: number;
  readonly maxLiveRuntimes: number;
  readonly maxOutboundBytes: number;
  readonly maxSynchronizationBytes: number;
  /** Maintainer-owned product endpoint. It is never accepted from mobile or tool input. */
  readonly pushServiceOrigin?: string;
}

const GATEWAY_CONFIG_MAX_BYTES = 16 * 1_024;
const MACHINE_GROUP_MAX_BYTES = 256;
const MACHINE_GROUP_FILE = ".tron-machine-group-id";

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

function ipv6Bytes(address: string): number[] | null {
  if (address.includes("%") || isIP(address) !== 6) return null;
  const halves = address.toLowerCase().split("::");
  if (halves.length > 2) return null;
  const parse = (part: string): number[] => part === "" ? [] : part.split(":").flatMap((piece, index, pieces) => {
    if (piece.includes(".")) {
      if (index !== pieces.length - 1) return [];
      const octets = piece.split(".").map(Number);
      return octets.length === 4 && octets.every((octet) => Number.isInteger(octet) && octet >= 0 && octet <= 255)
        ? [(octets[0]! << 8) | octets[1]!, (octets[2]! << 8) | octets[3]!]
        : [];
    }
    return /^[0-9a-f]{1,4}$/u.test(piece) ? [Number.parseInt(piece, 16)] : [];
  });
  const left = parse(halves[0]!);
  const right = halves.length === 2 ? parse(halves[1]!) : [];
  if (left.length + right.length > 8 || (halves.length === 1 && left.length !== 8)) return null;
  const words = halves.length === 2 ? [...left, ...Array(8 - left.length - right.length).fill(0), ...right] : left;
  return words.flatMap((word) => [word >>> 8, word & 0xff]);
}

export function isTailscaleAddress(address: string): boolean {
  if (typeof address !== "string") return false;
  if (isIP(address) === 4) {
    const octets = address.split(".").map(Number);
    return octets.length === 4 && octets.every((octet) => Number.isInteger(octet) && octet >= 0 && octet <= 255)
      && octets[0] === 100 && octets[1]! >= 64 && octets[1]! <= 127;
  }
  const bytes = ipv6Bytes(address);
  return bytes !== null
    && bytes[0] === 0xfd && bytes[1] === 0x7a && bytes[2] === 0x11
    && bytes[3] === 0x5c && bytes[4] === 0xa1 && bytes[5] === 0xe0;
}

export function resolveBindHost(raw: string | undefined, interfaces = networkInterfaces()): string {
  const requested = raw?.trim() || "127.0.0.1";
  if (requested !== "tailscale") return requested;
  const candidates = Object.entries(interfaces).flatMap(([name, addresses]) => (addresses ?? [])
    .filter((candidate) => !candidate.internal && isTailscaleAddress(candidate.address))
    .map((candidate) => ({ ...candidate, name })));
  candidates.sort((left, right) => {
    const family = (value: string | number) => value === "IPv4" || value === 4 ? 0 : 1;
    const compare = (a: string, b: string) => {
      const leftOctets = a.split(".").map(Number);
      const rightOctets = b.split(".").map(Number);
      if (leftOctets.length === 4 && rightOctets.length === 4
        && leftOctets.every(Number.isInteger) && rightOctets.every(Number.isInteger)) {
        for (let index = 0; index < 4; index += 1) {
          if (leftOctets[index] !== rightOctets[index]) return leftOctets[index]! - rightOctets[index]!;
        }
        return 0;
      }
      return a === b ? 0 : a < b ? -1 : 1;
    };
    return family(left.family) - family(right.family)
      || compare(left.address, right.address)
      || compare(left.name, right.name);
  });
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

function isStoredGatewayConfig(value: unknown): value is StoredGatewayConfig {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const document = value as Record<string, unknown>;
  const expectedKeys = document.defaultWorkspace === undefined
    ? ["version", "machineId", "machineName"]
    : ["version", "machineId", "machineName", "defaultWorkspace"];
  const keys = Object.keys(document);
  return keys.length === expectedKeys.length && keys.every((key) => expectedKeys.includes(key))
    && document.version === 1
    && typeof document.machineId === "string" && Buffer.byteLength(document.machineId) > 0
    && Buffer.byteLength(document.machineId) <= 256 && !/[\u0000-\u001f\u007f]/.test(document.machineId)
    && typeof document.machineName === "string" && Buffer.byteLength(document.machineName) > 0
    && Buffer.byteLength(document.machineName) <= 1_024 && !/[\u0000-\u001f\u007f]/.test(document.machineName)
    && (document.defaultWorkspace === undefined
      || (typeof document.defaultWorkspace === "string" && Buffer.byteLength(document.defaultWorkspace) > 0
        && Buffer.byteLength(document.defaultWorkspace) <= 8_192 && !/[\u0000-\u001f\u007f]/.test(document.defaultWorkspace)));
}

async function storedGatewayConfig(path: string): Promise<StoredGatewayConfig | null> {
  const missing = {};
  let value: unknown;
  try { value = await readJson<unknown>(path, missing, GATEWAY_CONFIG_MAX_BYTES); }
  catch (error) {
    if (error instanceof RangeError || error instanceof SyntaxError) {
      throw new GatewayError("conflict", "Gateway identity configuration is malformed or oversized");
    }
    throw error;
  }
  if (value === missing) {
    try {
      await stat(path);
      throw new GatewayError("conflict", "Gateway identity configuration is empty");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
      throw error;
    }
  }
  if (!isStoredGatewayConfig(value)) {
    throw new GatewayError("conflict", "Gateway identity configuration is malformed");
  }
  return value;
}

function validateMachineGroupID(value: unknown): string {
  if (typeof value !== "string" || value.trim().length === 0
    || Buffer.byteLength(value) > MACHINE_GROUP_MAX_BYTES
    || /[\u0000-\u001f\u007f]/.test(value)) {
    throw new GatewayError("conflict", "Machine group identity is malformed or oversized");
  }
  return value;
}

async function loadOrCreateStoredGatewayConfig(path: string): Promise<StoredGatewayConfig> {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  let created = false;
  try {
    await stat(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    try {
      await writeFile(path, "", { flag: "wx", mode: 0o600 });
      created = true;
    } catch (creationError) {
      if ((creationError as NodeJS.ErrnoException).code !== "EEXIST") throw creationError;
    }
  }
  const release = await lockfile.lock(path, {
    realpath: false,
    retries: { retries: 10, minTimeout: 20, maxTimeout: 100 },
  });
  try {
    if (!created) {
      const stored = await storedGatewayConfig(path);
      if (stored) return stored;
      throw new GatewayError("conflict", "Gateway identity configuration is empty");
    }
    const next: StoredGatewayConfig = {
      version: 1,
      machineId: randomUUID(),
      machineName: hostname(),
    };
    await atomicWriteJson(path, next);
    return next;
  } finally {
    await release();
  }
}

async function loadMachineGroupID(environment: NodeJS.ProcessEnv): Promise<string> {
  const injected = environment.TRON_MACHINE_GROUP_ID?.trim();
  if (injected) {
    if (Buffer.byteLength(injected) > MACHINE_GROUP_MAX_BYTES || /[\u0000-\u001f\u007f]/.test(injected)) {
      throw new GatewayError("invalid_request", "TRON_MACHINE_GROUP_ID is invalid");
    }
    return injected;
  }
  const path = environment.TRON_MACHINE_GROUP_PATH?.trim() || join(homedir(), MACHINE_GROUP_FILE);
  if (!isAbsolute(path)) throw new GatewayError("invalid_request", "TRON_MACHINE_GROUP_PATH must be absolute");
  try {
    await mkdir(dirname(path), { recursive: true, mode: 0o700 });
    const value = await updateJsonLocked<unknown>(
      path,
      null,
      current => current === null ? randomUUID() : validateMachineGroupID(current),
      MACHINE_GROUP_MAX_BYTES,
    );
    return validateMachineGroupID(value);
  } catch (error) {
    if (error instanceof GatewayError) throw error;
    if (error instanceof RangeError || error instanceof SyntaxError) {
      throw new GatewayError("conflict", "Machine group identity is malformed or oversized");
    }
    throw error;
  }
}

export async function loadConfig(
  args = process.argv.slice(2),
  environment: NodeJS.ProcessEnv = process.env,
): Promise<GatewayConfig> {
  const tronHome = resolveTronHome(environment);
  const machineGroupID = await loadMachineGroupID(environment);
  const configPath = join(tronHome, "gateway", "gateway.json");
  const next = await loadOrCreateStoredGatewayConfig(configPath);

  const explicitAgentDir = environment.PI_CODING_AGENT_DIR;
  const agentDirName = environment.TRON_AGENT_DIR_NAME?.trim();
  if (agentDirName && (agentDirName === "." || agentDirName === ".." || agentDirName.includes("/") || agentDirName.includes("\\"))) {
    throw new GatewayError("invalid_request", "TRON_AGENT_DIR_NAME must be one .pi-relative directory name");
  }
  const agentDir = resolve(explicitAgentDir ?? join(homedir(), ".pi", agentDirName || "agent"));
  return {
    host: resolveBindHost(valueAfter(args, "--host") ?? environment.TRON_GATEWAY_HOST),
    port: parsePort(valueAfter(args, "--port") ?? environment.TRON_GATEWAY_PORT),
    tronHome,
    agentDir,
    machineId: next.machineId,
    machineGroupID,
    machineName: next.machineName,
    maxFrameBytes: 1_048_576,
    maxUploadBytes: 25 * 1_048_576,
    terminalReplayBytes: 768 * 1_024,
    idleRuntimeMs: 10 * 60_000,
    maxConnections: 32,
    maxConnectionsPerIdentity: 4,
    maxSubscriptionsPerConnection: 64,
    maxLiveRuntimes: 16,
    maxOutboundBytes: 8 * 1_048_576,
    maxSynchronizationBytes: 2 * 1_048_576,
    ...(environment.TRON_PUSH_SERVICE_ORIGIN?.trim()
      ? { pushServiceOrigin: environment.TRON_PUSH_SERVICE_ORIGIN.trim() }
      : {}),
  };
}
