#!/usr/bin/env node
import { createHash } from "node:crypto";
import { lstatSync, readFileSync } from "node:fs";
import { dirname, isAbsolute, join, resolve, sep } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
const GATEWAY = args[0] === "--root" && args.length === 2 ? resolve(args[1]) : dirname(dirname(fileURLToPath(import.meta.url)));
const DEFAULT_PIN = join(GATEWAY, "pi-subagents-pin.json");
const pinPath = args[0] === "--pin" && args.length === 2 ? resolve(args[1]) : DEFAULT_PIN;

function fail(message) { console.error(`pi-subagents pin check failed: ${message}`); process.exitCode = 1; }
function regular(path, label) {
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`${label} must be a regular file`);
  return readFileSync(path);
}
function hash(bytes, algorithm) { return createHash(algorithm).update(bytes).digest("hex"); }
function sha512Bytes(bytes) { return createHash("sha512").update(bytes).digest(); }
function archiveEntries(path) {
  const result = spawnSync("tar", ["-tzf", path], { encoding: "utf8" });
  if (result.status !== 0) throw new Error(`cannot read archive entries: ${result.stderr.trim()}`);
  return result.stdout.split("\n").filter(Boolean);
}
function archiveJson(path, entry) {
  const result = spawnSync("tar", ["-xOzf", path, entry], { encoding: "utf8", maxBuffer: 2 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(`archive lacks ${entry}`);
  return JSON.parse(result.stdout);
}
function safeArtifact(relativePath) {
  if (typeof relativePath !== "string" || isAbsolute(relativePath) || relativePath.split(/[\\/]/u).includes("..")) throw new Error("artifact path must be relative and confined");
  const path = resolve(GATEWAY, relativePath);
  if (!path.startsWith(`${GATEWAY}${sep}`)) throw new Error("artifact path escapes Gateway root");
  return path;
}

function checkBuild(pin) {
  if (pin.schemaVersion !== 1 || pin.name !== "pi-subagents" || !/^0\.\d+\.\d+-tron\.\d+$/u.test(pin.version)
    || !/^[0-9a-f]{40}$/u.test(pin.fork?.commit)
    || !(pin.fork.repository === null || (typeof pin.fork.repository === "string" && /^https:\/\//u.test(pin.fork.repository)))
    || pin.upstream?.package !== "pi-subagents" || !/^v0\.\d+\.\d+$/u.test(pin.upstream.release)
    || !/^[0-9a-f]{40}$/u.test(pin.upstream.tagCommit) || !pin.version.startsWith(`${pin.upstream.release.slice(1)}-tron.`)
    || pin.nodeVersion !== "22.22.0" || pin.npmVersion !== "10.9.4") {
    throw new Error("pin identity/schema is invalid");
  }
  const sourcePath = safeArtifact(pin.sourceArchive?.path);
  const lockPath = safeArtifact(pin.lockfile?.path);
  const closurePath = safeArtifact(pin.closure?.path);
  const source = regular(sourcePath, "source archive");
  const lock = regular(lockPath, "fork lockfile");
  const closure = regular(closurePath, "closure archive");
  if (hash(source, "sha256") !== pin.sourceArchive.sha256) throw new Error("source archive SHA-256 mismatch");
  if (hash(lock, "sha256") !== pin.lockfile.sha256) throw new Error("fork lockfile SHA-256 mismatch");
  if (!/^[0-9a-f]{128}$/u.test(pin.closure.sha512) || hash(closure, "sha512") !== pin.closure.sha512) throw new Error("closure SHA-512 integrity mismatch");
  const sourceManifest = archiveJson(sourcePath, "package/package.json");
  if (sourceManifest.name !== pin.name || sourceManifest.version !== pin.version) throw new Error("source archive package identity mismatch");
  const lockData = JSON.parse(lock.toString("utf8"));
  if (lockData.version !== pin.version || lockData.packages?.[""]?.version !== pin.version
    || JSON.stringify(lockData.packages[""].dependencies) !== JSON.stringify(sourceManifest.dependencies)) throw new Error("lockfile root identity/dependencies mismatch");
  const manifest = archiveJson(closurePath, "package/package.json");
  if (manifest.name !== pin.name || manifest.version !== pin.version) throw new Error("closure package identity mismatch");
  const dependencies = Object.keys(manifest.dependencies ?? {}).sort();
  const bundled = [...(manifest.bundledDependencies ?? [])].sort();
  if (JSON.stringify(dependencies) !== JSON.stringify(bundled)) throw new Error("closure does not bundle every runtime dependency");
  const entries = new Set(archiveEntries(closurePath));
  for (const dependency of dependencies) {
    const entry = `package/node_modules/${dependency}/package.json`;
    if (!entries.has(entry)) throw new Error(`closure is missing bundled runtime dependency ${dependency}`);
    const actual = archiveJson(closurePath, entry);
    if (actual.name !== dependency || actual.version !== manifest.dependencies[dependency]) throw new Error(`bundled dependency mismatch for ${dependency}`);
  }
}

try {
  const pin = JSON.parse(regular(pinPath, "pin").toString("utf8"));
  checkBuild(pin);
  if (pin.previous !== null) {
    const previous = pin.previous;
    if (previous?.fork) {
      checkBuild(previous);
    } else {
      if (typeof previous !== "object" || !/^0\.\d+\.\d+$/u.test(previous.version ?? "")
        || !/^[0-9a-f]{128}$/u.test(previous.sha512 ?? "")
        || typeof previous.path !== "string" || typeof previous.lockfile !== "object"
        || typeof previous.closure !== "object" || typeof previous.sourceIntegrity !== "string") {
        throw new Error("previous pin record must bind version, source archive, lockfile, and closure");
      }
      const previousPath = safeArtifact(previous.path);
      const previousBytes = regular(previousPath, "previous source archive");
      if (hash(previousBytes, "sha512") !== previous.sha512) throw new Error("previous source archive SHA-512 mismatch");
      if (!/^sha512-[A-Za-z0-9+/]+={0,2}$/u.test(previous.sourceIntegrity)
        || `sha512-${Buffer.from(sha512Bytes(previousBytes)).toString("base64")}` !== previous.sourceIntegrity) {
        throw new Error("previous source archive registry integrity mismatch");
      }
      const previousLockPath = safeArtifact(previous.lockfile.path);
      const previousLock = regular(previousLockPath, "previous lockfile");
      if (hash(previousLock, "sha256") !== previous.lockfile.sha256) throw new Error("previous lockfile SHA-256 mismatch");
      const previousClosurePath = safeArtifact(previous.closure.path);
      const previousClosure = regular(previousClosurePath, "previous closure");
      if (hash(previousClosure, "sha512") !== previous.closure.sha512) throw new Error("previous closure SHA-512 mismatch");
      const previousManifest = archiveJson(previousPath, "package/package.json");
      if (previousManifest.name !== pin.name || previousManifest.version !== previous.version) throw new Error("previous source archive package identity mismatch");
    }
  }
  console.log(`pi-subagents ${pin.version}: source, lockfile, and self-contained closure verified`);
} catch (error) {
  fail(error instanceof Error ? error.message : String(error));
}
