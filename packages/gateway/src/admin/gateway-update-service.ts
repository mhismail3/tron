import { lstat, readFile, realpath, mkdir, rename, rm, writeFile } from "node:fs/promises";
import { lstatSync, realpathSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { isAbsolute, join, parse } from "node:path";
import { GatewayError } from "../errors.js";
import type { JsonValue } from "../protocol/types.js";

const MAX_DOCUMENT_BYTES = 64 * 1_024;
const MAX_STRING_BYTES = 256;
const MAX_VERSION_BYTES = 128;
const MAX_PATH_BYTES = 4_096;
const FINGERPRINT = /^[0-9a-f]{64}$/u;
const UPDATE_CONFIG_SCHEMA = 1;
const UPDATE_CONFIG_KIND = "tron-gateway-update-config";
const COMPONENT = /^[A-Za-z0-9._-]+$/u;

export type GatewayUpdateChannel = "stable" | "dev";
export type GatewayUpdateMode = "source" | "artifact" | "auto";

export interface GatewayUpdateRequest {
  channel: GatewayUpdateChannel;
  mode: GatewayUpdateMode;
  candidateVersion?: string;
  candidateFingerprint?: string;
  /** Gateway-owned receipt identity, never accepted from the update helper's options. */
  commandId?: string;
}

export interface GatewayRollbackRequest {
  channel: GatewayUpdateChannel;
  /** Gateway-owned receipt identity, never accepted from the update helper's options. */
  commandId: string;
}

export interface GatewayUpdateIdentity {
  version?: string;
  gatewayVersion?: string;
  sourceRevision?: string;
  runtimeEpoch?: string;
  payloadFingerprint?: string;
}

export interface GatewayUpdateConfig {
  schema: 1;
  kind: typeof UPDATE_CONFIG_KIND;
  sourceRoot: string;
  artifactRoot?: string;
  updatedAt: string;
}

export interface GatewayDebugCandidateProvenance {
  origin: "debug";
  version: string;
  payloadFingerprint: string;
  sourceRevision: string;
  testedRuntimeEpoch: string;
  candidateRuntimeEpoch: string;
}

export interface GatewayUpdateStatus {
  state: string;
  channel: GatewayUpdateChannel;
  currentIdentity: GatewayUpdateIdentity | null;
  candidateIdentity: GatewayUpdateIdentity | null;
  candidateAvailable: boolean;
  error: string | null;
  updatedAt: string | null;
  commandId: string | null;
  rollbackAvailable: boolean;
  candidateOrigin: "debug" | null;
  candidateProvenance: GatewayDebugCandidateProvenance | null;
}

export type GatewayUpdateCallback = (request: GatewayUpdateRequest | (GatewayRollbackRequest & { operation?: "rollback" })) => Promise<JsonValue>;
type RuntimeIdentityFallback = GatewayUpdateIdentity & { buildFingerprint?: string };

/** Convert the launcher's health-era buildFingerprint into update identity form. */
export function normalizeRuntimeIdentity(value: RuntimeIdentityFallback | undefined): GatewayUpdateIdentity | null {
  if (!value) return null;
  const { buildFingerprint, payloadFingerprint, ...rest } = value;
  const fingerprint = payloadFingerprint ?? buildFingerprint;
  return {
    ...rest,
    ...(typeof fingerprint === "string" && FINGERPRINT.test(fingerprint) ? { payloadFingerprint: fingerprint } : {}),
  };
}

/** The helper is trusted only when LaunchAgent exported an absolute, non-link file. */
export function gatewayUpdateHelperPath(environment: NodeJS.ProcessEnv = process.env): string | undefined {
  const value = environment.TRON_GATEWAY_UPDATE_HELPER;
  const payloadRoot = environment.TRON_GATEWAY_PAYLOAD_ROOT;
  if (environment.TRON_GATEWAY_SUPERVISED !== "1" || !value || !payloadRoot
    || !isAbsolute(value) || !isAbsolute(payloadRoot)
    || /[\u0000-\u001f\u007f]/u.test(value) || /[\u0000-\u001f\u007f]/u.test(payloadRoot)) return undefined;
  try {
    const rootInfo = lstatSync(payloadRoot);
    const helperInfo = lstatSync(value);
    if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink() || !helperInfo.isFile() || helperInfo.isSymbolicLink()) return undefined;
    const root = realpathSync(payloadRoot);
    const helper = realpathSync(value);
    if (helper !== root && !helper.startsWith(`${root}/`)) return undefined;
    // Retain the LaunchAgent's absolute spelling so helper argument
    // construction remains deterministic after containment is proven.
    return value;
  } catch { return undefined; }
}

export function gatewayRollbackHelperArgs(request: GatewayRollbackRequest): string[] {
  if (request.channel !== "stable" && request.channel !== "dev") {
    throw new GatewayError("invalid_request", "Gateway update channel must be stable or dev");
  }
  if (typeof request.commandId !== "string" || !/^[A-Za-z0-9._:-]{8,160}$/u.test(request.commandId)) {
    throw new GatewayError("invalid_request", "Gateway update command ID is invalid");
  }
  return ["rollback", "--channel", request.channel, "--command-id", request.commandId];
}

export function gatewayUpdateHelperArgs(request: GatewayUpdateRequest): string[] {
  const normalized = validateGatewayUpdateRequest({
    channel: request.channel, mode: request.mode,
    ...(request.candidateVersion === undefined ? {} : { candidateVersion: request.candidateVersion }),
    ...(request.candidateFingerprint === undefined ? {} : { candidateFingerprint: request.candidateFingerprint }),
  });
  const commandId = request.commandId;
  if (typeof commandId !== "string" || !/^[A-Za-z0-9._:-]{8,160}$/u.test(commandId)) {
    throw new GatewayError("invalid_request", "Gateway update command ID is invalid");
  }
  return ["apply", "--channel", normalized.channel, "--mode", normalized.mode,
    ...(normalized.candidateVersion === undefined ? [] : ["--candidate-version", normalized.candidateVersion]),
    ...(normalized.candidateFingerprint === undefined ? [] : ["--candidate-fingerprint", normalized.candidateFingerprint]),
    "--command-id", commandId];
}

export function updaterFailureMessage(error: unknown): string {
  return String(error instanceof Error ? error.message : error).slice(0, 2_048);
}

export function updaterFailureProgress(
  channel: GatewayUpdateChannel,
  commandId: string,
  error: unknown,
  updatedAt = new Date().toISOString(),
): Record<string, string | number> {
  return {
    schema: 1,
    kind: "tron-gateway-update-progress",
    channel,
    state: "failure",
    commandId,
    error: updaterFailureMessage(error),
    updatedAt,
  };
}

async function recordUpdaterFailure(tronHome: string, channel: GatewayUpdateChannel, commandId: string, error: unknown): Promise<void> {
  if (!isAbsolute(tronHome)) return;
  const directory = join(tronHome, "gateway", "payloads", channel);
  const root = parse(tronHome).root;
  let cursor = root;
  for (const component of tronHome.slice(root.length).split(/[\\/]+/u).filter(Boolean)) {
    cursor = join(cursor, component);
    const info = await lstat(cursor).catch(() => undefined);
    if (info?.isSymbolicLink() || info && !info.isDirectory()) return;
    const uid = process.getuid?.();
    if (info && cursor !== root && uid !== undefined && info.uid !== uid) return;
  }
  await mkdir(directory, { recursive: true, mode: 0o700 });
  for (const component of ["gateway", "payloads", channel]) {
    cursor = join(cursor, component);
    const info = await lstat(cursor).catch(() => undefined);
    const uid = process.getuid?.();
    if (!info?.isDirectory() || info.isSymbolicLink() || uid !== undefined && info.uid !== uid) return;
  }
  const path = join(directory, "update-progress.json");
  const temporary = `${path}.tmp-${process.pid}-${randomUUID()}`;
  await writeFile(temporary, `${JSON.stringify(updaterFailureProgress(channel, commandId, error))}\n`, { mode: 0o600, flag: "wx" });
  try { await rename(temporary, path); } catch (renameError) {
    await rm(temporary, { force: true });
    throw renameError;
  }
}

function launchAgentUpdater(environment: NodeJS.ProcessEnv = process.env, tronHome = environment.TRON_DATA_DIR ?? ""): GatewayUpdateCallback | undefined {
  const helper = gatewayUpdateHelperPath(environment);
  if (!helper) return undefined;
  return async (request) => {
    const commandId = request.commandId ?? `gateway-update-${randomUUID()}`;
    const args = "operation" in request && request.operation === "rollback"
      ? gatewayRollbackHelperArgs({ channel: request.channel, commandId })
      : gatewayUpdateHelperArgs({ ...(request as GatewayUpdateRequest), commandId });
    try {
      const child = spawn(process.execPath, [helper, ...args], {
        detached: true,
        stdio: "ignore",
        windowsHide: true,
      });
      // An unref'd child can still emit an asynchronous spawn error. Attach
      // this listener before unref so it is observed rather than uncaught;
      // acknowledgement remains truthful because the helper can fail later.
      child.once("error", (error) => {
        void recordUpdaterFailure(tronHome, request.channel, commandId, error).catch(() => {});
      });
      child.unref();
    } catch (error) {
      await recordUpdaterFailure(tronHome, request.channel, commandId, error).catch(() => {});
      throw new GatewayError("conflict", `Gateway update helper could not be started: ${updaterFailureMessage(error).slice(0, 256)}`);
    }
    return { accepted: true, commandId, state: "update-requested" };
  };
}

function boundedString(value: unknown, name: string, maximum = MAX_STRING_BYTES): string | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "string" || Buffer.byteLength(value) === 0 || Buffer.byteLength(value) > maximum
    || /[\u0000-\u001f\u007f]/u.test(value)) throw new GatewayError("conflict", `Gateway update ${name} is malformed`);
  return value;
}

function identity(value: unknown, name: string): GatewayUpdateIdentity {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new GatewayError("conflict", `Gateway update ${name} identity is malformed`);
  const raw = value as Record<string, unknown>;
  const result: GatewayUpdateIdentity = {};
  const version = boundedString(raw.version, `${name}.version`, MAX_VERSION_BYTES);
  const gatewayVersion = boundedString(raw.gatewayVersion, `${name}.gatewayVersion`, MAX_VERSION_BYTES);
  const sourceRevision = boundedString(raw.sourceRevision, `${name}.sourceRevision`);
  const runtimeEpoch = boundedString(raw.runtimeEpoch, `${name}.runtimeEpoch`, MAX_VERSION_BYTES);
  const payloadFingerprint = boundedString(raw.payloadFingerprint, `${name}.payloadFingerprint`, 64);
  if (version !== undefined && !COMPONENT.test(version)) throw new GatewayError("conflict", `Gateway update ${name} version is malformed`);
  if (runtimeEpoch !== undefined && !COMPONENT.test(runtimeEpoch)) throw new GatewayError("conflict", `Gateway update ${name} runtime epoch is malformed`);
  if (payloadFingerprint !== undefined && !FINGERPRINT.test(payloadFingerprint)) throw new GatewayError("conflict", `Gateway update ${name} fingerprint is malformed`);
  if (version !== undefined) result.version = version;
  if (gatewayVersion !== undefined) result.gatewayVersion = gatewayVersion;
  if (sourceRevision !== undefined) result.sourceRevision = sourceRevision;
  if (runtimeEpoch !== undefined) result.runtimeEpoch = runtimeEpoch;
  if (payloadFingerprint !== undefined) result.payloadFingerprint = payloadFingerprint;
  return result;
}

async function readBounded(path: string): Promise<unknown | undefined> {
  let data: Buffer;
  try {
    const file = await lstat(path);
    if (!file.isFile() || file.isSymbolicLink()) throw new GatewayError("conflict", "Gateway update state is malformed or oversized");
    data = await readFile(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw error;
  }
  if (data.length === 0 || data.length > MAX_DOCUMENT_BYTES) throw new GatewayError("conflict", "Gateway update state is malformed or oversized");
  try { return JSON.parse(data.toString("utf8")); }
  catch { throw new GatewayError("conflict", "Gateway update state is malformed or oversized"); }
}

function selection(value: unknown, channel: GatewayUpdateChannel): { version: string; payloadFingerprint: string } {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new GatewayError("conflict", "Gateway update selection is malformed");
  const raw = value as Record<string, unknown>;
  if (raw.schema !== 1 || raw.kind !== "tron-gateway-selection" || raw.channel !== channel
    || typeof raw.version !== "string" || !COMPONENT.test(raw.version) || Buffer.byteLength(raw.version) > MAX_VERSION_BYTES
    || typeof raw.payloadFingerprint !== "string" || !FINGERPRINT.test(raw.payloadFingerprint)) {
    throw new GatewayError("conflict", "Gateway update selection is malformed");
  }
  return { version: raw.version, payloadFingerprint: raw.payloadFingerprint };
}

function manifest(value: unknown, channel: GatewayUpdateChannel, selected: { version: string; payloadFingerprint: string }): GatewayUpdateIdentity {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new GatewayError("conflict", "Gateway payload manifest is malformed");
  const raw = value as Record<string, unknown>;
  if (raw.schema !== 1 || raw.kind !== "tron-gateway-payload" || raw.channel !== channel
    || raw.version !== selected.version || raw.payloadFingerprint !== selected.payloadFingerprint
    || typeof raw.gatewayVersion !== "string" || typeof raw.nodeVersion !== "string"
    || raw.gatewayVersion.length === 0 || raw.gatewayVersion.length > MAX_VERSION_BYTES
    || raw.nodeVersion.length === 0 || raw.nodeVersion.length > MAX_VERSION_BYTES
    || typeof raw.sourceRevision !== "string" || raw.sourceRevision.length === 0
    || typeof raw.runtimeEpoch !== "string" || !COMPONENT.test(raw.runtimeEpoch)) {
    throw new GatewayError("conflict", "Gateway payload manifest is malformed");
  }
  return identity({
    version: raw.version,
    gatewayVersion: raw.gatewayVersion,
    sourceRevision: raw.sourceRevision,
    runtimeEpoch: raw.runtimeEpoch,
    payloadFingerprint: raw.payloadFingerprint,
  }, "payload");
}

function stateIdentity(raw: Record<string, unknown>, name: string): GatewayUpdateIdentity {
  return identity({
    version: raw.version,
    gatewayVersion: raw.gatewayVersion,
    sourceRevision: raw.sourceRevision,
    runtimeEpoch: raw.runtimeEpoch,
    payloadFingerprint: raw.payloadFingerprint,
  }, name);
}

async function validateTrustedDirectory(path: unknown, name: string, markers: string[] = []): Promise<string> {
  if (typeof path !== "string" || !isAbsolute(path) || Buffer.byteLength(path) > MAX_PATH_BYTES
    || /[\u0000-\u001f\u007f]/u.test(path)) throw new GatewayError("invalid_request", `Gateway update ${name} must be an absolute path`);
  const normalized = path;
  const root = parse(normalized).root;
  let cursor = root;
  for (const component of normalized.slice(root.length).split(/[\\/]+/u).filter(Boolean)) {
    cursor = join(cursor, component);
    let info;
    try { info = await lstat(cursor); } catch { throw new GatewayError("conflict", `Gateway update ${name} is unavailable`); }
    if (info.isSymbolicLink()) throw new GatewayError("conflict", `Gateway update ${name} contains a symlink`);
  }
  let resolved: string;
  try { resolved = await realpath(normalized); } catch { throw new GatewayError("conflict", `Gateway update ${name} is unavailable`); }
  const info = await lstat(resolved);
  if (!info.isDirectory() || info.isSymbolicLink()) throw new GatewayError("conflict", `Gateway update ${name} must be a regular directory`);
  for (const marker of markers) {
    const markerPath = join(resolved, marker);
    const markerInfo = await lstat(markerPath).catch(() => undefined);
    if (!markerInfo?.isFile() || markerInfo.isSymbolicLink()) throw new GatewayError("conflict", `Gateway update ${name} is not a Tron repository`);
  }
  return resolved;
}

function configDocument(value: unknown): GatewayUpdateConfig {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new GatewayError("conflict", "Gateway update config is malformed");
  const raw = value as Record<string, unknown>;
  if (Object.keys(raw).some((key) => !["schema", "kind", "sourceRoot", "artifactRoot", "updatedAt"].includes(key))
    || raw.schema !== UPDATE_CONFIG_SCHEMA || raw.kind !== UPDATE_CONFIG_KIND
    || typeof raw.sourceRoot !== "string" || !isAbsolute(raw.sourceRoot)
    || Buffer.byteLength(raw.sourceRoot) > MAX_PATH_BYTES || /[\u0000-\u001f\u007f]/u.test(raw.sourceRoot)
    || raw.artifactRoot !== undefined && (typeof raw.artifactRoot !== "string" || !isAbsolute(raw.artifactRoot) || Buffer.byteLength(raw.artifactRoot) > MAX_PATH_BYTES || /[\u0000-\u001f\u007f]/u.test(raw.artifactRoot))
    || typeof raw.updatedAt !== "string" || Buffer.byteLength(raw.updatedAt) > 64
    || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/u.test(raw.updatedAt)) {
    throw new GatewayError("conflict", "Gateway update config is malformed");
  }
  return {
    schema: 1, kind: UPDATE_CONFIG_KIND, sourceRoot: raw.sourceRoot,
    ...(raw.artifactRoot === undefined ? {} : { artifactRoot: raw.artifactRoot }), updatedAt: raw.updatedAt,
  };
}

export class GatewayUpdateService {
  private readonly updater: GatewayUpdateCallback | undefined;
  private readonly runtimeChannel: GatewayUpdateChannel;

  constructor(private readonly options: {
    tronHome: string;
    runtimeIdentity?: RuntimeIdentityFallback;
    updater?: GatewayUpdateCallback;
    runtimeChannel?: GatewayUpdateChannel;
  }) {
    this.updater = options.updater ?? launchAgentUpdater(process.env, options.tronHome);
    const configuredChannel = options.runtimeChannel ?? process.env.TRON_GATEWAY_CHANNEL ?? "stable";
    if (configuredChannel !== "stable" && configuredChannel !== "dev") {
      throw new GatewayError("conflict", "Gateway runtime channel is invalid");
    }
    this.runtimeChannel = configuredChannel;
  }

  get isUsable(): boolean { return this.updater !== undefined; }
  get channel(): GatewayUpdateChannel { return this.runtimeChannel; }

  private configPath(): string { return join(this.options.tronHome, "gateway", "update-config.json"); }

  async configStatus(): Promise<GatewayUpdateConfig | null> {
    const path = this.configPath();
    const value = await readBounded(path);
    if (value === undefined) return null;
    const config = configDocument(value);
    await validateTrustedDirectory(config.sourceRoot, "sourceRoot", [
      "packages/gateway/package.json", "packages/gateway/package-lock.json",
      "packages/gateway/scripts/ensure-node-pty-helper.mjs", "scripts/gateway-payload-deploy.mjs",
    ]);
    if (config.artifactRoot !== undefined) await validateTrustedDirectory(config.artifactRoot, "artifactRoot");
    return config;
  }

  async configure(value: { sourceRoot: unknown; artifactRoot?: unknown }): Promise<GatewayUpdateConfig> {
    const sourceRoot = await validateTrustedDirectory(value.sourceRoot, "sourceRoot", [
      "packages/gateway/package.json", "packages/gateway/package-lock.json",
      "packages/gateway/scripts/ensure-node-pty-helper.mjs", "scripts/gateway-payload-deploy.mjs",
    ]);
    let artifactRoot: string | undefined;
    if (value.artifactRoot !== undefined && value.artifactRoot !== null) {
      artifactRoot = await validateTrustedDirectory(value.artifactRoot, "artifactRoot");
    }
    const config: GatewayUpdateConfig = {
      schema: 1, kind: UPDATE_CONFIG_KIND, sourceRoot,
      ...(artifactRoot === undefined ? {} : { artifactRoot }), updatedAt: new Date().toISOString(),
    };
    const path = this.configPath();
    await mkdir(join(this.options.tronHome, "gateway"), { recursive: true, mode: 0o700 });
    const temporary = `${path}.tmp-${process.pid}-${randomUUID()}`;
    await writeFile(temporary, `${JSON.stringify(config)}\n`, { mode: 0o600, flag: "wx" });
    try { await rename(temporary, path); } catch (error) { await rm(temporary, { force: true }); throw error; }
    return config;
  }

  async status(channel: GatewayUpdateChannel = this.runtimeChannel): Promise<GatewayUpdateStatus> {
    if (channel !== "stable" && channel !== "dev") throw new GatewayError("invalid_request", "Gateway update channel is invalid");
    if (channel !== this.runtimeChannel) throw new GatewayError("invalid_request", `Gateway ${this.runtimeChannel} runtime cannot inspect ${channel} updates`);
    const root = join(this.options.tronHome, "gateway", "payloads", channel);
    const stateValue = await readBounded(join(root, "deployment-state.json"));
    const progressValue = await readBounded(join(root, "update-progress.json"));
    const currentSelectionValue = await readBounded(join(root, "current.json"));
    const previousSelectionValue = await readBounded(join(root, "previous.json"));
    let currentIdentity = normalizeRuntimeIdentity(this.options.runtimeIdentity);
    let candidateIdentity: GatewayUpdateIdentity | null = null;
    let candidateAvailable = false;
    let state = "unknown";
    let error: string | null = null;
    let updatedAt: string | null = null;
    let commandId: string | null = null;
    let candidateOrigin: "debug" | null = null;
    let candidateProvenance: GatewayDebugCandidateProvenance | null = null;
    let debugOriginValue: unknown;
    let declaresDebugOrigin = false;

    if (currentSelectionValue !== undefined) {
      const selected = selection(currentSelectionValue, channel);
      const selectedManifest = await readBounded(join(root, "versions", selected.version, "manifest.json"));
      if (selectedManifest === undefined) throw new GatewayError("conflict", "Gateway payload manifest is missing");
      // Validate the selected pointer, but never replace observed live identity
      // with it: publication precedes restart and status must not report an
      // inactive candidate as the running Gateway.
      void manifest(selectedManifest, channel, selected);
    }
    const rollbackAvailable = previousSelectionValue !== undefined;
    if (previousSelectionValue !== undefined) {
      const previous = selection(previousSelectionValue, channel);
      const previousManifest = await readBounded(join(root, "versions", previous.version, "manifest.json"));
      if (previousManifest === undefined) throw new GatewayError("conflict", "Gateway payload manifest is missing");
      // Previous is intentionally only a rollback reference. It is not shown as
      // a candidate unless deployment state explicitly marks it as one.
      void manifest(previousManifest, channel, previous);
    }
    if (stateValue !== undefined) {
      if (!stateValue || typeof stateValue !== "object" || Array.isArray(stateValue)) throw new GatewayError("conflict", "Gateway deployment state is malformed");
      const raw = stateValue as Record<string, unknown>;
      if (raw.schema !== 1 || raw.kind !== "tron-gateway-deployment" || raw.channel !== channel
        || typeof raw.state !== "string" || raw.state.length === 0 || raw.state.length > 64) {
        throw new GatewayError("conflict", "Gateway deployment state is malformed");
      }
      state = raw.state;
      const stateUpdatedAt = boundedString(raw.updatedAt, "updatedAt", 64);
      if (stateUpdatedAt === undefined || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/u.test(stateUpdatedAt)) {
        throw new GatewayError("conflict", "Gateway deployment state is malformed");
      }
      updatedAt = stateUpdatedAt;
      const stateCommandId = boundedString(raw.commandId, "commandId", 160);
      if (stateCommandId !== undefined && !/^[A-Za-z0-9._:-]{8,160}$/u.test(stateCommandId)) {
        throw new GatewayError("conflict", "Gateway deployment command ID is malformed");
      }
      commandId = stateCommandId ?? null;
      if (raw.error !== undefined) error = boundedString(raw.error, "error", 2_048) ?? null;
      if (raw.candidateOrigin !== undefined) {
        if (raw.candidateOrigin !== "debug") throw new GatewayError("conflict", "Gateway candidate origin is malformed");
        declaresDebugOrigin = true;
        debugOriginValue = raw.debugOriginIdentity;
      }
      let candidateReference: GatewayUpdateIdentity | null = null;
      if (raw.candidateIdentity !== undefined) {
        candidateReference = stateIdentity(raw.candidateIdentity as Record<string, unknown>, "candidate");
      } else if (raw.candidate !== undefined) {
        candidateReference = stateIdentity(raw.candidate as Record<string, unknown>, "candidate");
      } else if (raw.candidateVersion !== undefined || raw.candidateFingerprint !== undefined) {
        candidateReference = stateIdentity({
          version: raw.candidateVersion,
          payloadFingerprint: raw.candidateFingerprint,
          sourceRevision: raw.candidateSourceRevision,
          runtimeEpoch: raw.candidateRuntimeEpoch,
          gatewayVersion: raw.candidateGatewayVersion,
        }, "candidate");
      }
      if (candidateReference !== null) {
        try {
          if (!candidateReference.version || !candidateReference.payloadFingerprint) {
            throw new GatewayError("conflict", "Gateway update candidate identity is malformed");
          }
          const candidateSelection = {
            version: candidateReference.version,
            payloadFingerprint: candidateReference.payloadFingerprint,
          };
          const candidateManifest = await readBounded(join(root, "versions", candidateSelection.version, "manifest.json"));
          if (candidateManifest === undefined) throw new GatewayError("conflict", "Gateway candidate manifest is missing");
          const verifiedCandidate = manifest(candidateManifest, channel, candidateSelection);
          // A supervised runtime may only expose health-era provenance (no
          // payload version). A verified fingerprint is still authoritative;
          // an optional runtime version narrows the comparison when present.
          const isCurrent = currentIdentity?.payloadFingerprint === verifiedCandidate.payloadFingerprint
            && (currentIdentity?.version === undefined || currentIdentity?.version === verifiedCandidate.version);
          if (!isCurrent) {
            candidateIdentity = verifiedCandidate;
            candidateAvailable = true;
            if (declaresDebugOrigin) {
              if (!debugOriginValue || typeof debugOriginValue !== "object" || Array.isArray(debugOriginValue)) {
                throw new GatewayError("conflict", "Gateway Debug candidate provenance is malformed");
              }
              const origin = debugOriginValue as Record<string, unknown>;
              const fields = ["version", "payloadFingerprint", "testedPayloadFingerprint", "sourceRevision", "testedRuntimeEpoch", "candidateRuntimeEpoch"];
              if (Object.keys(origin).some((key) => !fields.includes(key))
                || typeof origin.version !== "string" || !COMPONENT.test(origin.version) || origin.version !== verifiedCandidate.version
                || typeof origin.payloadFingerprint !== "string" || !FINGERPRINT.test(origin.payloadFingerprint) || origin.payloadFingerprint !== verifiedCandidate.payloadFingerprint
                || typeof origin.testedPayloadFingerprint !== "string" || !FINGERPRINT.test(origin.testedPayloadFingerprint)
                || typeof origin.sourceRevision !== "string" || origin.sourceRevision !== verifiedCandidate.sourceRevision
                || typeof origin.testedRuntimeEpoch !== "string" || !COMPONENT.test(origin.testedRuntimeEpoch)
                || typeof origin.candidateRuntimeEpoch !== "string" || !COMPONENT.test(origin.candidateRuntimeEpoch)
                || origin.candidateRuntimeEpoch !== verifiedCandidate.runtimeEpoch) {
                throw new GatewayError("conflict", "Gateway Debug candidate provenance does not match the verified candidate");
              }
              candidateOrigin = "debug";
              candidateProvenance = {
                origin: "debug", version: origin.version, payloadFingerprint: origin.payloadFingerprint,
                sourceRevision: origin.sourceRevision, testedRuntimeEpoch: origin.testedRuntimeEpoch,
                candidateRuntimeEpoch: origin.candidateRuntimeEpoch,
              } as GatewayDebugCandidateProvenance;
            }
          }
        } catch (candidateError) {
          // A deployment marker may outlive a failed staging attempt. Never
          // project an unverified candidate to iOS; retain only bounded status.
          candidateIdentity = null;
          candidateAvailable = false;
          error = error ?? "Gateway candidate is unavailable or invalid";
          void candidateError;
        }
      }
    }
    if (progressValue !== undefined) {
      if (!progressValue || typeof progressValue !== "object" || Array.isArray(progressValue)) throw new GatewayError("conflict", "Gateway update progress is malformed");
      const raw = progressValue as Record<string, unknown>;
      if (raw.schema !== 1 || raw.kind !== "tron-gateway-update-progress" || raw.channel !== channel
        || typeof raw.state !== "string" || raw.state.length === 0 || raw.state.length > 64) {
        throw new GatewayError("conflict", "Gateway update progress is malformed");
      }
      const progressUpdatedAt = boundedString(raw.updatedAt, "updatedAt", 64);
      if (progressUpdatedAt === undefined || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/u.test(progressUpdatedAt)) {
        throw new GatewayError("conflict", "Gateway update progress is malformed");
      }
      // A delayed helper write must not regress an authoritative terminal
      // deployment state. Timestamps are validated ISO-8601 strings, so their
      // epoch comparison is deterministic and bounded.
      const progressCommandId = boundedString(raw.commandId, "commandId", 160);
      if (progressCommandId !== undefined && !/^[A-Za-z0-9._:-]{8,160}$/u.test(progressCommandId)) {
        throw new GatewayError("conflict", "Gateway update progress command ID is malformed");
      }
      if (updatedAt === null || Date.parse(progressUpdatedAt) >= Date.parse(updatedAt)) {
        state = raw.state;
        updatedAt = progressUpdatedAt;
        commandId = progressCommandId ?? null;
        if (raw.error !== undefined) error = boundedString(raw.error, "error", 2_048) ?? null;
      }
    }
    if (!candidateAvailable) { candidateOrigin = null; candidateProvenance = null; }
    return { state, channel, currentIdentity, candidateIdentity, candidateAvailable, error, updatedAt, commandId, rollbackAvailable, candidateOrigin, candidateProvenance };
  }

  async rollback(request: GatewayRollbackRequest): Promise<JsonValue> {
    if (request.channel !== this.runtimeChannel) throw new GatewayError("invalid_request", `Gateway ${this.runtimeChannel} runtime cannot roll back ${request.channel}`);
    if (!this.updater) throw new GatewayError("unsupported", "Gateway updates require the LaunchAgent-owned update helper");
    return this.updater({ ...request, operation: "rollback" });
  }

  async update(request: GatewayUpdateRequest): Promise<JsonValue> {
    if (request.channel !== this.runtimeChannel) throw new GatewayError("invalid_request", `Gateway ${this.runtimeChannel} runtime cannot update ${request.channel}`);
    if (!this.updater) throw new GatewayError("unsupported", "Gateway updates require the LaunchAgent-owned update helper");
    return this.updater(request);
  }
}

export function validateGatewayUpdateRequest(value: Record<string, unknown>): GatewayUpdateRequest {
  const allowed = new Set(["commandId", "channel", "mode", "candidateVersion", "candidateFingerprint"]);
  if (Object.keys(value).some((key) => !allowed.has(key))) throw new GatewayError("invalid_request", "Gateway update parameters contain an unsupported field");
  const channel = value.channel === undefined ? "stable" : value.channel;
  const mode = value.mode === undefined ? "auto" : value.mode;
  if (channel !== "stable" && channel !== "dev") throw new GatewayError("invalid_request", "Gateway update channel must be stable or dev");
  if (mode !== "source" && mode !== "artifact" && mode !== "auto") throw new GatewayError("invalid_request", "Gateway update mode is invalid");
  const candidateVersion = value.candidateVersion === undefined ? undefined : boundedString(value.candidateVersion, "candidateVersion", MAX_VERSION_BYTES);
  if (candidateVersion !== undefined && !COMPONENT.test(candidateVersion)) throw new GatewayError("invalid_request", "Gateway update candidateVersion is invalid");
  const candidateFingerprint = value.candidateFingerprint === undefined ? undefined : boundedString(value.candidateFingerprint, "candidateFingerprint", 64);
  if (candidateFingerprint !== undefined && !FINGERPRINT.test(candidateFingerprint)) throw new GatewayError("invalid_request", "Gateway update candidateFingerprint is invalid");
  if (mode === "artifact" && (candidateVersion === undefined || candidateFingerprint === undefined)) {
    throw new GatewayError("invalid_request", "Artifact updates require exact candidateVersion and candidateFingerprint");
  }
  return { channel, mode, ...(candidateVersion === undefined ? {} : { candidateVersion }), ...(candidateFingerprint === undefined ? {} : { candidateFingerprint }) };
}
