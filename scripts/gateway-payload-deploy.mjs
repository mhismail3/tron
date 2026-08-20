#!/usr/bin/env node
/**
 * Agent-manageable Gateway payload staging and promotion.  This command owns
 * only the bounded payload projection; the LaunchAgent remains the process
 * supervisor and canonical Gateway state is never modified.
 */
import { createHash, randomUUID } from "node:crypto";
import { constants as fsConstants } from "node:fs";
import { createRequire } from "node:module";
import { existsSync, lstatSync, readdirSync, realpathSync, statSync } from "node:fs";
import { spawn } from "node:child_process";
import { homedir, networkInterfaces, tmpdir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  access,
  chmod,
  cp,
  lstat,
  readlink,
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
const MAX_RETAINED_VERSIONS = 8;
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

async function validatePayloadSymlink(root, path, relativePath) {
  if (/[\u0000-\u001f\u007f]/u.test(relativePath)) throw new Error(`payload path contains control bytes: ${relativePath}`);
  const targetText = await readlink(path);
  if (!targetText || /[\u0000-\u001f\u007f]/u.test(targetText)) throw new Error(`payload symlink target contains control bytes: ${relativePath}`);
  const target = await realpath(path).catch(() => { throw new Error(`payload contains a dangling symlink: ${relativePath}`); });
  if (!under(root, target)) throw new Error(`payload symlink escapes root: ${relativePath}`);
  const targetInfo = await stat(target);
  if (!targetInfo.isFile() && !targetInfo.isDirectory()) throw new Error(`payload symlink targets a special entry: ${relativePath}`);
  return readlink(path);
}

async function completePayload(root) {
  const requested = resolve(root);
  if ((await lstat(requested)).isSymbolicLink()) throw new Error("payload root must not be a symlink");
  const resolved = await realpath(requested);
  const rootInfo = await stat(resolved);
  if (!rootInfo.isDirectory()) throw new Error("payload root is not a directory");
  for (const directory of ["app", "runtime"]) {
    const directoryInfo = await lstat(join(resolved, directory));
    if (!directoryInfo.isDirectory() || directoryInfo.isSymbolicLink()) throw new Error(`payload root is not a regular directory: ${directory}`);
  }
  for (const [path, minimum, directory] of REQUIREMENTS) {
    const candidate = join(resolved, path);
    if (!under(resolved, candidate)) throw new Error(`payload path escapes root: ${path}`);
    const linkInfo = await lstat(candidate);
    if (linkInfo.isSymbolicLink()) throw new Error(`payload required entry is not regular: ${path}`);
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
  const payloadRoot = await realpath(root);
  async function visit(directory, relativePath) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const entryRelative = relativePath ? join(relativePath, entry.name) : entry.name;
      if (/[\u0000-\u001f\u007f]/u.test(entry.name)) throw new Error(`payload path contains control bytes: ${entryRelative}`);
      const path = join(directory, entry.name);
      if (entry.isDirectory()) await visit(path, entryRelative);
      else if (entry.isFile()) output.push({ path: entryRelative, target: undefined });
      else if (entry.isSymbolicLink()) {
        const target = await validatePayloadSymlink(payloadRoot, path, entryRelative);
        output.push({ path: entryRelative, target });
      } else throw new Error(`payload contains unsupported entry: ${entryRelative}`);
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
  ].sort((a, b) => Buffer.from(a.path).compare(Buffer.from(b.path)));
  const lines = [];
  for (const entry of files) {
    if (entry.target !== undefined) {
      const digest = createHash("sha256").update(`${entry.target}\n`).digest("hex");
      lines.push(`symlink:${digest}  ${entry.path}\n`);
    } else {
      const digest = createHash("sha256").update(await readFile(join(root, entry.path))).digest("hex");
      lines.push(`${digest}  ${entry.path}\n`);
    }
  }
  return createHash("sha256").update(lines.join("")).digest("hex");
}

async function json(path, maximum = MAX_MANIFEST_BYTES) {
  const info = await lstat(path);
  if (!info.isFile() || info.isSymbolicLink()) throw new Error(`${path} is not a regular file`);
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
  // lstat followed by readFile leaves a replacement race. Keep the descriptor
  // open while checking ownership/mode and reading the bounded bytes.
  const handle = await open(path, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW).catch(() => { throw new Error("local Gateway credential is missing or unsafe"); });
  try {
    const info = await handle.stat();
    if (!info.isFile() || info.size <= 0 || info.size > LOCAL_CREDENTIAL_MAX_BYTES
      || (info.mode & 0o077) !== 0) throw new Error("local Gateway credential is missing or unsafe");
    const chunks = [];
    let remaining = info.size;
    while (remaining > 0) {
      const chunk = Buffer.alloc(Math.min(16 * 1024, remaining));
      const result = await handle.read(chunk, 0, chunk.length, null);
      if (result.bytesRead <= 0) throw new Error("local Gateway credential is truncated");
      chunks.push(chunk.subarray(0, result.bytesRead));
      remaining -= result.bytesRead;
    }
    const document = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    if (!validateLocalCredentialDocument(document)) throw new Error("local Gateway credential has an invalid shape");
    return document.bearerToken;
  } catch (error) {
    if (error instanceof SyntaxError) throw new Error("local Gateway credential has an invalid shape");
    throw error;
  } finally { await handle.close(); }
}

function payloadManifest(value, expected = {}) {
  const safeIdentity = (item, maximum = 256) => typeof item === "string" && item.length > 0
    && Buffer.byteLength(item) <= maximum && !/[\u0000-\u001f\u007f]/u.test(item);
  if (!value || typeof value !== "object" || Array.isArray(value)
    || value.schema !== SCHEMA || value.kind !== KIND
    || !validComponent(value.channel, 64) || !validComponent(value.version, 128)
    || !safeIdentity(value.gatewayVersion) || !safeIdentity(value.nodeVersion)
    || !safeIdentity(value.sourceRevision) || !validComponent(value.runtimeEpoch, 128) || !fingerprint(value.payloadFingerprint)) {
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
    pending: join(channelRoot, "pending-attempt.json"),
    config: join(home, "gateway", "update-config.json"),
    lock: join(channelRoot, ".update.lock"),
    // Apply operations hold this distinct lock for their full lifetime. Stage
    // and promote still take the channel lock internally, so an apply can
    // compose them without recursively acquiring the same lock.
    applyLock: join(channelRoot, ".apply.lock"),
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
  const sourceRoot = await noSymlinkDirectory(value.sourceRoot, [
    "packages/gateway/package.json", "packages/gateway/package-lock.json",
    "packages/gateway/scripts/ensure-node-pty-helper.mjs", "scripts/gateway-payload-deploy.mjs",
  ]);
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

async function writePendingAttempt(paths, candidate, previous) {
  if (!previous) return;
  selection(previous, paths.channel);
  await atomicJson(paths.pending ?? join(paths.channelRoot, "pending-attempt.json"), {
    schema: SCHEMA, kind: "tron-gateway-pending-attempt", channel: paths.channel,
    attempt: "pending",
    version: candidate.version, payloadFingerprint: candidate.payloadFingerprint,
    previousVersion: previous.version, previousFingerprint: previous.payloadFingerprint,
  });
}

async function clearPendingAttempt(paths, identity) {
  const pending = paths.pending ?? join(paths.channelRoot, "pending-attempt.json");
  const value = await readOptional(pending);
  if (!value) return;
  if (value.schema !== SCHEMA || value.kind !== "tron-gateway-pending-attempt"
    || value.channel !== paths.channel || value.version !== identity.version
    || value.payloadFingerprint !== identity.payloadFingerprint) return;
  await rm(pending, { force: true });
}

async function captureSelectionState(paths) {
  const read = async (path) => {
    try {
      const info = await lstat(path);
      if (!info.isFile() || info.isSymbolicLink()) throw new Error(`selection pointer is not a regular file: ${path}`);
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
  const payloadRoot = await realpath(root);
  const visit = async (path) => {
    const info = await lstat(path);
    if (info.isSymbolicLink()) {
      await validatePayloadSymlink(payloadRoot, path, relative(payloadRoot, path));
      return;
    }
    if (info.isDirectory()) {
      await chmod(path, 0o755);
      for (const entry of await readdir(path, { withFileTypes: true })) await visit(join(path, entry.name));
    } else if (info.isFile()) {
      await chmod(path, (info.mode & 0o111) !== 0 ? 0o755 : 0o644);
    } else throw new Error("payload contains unsupported entry");
  };
  const rootInfo = await lstat(root);
  if (rootInfo.isSymbolicLink()) throw new Error("payload root must not be a symlink");
  await visit(root);
}

async function makeImmutable(root) {
  const payloadRoot = await realpath(root);
  const visit = async (path) => {
    const info = await lstat(path);
    if (info.isSymbolicLink()) {
      await validatePayloadSymlink(payloadRoot, path, relative(payloadRoot, path));
      return;
    }
    if (info.isDirectory()) {
      for (const entry of await readdir(path, { withFileTypes: true })) await visit(join(path, entry.name));
      await chmod(path, 0o555);
    } else if (info.isFile()) {
      await chmod(path, (info.mode & 0o111) !== 0 ? 0o555 : 0o444);
    } else throw new Error("payload contains unsupported entry");
  };
  const rootInfo = await lstat(root);
  if (rootInfo.isSymbolicLink()) throw new Error("payload root must not be a symlink");
  await visit(root);
}

async function assertStoreRoots(paths) {
  // Never let mkdir/read/lock follow an attacker-created projection link. The
  // updater is not a sandbox, but its owned roots must not silently redirect
  // selection or payload writes outside the selected home.
  const home = paths.home ?? resolve(paths.channelRoot, "../../..");
  const roots = [join(home, "gateway"), join(home, "gateway", "payloads"), paths.channelRoot, paths.versionsRoot];
  for (const root of roots) {
    const components = resolve(root).split("/").filter(Boolean);
    let cursor = "/";
    for (const component of components) {
      cursor = join(cursor, component);
      const info = await lstat(cursor).catch(() => undefined);
      const uid = process.getuid?.();
      const ownedRoot = cursor === resolve(home) || cursor.startsWith(`${resolve(home)}/`);
      if (info?.isSymbolicLink() && ownedRoot) throw new Error(`Gateway payload store contains a symlinked root: ${cursor}`);
      if (info && ownedRoot && !info.isDirectory()) throw new Error(`Gateway payload store root is not a directory: ${cursor}`);
      if (info && ownedRoot && uid !== undefined && info.uid !== uid) throw new Error(`Gateway payload store root is not owned by the updater: ${cursor}`);
    }
  }
}

async function withStoreLock(paths, operation) {
  await assertStoreRoots(paths);
  await mkdir(paths.channelRoot, { recursive: true, mode: 0o700 });
  await assertStoreRoots(paths);
  const handle = await open(paths.lock, "a", 0o600);
  await handle.close();
  const release = await lockfile.lock(paths.lock, {
    realpath: false,
    retries: { retries: 100, minTimeout: 25, maxTimeout: 250 },
  });
  try { return await operation(); } finally { await release(); }
}

async function withApplyLock(paths, operation) {
  // This lock is intentionally separate from the channel publication lock:
  // apply composes stage/build/promote, each of which takes withStoreLock.
  await assertStoreRoots(paths);
  await mkdir(paths.channelRoot, { recursive: true, mode: 0o700 });
  await assertStoreRoots(paths);
  const handle = await open(paths.applyLock, "a", 0o600);
  await handle.close();
  const release = await lockfile.lock(paths.applyLock, {
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
    const same = prior && prior.version === next.version && prior.payloadFingerprint === next.payloadFingerprint;
    if (prior && !same) await atomicJson(paths.previous, prior);
    else if (!prior) await rm(paths.previous, { force: true });
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
  await assertStoreRoots(paths);
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

export function sourceBuildCommands(sourceRoot, compilerOutput = "<private-output>", npmCommand = { tool: "npm", script: undefined }) {
  const gatewayRoot = join(sourceRoot, "packages", "gateway");
  const npm = npmCommand.script ? { tool: npmCommand.tool, args: [npmCommand.script, "ci", "--omit=dev", "--ignore-scripts=false"] } : { tool: npmCommand.tool, args: ["ci", "--omit=dev", "--ignore-scripts=false"] };
  return [
    {
      tool: process.execPath,
      args: [join(gatewayRoot, "node_modules", "typescript", "bin", "tsc"), "-p", join(gatewayRoot, "tsconfig.json"), "--outDir", compilerOutput],
      cwd: gatewayRoot,
    },
    { ...npm, cwd: "<candidate>/app" },
  ];
}

/** Resolve npm without trusting launchd's usually-minimal PATH. The returned
 * command always invokes npm's JS CLI through this exact Node runtime. */
export function resolveNpmCommand(environment = process.env) {
  const candidates = [];
  const configured = environment.TRON_NPM_BIN;
  if (configured) candidates.push(configured);
  if (environment.PATH) candidates.push(...environment.PATH.split(":").filter((value) => value.startsWith("/")).map((value) => join(value, "npm")));
  const home = environment.HOME ?? homedir();
  for (const root of [join(environment.NVM_DIR ?? join(home, ".nvm"), "versions", "node"), "/opt/homebrew/bin", "/usr/local/bin"]) {
    if (root.endsWith("/node")) {
      try { candidates.push(...readdirSync(root).map((version) => join(root, version, "bin", "npm"))); } catch { /* unavailable */ }
    } else candidates.push(join(root, "npm"));
  }
  for (const candidate of candidates) {
    if (!candidate.startsWith("/") || /[\u0000-\u001f\u007f]/u.test(candidate)) continue;
    let resolvedCandidate;
    try {
      resolvedCandidate = realpathSync(candidate);
      const candidateInfo = lstatSync(resolvedCandidate);
      if (!candidateInfo.isFile() || (candidateInfo.mode & 0o111) === 0) continue;
    } catch { continue; }
    const prefix = dirname(dirname(candidate));
    const script = join(prefix, "lib", "node_modules", "npm", "bin", "npm-cli.js");
    try {
      const scriptInfo = lstatSync(script);
      if (scriptInfo.isFile() && !scriptInfo.isSymbolicLink()) return { tool: process.execPath, script, bin: candidate };
    } catch { /* next candidate */ }
  }
  throw new Error("npm is unavailable under the sanitized launchd PATH; configure TRON_NPM_BIN or install npm with Node");
}

async function copyTrustedSourceScripts(sourceRoot, candidateRoot) {
  const files = [
    [join(sourceRoot, "scripts", "gateway-payload-deploy.mjs"), join(candidateRoot, "app", "scripts", "gateway-payload-deploy.mjs")],
    [join(sourceRoot, "packages", "gateway", "scripts", "ensure-node-pty-helper.mjs"), join(candidateRoot, "app", "scripts", "ensure-node-pty-helper.mjs")],
  ];
  for (const [source, destination] of files) {
    const info = await lstat(source).catch(() => undefined);
    if (!info?.isFile() || info.isSymbolicLink()) throw new Error(`trusted source script is missing or unsafe: ${source}`);
    await cp(source, destination, { force: true, errorOnExist: false });
    const copied = await lstat(destination);
    if (!copied.isFile() || copied.isSymbolicLink()) throw new Error(`trusted source script copy is unsafe: ${destination}`);
  }
}

async function verifiedSourceCompilerOutput(root) {
  const info = await lstat(root);
  if (!info.isDirectory() || info.isSymbolicLink()) throw new Error("source compiler output is not a regular directory");
  await regularFiles(root, "");
  if (!(await regular(join(root, "index.js"), 1_024))) throw new Error("source compiler output is incomplete");
  return root;
}

export function runBounded(tool, args, options = {}) {
  const timeoutMs = options.timeoutMs ?? 120_000;
  const maxOutputBytes = options.maxOutputBytes ?? 128 * 1_024;
  return new Promise((resolvePromise, rejectPromise) => {
    let output = "";
    let settled = false;
    let terminating = false;
    let timer;
    const child = spawn(tool, args, {
      cwd: options.cwd, env: options.env, shell: false, detached: true,
      stdio: ["ignore", "pipe", "pipe"], windowsHide: true,
    });
    const terminateGroup = (signal) => {
      if (child.pid === undefined) return;
      try { process.kill(-child.pid, signal); } catch { try { child.kill(signal); } catch { /* already exited */ } }
    };
    const finish = (error, result) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      if (error) rejectPromise(error); else resolvePromise(result);
    };
    const failAndTerminate = (message) => {
      if (terminating) return;
      terminating = true;
      terminateGroup("SIGTERM");
      const killTimer = setTimeout(() => {
        terminateGroup("SIGKILL");
        // Descendants can retain inherited pipes after the process group is
        // killed. Destroy them and settle at the bounded deadline instead of
        // waiting forever for Node's close event.
        child.stdout?.destroy();
        child.stderr?.destroy();
        finish(new Error(message));
      }, 2_000);
      killTimer.unref?.();
      child.once("close", () => { clearTimeout(killTimer); finish(new Error(message)); });
    };
    const collect = (chunk) => {
      if (terminating) return;
      output += chunk.toString();
      if (Buffer.byteLength(output) > maxOutputBytes) failAndTerminate("Gateway source build output exceeded the limit");
    };
    child.stdout.on("data", collect);
    child.stderr.on("data", collect);
    child.once("error", (error) => { if (!terminating) finish(error); });
    child.once("close", (code, signal) => {
      if (terminating) return;
      if (code === 0) finish(undefined, { code, signal, output });
      else finish(new Error(`Gateway source build failed (${signal ?? `exit ${code}`}): ${output.slice(-2_048)}`));
    });
    timer = setTimeout(() => failAndTerminate("Gateway source build timed out"), timeoutMs);
    timer.unref?.();
  });
}

async function cleanupPayloadVersionsUnlocked(paths, maximum = MAX_RETAINED_VERSIONS) {
  const protectedVersions = new Set();
  for (const pointer of [paths.current, paths.previous]) {
    const value = await readOptional(pointer);
    if (value) protectedVersions.add(selection(value, paths.channel).version);
  }
  const stateValue = await readOptional(paths.state);
  const candidate = stateValue?.candidateIdentity?.version ?? stateValue?.candidateVersion;
  if (validComponent(candidate, 128)) protectedVersions.add(candidate);
  const entries = await readdir(paths.versionsRoot, { withFileTypes: true }).catch((error) => error?.code === "ENOENT" ? [] : Promise.reject(error));
  const versions = [];
  const removed = [];
  for (const entry of entries) {
    if (entry.isDirectory() && !entry.isSymbolicLink() && (entry.name.startsWith(".staging-") || entry.name.startsWith(".source-staging-"))) {
      await makeMutable(join(paths.versionsRoot, entry.name));
      await rm(join(paths.versionsRoot, entry.name), { recursive: true, force: true });
      removed.push(entry.name);
      continue;
    }
    if (!entry.isDirectory() || entry.isSymbolicLink() || entry.name.startsWith(".")) continue;
    if (!validComponent(entry.name, 128)) continue;
    const path = join(paths.versionsRoot, entry.name);
    const info = await lstat(path);
    versions.push({ name: entry.name, path, mtime: Number(info.mtimeMs) });
  }
  versions.sort((left, right) => right.mtime - left.mtime || left.name.localeCompare(right.name));
  const keep = new Set(versions.slice(0, Math.max(0, maximum)).map((entry) => entry.name));
  for (const version of protectedVersions) keep.add(version);
  for (const entry of versions) {
    if (keep.has(entry.name)) continue;
    await makeMutable(entry.path);
    await rm(entry.path, { recursive: true, force: true });
    removed.push(entry.name);
  }
  return removed;
}

export async function cleanupPayloadVersions(paths, maximum = MAX_RETAINED_VERSIONS) {
  return withStoreLock(paths, () => cleanupPayloadVersionsUnlocked(paths, maximum));
}

export async function stagePayload({ home, channel, source, version, sourceRevision }) {
  const paths = store(home, channel);
  const sourceRoot = resolve(source);
  const sourceManifest = await validatePayload(sourceRoot, {}, true);
  const targetVersion = version ?? sourceManifest.version;
  if (!validComponent(targetVersion, 128)) throw new Error("invalid payload version");
  const target = join(paths.versionsRoot, targetVersion);
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
      // State now protects the candidate; cleanup is safe at this terminal
      // staging point and remains under the channel lock.
      await cleanupPayloadVersionsUnlocked(paths);
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
    if (!value || value.status !== "ok" || value.protocolVersion !== PROTOCOL_VERSION
      || value.minProtocolVersion !== PROTOCOL_VERSION || typeof value.runtimeEpoch !== "string"
      || typeof value.buildFingerprint !== "string" || typeof value.sourceRevision !== "string") {
      throw new Error("Gateway health identity is incomplete");
    }
    return value;
  } finally { clearTimeout(timer); }
}

export async function preflightPayload(root, runCommand = runBounded, timeoutMs = 30_000) {
  const manifest = await validatePayload(root, {}, true);
  const runtime = join(root, process.arch === "arm64" ? "runtime/node-arm64" : "runtime/node-x64");
  const entrypoint = join(root, "app", "dist", "index.js");
  await runCommand(runtime, ["--check", entrypoint], { timeoutMs, maxOutputBytes: 64 * 1024 });
  // Protocol values are deliberately read from the candidate's compiled
  // module with the candidate runtime. Manifests do not carry these fields;
  // defaulting them here would turn a preflight into a self-assertion.
  const versionModule = join(root, "app", "dist", "version.js");
  const probe = "import(process.env.TRON_CANDIDATE_VERSION_URL).then(({PROTOCOL_VERSION, MIN_PROTOCOL_VERSION}) => { if (!Number.isSafeInteger(PROTOCOL_VERSION) || !Number.isSafeInteger(MIN_PROTOCOL_VERSION)) process.exit(2); process.stdout.write(JSON.stringify({ protocolVersion: PROTOCOL_VERSION, minProtocolVersion: MIN_PROTOCOL_VERSION })); }).catch(() => process.exit(3));";
  const probeResult = await runCommand(runtime, ["-e", probe], {
    timeoutMs, maxOutputBytes: 8 * 1024,
    env: { ...process.env, TRON_CANDIDATE_VERSION_URL: pathToFileURL(versionModule).href },
  });
  let protocol;
  let minimum;
  try {
    const value = JSON.parse(probeResult?.output ?? "");
    protocol = value.protocolVersion;
    minimum = value.minProtocolVersion;
  } catch {
    throw new Error("candidate Gateway did not emit a valid protocol version range");
  }
  // The installed client speaks PROTOCOL_VERSION. The candidate must both
  // understand that version and not require a newer one.
  if (protocol < PROTOCOL_VERSION || minimum > PROTOCOL_VERSION || minimum < 1 || protocol < minimum) {
    throw new Error("candidate Gateway protocol range is incompatible");
  }
  return manifest;
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
    // If current already names the candidate, publication happened before a
    // crash and `previous` is the real rollback pointer. Otherwise recovery
    // must target the selection that was current before this promotion.
    const candidateAlreadyPublished = prior?.version === version && prior.payloadFingerprint === manifest.payloadFingerprint;
    const recoverySelectionValue = candidateAlreadyPublished
      ? (priorState.previous === undefined ? undefined : selection(JSON.parse(priorState.previous), channel))
      : prior;
    let recoveryManifest;
    if (recoverySelectionValue) {
      recoveryManifest = await validatePayload(join(paths.versionsRoot, recoverySelectionValue.version), {
        channel, version: recoverySelectionValue.version, payloadFingerprint: recoverySelectionValue.payloadFingerprint,
      }, true);
    }
    const before = await health(host, port, timeoutMs);
    await preflightPayload(targetRoot, runBounded, Math.min(timeoutMs, 30_000));
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

    // A crash can occur after current.json is published but before the new
    // process is healthy. In that case current already names the candidate;
    // publishing again would overwrite the real rollback pointer with itself.
    let published = candidateAlreadyPublished;
    try {
      if (!unchanged) {
        await writePendingAttempt(paths, target, prior);
        await publishSelection(paths, target);
        // Set ownership immediately after atomic publication. A later failure
        // must not skip recovery because this flag remained false.
        published = true;
      }
      await writeState(paths, { ...stateBase, state: deploymentTransition("prepared", "published") });
      await requestRestart({ host, port, token, timeoutMs, commandId: stateBase.commandId });
      await writeState(paths, { ...stateBase, state: deploymentTransition("published", "restartRequested") });
      const ready = await waitHealth({ host, port, timeoutMs }, manifest, before.runtimeEpoch);
      await writeState(paths, { ...stateBase, state: "ready" });
      await clearPendingAttempt(paths, target);
      return { state: "ready", manifest, health: ready };
    } catch (error) {
      if (published) {
        try {
          if (unchanged) await rollbackSelection(paths);
          else await restoreSelectionState(paths, priorState);
          await writeState(paths, { ...stateBase, state: deploymentTransition("published", "failed"), error: String(error?.message ?? error) });
          await requestRestart({ host, port, token, timeoutMs, commandId: suffixedCommandId(stateBase.commandId, "-rollback") });
          const recoveryTarget = recoveryManifest ?? {
            payloadFingerprint: before.buildFingerprint, sourceRevision: before.sourceRevision,
          };
          await waitHealth({ host, port, timeoutMs }, recoveryTarget, before.runtimeEpoch);
          await writeState(paths, { ...stateBase, state: deploymentTransition("failed", "rollbackRequested") });
          await writeState(paths, { ...stateBase, state: deploymentTransition("rollback-requested", "rolledBack") });
          // Preserve terminal automatic rollback through the outer apply
          // boundary; callers still receive the original bounded failure.
          await rm(paths.pending ?? join(paths.channelRoot, "pending-attempt.json"), { force: true });
          if (error && typeof error === "object") error.automaticRollbackCompleted = true;
        } catch (recoveryError) {
          try { await restoreSelectionState(paths, priorState); } catch { /* best effort, keep original error */ }
          error.message += `; deployment recovery failed: ${recoveryError.message}`;
        }
      } else {
        await rm(paths.pending ?? join(paths.channelRoot, "pending-attempt.json"), { force: true }).catch(() => {});
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

export async function buildSourcePayload({ paths, config, candidateVersion, timeoutMs = 120_000, runCommand = runBounded, npmCommand = resolveNpmCommand() }) {
  const active = await currentPayload(paths);
  const gatewayRoot = join(config.sourceRoot, "packages", "gateway");
  // Compile into a private temporary directory. In particular, never invoke
  // the package build script here: its configured outDir is the trusted source
  // tree's packages/gateway/dist, which must remain byte-for-byte unchanged.
  const compilerOutput = await mkdtemp(join(tmpdir(), "tron-gateway-source-build-"));
  let privateStaging;
  try {
    await runCommand(process.execPath, [
      join(gatewayRoot, "node_modules", "typescript", "bin", "tsc"),
      "-p", join(gatewayRoot, "tsconfig.json"), "--outDir", compilerOutput,
    ], { cwd: gatewayRoot, timeoutMs });
    const sourcePackage = JSON.parse(await readFile(join(gatewayRoot, "package.json"), "utf8"));
    const version = candidateVersion ?? `${sourcePackage.version}-source-${Date.now()}`;
    if (!validComponent(version, 128)) throw new Error("source build produced an invalid candidate version");
    const target = join(paths.versionsRoot, version);
    // Keep the expensive private install outside the channel projection. A
    // staging directory under versionsRoot would be visible to retention and
    // could be removed by a concurrent updater.
    const temporaryParent = await mkdtemp(join(tmpdir(), "tron-gateway-source-staging-"));
    const temporary = join(temporaryParent, "payload");
    try {
      await cp(active.root, temporary, { recursive: true, errorOnExist: true, force: false });
      await makeMutable(temporary);
      await rm(join(temporary, "app", "dist"), { recursive: true, force: true });
      await verifiedSourceCompilerOutput(compilerOutput);
      await cp(compilerOutput, join(temporary, "app", "dist"), { recursive: true, errorOnExist: true, force: false });
      await cp(join(gatewayRoot, "package.json"), join(temporary, "app", "package.json"));
      await cp(join(gatewayRoot, "package-lock.json"), join(temporary, "app", "package-lock.json"));
      // The updater and helper are part of the trusted source revision, not
      // stale files inherited from whichever payload happened to be active.
      await copyTrustedSourceScripts(config.sourceRoot, temporary);
      await rm(join(temporary, "app", "node_modules"), { recursive: true, force: true });
      await runCommand(npmCommand.tool, [
        ...(npmCommand.script ? [npmCommand.script] : []),
        "ci", "--omit=dev", "--ignore-scripts=false",
      ], {
        cwd: join(temporary, "app"), timeoutMs,
        env: {
          ...process.env,
          PATH: npmCommand.bin ? `${dirname(npmCommand.bin)}:/usr/bin:/bin` : process.env.PATH,
        },
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
      // Compilation and dependency installation above are private and do not
      // hold the channel lock. Publication is one serialized transaction:
      // immutable finalization, rename, candidate state, and retention all
      // observe the same channel snapshot. applyPayload holds only the
      // distinct apply lock, so this cannot recursively deadlock it.
      return await withStoreLock(paths, async () => {
        try {
          await access(target);
          throw new Error(`version ${version} already exists`);
        } catch (error) {
          if (error?.code !== "ENOENT") throw error;
        }
        privateStaging = join(paths.versionsRoot, `.source-staging-${version}-${process.pid}-${randomUUID()}`);
        await mkdir(paths.versionsRoot, { recursive: true, mode: 0o700 });
        await cp(temporary, privateStaging, { recursive: true, errorOnExist: true, force: false });
        await makeImmutable(privateStaging);
        try { await rename(privateStaging, target); } catch (error) {
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
        await cleanupPayloadVersionsUnlocked(paths);
        return { root: target, manifest };
      });
    } catch (error) {
      if (privateStaging) await rm(privateStaging, { recursive: true, force: true });
      throw error;
    } finally {
      await rm(temporaryParent, { recursive: true, force: true });
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
async function applyPayloadInternal(request) {
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
    if (error?.automaticRollbackCompleted === true) {
      await writeProgress(paths, "rolled-back", value.commandId, error?.message ?? error).catch(() => {});
    } else {
      await writeProgress(paths, "rollback", value.commandId, error?.message ?? error).catch(() => {});
    }
    throw error;
  }
  await writeProgress(paths, result.state, value.commandId);
  return { accepted: true, channel: value.channel, mode: selectedMode === "source" ? "source" : value.mode, commandId: value.commandId, state: result.state, version };
}

export async function applyPayload(request) {
  const value = validateApplyRequest(request);
  if (process.env.TRON_GATEWAY_SUPERVISED !== "1") {
    throw new Error("Gateway updates require the supervised LaunchAgent runtime");
  }
  const home = homeForChannel(value.channel, process.env.TRON_DATA_DIR);
  const paths = store(home, value.channel);
  return withApplyLock(paths, async () => {
    await writeProgress(paths, "starting", value.commandId);
    try {
      return await applyPayloadInternal(value);
    } catch (error) {
      // Every acknowledged detached request gets one terminal bounded result,
      // including malformed config, unavailable npm, and pre-build failures.
      // Automatic rollback is already terminal and must retain its original
      // bounded error rather than being overwritten by generic failure.
      if (error?.automaticRollbackCompleted !== true) {
        await writeProgress(paths, "failure", value.commandId, error?.message ?? error).catch(() => {});
      }
      throw error;
    }
  });
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
    if (!callerCommandId) throw new Error("rollback requires --command-id");
    await writeProgress(paths, "rollback", callerCommandId);
    try {
      result = await rollback({ ...options, commandId: callerCommandId });
      await writeProgress(paths, "rolled-back", callerCommandId);
    } catch (error) {
      await writeProgress(paths, "failure", callerCommandId, error?.message ?? error).catch(() => {});
      throw error;
    }
  } else {
    throw new Error("usage: gateway-payload-deploy.mjs stage|promote|rollback [options]");
  }
  console.log(JSON.stringify({ command, channel, home, ...result }));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch((error) => { console.error(`Gateway payload deployment failed: ${error.message}`); process.exitCode = 1; });
}
