#!/usr/bin/env node
/** Compare the Pi dependency graph at two Git revisions without installing anything. */
import { execFileSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { PI_PACKAGES } from "./check-pi-sdk.mjs";

const GRAPH_MAX_BYTES = 16 * 1024 * 1024;
const PI_PACKAGE_PREFIX = "@earendil-works/pi-";

function stable(value) {
  if (Array.isArray(value)) return value.map(stable);
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(Object.keys(value).sort().map((key) => [key, stable(value[key])]));
}

function resolvedDependencyPath(packages, packagePath, dependency) {
  let owner = packagePath;
  for (;;) {
    const candidate = owner ? `${owner}/node_modules/${dependency}` : `node_modules/${dependency}`;
    if (Object.hasOwn(packages, candidate)) return candidate;
    const parentNodeModules = owner.lastIndexOf("/node_modules/");
    if (parentNodeModules >= 0) owner = owner.slice(0, parentNodeModules);
    else if (owner) owner = "";
    else return undefined;
  }
}

function dependencyNames(entry) {
  return new Set([
    ...Object.keys(entry?.dependencies ?? {}),
    ...Object.keys(entry?.optionalDependencies ?? {}),
    ...Object.keys(entry?.peerDependencies ?? {}),
  ]);
}

export function piGraphDocument(packageJson, lockJson) {
  const dependencies = packageJson?.dependencies ?? {};
  const directNames = [...new Set([
    ...PI_PACKAGES,
    ...Object.keys(dependencies).filter((name) => name.startsWith(PI_PACKAGE_PREFIX)),
  ])].sort();
  const direct = {};
  for (const name of directNames) direct[name] = dependencies[name] ?? null;

  const packages = lockJson?.packages ?? {};
  const resolved = {};
  const unresolved = {};
  const queue = directNames
    .filter((name) => direct[name] !== null)
    .map((name) => `node_modules/${name}`);
  const seen = new Set();
  while (queue.length > 0) {
    const path = queue.shift();
    if (seen.has(path)) continue;
    seen.add(path);
    const entry = packages[path];
    if (!entry || typeof entry !== "object") {
      unresolved[path] = "missing-root";
      continue;
    }
    resolved[path] = entry;
    for (const name of [...dependencyNames(entry)].sort()) {
      const dependencyPath = resolvedDependencyPath(packages, path, name);
      if (dependencyPath) queue.push(dependencyPath);
      else unresolved[`${path} -> ${name}`] = "missing-dependency";
    }
  }
  return stable({ direct, resolved, unresolved });
}

export function piGraphChanged(packageJsonA, lockJsonA, packageJsonB, lockJsonB) {
  return JSON.stringify(piGraphDocument(packageJsonA, lockJsonA)) !== JSON.stringify(piGraphDocument(packageJsonB, lockJsonB));
}

function gitFile(repoDir, revision, path) {
  try {
    const bytes = execFileSync("git", ["-C", repoDir, "show", `${revision}:${path}`], { maxBuffer: GRAPH_MAX_BYTES });
    return JSON.parse(bytes.toString("utf8"));
  } catch (error) {
    throw new Error(`cannot read ${path} at ${revision}: ${error instanceof Error ? error.message : String(error)}`);
  }
}

export function comparePiSdkRevisions({ repoDir = resolve(dirname(fileURLToPath(import.meta.url)), "../../.."), base, candidate, gatewayPath = "packages/gateway" } = {}) {
  if (typeof base !== "string" || typeof candidate !== "string" || !base || !candidate) throw new Error("two Git revisions are required");
  const packageRelative = `${gatewayPath}/package.json`;
  const lockRelative = `${gatewayPath}/package-lock.json`;
  const before = piGraphDocument(gitFile(repoDir, base, packageRelative), gitFile(repoDir, base, lockRelative));
  const after = piGraphDocument(gitFile(repoDir, candidate, packageRelative), gitFile(repoDir, candidate, lockRelative));
  return { changed: JSON.stringify(before) !== JSON.stringify(after), base, candidate, before, after };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [base, candidate = "HEAD", repoDir = resolve(dirname(fileURLToPath(import.meta.url)), "../../..")] = process.argv.slice(2);
    const result = comparePiSdkRevisions({ repoDir, base, candidate });
    console.log(JSON.stringify({ changed: result.changed, base: result.base, candidate: result.candidate }));
  } catch (error) {
    console.error(`Pi SDK graph comparison failed: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}
