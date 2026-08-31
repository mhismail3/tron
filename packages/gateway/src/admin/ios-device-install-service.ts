import { spawn } from "node:child_process";
import { lstatSync } from "node:fs";
import { lstat, mkdir, mkdtemp, readFile, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, parse } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { execFile } from "node:child_process";
import { GatewayError } from "../errors.js";
import { atomicWriteJson, removeIfExists } from "../util/json.js";
import { readSecureJson } from "../util/secure-json.js";
import { AsyncMutex } from "../util/async-mutex.js";

export const IOS_DEVICE_INSTALL_CAPABILITY = "ios-device-install.v2";
const CONFIG_KIND = "tron-ios-device-install-config";
const STATUS_KIND = "tron-ios-device-install-status";
const ACTIVE_KIND = "tron-ios-device-install-active";
const MAX_DOCUMENT_BYTES = 64 * 1_024;
const MAX_DISCOVERY_BYTES = 2 * 1_024 * 1_024;
const MAX_PATH_BYTES = 4_096;
const MAX_TARGETS = 256;
const MAX_ERROR_BYTES = 2_048;
const INSTALL_TIMEOUT_MS = 2 * 60 * 60_000;
const ACTIVE_STALE_MS = INSTALL_TIMEOUT_MS + 5 * 60_000;
const IDENTIFIER = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/u;
const DEVICE_ID = /^[A-Za-z0-9._:-]{1,100}$/u;
const COMMAND_ID = /^[A-Za-z0-9._:-]{8,160}$/u;
const execFileAsync = promisify(execFile);

export type IosDeviceInstallChannel = "stable" | "dev";
export type IosDeviceInstallState = "requested" | "running" | "succeeded" | "failed";

export interface IosPhysicalDeviceTarget {
  /** Owner-only CoreDevice identifier. Never project this field over RPC. */
  identifier: string;
  name: string;
  deviceType: string;
  connectionState: string;
  developerModeEnabled: boolean;
}

export interface IosDeviceInstallConfig {
  schema: 1;
  kind: typeof CONFIG_KIND;
  deviceId: string;
  gatewayChannel: IosDeviceInstallChannel;
  sourceRoot?: string;
  target?: IosPhysicalDeviceTarget;
  updatedAt: string;
}

export interface IosDeviceInstallConfigProjection {
  schema: 1;
  kind: typeof CONFIG_KIND;
  deviceId: string;
  gatewayChannel: IosDeviceInstallChannel;
  sourceRoot?: string;
  target?: Omit<IosPhysicalDeviceTarget, "identifier">;
  updatedAt: string;
}

export interface IosDeviceInstallStatus {
  schema: 1;
  kind: typeof STATUS_KIND;
  deviceId: string;
  state: IosDeviceInstallState;
  commandId: string;
  targetName: string;
  startedAt: string;
  updatedAt: string;
  error?: string;
}

interface ActiveInstall {
  schema: 1;
  kind: typeof ACTIVE_KIND;
  deviceId: string;
  commandId: string;
  startedAt: string;
}

export type IosDeviceTargetDiscovery = () => Promise<IosPhysicalDeviceTarget[]>;
export type IosDeviceInstallLauncher = (request: {
  tronHome: string;
  deviceId: string;
  commandId: string;
}) => Promise<void>;

function boundedText(value: unknown, name: string, maximum: number): string {
  if (typeof value !== "string" || Buffer.byteLength(value) === 0 || Buffer.byteLength(value) > maximum
    || /[\u0000-\u001f\u007f]/u.test(value)) {
    throw new GatewayError("conflict", `iOS device install ${name} is malformed`);
  }
  return value;
}

function admitDeviceId(value: unknown): string {
  const result = boundedText(value, "paired device ID", 100);
  if (!DEVICE_ID.test(result)) throw new GatewayError("invalid_request", "Paired device ID is invalid");
  return result;
}

function admitCommandId(value: unknown): string {
  const result = boundedText(value, "command ID", 160);
  if (!COMMAND_ID.test(result)) throw new GatewayError("invalid_request", "iOS device install command ID is invalid");
  return result;
}

function admitTimestamp(value: unknown, name: string): string {
  const result = boundedText(value, name, 64);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/u.test(result)) {
    throw new GatewayError("conflict", `iOS device install ${name} is malformed`);
  }
  return result;
}

function record(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined;
}

function targetDocument(value: unknown): IosPhysicalDeviceTarget {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new GatewayError("conflict", "iOS install target is malformed");
  }
  const raw = value as Record<string, unknown>;
  if (Object.keys(raw).some((key) => !["identifier", "name", "deviceType", "connectionState", "developerModeEnabled"].includes(key))
    || typeof raw.identifier !== "string" || !IDENTIFIER.test(raw.identifier)
    || typeof raw.developerModeEnabled !== "boolean") {
    throw new GatewayError("conflict", "iOS install target is malformed");
  }
  return {
    identifier: raw.identifier,
    name: boundedText(raw.name, "target name", 320),
    deviceType: boundedText(raw.deviceType, "target type", 80),
    connectionState: boundedText(raw.connectionState, "target connection state", 80),
    developerModeEnabled: raw.developerModeEnabled,
  };
}

async function validateSourceRoot(value: unknown): Promise<string> {
  if (typeof value !== "string" || !isAbsolute(value) || Buffer.byteLength(value) > MAX_PATH_BYTES
    || /[\u0000-\u001f\u007f]/u.test(value)) {
    throw new GatewayError("invalid_request", "iOS source repository must be an absolute path");
  }
  const root = parse(value).root;
  let cursor = root;
  for (const component of value.slice(root.length).split(/[\\/]+/u).filter(Boolean)) {
    cursor = join(cursor, component);
    const info = await lstat(cursor).catch(() => undefined);
    if (!info) throw new GatewayError("conflict", "iOS source repository is unavailable");
    if (info.isSymbolicLink()) throw new GatewayError("conflict", "iOS source repository contains a symlink");
  }
  const resolved = await realpath(value).catch(() => undefined);
  if (!resolved) throw new GatewayError("conflict", "iOS source repository is unavailable");
  const info = await lstat(resolved);
  if (!info.isDirectory() || info.isSymbolicLink()) {
    throw new GatewayError("conflict", "iOS source repository must be a regular directory");
  }
  for (const marker of [
    "packages/ios-app/project.yml",
    "config/ci-toolchain.env",
    "scripts/tron-ios-device",
    "scripts/validate-ios-artifact.py",
    "scripts/verify-gateway-protocol-contract.py",
  ]) {
    const markerInfo = await lstat(join(resolved, marker)).catch(() => undefined);
    if (!markerInfo?.isFile() || markerInfo.isSymbolicLink()) {
      throw new GatewayError("conflict", "iOS source repository is not a complete Tron checkout");
    }
  }
  return resolved;
}

function configDocument(value: unknown): IosDeviceInstallConfig {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new GatewayError("conflict", "iOS device install configuration is malformed");
  }
  const raw = value as Record<string, unknown>;
  if (Object.keys(raw).some((key) => !["schema", "kind", "deviceId", "gatewayChannel", "sourceRoot", "target", "updatedAt"].includes(key))
    || raw.schema !== 1 || raw.kind !== CONFIG_KIND
    || raw.gatewayChannel !== "stable" && raw.gatewayChannel !== "dev") {
    throw new GatewayError("conflict", "iOS device install configuration is malformed");
  }
  const sourceRoot = raw.sourceRoot === undefined ? undefined : boundedText(raw.sourceRoot, "source repository", MAX_PATH_BYTES);
  const target = raw.target === undefined ? undefined : targetDocument(raw.target);
  return {
    schema: 1,
    kind: CONFIG_KIND,
    deviceId: admitDeviceId(raw.deviceId),
    gatewayChannel: raw.gatewayChannel,
    ...(sourceRoot === undefined ? {} : { sourceRoot }),
    ...(target === undefined ? {} : { target }),
    updatedAt: admitTimestamp(raw.updatedAt, "configuration timestamp"),
  };
}

export function projectIosDeviceInstallConfig(config: IosDeviceInstallConfig): IosDeviceInstallConfigProjection {
  let target: Omit<IosPhysicalDeviceTarget, "identifier"> | undefined;
  if (config.target !== undefined) {
    const { identifier: _identifier, ...projection } = config.target;
    target = projection;
  }
  return {
    schema: 1,
    kind: CONFIG_KIND,
    deviceId: config.deviceId,
    gatewayChannel: config.gatewayChannel,
    ...(config.sourceRoot === undefined ? {} : { sourceRoot: config.sourceRoot }),
    ...(target === undefined ? {} : { target }),
    updatedAt: config.updatedAt,
  };
}

function statusDocument(value: unknown): IosDeviceInstallStatus {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new GatewayError("conflict", "iOS device install status is malformed");
  }
  const raw = value as Record<string, unknown>;
  if (Object.keys(raw).some((key) => !["schema", "kind", "deviceId", "state", "commandId", "targetName", "startedAt", "updatedAt", "error"].includes(key))
    || raw.schema !== 1 || raw.kind !== STATUS_KIND
    || !["requested", "running", "succeeded", "failed"].includes(String(raw.state))) {
    throw new GatewayError("conflict", "iOS device install status is malformed");
  }
  const error = raw.error === undefined ? undefined : admittedFailure(raw.error);
  return {
    schema: 1,
    kind: STATUS_KIND,
    deviceId: admitDeviceId(raw.deviceId),
    state: raw.state as IosDeviceInstallState,
    commandId: admitCommandId(raw.commandId),
    targetName: boundedText(raw.targetName, "target name", 320),
    startedAt: admitTimestamp(raw.startedAt, "start timestamp"),
    updatedAt: admitTimestamp(raw.updatedAt, "status timestamp"),
    ...(error === undefined ? {} : { error }),
  };
}

function activeDocument(value: unknown): ActiveInstall {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new GatewayError("conflict", "iOS device install activity is malformed");
  }
  const raw = value as Record<string, unknown>;
  if (Object.keys(raw).some((key) => !["schema", "kind", "deviceId", "commandId", "startedAt"].includes(key))
    || raw.schema !== 1 || raw.kind !== ACTIVE_KIND) {
    throw new GatewayError("conflict", "iOS device install activity is malformed");
  }
  return {
    schema: 1,
    kind: ACTIVE_KIND,
    deviceId: admitDeviceId(raw.deviceId),
    commandId: admitCommandId(raw.commandId),
    startedAt: admitTimestamp(raw.startedAt, "activity timestamp"),
  };
}

async function readDocument(path: string): Promise<unknown | undefined> {
  const result = await readSecureJson<unknown>(path, MAX_DOCUMENT_BYTES);
  return result.present ? result.value : undefined;
}

function installRoot(tronHome: string): string {
  return join(tronHome, "gateway", "ios-device-installs");
}

function configPath(tronHome: string, deviceId: string): string {
  return join(installRoot(tronHome), "configs", `${admitDeviceId(deviceId)}.json`);
}

function statusPath(tronHome: string, deviceId: string): string {
  return join(installRoot(tronHome), "status", `${admitDeviceId(deviceId)}.json`);
}

function activePath(tronHome: string): string {
  return join(installRoot(tronHome), "active.json");
}

export function admitDevicectlTargets(value: unknown): IosPhysicalDeviceTarget[] {
  const devices = record(record(value)?.result)?.devices;
  if (!Array.isArray(devices) || devices.length > MAX_TARGETS) {
    throw new GatewayError("conflict", "Xcode device discovery returned a malformed result");
  }
  const targets: IosPhysicalDeviceTarget[] = [];
  const identifiers = new Set<string>();
  for (const value of devices) {
    const raw = record(value);
    if (!raw) continue;
    const properties = record(raw.properties);
    const hardware = record(properties?.hardware);
    const state = record(properties?.state);
    const connection = record(properties?.connection);
    const legacyHardware = record(raw.hardwareProperties);
    const deviceProperties = record(raw.deviceProperties);
    const identifier = raw.identifier;
    const platform = hardware?.platform ?? legacyHardware?.platform;
    const reality = hardware?.reality ?? legacyHardware?.reality;
    const deviceType = hardware?.deviceType ?? legacyHardware?.deviceType;
    const name = state?.name ?? deviceProperties?.name;
    if (typeof identifier !== "string" || !IDENTIFIER.test(identifier)
      || platform !== "iOS" || reality !== undefined && reality !== "physical"
      || deviceType !== "iPhone" && deviceType !== "iPad"
      || typeof name !== "string" || identifiers.has(identifier)) continue;
    const target = targetDocument({
      identifier,
      name,
      deviceType,
      connectionState: typeof connection?.state === "string" ? connection.state : "unknown",
      developerModeEnabled: deviceProperties?.developerModeStatus === "enabled",
    });
    identifiers.add(identifier);
    targets.push(target);
  }
  return targets.sort((lhs, rhs) => lhs.name.localeCompare(rhs.name) || lhs.identifier.localeCompare(rhs.identifier));
}

async function defaultDiscoverTargets(): Promise<IosPhysicalDeviceTarget[]> {
  const directory = await mkdtemp(join(tmpdir(), "tron-ios-targets-"));
  const output = join(directory, "devices.json");
  try {
    await execFileAsync("/usr/bin/xcrun", ["devicectl", "list", "devices", "--json-output", output], {
      timeout: 20_000,
      maxBuffer: 256 * 1_024,
    });
    const data = await readFile(output);
    if (data.length === 0 || data.length > MAX_DISCOVERY_BYTES) {
      throw new GatewayError("conflict", "Xcode device discovery returned an oversized result");
    }
    return admitDevicectlTargets(JSON.parse(data.toString("utf8")));
  } catch (error) {
    if (error instanceof GatewayError) throw error;
    throw new GatewayError("conflict", `Xcode device discovery failed: ${failureText(error, 256)}`);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

function failureText(error: unknown, maximum = MAX_ERROR_BYTES): string {
  const raw = error instanceof Error ? error.message : String(error);
  const cleaned = raw.replace(/[\u0000-\u001f\u007f]+/gu, " ").replace(/\s+/gu, " ").trim();
  if (Buffer.byteLength(cleaned) <= maximum) return cleaned || "The iOS install helper failed.";
  return Buffer.from(cleaned).subarray(0, maximum).toString("utf8").replace(/�+$/u, "");
}

function admittedFailure(value: unknown): string {
  if (typeof value !== "string" || Buffer.byteLength(value) === 0) {
    throw new GatewayError("conflict", "iOS device install failure is malformed");
  }
  return failureText(value);
}

function defaultLauncher(environment: NodeJS.ProcessEnv): IosDeviceInstallLauncher | undefined {
  if (process.platform !== "darwin" || environment.TRON_GATEWAY_SUPERVISED !== "1") return undefined;
  const helper = fileURLToPath(new URL("./ios-device-install-helper.js", import.meta.url));
  return async (request) => {
    const child = spawn(process.execPath, [
      helper,
      "--tron-home", request.tronHome,
      "--device-id", request.deviceId,
      "--command-id", request.commandId,
    ], { detached: true, stdio: "ignore", windowsHide: true });
    child.once("error", (error) => {
      void recordIosDeviceInstallHelperFailure(request.tronHome, request.deviceId, request.commandId, error);
    });
    child.unref();
  };
}

export async function recordIosDeviceInstallHelperFailure(
  tronHome: string,
  deviceId: string,
  commandId: string,
  error: unknown,
): Promise<void> {
  const current = await readDocument(statusPath(tronHome, deviceId)).catch(() => undefined);
  const startedAt = current === undefined ? new Date().toISOString() : statusDocument(current).startedAt;
  const targetName = current === undefined ? "iOS device" : statusDocument(current).targetName;
  await atomicWriteJson(statusPath(tronHome, deviceId), {
    schema: 1,
    kind: STATUS_KIND,
    deviceId,
    state: "failed",
    commandId,
    targetName,
    startedAt,
    updatedAt: new Date().toISOString(),
    error: failureText(error),
  } satisfies IosDeviceInstallStatus).catch(() => {});
  await removeIfExists(activePath(tronHome)).catch(() => {});
}

export class IosDeviceInstallService {
  private readonly discoverer: IosDeviceTargetDiscovery;
  private readonly launcher: IosDeviceInstallLauncher | undefined;
  private readonly mutex = new AsyncMutex();

  constructor(private readonly options: {
    tronHome: string;
    gatewayChannel?: IosDeviceInstallChannel;
    environment?: NodeJS.ProcessEnv;
    discoverer?: IosDeviceTargetDiscovery;
    launcher?: IosDeviceInstallLauncher | false;
  }) {
    if (!isAbsolute(options.tronHome) || /[\u0000-\u001f\u007f]/u.test(options.tronHome)) {
      throw new GatewayError("conflict", "iOS device install data root is invalid");
    }
    if (options.gatewayChannel !== undefined
      && options.gatewayChannel !== "stable" && options.gatewayChannel !== "dev") {
      throw new GatewayError("conflict", "iOS device install Gateway channel is invalid");
    }
    this.discoverer = options.discoverer ?? defaultDiscoverTargets;
    this.launcher = options.launcher === false
      ? undefined
      : options.launcher ?? defaultLauncher(options.environment ?? process.env);
  }

  get isUsable(): boolean { return this.launcher !== undefined; }

  async configStatus(deviceIdValue: unknown): Promise<IosDeviceInstallConfig | null> {
    this.requireUsable();
    const deviceId = admitDeviceId(deviceIdValue);
    const value = await readDocument(configPath(this.options.tronHome, deviceId));
    if (value === undefined) return null;
    const config = configDocument(value);
    if (config.deviceId !== deviceId) throw new GatewayError("conflict", "iOS device install configuration owner is malformed");
    if (config.sourceRoot !== undefined) await validateSourceRoot(config.sourceRoot);
    return config;
  }

  async configure(value: {
    deviceId: unknown;
    sourceRoot: unknown;
  }): Promise<IosDeviceInstallConfig> {
    this.requireUsable();
    const deviceId = admitDeviceId(value.deviceId);
    const sourceRoot = await validateSourceRoot(value.sourceRoot);
    return this.mutex.run(async () => {
      const previous = await this.configStatus(deviceId);
      const gatewayChannel = this.options.gatewayChannel ?? "stable";
      const config: IosDeviceInstallConfig = {
        schema: 1,
        kind: CONFIG_KIND,
        deviceId,
        gatewayChannel,
        sourceRoot,
        ...(previous?.target === undefined ? {} : { target: previous.target }),
        updatedAt: new Date().toISOString(),
      };
      await mkdir(join(installRoot(this.options.tronHome), "configs"), { recursive: true, mode: 0o700 });
      await atomicWriteJson(configPath(this.options.tronHome, deviceId), config);
      return config;
    });
  }

  async activeStatus(): Promise<IosDeviceInstallStatus | null> {
    if (!this.isUsable) return null;
    const value = await readDocument(activePath(this.options.tronHome));
    if (value === undefined) return null;
    const active = activeDocument(value);
    const status = await this.status(active.deviceId);
    if (!status || status.commandId !== active.commandId) {
      throw new GatewayError("conflict", "iOS device install activity has unresolved owner state");
    }
    return status;
  }

  async status(deviceIdValue: unknown): Promise<IosDeviceInstallStatus | null> {
    this.requireUsable();
    const deviceId = admitDeviceId(deviceIdValue);
    const value = await readDocument(statusPath(this.options.tronHome, deviceId));
    if (value === undefined) return null;
    const status = statusDocument(value);
    if (status.deviceId !== deviceId) throw new GatewayError("conflict", "iOS device install status owner is malformed");
    return status;
  }

  async install(deviceIdValue: unknown, commandIdValue: unknown): Promise<{ accepted: true; commandId: string; state: string }> {
    this.requireUsable();
    const deviceId = admitDeviceId(deviceIdValue);
    const commandId = admitCommandId(commandIdValue);
    return this.mutex.run(async () => {
      let config = await this.configStatus(deviceId);
      if (!config?.sourceRoot) {
        throw new GatewayError("conflict", "Configure the source repository before installing");
      }
      const targets = await this.discoverTargets();
      let currentTarget = config.target === undefined
        ? undefined
        : targets.find((candidate) => candidate.identifier === config?.target?.identifier
          && candidate.developerModeEnabled);
      if (!currentTarget) {
        const eligible = targets.filter((candidate) => candidate.developerModeEnabled);
        if (eligible.length === 0) {
          throw new GatewayError(
            "not_found",
            "Connect and unlock this iOS device on the Mac, trust the Mac, and enable Developer Mode before installing",
            true,
          );
        }
        if (eligible.length > 1) {
          throw new GatewayError(
            "conflict",
            "Tron cannot safely identify this device while multiple Developer Mode iOS devices are available; disconnect the others and retry",
            true,
          );
        }
        currentTarget = eligible[0]!;
        config = { ...config, target: currentTarget, updatedAt: new Date().toISOString() };
        await atomicWriteJson(configPath(this.options.tronHome, deviceId), config);
      }
      const activeValue = await readDocument(activePath(this.options.tronHome));
      if (activeValue !== undefined) {
        const active = activeDocument(activeValue);
        const activeStatus = await this.status(active.deviceId).catch(() => null);
        const age = Date.now() - Date.parse(active.startedAt);
        if (age < ACTIVE_STALE_MS) {
          if (!activeStatus || activeStatus.commandId !== active.commandId) {
            throw new GatewayError("busy", "An iOS build/install has unresolved owner state", true);
          }
          if (activeStatus.state === "requested" || activeStatus.state === "running") {
            throw new GatewayError("busy", `An iOS build/install is already running for ${activeStatus.targetName}`, true);
          }
        }
        await removeIfExists(activePath(this.options.tronHome));
      }
      const startedAt = new Date().toISOString();
      const status: IosDeviceInstallStatus = {
        schema: 1,
        kind: STATUS_KIND,
        deviceId,
        state: "requested",
        commandId,
        targetName: currentTarget.name,
        startedAt,
        updatedAt: startedAt,
      };
      await mkdir(join(installRoot(this.options.tronHome), "status"), { recursive: true, mode: 0o700 });
      await atomicWriteJson(statusPath(this.options.tronHome, deviceId), status);
      await atomicWriteJson(activePath(this.options.tronHome), {
        schema: 1, kind: ACTIVE_KIND, deviceId, commandId, startedAt,
      } satisfies ActiveInstall);
      try {
        await this.launcher!({ tronHome: this.options.tronHome, deviceId, commandId });
      } catch (error) {
        await recordIosDeviceInstallHelperFailure(this.options.tronHome, deviceId, commandId, error);
        throw new GatewayError("conflict", `iOS install helper could not be started: ${failureText(error, 256)}`);
      }
      return { accepted: true, commandId, state: "install-requested" };
    });
  }

  async removeDevice(deviceIdValue: unknown): Promise<void> {
    const deviceId = admitDeviceId(deviceIdValue);
    await removeIfExists(configPath(this.options.tronHome, deviceId)).catch(() => {});
    const status = await this.status(deviceId).catch(() => null);
    if (status?.state === "succeeded" || status?.state === "failed") {
      await removeIfExists(statusPath(this.options.tronHome, deviceId)).catch(() => {});
    }
  }

  private async discoverTargets(): Promise<IosPhysicalDeviceTarget[]> {
    this.requireUsable();
    const targets = await this.discoverer();
    if (targets.length > MAX_TARGETS) throw new GatewayError("conflict", "Too many physical iOS devices were discovered");
    return targets.map(targetDocument);
  }

  private requireUsable(): void {
    if (!this.isUsable) {
      throw new GatewayError("unsupported", "Remote iOS device installation requires a supervised macOS Gateway");
    }
  }
}

function appendTail(current: string, chunk: Buffer): string {
  const next = current + chunk.toString("utf8");
  const maximum = 32 * 1_024;
  if (Buffer.byteLength(next) <= maximum) return next;
  return Buffer.from(next).subarray(-maximum).toString("utf8").replace(/^�+/u, "");
}

export function iosDeviceInstallInvocation(
  sourceRoot: string,
  targetIdentifier: string,
): { executable: "/bin/bash"; args: string[]; cwd: string } {
  return {
    executable: "/bin/bash",
    args: [join(sourceRoot, "scripts", "tron-ios-device"), "install", "--device-id", targetIdentifier],
    cwd: sourceRoot,
  };
}

function bundledXcodegen(runtimeExecutable: string): string | undefined {
  const candidate = join(dirname(runtimeExecutable), "xcodegen", "bin", "xcodegen");
  try {
    const info = lstatSync(candidate);
    return info.isFile() && !info.isSymbolicLink() && (info.mode & 0o111) !== 0 ? candidate : undefined;
  } catch { return undefined; }
}

export function iosDeviceInstallHelperEnvironment(
  config: IosDeviceInstallConfig,
  inherited: NodeJS.ProcessEnv = process.env,
  runtimeExecutable = process.execPath,
): NodeJS.ProcessEnv {
  const immutableXcodegen = bundledXcodegen(runtimeExecutable);
  const result: NodeJS.ProcessEnv = {
    PATH: inherited.PATH ?? "/usr/bin:/bin:/usr/sbin:/sbin",
    HOME: inherited.HOME,
    TMPDIR: inherited.TMPDIR,
    USER: inherited.USER,
    LOGNAME: inherited.LOGNAME,
    LANG: inherited.LANG,
    LC_ALL: inherited.LC_ALL,
    DEVELOPER_DIR: inherited.DEVELOPER_DIR,
    TRON_XCODEGEN: immutableXcodegen ?? inherited.TRON_XCODEGEN,
    TRON_IOS_GATEWAY_PROTOCOL_TARGET: config.gatewayChannel === "dev" ? "source" : "stable",
  };
  return Object.fromEntries(Object.entries(result).filter((entry): entry is [string, string] => typeof entry[1] === "string"));
}

export async function runIosDeviceInstallHelper(input: {
  tronHome: string;
  deviceId: string;
  commandId: string;
}): Promise<void> {
  const tronHome = await realpath(input.tronHome);
  const deviceId = admitDeviceId(input.deviceId);
  const commandId = admitCommandId(input.commandId);
  const configValue = await readDocument(configPath(tronHome, deviceId));
  if (configValue === undefined) throw new Error("iOS device install configuration is missing");
  const config = configDocument(configValue);
  if (!config.sourceRoot || !config.target) throw new Error("iOS device install configuration is incomplete");
  const sourceRoot = await validateSourceRoot(config.sourceRoot);
  const currentValue = await readDocument(statusPath(tronHome, deviceId));
  const current = currentValue === undefined ? undefined : statusDocument(currentValue);
  if (!current || current.commandId !== commandId) throw new Error("iOS device install command ownership changed");
  const running: IosDeviceInstallStatus = {
    ...current,
    state: "running",
    updatedAt: new Date().toISOString(),
  };
  await atomicWriteJson(statusPath(tronHome, deviceId), running);

  let tail = "";
  let timedOut = false;
  const invocation = iosDeviceInstallInvocation(sourceRoot, config.target.identifier);
  const child = spawn(invocation.executable, invocation.args, {
    cwd: invocation.cwd,
    env: iosDeviceInstallHelperEnvironment(config),
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
  });
  child.stdout?.on("data", (chunk: Buffer) => { tail = appendTail(tail, chunk); });
  child.stderr?.on("data", (chunk: Buffer) => { tail = appendTail(tail, chunk); });
  const timer = setTimeout(() => {
    timedOut = true;
    child.kill("SIGTERM");
    setTimeout(() => child.kill("SIGKILL"), 5_000).unref();
  }, INSTALL_TIMEOUT_MS);
  timer.unref();
  const outcome = await new Promise<{ code: number | null; error?: unknown }>((resolve) => {
    child.once("error", (error) => resolve({ code: null, error }));
    child.once("exit", (code) => resolve({ code }));
  });
  clearTimeout(timer);
  const succeeded = outcome.code === 0 && outcome.error === undefined && !timedOut;
  const error = succeeded ? undefined : failureText(
    timedOut
      ? "The iOS build/install exceeded its two-hour deadline."
      : outcome.error ?? (tail.trim().split("\n").slice(-12).join("\n") || `The iOS build/install exited with status ${outcome.code ?? "unknown"}.`),
  ).replaceAll(config.target.identifier, "[physical device]");
  await atomicWriteJson(statusPath(tronHome, deviceId), {
    ...running,
    state: succeeded ? "succeeded" : "failed",
    updatedAt: new Date().toISOString(),
    ...(error === undefined ? {} : { error }),
  } satisfies IosDeviceInstallStatus);
  const activeValue = await readDocument(activePath(tronHome)).catch(() => undefined);
  if (activeValue !== undefined) {
    const active = activeDocument(activeValue);
    if (active.deviceId === deviceId && active.commandId === commandId) {
      await removeIfExists(activePath(tronHome));
    }
  }
}
