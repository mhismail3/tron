#!/usr/bin/env node
import { createHash } from "node:crypto";
import { lstatSync, readFileSync } from "node:fs";
import { dirname, isAbsolute, join, posix, resolve, sep } from "node:path";
import { isDeepStrictEqual } from "node:util";
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

function runtimeDependencies(manifest) {
  // Peers are supplied by the host, not runtime edges of the bundled graph.
  // A package declared in dependencies as well as peers is still a runtime edge.
  return { ...(manifest.dependencies ?? {}), ...(manifest.optionalDependencies ?? {}) };
}
function sameRuntimeDeclarations(left, right) {
  return ["dependencies", "optionalDependencies"].every((field) => isDeepStrictEqual(left[field] ?? {}, right[field] ?? {}));
}
function resolveDependency(contains, importer, name) {
  if (!/^(?:@[a-z0-9._-]+\/)?[a-z0-9._-]+$/iu.test(name) || name === "." || name === "..") throw new Error(`invalid runtime dependency name ${name}`);
  let base = importer;
  for (;;) {
    if (posix.basename(base) !== "node_modules") {
      const candidate = `${base ? `${base}/` : ""}node_modules/${name}`;
      if (contains(candidate)) return candidate;
    }
    if (!base) throw new Error(`missing runtime dependency ${name} from ${importer || "root"}`);
    const parent = posix.dirname(base);
    base = parent === "." ? "" : parent;
  }
}

function checkClosure(name, version, sourceManifest, lockBytes, closurePath) {
  const lock = JSON.parse(lockBytes.toString("utf8"));
  const packages = lock.packages;
  if (lock.version !== version || packages?.[""]?.version !== version
    || !sameRuntimeDeclarations(packages[""], sourceManifest)) throw new Error("lockfile root identity/dependencies mismatch");
  const manifest = archiveJson(closurePath, "package/package.json");
  if (manifest.name !== name || manifest.version !== version) throw new Error("closure package identity mismatch");
  if (!sameRuntimeDeclarations(manifest, sourceManifest)) throw new Error("closure runtime dependencies differ from source declarations");
  const dependencies = Object.keys(runtimeDependencies(manifest)).sort();
  if (!Array.isArray(manifest.bundledDependencies)
    || !isDeepStrictEqual(dependencies, [...manifest.bundledDependencies].sort())) throw new Error("closure does not bundle every runtime dependency");
  if (!isDeepStrictEqual(archiveJson(closurePath, "package/package-lock.json"), lock)) throw new Error("closure embedded lockfile differs from pinned lockfile");
  if (dependencies.length === 0) return;
  const installed = archiveJson(closurePath, "package/node_modules/.package-lock.json").packages;
  const entries = new Set(archiveEntries(closurePath));
  const visited = new Set();
  const pending = dependencies.map((dependency) => ["", dependency]);
  // Resolve each edge exactly as node_modules lookup does, including nested
  // versions and hoisting. A visited package path bounds cycles and diamond graphs.
  while (pending.length) {
    const [importer, dependency] = pending.pop();
    const path = resolveDependency((candidate) => Object.hasOwn(packages, candidate), importer, dependency);
    const actualPath = resolveDependency((candidate) => entries.has(`package/${candidate}/package.json`), importer, dependency);
    if (actualPath !== path) throw new Error(`bundled dependency resolution mismatch for ${dependency}: ${actualPath} instead of ${path}`);
    if (visited.has(path)) continue;
    visited.add(path);
    const entry = `package/${path}/package.json`;
    const actual = archiveJson(closurePath, entry);
    const locked = packages[path];
    if (actual.name !== (locked.name ?? dependency) || actual.version !== locked.version) throw new Error(`bundled dependency version/identity mismatch for ${dependency} at ${path}`);
    if (!sameRuntimeDeclarations(actual, locked)) throw new Error(`bundled dependency declarations mismatch for ${dependency} at ${path}`);
    const record = installed?.[path];
    if (typeof locked.resolved !== "string" || typeof locked.integrity !== "string"
      || !/^sha(?:256|384|512)-[A-Za-z0-9+/]+={0,2}$/u.test(locked.integrity)
      || record?.version !== locked.version || record?.resolved !== locked.resolved || record?.integrity !== locked.integrity) throw new Error(`bundled dependency resolution/integrity mismatch for ${dependency} at ${path}`);
    for (const child of Object.keys(runtimeDependencies(actual))) pending.push([path, child]);
  }
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
  checkClosure(pin.name, pin.version, sourceManifest, lock, closurePath);
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
      checkClosure(pin.name, previous.version, previousManifest, previousLock, previousClosurePath);
    }
  }
  console.log(`pi-subagents ${pin.version}: source, lockfile, and self-contained closure verified`);
} catch (error) {
  fail(error instanceof Error ? error.message : String(error));
}
