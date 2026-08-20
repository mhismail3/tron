#!/usr/bin/env node
/**
 * Agent-manageable Gateway payload staging and promotion.  This command owns
 * only the bounded payload projection; the LaunchAgent remains the process
 * supervisor and canonical Gateway state is never modified.
 */
import { createHash, randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import { existsSync } from "node:fs";
import { spawn } from "node:child_process";
import { homedir, networkInterfaces, tmpdir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  access,
  chmod,
  cp,
  lstat,
  mkdir,
  mkdtemp,
  open,
  readFile,
  readdir,
  realpath,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";

// The helper is copied into app/scripts in the shipped payload. Resolve its
// production dependencies from that adjacent app package first, then fall back
// to the repository package when this source copy is run in-place.
const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const adjacentPackage = join(scriptDirectory, "..", "package.json");
const sourcePackage = join(scriptDirectory, "../packages/gateway/package.json");
const dependencyPackage = (() => {
  try { return existsSync(adjacentPackage) ? adjacentPackage : sourcePackage; } catch { return sourcePackage; }
})();
const requireForDependencies = createRequire(dependencyPackage);
const WebSocket = requireForDependencies("ws");
const lockfile = requireForDependencies("proper-lockfile");

const MAX_MANIFEST_BYTES = 64 * 1024;
const SCHEMA = 1;
const KIND = "tron-gateway-payload";
const SELECTION_KIND = "tron-gateway-selection";
const PROTOCOL_VERSION = 3;
const LOCAL_CREDENTIAL_MAX_BYTES = 64 * 1024;
const REQUIREMENTS = [
  ["app/dist/index.js", 1_024, false],
  ["app/package.json", 1, false],
  ["app/package-lock.json", 1, false],
  ["app/scripts/ensure-node-pty-helper.mjs", 1, false],
  ["app/scripts/gateway-payload-deploy.mjs", 1, false],
  ["app/node_modules", 0, true],
  ["runtime/node-arm64", 1_048_576, false],
  ["runtime/node-x64", 1_048_576, false],
];

export function isTailscaleAddress(address) {
  if (address.toLowerCase().startsWith("fd7a:115c:a1e0:")) return true;
  const octets = address.split(".").map(Number);
  return octets.length === 4 && octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127;
}

/** Resolve the documented bind name identically for health and WebSocket traffic. */
export function resolveDeploymentHost(raw, interfaces = networkInterfaces()) {
  const requested = raw?.trim() || "tailscale";
  if (requested !== "tailscale") return requested;
  const candidates = Object.entries(interfaces).flatMap(([name, addresses]) => (addresses ?? [])
    .filter((candidate) => !candidate.internal && isTailscaleAddress(candidate.address))
    .map((candidate) => ({ ...candidate, name })));
  candidates.sort((left, right) => {
    const family = (value) => value === "IPv4" || value === 4 ? 0 : 1;
    const compare = (a, b) => a === b ? 0 : a < b ? -1 : 1;
    const compareIPv4 = (a, b) => {
      const leftOctets = a.split(".").map(Number);
      const rightOctets = b.split(".").map(Number);
      for (let index = 0; index < leftOctets.length; index += 1) {
        if (leftOctets[index] !== rightOctets[index]) return leftOctets[index] - rightOctets[index];
      }
      return 0;
    };
    const leftFamily = family(left.family);
    const rightFamily = family(right.family);
    return leftFamily - rightFamily
      || (leftFamily === 0 ? compareIPv4(left.address, right.address) : compare(left.address, right.address))
      || compare(left.name, right.name);
  });
  if (candidates[0]) return candidates[0].address;
  throw new Error("Tailscale is not connected; Tron cannot reach the Gateway");
}

export function protocolHandshakeCompatible(frame, expected = PROTOCOL_VERSION) {
  return !!frame && frame.type === "hello"
    && frame.protocolVersion === expected && frame.minProtocolVersion === expected;
}

export function validComponent(value, maximum) {
  return typeof value === "string" && value.length > 0 && Buffer.byteLength(value) <= maximum
    && value !== "." && value !== ".." && /^[A-Za-z0-9._-]+$/u.test(value);
}

function fingerprint(value) {
  return typeof value === "string" && /^[0-9a-f]{64}$/u.test(value);
}

function under(root, candidate) {
  const rootPath = resolve(root);
  const candidatePath = resolve(candidate);
  return candidatePath === rootPath || candidatePath.startsWith(`${rootPath}/`);
}

async function regular(path, minimum = 1) {
  const info = await stat(path);
  return info.isFile() && info.size >= minimum;
}

async function completePayload(root) {
  const requested = resolve(root);
  if ((await lstat(requested)).isSymbolicLink()) throw new Error("payload root must not be a symlink");
  const resolved = await realpath(requested);
  const rootInfo = await stat(resolved);
  if (!rootInfo.isDirectory()) throw new Error("payload root is not a directory");
  for (const [path, minimum, directory] of REQUIREMENTS) {
    const candidate = join(resolved, path);
    if (!under(resolved, candidate)) throw new Error(`payload path escapes root: ${path}`);
    const linkInfo = await lstat(candidate);
    if (linkInfo.isSymbolicLink()) throw new Error(`payload contains a symlink: ${path}`);
    const info = await stat(candidate);
    if (directory ? !info.isDirectory() : !info.isFile() || info.size < minimum) {
      throw new Error(`payload is incomplete: ${path}`);
    }
    if (!directory && path.startsWith("runtime/") && (info.mode & 0o111) === 0) {
      throw new Error(`runtime is not executable: ${path}`);
    }
  }
}

async function regularFiles(root, prefix) {
  const output = [];
  async function visit(directory, relativePath) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const entryRelative = relativePath ? join(relativePath, entry.name) : entry.name;
      const path = join(directory, entry.name);
      if (entry.isDirectory()) await visit(path, entryRelative);
      else if (entry.isFile()) output.push(entryRelative);
      else throw new Error(`payload contains unsupported entry: ${entryRelative}`);
    }
  }
  await visit(join(root, prefix), prefix);
  return output;
}

/** Must remain byte-for-byte compatible with hash-gateway-payload.sh. */
export async function payloadFingerprint(root) {
  await completePayload(root);
  const files = [
    ...(await regularFiles(root, "app")),
    ...(await regularFiles(root, "runtime")),
  ].sort((a, b) => Buffer.from(a).compare(Buffer.from(b)));
  const lines = [];
  for (const path of files) {
    const digest = createHash("sha256").update(await readFile(join(root, path))).digest("hex");
    lines.push(`${digest}  ${path}\n`);
  }
  return createHash("sha256").update(lines.join("")).digest("hex");
}

async function json(path, maximum = MAX_MANIFEST_BYTES) {
  const data = await readFile(path);
  if (data.length === 0 || data.length > maximum) throw new Error(`${path} is missing, empty, or oversized`);
  try { return JSON.parse(data); } catch { throw new Error(`${path} is not valid JSON`); }
}

function gatewayTimestamp(value) {
  if (typeof value !== "string" || Buffer.byteLength(value) > 64
    || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/u.test(value)) return false;
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(?:Z|[+-](\d{2}):(\d{2}))$/u.exec(value);
  if (!match) return false;
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = Number(match[6]);
  const offsetHour = match[7] === undefined ? 0 : Number(match[7]);
  const offsetMinute = match[8] === undefined ? 0 : Number(match[8]);
  const days = new Date(Date.UTC(Number(match[1]), month, 0)).getUTCDate();
  return month >= 1 && month <= 12 && day >= 1 && day <= days && hour <= 23 && minute <= 59 && second <= 59
    && offsetHour <= 23 && offsetMinute <= 59 && Number.isFinite(Date.parse(value));
}

export function validateLocalCredentialDocument(document) {
  if (!document || typeof document !== "object" || Array.isArray(document)) return false;
  const keys = Object.keys(document);
  return keys.length === 4 && keys.every((key) => ["version", "bearerToken", "purpose", "lastUpdated"].includes(key))
    && document.version === 2 && document.purpose === "local-wrapper-health"
    && typeof document.bearerToken === "string" && Buffer.byteLength(document.bearerToken) >= 32
    && Buffer.byteLength(document.bearerToken) <= 256 && gatewayTimestamp(document.lastUpdated);
}

async function readLocalCredential(path) {
  const info = await lstat(path);
  if (!info.isFile() || info.isSymbolicLink() || info.size <= 0 || info.size > LOCAL_CREDENTIAL_MAX_BYTES
    || (info.mode & 0o077) !== 0) throw new Error("local Gateway credential is missing or unsafe");
  const document = await json(path, LOCAL_CREDENTIAL_MAX_BYTES);
  if (!validateLocalCredentialDocument(document)) throw new Error("local Gateway credential has an invalid shape");
  return document.bearerToken;
}

function payloadManifest(value, expected = {}) {
  if (!value || typeof value !== "object" || Array.isArray(value)
    || value.schema !== SCHEMA || value.kind !== KIND
    || !validComponent(value.channel, 64) || !validComponent(value.version, 128)
    || typeof value.gatewayVersion !== "string" || value.gatewayVersion.length === 0
    || typeof value.nodeVersion !== "string" || value.nodeVersion.length === 0
    || typeof value.sourceRevision !== "string" || value.sourceRevision.length === 0
    || !validComponent(value.runtimeEpoch, 128) || !fingerprint(value.payloadFingerprint)) {
    throw new Error("payload manifest identity is invalid");
  }
  for (const [key, expectedValue] of Object.entries(expected)) {
    if (expectedValue !== undefined && value[key] !== expectedValue) throw new Error(`payload manifest ${key} does not match expected identity`);
  }
  return value;
}

export async function validatePayload(root, expected = {}, checkFingerprint = true) {
  await completePayload(root);
  const manifest = payloadManifest(await json(join(root, "manifest.json")), expected);
  if (checkFingerprint) {
    const actual = await payloadFingerprint(root);
    if (actual !== manifest.payloadFingerprint) throw new Error("payload fingerprint does not match staged files");
  }
  return manifest;
}

function store(home, channel) {
  if (!isAbsolute(home) || !validComponent(channel, 64)) throw new Error("invalid home or channel");
  const channelRoot = join(home, "gateway", "payloads", channel);
  return {
    home, channel, channelRoot,
    versionsRoot: join(channelRoot, "versions"),
    current: join(channelRoot, "current.json"),
    previous: join(channelRoot, "previous.json"),
    state: join(channelRoot, "deployment-state.json"),
    progress: join(channelRoot, "update-progress.json"),
    config: join(home, "gateway", "update-config.json"),
    lock: join(channelRoot, ".update.lock"),
  };
}

async function readOptional(path) {
  try { return await json(path); } catch (error) {
    if (error?.code === "ENOENT") return undefined;
    throw error;
  }
}

const UPDATE_CONFIG_KIND = "tron-gateway-update-config";
const MAX_UPDATE_CONFIG_PATH_BYTES = 4_096;

export function validateUpdateConfigDocument(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)
    || Object.keys(value).some((key) => !["schema", "kind", "sourceRoot", "artifactRoot", "updatedAt"].includes(key))
    || value.schema !== SCHEMA || value.kind !== UPDATE_CONFIG_KIND
    || typeof value.sourceRoot !== "string" || !isAbsolute(value.sourceRoot)
    || Buffer.byteLength(value.sourceRoot) > MAX_UPDATE_CONFIG_PATH_BYTES || /[\u0000-\u001f\u007f]/u.test(value.sourceRoot)
    || (value.artifactRoot !== undefined && (typeof value.artifactRoot !== "string"
      || !isAbsolute(value.artifactRoot) || Buffer.byteLength(value.artifactRoot) > MAX_UPDATE_CONFIG_PATH_BYTES || /[\u0000-\u001f\u007f]/u.test(value.artifactRoot)))
    || typeof value.updatedAt !== "string" || !gatewayTimestamp(value.updatedAt)) return false;
  return true;
}

async function noSymlinkDirectory(path, markers = []) {
  if (!isAbsolute(path) || Buffer.byteLength(path) > MAX_UPDATE_CONFIG_PATH_BYTES) throw new Error("trusted update path must be absolute and bounded");
  const root = resolve(path).split("/")[0] === "" ? "/" : resolve(path).slice(0, resolve(path).indexOf("/") + 1);
  let cursor = root;
  for (const component of resolve(path).slice(root.length).split("/").filter(Boolean)) {
    cursor = join(cursor, component);
    const info = await lstat(cursor).catch(() => undefined);
    if (!info || info.isSymbolicLink()) throw new Error("trusted update path is missing or contains a symlink");
  }
  const info = await lstat(path);
  if (!info.isDirectory() || info.isSymbolicLink()) throw new Error("trusted update path is not a regular directory");
  for (const marker of markers) {
    const markerInfo = await lstat(join(path, marker)).catch(() => undefined);
    if (!markerInfo?.isFile() || markerInfo.isSymbolicLink()) throw new Error("trusted source is not a Tron repository");
  }
  return resolve(path);
}

async function readUpdateConfig(paths) {
  const value = await readOptional(paths.config);
  if (value === undefined || !validateUpdateConfigDocument(value)) throw new Error("trusted Gateway update config is missing or malformed");
  const sourceRoot = await noSymlinkDirectory(value.sourceRoot, ["packages/gateway/package.json", "packages/gateway/package-lock.json"]);
  const artifactRoot = value.artifactRoot === undefined ? undefined : await noSymlinkDirectory(value.artifactRoot);
  return { ...value, sourceRoot, ...(artifactRoot === undefined ? {} : { artifactRoot }) };
}

async function atomicBytes(path, data, mode = 0o600) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.tmp-${process.pid}-${randomUUID()}`;
  await writeFile(temporary, data, { mode, flag: "wx" });
  try {
    await rename(temporary, path);
  } catch (error) {
    await rm(temporary, { force: true });
    throw error;
  }
}

async function atomicJson(path, value) {
  return atomicBytes(path, `${JSON.stringify(value)}\n`);
}

async function captureSelectionState(paths) {
  const read = async (path) => {
    try {
      const bytes = await readFile(path);
      selection(JSON.parse(bytes), paths.channel);
      return bytes;
    } catch (error) {
      if (error?.code === "ENOENT") return undefined;
      throw error;
    }
  };
  return { current: await read(paths.current), previous: await read(paths.previous) };
}

async function restoreSelectionState(paths, state) {
  // Restore current first: never intentionally leave a newly active selection
  // while state recovery is still in progress. Each replacement remains atomic.
  if (state.current === undefined) await rm(paths.current, { force: true });
  else await atomicBytes(paths.current, state.current);
  if (state.previous === undefined) await rm(paths.previous, { force: true });
  else await atomicBytes(paths.previous, state.previous);
}

async function makeMutable(root) {
  const info = await lstat(root);
  if (info.isSymbolicLink()) throw new Error("payload contains a symlink");
  if (info.isDirectory()) {
    await chmod(root, 0o755);
    for (const entry of await readdir(root, { withFileTypes: true })) await makeMutable(join(root, entry.name));
  } else if (info.isFile()) {
    await chmod(root, (info.mode & 0o111) !== 0 ? 0o755 : 0o644);
  } else throw new Error("payload contains unsupported entry");
}

async function makeImmutable(root) {
  const info = await lstat(root);
  if (info.isSymbolicLink()) throw new Error("payload contains a symlink");
  if (info.isDirectory()) {
    for (const entry of await readdir(root, { withFileTypes: true })) await makeImmutable(join(root, entry.name));
    await chmod(root, 0o555);
  } else if (info.isFile()) {
    await chmod(root, (info.mode & 0o111) !== 0 ? 0o555 : 0o444);
  } else throw new Error("payload contains unsupported entry");
}

async function withStoreLock(paths, operation) {
  await mkdir(paths.channelRoot, { recursive: true, mode: 0o700 });
  const handle = await open(paths.lock, "a", 0o600);
  await handle.close();
  const release = await lockfile.lock(paths.lock, {
    realpath: false,
    retries: { retries: 100, minTimeout: 25, maxTimeout: 250 },
  });
  try { return await operation(); } finally { await release(); }
}

function selection(value, channel) {
  if (!value || typeof value !== "object" || Array.isArray(value)
    || value.schema !== SCHEMA || value.kind !== SELECTION_KIND || value.channel !== channel
    || !validComponent(value.version, 128) || !fingerprint(value.payloadFingerprint)) {
    throw new Error("selection identity is invalid");
  }
  return value;
}

async function currentSelection(paths) {
  const value = await readOptional(paths.current);
  return value === undefined ? undefined : selection(value, paths.channel);
}

export async function publishSelection(paths, next) {
  selection(next, paths.channel);
  const state = await captureSelectionState(paths);
  const prior = state.current === undefined ? undefined : selection(JSON.parse(state.current), paths.channel);
  try {
    if (prior) await atomicJson(paths.previous, prior);
    await atomicJson(paths.current, next);
  } catch (error) {
    try { await restoreSelectionState(paths, state); } catch (restoreError) {
      error.message += `; selection restoration failed: ${restoreError.message}`;
    }
    throw error;
  }
  return { previous: prior, current: next };
}

export async function rollbackSelection(paths) {
  const state = await captureSelectionState(paths);
  if (state.previous === undefined) throw new Error("no previous Gateway selection is available for rollback");
  const prior = selection(JSON.parse(state.previous), paths.channel);
  const current = state.current === undefined ? undefined : selection(JSON.parse(state.current), paths.channel);
  try {
    if (current) await atomicJson(paths.previous, current);
    await atomicJson(paths.current, prior);
  } catch (error) {
    try { await restoreSelectionState(paths, state); } catch (restoreError) {
      error.message += `; selection restoration failed: ${restoreError.message}`;
    }
    throw error;
  }
  return { previous: current, current: prior };
}

export function deploymentTransition(state, event) {
  const transitions = {
    prepared: { published: "published", failed: "failed" },
    published: { restartRequested: "restart-requested", failed: "failed" },
    "restart-requested": { ready: "ready", failed: "failed" },
    failed: { rollbackRequested: "rollback-requested" },
    "rollback-requested": { rolledBack: "rolled-back", failed: "failed" },
    ready: {},
    "rolled-back": {},
  };
  const next = transitions[state]?.[event];
  if (!next) throw new Error(`invalid deployment transition: ${state} + ${event}`);
  return next;
}

async function writeState(paths, value) {
  await atomicJson(paths.state, { schema: SCHEMA, kind: "tron-gateway-deployment", ...value, updatedAt: new Date().toISOString() });
}

async function writeProgress(paths, state, commandId, error) {
  await atomicJson(paths.progress, {
    schema: SCHEMA, kind: "tron-gateway-update-progress", channel: paths.channel, state,
    commandId, ...(error ? { error: String(error).slice(0, 2_048) } : {}), updatedAt: new Date().toISOString(),
  });
}

function homeForChannel(channel, explicit) {
  if (explicit) return resolve(explicit);
  return join(homedir(), channel === "dev" ? ".tron-dev" : ".tron");
}

function validCommandId(value) {
  return typeof value === "string" && /^[A-Za-z0-9._:-]{8,160}$/u.test(value);
}

export function validateApplyRequest(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Gateway update apply request is malformed");
  const keys = Object.keys(value);
  if (keys.some((key) => !["channel", "mode", "candidateVersion", "commandId"].includes(key))) {
    throw new Error("Gateway update apply request contains an unsupported field");
  }
  const channel = value.channel === undefined ? "stable" : value.channel;
  const mode = value.mode === undefined ? "auto" : value.mode;
  const candidateVersion = value.candidateVersion;
  const commandId = value.commandId;
  if (channel !== "stable" && channel !== "dev") throw new Error("invalid update channel");
  if (mode !== "source" && mode !== "artifact" && mode !== "auto") throw new Error("invalid update mode");
  if (candidateVersion !== undefined && !validComponent(candidateVersion, 128)) throw new Error("invalid candidate version");
  if (!validCommandId(commandId)) throw new Error("invalid update command ID");
  return { channel, mode, ...(candidateVersion === undefined ? {} : { candidateVersion }), commandId };
}

function suffixedCommandId(value, suffix) {
  return `${value.slice(0, 160 - suffix.length)}${suffix}`;
}

function applyArguments() {
  const values = {};
  const names = new Map([
    ["--channel", "channel"], ["--mode", "mode"],
    ["--candidate-version", "candidateVersion"], ["--command-id", "commandId"],
  ]);
  for (let index = 3; index < process.argv.length; index += 1) {
    const raw = process.argv[index];
    const equals = raw.indexOf("=");
    const flag = equals >= 0 ? raw.slice(0, equals) : raw;
    const name = names.get(flag);
    if (!name) throw new Error("apply accepts only channel, mode, candidateVersion, and commandId");
    const value = equals >= 0 ? raw.slice(equals + 1) : process.argv[++index];
    if (value === undefined || value.startsWith("--")) throw new Error(`missing value for ${flag}`);
    values[name] = value;
  }
  return validateApplyRequest({ channel: "stable", mode: "auto", ...values });
}

function argument(name) {
  const equals = process.argv.find((value) => value.startsWith(`${name}=`));
  if (equals) return equals.slice(name.length + 1);
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function args() {
  const command = process.argv[2];
  const channel = argument("--channel") ?? "stable";
  if (!validComponent(channel, 64)) throw new Error("invalid channel");
  const home = homeForChannel(channel, argument("--home"));
  return { command, channel, home, paths: store(home, channel) };
}

async function gitRevision(cwd) {
  try {
    const { execFile } = await import("node:child_process");
    const { promisify } = await import("node:util");
    return (await promisify(execFile)("git", ["rev-parse", "HEAD"], { cwd, encoding: "utf8" })).stdout.trim() || "unknown";
  } catch { return "unknown"; }
}

export function sourceBuildCommands(sourceRoot, compilerOutput = "<private-output>") {
  const gatewayRoot = join(sourceRoot, "packages", "gateway");
  return [
    {
      tool: process.execPath,
      args: [join(gatewayRoot, "node_modules", "typescript", "bin", "tsc"), "-p", join(gatewayRoot, "tsconfig.json"), "--outDir", compilerOutput],
      cwd: gatewayRoot,
    },
    { tool: "npm", args: ["ci", "--omit=dev", "--ignore-scripts=false"], cwd: "<candidate>/app" },
  ];
}

async function verifiedSourceCompilerOutput(root) {
  const info = await lstat(root);
  if (!info.isDirectory() || info.isSymbolicLink()) throw new Error("source compiler output is not a regular directory");
  await regularFiles(root, "");
  if (!(await regular(join(root, "index.js"), 1_024))) throw new Error("source compiler output is incomplete");
  return root;
}

function runBounded(tool, args, options = {}) {
  const timeoutMs = options.timeoutMs ?? 120_000;
  const maxOutputBytes = options.maxOutputBytes ?? 128 * 1_024;
  return new Promise((resolvePromise, rejectPromise) => {
    let output = "";
    let settled = false;
    const child = spawn(tool, args, { cwd: options.cwd, shell: false, stdio: ["ignore", "pipe", "pipe"], windowsHide: true });
    const finish = (error, result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) rejectPromise(error); else resolvePromise(result);
    };
    const collect = (chunk) => {
      output += chunk.toString();
      if (Buffer.byteLength(output) > maxOutputBytes) finish(new Error("Gateway source build output exceeded the limit"));
    };
    child.stdout.on("data", collect);
    child.stderr.on("data", collect);
    child.once("error", (error) => finish(error));
    child.once("exit", (code, signal) => {
      if (code === 0) finish(undefined, { code, signal, output });
      else finish(new Error(`Gateway source build failed (${signal ?? `exit ${code}`}): ${output.slice(-2_048)}`));
    });
    const timer = setTimeout(() => { child.kill("SIGTERM"); finish(new Error("Gateway source build timed out")); }, timeoutMs);
    timer.unref?.();
  });
}

export async function stagePayload({ home, channel, source, version, sourceRevision }) {
  const paths = store(home, channel);
  const sourceRoot = resolve(source);
  const sourceManifest = await validatePayload(sourceRoot, {}, true);
  const targetVersion = version ?? sourceManifest.version;
  if (!validComponent(targetVersion, 128)) throw new Error("invalid payload version");
  const target = join(paths.versionsRoot, targetVersion);
  await mkdir(paths.versionsRoot, { recursive: true, mode: 0o700 });
  return withStoreLock(paths, async () => {
    const markCandidate = async (result) => {
      await writeState(paths, {
        state: "prepared", channel, version: result.manifest.version,
        payloadFingerprint: result.manifest.payloadFingerprint,
        sourceRevision: result.manifest.sourceRevision, runtimeEpoch: result.manifest.runtimeEpoch,
        candidateIdentity: {
          version: result.manifest.version, gatewayVersion: result.manifest.gatewayVersion,
          sourceRevision: result.manifest.sourceRevision, runtimeEpoch: result.manifest.runtimeEpoch,
          payloadFingerprint: result.manifest.payloadFingerprint,
        },
      });
      return result;
    };
    try {
      await access(target);
      const existing = await validatePayload(target, { channel, version: targetVersion }, true);
      if (existing.payloadFingerprint === sourceManifest.payloadFingerprint) return markCandidate({ root: target, manifest: existing, reused: true });
      throw new Error(`version ${targetVersion} already exists with a different payload`);
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    const temporary = join(paths.versionsRoot, `.staging-${targetVersion}-${process.pid}-${randomUUID()}`);
    await rm(temporary, { recursive: true, force: true });
    await cp(sourceRoot, temporary, { recursive: true, errorOnExist: true, force: false });
    await makeMutable(temporary);
    const stagedFingerprint = await payloadFingerprint(temporary);
    if (stagedFingerprint !== sourceManifest.payloadFingerprint) throw new Error("staged payload fingerprint changed during copy");
    const manifest = {
      ...sourceManifest,
      channel,
      version: targetVersion,
      sourceRevision: sourceRevision ?? sourceManifest.sourceRevision ?? await gitRevision(),
      runtimeEpoch: randomUUID(),
      payloadFingerprint: stagedFingerprint,
    };
    payloadManifest(manifest, { channel, version: targetVersion });
    await atomicJson(join(temporary, "manifest.json"), manifest);
    await validatePayload(temporary, { channel, version: targetVersion, payloadFingerprint: stagedFingerprint }, true);
    await makeImmutable(temporary);
    try { await rename(temporary, target); } catch (error) {
      await rm(temporary, { recursive: true, force: true });
      throw error;
    }
    return markCandidate({ root: target, manifest, reused: false });
  });
}

async function requestRestart({ host, port, token, timeoutMs, commandId }) {
  const ws = new WebSocket(`ws://${host.includes(":") ? `[${host}]` : host}:${port}/v1/socket`, {
    headers: { authorization: `Bearer ${token}` }, perMessageDeflate: false,
  });
  const response = await new Promise((resolveResponse, reject) => {
    const timer = setTimeout(() => { ws.terminate(); reject(new Error("gateway restart request timed out")); }, timeoutMs);
    ws.once("error", (error) => { clearTimeout(timer); reject(error); });
    const requestId = randomUUID();
    ws.once("open", () => ws.send(JSON.stringify({ type: "hello", protocolVersion: PROTOCOL_VERSION, clientId: randomUUID() })));
    ws.on("message", (raw) => {
      let frame;
      try { frame = JSON.parse(raw.toString()); } catch { return; }
      if (frame.type === "hello") {
        if (!protocolHandshakeCompatible(frame)) {
          clearTimeout(timer);
          ws.terminate();
          reject(new Error("Gateway protocol handshake is not compatible"));
          return;
        }
        ws.send(JSON.stringify({ type: "request", id: requestId, method: "gateway.restart", params: { commandId } }));
        return;
      }
      if (frame.type !== "response" || frame.id !== requestId) return;
      clearTimeout(timer);
      if (frame.ok === true) resolveResponse(frame.result ?? null);
      else reject(new Error(frame.error?.message ?? "authenticated gateway.restart failed"));
      ws.close();
    });
  });
  return response;
}

async function health(host, port, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(`http://${host.includes(":") ? `[${host}]` : host}:${port}/health`, { signal: controller.signal });
    if (!response.ok) throw new Error(`Gateway health returned HTTP ${response.status}`);
    const value = await response.json();
    if (!value || value.status !== "ok" || typeof value.runtimeEpoch !== "string"
      || typeof value.buildFingerprint !== "string" || typeof value.sourceRevision !== "string") {
      throw new Error("Gateway health identity is incomplete");
    }
    return value;
  } finally { clearTimeout(timer); }
}

async function waitHealth(options, expected, oldEpoch) {
  const deadline = Date.now() + options.timeoutMs;
  let last;
  while (Date.now() < deadline) {
    try {
      const value = await health(options.host, options.port, Math.min(2_000, options.timeoutMs));
      last = value;
      if (value.buildFingerprint === expected.payloadFingerprint && value.sourceRevision === expected.sourceRevision
        && value.runtimeEpoch !== oldEpoch) return value;
    } catch { /* restart window */ }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 500));
  }
  throw new Error(`Gateway did not become ready with the expected payload identity${last ? ` (observed ${JSON.stringify(last)})` : ""}`);
}

async function promote({ paths, channel, version, expectedFingerprint, host, port, token, timeoutMs, commandId }) {
  return withStoreLock(paths, async () => {
    const targetRoot = join(paths.versionsRoot, version);
    const manifest = await validatePayload(targetRoot, { channel, version }, true);
    if (expectedFingerprint && expectedFingerprint !== manifest.payloadFingerprint) throw new Error("requested fingerprint does not match staged manifest");
    const priorState = await captureSelectionState(paths);
    const prior = priorState.current === undefined ? undefined : selection(JSON.parse(priorState.current), channel);
    let priorManifest;
    if (prior) {
      priorManifest = await validatePayload(join(paths.versionsRoot, prior.version), {
        channel, version: prior.version, payloadFingerprint: prior.payloadFingerprint,
      }, true);
    }
    const before = await health(host, port, timeoutMs);
    const target = { schema: SCHEMA, kind: SELECTION_KIND, channel, version, payloadFingerprint: manifest.payloadFingerprint };
    const stateBase = {
      channel, version, payloadFingerprint: manifest.payloadFingerprint, sourceRevision: manifest.sourceRevision,
      runtimeEpoch: manifest.runtimeEpoch, commandId: commandId ?? `gateway-payload-${randomUUID()}`,
      previousSelection: prior,
      candidateIdentity: {
        version: manifest.version, gatewayVersion: manifest.gatewayVersion,
        sourceRevision: manifest.sourceRevision, runtimeEpoch: manifest.runtimeEpoch,
        payloadFingerprint: manifest.payloadFingerprint,
      },
    };
    await writeState(paths, { ...stateBase, state: "prepared" });
    const unchanged = prior?.version === version && prior.payloadFingerprint === manifest.payloadFingerprint;
    if (before.buildFingerprint === manifest.payloadFingerprint && before.sourceRevision === manifest.sourceRevision) {
      if (!unchanged) {
        try {
          await publishSelection(paths, target);
          await writeState(paths, { ...stateBase, state: "ready" });
        } catch (error) {
          try { await restoreSelectionState(paths, priorState); } catch (restoreError) {
            error.message += `; selection restoration failed: ${restoreError.message}`;
          }
          throw error;
        }
      } else {
        await writeState(paths, { ...stateBase, state: "ready" });
      }
      return { state: "ready", manifest, health: before, unchanged };
    }

    let published = false;
    try {
      await publishSelection(paths, target);
      published = true;
      await writeState(paths, { ...stateBase, state: deploymentTransition("prepared", "published") });
      await requestRestart({ host, port, token, timeoutMs, commandId: stateBase.commandId });
      await writeState(paths, { ...stateBase, state: deploymentTransition("published", "restartRequested") });
      const ready = await waitHealth({ host, port, timeoutMs }, manifest, before.runtimeEpoch);
      await writeState(paths, { ...stateBase, state: "ready" });
      return { state: "ready", manifest, health: ready };
    } catch (error) {
      if (published) {
        try {
          await restoreSelectionState(paths, priorState);
          await writeState(paths, { ...stateBase, state: deploymentTransition("published", "failed"), error: String(error?.message ?? error) });
          await requestRestart({ host, port, token, timeoutMs, commandId: suffixedCommandId(stateBase.commandId, "-rollback") });
          const recoveryTarget = priorManifest ?? {
            payloadFingerprint: before.buildFingerprint, sourceRevision: before.sourceRevision,
          };
          await waitHealth({ host, port, timeoutMs }, recoveryTarget, before.runtimeEpoch);
          await writeState(paths, { ...stateBase, state: deploymentTransition("failed", "rollbackRequested") });
          await writeState(paths, { ...stateBase, state: deploymentTransition("rollback-requested", "rolledBack") });
        } catch (recoveryError) {
          try { await restoreSelectionState(paths, priorState); } catch { /* best effort, keep original error */ }
          error.message += `; deployment recovery failed: ${recoveryError.message}`;
        }
      }
      throw error;
    }
  });
}

async function stagedCandidate(paths, requestedVersion) {
  let candidate = requestedVersion;
  if (candidate === undefined) {
    const stateValue = await readOptional(paths.state);
    if (!stateValue || typeof stateValue !== "object" || Array.isArray(stateValue)) return undefined;
    const raw = stateValue;
    candidate = raw.candidateIdentity && typeof raw.candidateIdentity === "object"
      ? raw.candidateIdentity.version : raw.candidateVersion;
  }
  if (!validComponent(candidate, 128)) return undefined;
  try {
    await validatePayload(join(paths.versionsRoot, candidate), { channel: paths.channel, version: candidate }, true);
    return candidate;
  } catch { return undefined; }
}

async function currentPayload(paths) {
  try {
    const selected = await currentSelection(paths);
    if (selected) {
      const root = join(paths.versionsRoot, selected.version);
      const manifest = await validatePayload(root, {
        channel: paths.channel, version: selected.version, payloadFingerprint: selected.payloadFingerprint,
      }, true);
      return { root, manifest };
    }
  } catch { /* fall through to the validated bundled payload */ }
  const bundledCandidates = [
    resolve(scriptDirectory, "..", ".."),
    resolve(scriptDirectory, "../packages/mac-app/Sources/Resources/Gateway"),
  ];
  for (const bundledRoot of bundledCandidates) {
    try {
      const manifest = await validatePayload(bundledRoot, {}, true);
      return { root: bundledRoot, manifest };
    } catch { /* Try the next known bundled-payload location. */ }
  }
  throw new Error("source update requires an active or bundled validated Gateway payload");
}

async function stageConfiguredArtifact(paths, config, requestedVersion) {
  if (!config.artifactRoot) return undefined;
  const sourceManifest = await validatePayload(config.artifactRoot, {}, true);
  const version = requestedVersion ?? sourceManifest.version;
  const result = await stagePayload({
    home: paths.home, channel: paths.channel, source: config.artifactRoot, version,
    sourceRevision: sourceManifest.sourceRevision,
  });
  return result.manifest.version;
}

export async function buildSourcePayload({ paths, config, candidateVersion, timeoutMs = 120_000, runCommand = runBounded }) {
  const active = await currentPayload(paths);
  const gatewayRoot = join(config.sourceRoot, "packages", "gateway");
  // Compile into a private temporary directory. In particular, never invoke
  // the package build script here: its configured outDir is the trusted source
  // tree's packages/gateway/dist, which must remain byte-for-byte unchanged.
  const compilerOutput = await mkdtemp(join(tmpdir(), "tron-gateway-source-build-"));
  try {
    await runCommand(process.execPath, [
      join(gatewayRoot, "node_modules", "typescript", "bin", "tsc"),
      "-p", join(gatewayRoot, "tsconfig.json"), "--outDir", compilerOutput,
    ], { cwd: gatewayRoot, timeoutMs });
    const sourcePackage = JSON.parse(await readFile(join(gatewayRoot, "package.json"), "utf8"));
    const version = candidateVersion ?? `${sourcePackage.version}-source-${Date.now()}`;
    if (!validComponent(version, 128)) throw new Error("source build produced an invalid candidate version");
    const target = join(paths.versionsRoot, version);
    const temporary = join(paths.versionsRoot, `.source-staging-${version}-${process.pid}-${randomUUID()}`);
    await rm(temporary, { recursive: true, force: true });
    try {
      await mkdir(paths.versionsRoot, { recursive: true, mode: 0o700 });
      await cp(active.root, temporary, { recursive: true, errorOnExist: true, force: false });
      await makeMutable(temporary);
      await rm(join(temporary, "app", "dist"), { recursive: true, force: true });
      await verifiedSourceCompilerOutput(compilerOutput);
      await cp(compilerOutput, join(temporary, "app", "dist"), { recursive: true, errorOnExist: true, force: false });
      await cp(join(gatewayRoot, "package.json"), join(temporary, "app", "package.json"));
      await cp(join(gatewayRoot, "package-lock.json"), join(temporary, "app", "package-lock.json"));
      await rm(join(temporary, "app", "node_modules"), { recursive: true, force: true });
      await runCommand("npm", ["ci", "--omit=dev", "--ignore-scripts=false"], {
        cwd: join(temporary, "app"), timeoutMs,
      });
      const fingerprint = await payloadFingerprint(temporary);
      const manifest = {
        ...active.manifest,
        schema: SCHEMA, kind: KIND, channel: paths.channel, version,
        gatewayVersion: sourcePackage.version, sourceRevision: await gitRevision(config.sourceRoot),
        runtimeEpoch: randomUUID(), payloadFingerprint: fingerprint,
      };
      payloadManifest(manifest, { channel: paths.channel, version });
      await atomicJson(join(temporary, "manifest.json"), manifest);
      await validatePayload(temporary, { channel: paths.channel, version, payloadFingerprint: fingerprint }, true);
      await makeImmutable(temporary);
      try { await rename(temporary, target); } catch (error) {
        if (error?.code === "EEXIST") throw new Error(`version ${version} already exists`);
        throw error;
      }
      await writeState(paths, {
        state: "prepared", channel: paths.channel, version, payloadFingerprint: fingerprint,
        sourceRevision: manifest.sourceRevision, runtimeEpoch: manifest.runtimeEpoch,
        candidateIdentity: {
          version, gatewayVersion: manifest.gatewayVersion, sourceRevision: manifest.sourceRevision,
          runtimeEpoch: manifest.runtimeEpoch, payloadFingerprint: fingerprint,
        },
      });
      return { root: target, manifest };
    } catch (error) {
      await rm(temporary, { recursive: true, force: true });
      throw error;
    }
  } finally {
    await rm(compilerOutput, { recursive: true, force: true });
  }
}

/**
 * LaunchAgent-only update entrypoint. It deliberately has no source/path,
 * executable, host, or port arguments. Source and artifact roots are read only
 * from the validated home projection; request parameters select policy only.
 */
export async function applyPayload(request) {
  const value = validateApplyRequest(request);
  const home = homeForChannel(value.channel, process.env.TRON_DATA_DIR);
  const paths = store(home, value.channel);
  let version = value.mode === "source" ? undefined : await stagedCandidate(paths, value.candidateVersion);
  let selectedMode = "artifact";
  const config = version === undefined || value.mode === "source" ? await readUpdateConfig(paths) : undefined;
  if (!version && value.mode !== "source") {
    try {
      version = await stageConfiguredArtifact(paths, config, value.candidateVersion);
    } catch (error) {
      if (value.mode !== "auto") throw error;
    }
  }
  if (!version && value.mode !== "artifact") {
    selectedMode = "source";
    await writeProgress(paths, "building", value.commandId);
    let built;
    try {
      built = await buildSourcePayload({ paths, config, candidateVersion: value.candidateVersion });
    } catch (error) {
      await writeProgress(paths, "failure", value.commandId, error?.message ?? error).catch(() => {});
      throw error;
    }
    await writeProgress(paths, "staging", value.commandId);
    version = built.manifest.version;
    version = built.manifest.version;
  }
  if (!version) throw new Error("artifact update requires an available staged candidate version");
  const requestedHost = process.env.TRON_GATEWAY_HEALTH_HOST ?? process.env.TRON_GATEWAY_HOST ?? "tailscale";
  const host = resolveDeploymentHost(requestedHost);
  const port = Number(process.env.TRON_GATEWAY_PORT ?? (value.channel === "dev" ? "9848" : "9847"));
  if (!Number.isSafeInteger(port) || port < 1 || port > 65_535) throw new Error("invalid Gateway port");
  const timeoutMs = Number(process.env.TRON_GATEWAY_UPDATE_TIMEOUT_MS ?? "60_000");
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 2_000 || timeoutMs > 300_000) throw new Error("invalid update timeout");
  const token = await readLocalCredential(join(home, "gateway", "local-auth.json"));
  await writeProgress(paths, "promoting", value.commandId);
  let result;
  try {
    result = await promote({
      paths, channel: value.channel, version, host, port, token, timeoutMs,
      commandId: value.commandId,
    });
  } catch (error) {
    await writeProgress(paths, "rollback", value.commandId, error?.message ?? error).catch(() => {});
    throw error;
  }
  await writeProgress(paths, result.state, value.commandId);
  return { accepted: true, channel: value.channel, mode: selectedMode === "source" ? "source" : value.mode, commandId: value.commandId, state: result.state, version };
}

export async function loadRollbackTarget(paths) {
  const priorState = await captureSelectionState(paths);
  if (priorState.previous === undefined) throw new Error("no previous Gateway selection is available for rollback");
  // Validate the prior manifest before changing either pointer. A missing or
  // corrupt target must never make current.json point at an unusable version.
  const priorSelection = selection(JSON.parse(priorState.previous), paths.channel);
  const manifest = await validatePayload(join(paths.versionsRoot, priorSelection.version), {
    channel: paths.channel, version: priorSelection.version, payloadFingerprint: priorSelection.payloadFingerprint,
  }, true);
  return { priorState, priorSelection, manifest };
}

async function rollback({ paths, host, port, token, timeoutMs, commandId }) {
  return withStoreLock(paths, async () => {
    const { priorState, manifest: target } = await loadRollbackTarget(paths);
    const before = await health(host, port, timeoutMs);
    let switched = false;
    const restartCommandId = commandId ?? `gateway-payload-rollback-${randomUUID()}`;
    try {
      await rollbackSelection(paths);
      switched = true;
      await requestRestart({ host, port, token, timeoutMs, commandId: restartCommandId });
      const ready = await waitHealth({ host, port, timeoutMs }, target, before.runtimeEpoch);
      await writeState(paths, {
        state: "rolled-back", channel: paths.channel, version: target.version,
        payloadFingerprint: target.payloadFingerprint, sourceRevision: target.sourceRevision, runtimeEpoch: target.runtimeEpoch,
        commandId: restartCommandId,
      });
      return { state: "rolled-back", manifest: target, health: ready };
    } catch (error) {
      if (switched) {
        try { await restoreSelectionState(paths, priorState); } catch (restoreError) {
          error.message += `; rollback selection restoration failed: ${restoreError.message}`;
        }
      }
      throw error;
    }
  });
}

async function main() {
  const { command, channel, home, paths } = args();
  if (command === "apply") {
    const request = applyArguments();
    const result = await applyPayload(request);
    console.log(JSON.stringify({ command, channel: request.channel, home: homeForChannel(request.channel, process.env.TRON_DATA_DIR), ...result }));
    return;
  }
  if (command === "stage") {
    const source = argument("--source") ?? resolve(dirname(fileURLToPath(import.meta.url)), "../packages/mac-app/Sources/Resources/Gateway");
    const result = await stagePayload({ home, channel, source, version: argument("--version"), sourceRevision: argument("--source-revision") });
    console.log(JSON.stringify({ command, channel, home, ...result }));
    return;
  }
  const requestedHost = argument("--host") ?? process.env.TRON_GATEWAY_HEALTH_HOST ?? process.env.TRON_GATEWAY_HOST ?? "tailscale";
  const host = resolveDeploymentHost(requestedHost);
  const port = Number(argument("--port") ?? process.env.TRON_GATEWAY_PORT ?? (channel === "dev" ? "9848" : "9847"));
  if (!Number.isSafeInteger(port) || port < 1 || port > 65_535) throw new Error("invalid Gateway port");
  const timeoutMs = Number(argument("--timeout-ms") ?? "60_000");
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 2_000 || timeoutMs > 300_000) throw new Error("invalid timeout");
  const tokenPath = join(home, "gateway", "local-auth.json");
  const token = await readLocalCredential(tokenPath);
  const callerCommandId = argument("--command-id");
  if (callerCommandId !== undefined && !validCommandId(callerCommandId)) throw new Error("--command-id must contain 8–160 safe characters");
  const options = { paths, channel, host, port, token, timeoutMs };
  let result;
  if (command === "promote") {
    const version = argument("--version");
    if (!version || !validComponent(version, 128)) throw new Error("promote requires a valid --version");
    result = await promote({ ...options, version, expectedFingerprint: argument("--fingerprint"), commandId: callerCommandId });
  } else if (command === "rollback") {
    result = await rollback({ ...options, commandId: callerCommandId });
  } else {
    throw new Error("usage: gateway-payload-deploy.mjs stage|promote|rollback [options]");
  }
  console.log(JSON.stringify({ command, channel, home, ...result }));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch((error) => { console.error(`Gateway payload deployment failed: ${error.message}`); process.exitCode = 1; });
}
