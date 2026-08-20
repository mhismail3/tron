#!/usr/bin/env node
/** Bounded, atomic state/identity helper for the developer-owned Debug Gateway. */
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { networkInterfaces } from "node:os";
import { mkdir, readFile, rename, writeFile, readdir, rm, stat } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";

const MAX_BYTES = 64 * 1024;
const MAX_TEXT = 512;
const STATE_LOCK_WAIT_MS = 5_000;
const STATE_LOCK_RETRY_MS = 25;
const STATE_LOCK_STALE_MS = 30_000;
const STATES = new Set(["starting", "ready", "draining", "restarting", "failed", "stopped"]);
const text = (value, fallback = undefined) => {
  if (value === undefined || value === null) return fallback;
  const result = String(value);
  if (result.length > MAX_TEXT || /[\u0000-\u001f\u007f]/u.test(result)) throw new Error("lifecycle value is invalid or oversized");
  return result;
};

async function atomicWrite(path, value) {
  const target = resolve(path);
  await mkdir(dirname(target), { recursive: true, mode: 0o700 });
  const temporary = `${target}.tmp-${process.pid}-${Date.now()}`;
  const encoded = `${JSON.stringify(value)}\n`;
  if (Buffer.byteLength(encoded) > MAX_BYTES) throw new Error("lifecycle state is oversized");
  await writeFile(temporary, encoded, { mode: 0o600 });
  await rename(temporary, target);
}

async function readState(path) {
  try {
    const raw = await readFile(resolve(path), "utf8");
    if (Buffer.byteLength(raw) > MAX_BYTES) throw new Error("lifecycle state is oversized");
    const value = JSON.parse(raw);
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("lifecycle state is malformed");
    return value;
  } catch (error) {
    if (error?.code === "ENOENT") return {};
    throw error;
  }
}

async function withStateLock(path, operation) {
  const target = resolve(path);
  const lockPath = `${target}.lock`;
  await mkdir(dirname(target), { recursive: true, mode: 0o700 });
  const deadline = Date.now() + STATE_LOCK_WAIT_MS;
  while (true) {
    try {
      await mkdir(lockPath, { mode: 0o700 });
      break;
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
      try {
        const lock = await stat(lockPath);
        if (Date.now() - lock.mtimeMs > STATE_LOCK_STALE_MS) {
          await rm(lockPath, { recursive: true, force: true });
          continue;
        }
      } catch (statError) {
        if (statError?.code !== "ENOENT") throw statError;
        continue;
      }
      if (Date.now() >= deadline) throw new Error("timed out waiting for lifecycle state lock");
      await new Promise((resolveWait) => setTimeout(resolveWait, STATE_LOCK_RETRY_MS));
    }
  }
  try {
    return await operation();
  } finally {
    await rm(lockPath, { recursive: true, force: true });
  }
}

function pidStartIdentity(pid) {
  if (!/^\d+$/u.test(String(pid)) || Number(pid) < 1) return "";
  try {
    const output = execFileSync("ps", ["-o", "lstart=", "-p", String(pid)], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
    return output.trim().slice(0, MAX_TEXT);
  } catch { return ""; }
}

async function fingerprint(root) {
  const hash = createHash("sha256");
  async function visit(path, relative) {
    let entries;
    try { entries = await readdir(path, { withFileTypes: true }); } catch { return; }
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      const absolute = join(path, entry.name);
      const name = join(relative, entry.name);
      if (entry.isDirectory()) await visit(absolute, name);
      else if (entry.isFile()) {
        hash.update(name); hash.update("\0"); hash.update(await readFile(absolute)); hash.update("\0");
      }
    }
  }
  await visit(resolve(root), "");
  return hash.digest("hex");
}

function isTailscaleAddress(address) {
  if (address.toLowerCase().startsWith("fd7a:115c:a1e0:")) return true;
  const octets = address.split(".").map(Number);
  return octets.length === 4 && octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127;
}

function selectTailscaleAddress(interfaces) {
  const candidates = Object.entries(interfaces).flatMap(([name, addresses]) => (addresses ?? [])
    .filter((candidate) => !candidate.internal && isTailscaleAddress(candidate.address))
    .map((candidate) => ({ ...candidate, name })));
  const family = (value) => value === "IPv4" || value === 4 ? 0 : 1;
  const compare = (left, right) => {
    const leftOctets = left.split(".").map(Number); const rightOctets = right.split(".").map(Number);
    if (leftOctets.length === 4 && rightOctets.length === 4
      && leftOctets.every(Number.isInteger) && rightOctets.every(Number.isInteger)) {
      for (let index = 0; index < 4; index += 1) if (leftOctets[index] !== rightOctets[index]) return leftOctets[index] - rightOctets[index];
      return 0;
    }
    return left === right ? 0 : left < right ? -1 : 1;
  };
  candidates.sort((left, right) => family(left.family) - family(right.family)
    || compare(left.address, right.address) || compare(left.name, right.name));
  return candidates[0]?.address;
}

function hostForHealth(raw) {
  if (raw !== "tailscale") return raw;
  return selectTailscaleAddress(networkInterfaces()) ?? raw;
}

async function health(host, port) {
  const target = hostForHealth(host);
  if (target === "tailscale") return { status: "unavailable", readiness: "unknown", reason: "tailscale address unavailable" };
  const authority = target.includes(":") ? `[${target}]` : target;
  try {
    const response = await fetch(`http://${authority}:${port}/health`, { signal: AbortSignal.timeout(1500) });
    const raw = await response.text();
    if (Buffer.byteLength(raw) > 16 * 1024) return { status: "invalid", readiness: "unknown", httpStatus: response.status, reason: "health response is oversized" };
    let body;
    try { body = JSON.parse(raw); } catch { body = {}; }
    const details = body && typeof body === "object" && !Array.isArray(body) ? body : {};
    return {
      status: typeof details.status === "string" ? details.status : "unknown",
      readiness: response.status === 200 && details.status === "ok" ? "ready" : "not-ready",
      httpStatus: response.status,
      ...(typeof details.runtimeEpoch === "string" ? { runtimeEpoch: details.runtimeEpoch } : {}),
      ...(typeof details.sourceRevision === "string" ? { sourceRevision: details.sourceRevision } : {}),
      ...(typeof details.buildFingerprint === "string" ? { buildFingerprint: details.buildFingerprint } : {}),
    };
  } catch (error) {
    return { status: "unavailable", readiness: "unknown", reason: error instanceof Error ? error.message.slice(0, MAX_TEXT) : "health request failed" };
  }
}

const [command, ...args] = process.argv.slice(2);
if (!command) throw new Error("missing lifecycle command");
if (command === "update" || command === "patch") {
  const path = args[0];
  const patch = command === "update" ? JSON.parse(args[1] ?? "{}") : Object.fromEntries(args.slice(1).map((entry) => {
    const separator = entry.indexOf("=");
    if (separator < 1) throw new Error("invalid lifecycle field");
    const key = entry.slice(0, separator); const value = entry.slice(separator + 1);
    return [key, value === "true" ? true : value === "false" ? false : /^-?\d+$/u.test(value) ? Number(value) : value];
  }));
  if (!path || !patch || typeof patch !== "object" || Array.isArray(patch)) throw new Error("invalid lifecycle patch");
  await withStateLock(path, async () => {
    const current = await readState(path);
    const next = { ...current, ...patch, updatedAt: new Date().toISOString() };
    if (next.lifecycle !== undefined && !STATES.has(next.lifecycle)) throw new Error("invalid lifecycle state");
    for (const [key, value] of Object.entries(next)) {
      if (!/^[A-Za-z][A-Za-z0-9_]{0,63}$/u.test(key)) throw new Error("invalid lifecycle field name");
      if (typeof value === "string") next[key] = text(value);
    }
    await atomicWrite(path, next);
  });
} else if (command === "read") {
  process.stdout.write(`${JSON.stringify(await readState(args[0]))}\n`);
} else if (command === "get") {
  const value = (await readState(args[0]))[args[1]];
  if (value !== undefined && value !== null) process.stdout.write(`${String(value)}\n`);
} else if (command === "pid-start") {
  process.stdout.write(`${pidStartIdentity(args[0])}\n`);
} else if (command === "pid-current") {
  const expectedIdentity = typeof args[1] === "string" ? args[1] : "";
  const actualIdentity = pidStartIdentity(args[0]);
  process.stdout.write(`${expectedIdentity !== "" && actualIdentity !== "" && actualIdentity === expectedIdentity ? "yes" : "no"}\n`);
} else if (command === "fingerprint") {
  process.stdout.write(`${await fingerprint(args[0])}\n`);
} else if (command === "selected-identity") {
  const home = resolve(args[0]);
  const channel = args[1];
  if (channel !== "dev") throw new Error("developer selection must use the dev channel");
  const root = join(home, "gateway", "payloads", channel);
  const selected = await readState(join(root, "current.json"));
  if (selected.schema !== 1 || selected.kind !== "tron-gateway-selection" || selected.channel !== channel
    || typeof selected.version !== "string" || !/^[A-Za-z0-9._-]{1,128}$/u.test(selected.version)
    || typeof selected.payloadFingerprint !== "string" || !/^[a-f0-9]{64}$/u.test(selected.payloadFingerprint)) {
    throw new Error("Debug selection is missing or malformed");
  }
  const manifest = await readState(join(root, "versions", selected.version, "manifest.json"));
  if (manifest.schema !== 1 || manifest.kind !== "tron-gateway-payload" || manifest.channel !== channel
    || manifest.version !== selected.version || manifest.payloadFingerprint !== selected.payloadFingerprint
    || typeof manifest.runtimeEpoch !== "string" || !/^[A-Za-z0-9._-]{1,128}$/u.test(manifest.runtimeEpoch)
    || typeof manifest.sourceRevision !== "string" || !/^[A-Za-z0-9._-]{1,256}$/u.test(manifest.sourceRevision)) {
    throw new Error("Debug selected manifest identity is missing or malformed");
  }
  process.stdout.write(`${manifest.runtimeEpoch} ${manifest.sourceRevision} ${manifest.payloadFingerprint}\n`);
} else if (command === "validate-build-identity") {
  const value = args[0] ?? "";
  const match = /^([A-Za-z0-9._-]{1,128}) ([a-f0-9]{64})$/u.exec(value);
  if (!match) throw new Error("Debug candidate build returned an invalid identity");
  process.stdout.write(`${match[1]} ${match[2]}\n`);
} else if (command === "resolve-host-fixture") {
  const fixture = JSON.parse(args[0] ?? "{}");
  process.stdout.write(`${selectTailscaleAddress(fixture) ?? ""}\n`);
} else if (command === "resolve-command-host") {
  const state = await readState(args[0]);
  const requested = args[1] ?? "";
  const explicit = args[2] === "yes";
  const supervisorLive = args[3] === "yes";
  const recorded = typeof state.expectedHost === "string" ? text(state.expectedHost) : undefined;
  const validHost = (value) => typeof value === "string" && value.length > 0
    && value.length <= 255 && !/[\s\u0000-\u001f\u007f/\\]/u.test(value);
  if (requested && !validHost(requested)) throw new Error("requested Debug host is invalid");
  if (supervisorLive) {
    if (!validHost(recorded)) throw new Error("live Debug supervisor host is missing or invalid");
    if (explicit && requested !== recorded) {
      throw new Error(`live Debug supervisor uses ${recorded}; stop it before changing to ${requested}`);
    }
    process.stdout.write(`${recorded}\n`);
  } else {
    process.stdout.write(`${requested || "127.0.0.1"}\n`);
  }
} else if (command === "health") {
  process.stdout.write(`${JSON.stringify(await health(args[0], args[1]))}\n`);
} else if (command === "status") {
  const path = args[0]; const state = await readState(path);
  const host = args[1] || (typeof state.expectedHost === "string" ? state.expectedHost : "127.0.0.1");
  const requestedPort = args[2] ?? state.expectedPort ?? 9848;
  const parsedPort = Number(requestedPort);
  const port = Number.isSafeInteger(parsedPort) && parsedPort >= 1 && parsedPort <= 65_535 ? parsedPort : 9848;
  const healthResult = await health(host, port);
  const supervisorIdentity = typeof state.supervisorStartIdentity === "string" ? state.supervisorStartIdentity : "";
  const childIdentity = typeof state.childStartIdentity === "string" ? state.childStartIdentity : "";
  const supervisorObservedIdentity = supervisorIdentity ? pidStartIdentity(state.supervisorPid) : "";
  const childObservedIdentity = childIdentity ? pidStartIdentity(state.childPid) : "";
  const supervisorLive = Boolean(state.supervisorPid && supervisorIdentity && supervisorObservedIdentity !== "" && supervisorObservedIdentity === supervisorIdentity);
  const childLive = Boolean(state.childPid && childIdentity && childObservedIdentity !== "" && childObservedIdentity === childIdentity);
  const recordedLifecycle = state.lifecycle ?? (supervisorLive ? "starting" : "stopped");
  const activeLifecycle = new Set(["starting", "ready", "draining", "restarting"]);
  const lifecycle = !supervisorLive && activeLifecycle.has(recordedLifecycle) ? "failed" : recordedLifecycle;
  process.stdout.write(`${JSON.stringify({
    expected: { host, port, home: state.expectedHome ?? join(process.env.HOME ?? "", ".tron-dev") },
    lifecycle, epoch: state.epoch ?? null,
    supervisor: { pid: state.supervisorPid ?? null, startIdentity: state.supervisorStartIdentity ?? null, live: Boolean(supervisorLive) },
    child: { pid: state.childPid ?? null, startIdentity: state.childStartIdentity ?? null, live: Boolean(childLive) },
    sourceRevision: state.sourceRevision ?? null, buildFingerprint: state.buildFingerprint ?? null,
    health: healthResult, intentionalExit: state.intentionalExit ?? false, exitCode: state.exitCode ?? null,
    restartCount: state.restartCount ?? 0, commandId: state.commandId ?? null,
  })}\n`);
} else {
  throw new Error(`unknown lifecycle command: ${command}`);
}
