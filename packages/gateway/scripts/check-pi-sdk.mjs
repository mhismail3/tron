#!/usr/bin/env node
/**
 * Validate the locked Pi SDK cohort without contacting a registry.
 * package.json is the version authority; package-lock.json remains npm's
 * authoritative resolved graph (including pi-coding-agent's shrinkwrap).
 */
import { existsSync, lstatSync, readFileSync, readlinkSync, realpathSync, statSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const PI_PACKAGES = Object.freeze([
  "@earendil-works/pi-agent-core",
  "@earendil-works/pi-ai",
  "@earendil-works/pi-coding-agent",
  "@earendil-works/pi-tui",
  "@earendil-works/pi-client",
  "@earendil-works/pi-protocol",
  "@earendil-works/pi-telemetry",
]);
export const DIRECT_PI_PACKAGES = Object.freeze(PI_PACKAGES.slice(0, 4));
const REGISTRY = "https://registry.npmjs.org/";
const EXACT_VERSION = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u;
const PACKAGE_JSON_MAX_BYTES = 64 * 1024;
const PACKAGE_LOCK_MAX_BYTES = 16 * 1024 * 1024;
const BASELINE_MAX_BYTES = 4 * 1024;
export const BASELINE_FILE = "pi-sdk-baseline.json";
export function validSha512Integrity(value) {
  if (typeof value !== "string" || !/^sha512-[A-Za-z0-9+/]+={0,2}$/u.test(value)) return false;
  const encoded = value.slice("sha512-".length);
  const digest = Buffer.from(encoded, "base64");
  return digest.length === 64 && digest.toString("base64") === encoded;
}

function packageNameFromLockPath(path) {
  const match = path.match(/node_modules\/(?:@earendil-works\/)?(pi-[^/]+)$/u);
  return match ? `@earendil-works/${match[1]}` : undefined;
}

function expectedTarball(name, version) {
  const shortName = name.slice(name.indexOf("/") + 1);
  return `${REGISTRY}${name}/-/${shortName}-${version}.tgz`;
}

function isNestedShrinkwrapPath(path) {
  return path.startsWith("node_modules/@earendil-works/pi-coding-agent/node_modules/");
}

function addIssue(issues, message) { issues.push(message); }

function readJson(path, label, issues, maximumBytes) {
  try {
    const info = lstatSync(path);
    if (!info.isFile() || info.isSymbolicLink()) throw new Error("must be a regular file");
    if (info.size > maximumBytes) throw new Error(`exceeds ${maximumBytes} byte limit`);
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    addIssue(issues, `${label} is not valid JSON: ${error instanceof Error ? error.message : String(error)}`);
    return undefined;
  }
}

function safePackageBin(root, packageRoot, packageJson, issues) {
  try {
    const packageInfo = lstatSync(packageRoot);
    if (!packageInfo.isDirectory() || packageInfo.isSymbolicLink()) {
      addIssue(issues, "installed pi-coding-agent package root must be a regular directory");
      return;
    }
  } catch {
    addIssue(issues, "installed pi-coding-agent package root is missing");
    return;
  }
  const nodeModulesRoot = resolve(root, "node_modules");
  if (!resolve(packageRoot).startsWith(`${nodeModulesRoot}/`)) {
    addIssue(issues, "installed pi-coding-agent package root escapes node_modules");
    return;
  }
  const bin = packageJson?.bin;
  const binPath = typeof bin === "object" && bin !== null ? bin.pi : undefined;
  if (typeof binPath !== "string" || !binPath || isAbsolute(binPath) || binPath.split(/[\\/]/u).includes("..")) {
    addIssue(issues, "installed pi-coding-agent package must declare a safe relative bin.pi path");
    return;
  }
  const executable = resolve(packageRoot, binPath);
  if (!executable.startsWith(`${resolve(packageRoot)}${"/"}`)) {
    addIssue(issues, `installed pi-coding-agent bin.pi escapes its package: ${binPath}`);
    return;
  }
  let info;
  let realExecutable;
  try {
    info = lstatSync(executable);
    const realRoot = realpathSync(packageRoot);
    realExecutable = realpathSync(executable);
    if (!info.isFile() || info.isSymbolicLink() || !realExecutable.startsWith(`${realRoot}/`)
      || (statSync(executable).mode & 0o111) === 0) {
      addIssue(issues, `installed pi-coding-agent bin.pi is not an executable regular file: ${binPath}`);
      return;
    }
  } catch {
    addIssue(issues, `installed pi-coding-agent bin.pi target is missing: ${binPath}`);
    return;
  }
  const projection = join(root, "node_modules", ".bin", "pi");
  try {
    const projectionInfo = lstatSync(projection);
    const projectionReal = realpathSync(projection);
    const expectedProjectionTarget = relative(dirname(projection), executable);
    if (!projectionInfo.isSymbolicLink() || readlinkSync(projection) !== expectedProjectionTarget || projectionReal !== realExecutable) {
      addIssue(issues, "node_modules/.bin/pi must be npm's symlink to the declared pi-coding-agent bin.pi");
    }
  } catch {
    addIssue(issues, "node_modules/.bin/pi projection is missing or dangling");
  }
}

function validateInstalled(root, lockPackages, version, issues) {
  const nodeModules = join(root, "node_modules");
  if (!existsSync(nodeModules)) return;
  let nodeModulesReal;
  try {
    const info = lstatSync(nodeModules);
    if (!info.isDirectory() || info.isSymbolicLink()) throw new Error("node_modules is not a regular directory");
    nodeModulesReal = realpathSync(nodeModules);
  } catch (error) {
    addIssue(issues, `installed node_modules is invalid: ${error instanceof Error ? error.message : String(error)}`);
    return;
  }
  for (const [lockPath, lockEntry] of lockPackages) {
    const name = packageNameFromLockPath(lockPath);
    if (!name) continue;
    const packageRoot = join(root, lockPath);
    try {
      const packageInfo = lstatSync(packageRoot);
      const packageReal = realpathSync(packageRoot);
      if (!packageInfo.isDirectory() || packageInfo.isSymbolicLink() || !packageReal.startsWith(`${nodeModulesReal}/`)) {
        addIssue(issues, `installed ${lockPath} escapes node_modules or is substituted`);
        continue;
      }
    } catch {
      addIssue(issues, `installed ${lockPath} package root is missing or inaccessible`);
      continue;
    }
    const packageJsonPath = join(packageRoot, "package.json");
    let packageJson;
    try {
      const info = lstatSync(packageJsonPath);
      if (!info.isFile() || info.isSymbolicLink()) throw new Error("package.json is not a regular file");
      const packageInfo = lstatSync(packageJsonPath);
      if (packageInfo.size > PACKAGE_JSON_MAX_BYTES) throw new Error("package.json exceeds size limit");
      packageJson = JSON.parse(readFileSync(packageJsonPath, "utf8"));
    } catch (error) {
      addIssue(issues, `installed ${name} at ${lockPath} is missing or invalid: ${error instanceof Error ? error.message : String(error)}`);
      continue;
    }
    if (packageJson.name !== name) addIssue(issues, `installed ${lockPath} declares name ${packageJson.name ?? "missing"}, expected ${name}`);
    if (packageJson.version !== version) addIssue(issues, `installed ${lockPath} is ${packageJson.version ?? "missing"}, expected ${version}`);
    if (lockEntry.version !== packageJson.version) addIssue(issues, `installed ${lockPath} disagrees with its lock entry`);
    if (name === "@earendil-works/pi-coding-agent") safePackageBin(root, packageRoot, packageJson, issues);
  }
}

/**
 * Validate the Pi family in a Gateway package directory.
 * Returns a stable report and never performs network or filesystem mutation.
 */
export function readPiSdkBaseline(gatewayDir) {
  const issues = [];
  const path = join(resolve(gatewayDir), BASELINE_FILE);
  const value = readJson(path, BASELINE_FILE, issues, BASELINE_MAX_BYTES);
  if (!value || Object.keys(value).length !== 2 || value.schema !== 1
    || typeof value.rollbackVersion !== "string" || !EXACT_VERSION.test(value.rollbackVersion)) {
    addIssue(issues, `${BASELINE_FILE} must contain exactly schema 1 and an exact rollbackVersion`);
    return { value: undefined, issues };
  }
  return { value, issues };
}

export function validatePiSdk({ gatewayDir = resolve(dirname(fileURLToPath(import.meta.url)), ".."), checkInstalled = true, requireBaseline = true } = {}) {
  const root = resolve(gatewayDir);
  const issues = [];
  const baseline = requireBaseline ? readPiSdkBaseline(root) : { value: undefined, issues: [] };
  issues.push(...baseline.issues);
  const packageJson = readJson(join(root, "package.json"), "package.json", issues, PACKAGE_JSON_MAX_BYTES);
  const lockJson = readJson(join(root, "package-lock.json"), "package-lock.json", issues, PACKAGE_LOCK_MAX_BYTES);
  if (!packageJson || !lockJson) return { ok: false, version: undefined, issues };

  const directVersions = DIRECT_PI_PACKAGES.map((name) => packageJson.dependencies?.[name]);
  if (directVersions.some((value) => typeof value !== "string" || !EXACT_VERSION.test(value))) {
    for (const [index, name] of DIRECT_PI_PACKAGES.entries()) {
      const value = directVersions[index];
      if (typeof value !== "string" || !EXACT_VERSION.test(value)) addIssue(issues, `${name} must be an exact semver dependency (found ${value ?? "missing"})`);
    }
  }
  const version = directVersions[0];
  if (typeof version !== "string" || !EXACT_VERSION.test(version)) return { ok: false, version, issues };
  for (const [index, name] of DIRECT_PI_PACKAGES.entries()) {
    if (directVersions[index] !== version) addIssue(issues, `${name} is ${directVersions[index] ?? "missing"}, expected cohort ${version}`);
  }

  const rootLock = lockJson.packages?.[""];
  if (!rootLock || typeof rootLock !== "object") addIssue(issues, "package-lock.json is missing its root package entry");
  for (const name of DIRECT_PI_PACKAGES) {
    if (rootLock?.dependencies?.[name] !== version) addIssue(issues, `package-lock root dependency ${name} is ${rootLock?.dependencies?.[name] ?? "missing"}, expected ${version}`);
  }
  const lockPackages = Object.entries(lockJson.packages ?? {}).filter(([path]) => packageNameFromLockPath(path));
  const seen = new Set();
  for (const [path, entry] of lockPackages) {
    const name = packageNameFromLockPath(path);
    const lockAbsolute = resolve(root, path);
    if (isAbsolute(path) || (lockAbsolute !== root && !lockAbsolute.startsWith(`${root}/`))) {
      addIssue(issues, `${path} escapes the Gateway package root`);
      continue;
    }
    seen.add(name);
    if (!entry || typeof entry !== "object") { addIssue(issues, `${path} has no package metadata`); continue; }
    if (entry.version !== version) addIssue(issues, `${path} resolves ${entry.version ?? "missing"}, expected cohort ${version}`);
    if (entry.resolved !== expectedTarball(name, version)) addIssue(issues, `${path} must use canonical registry tarball ${expectedTarball(name, version)}`);
    if (entry.integrity !== undefined && !validSha512Integrity(entry.integrity)) {
      addIssue(issues, `${path} has invalid npm integrity metadata`);
    } else if (entry.integrity === undefined && !isNestedShrinkwrapPath(path)) {
      addIssue(issues, `${path} is missing npm integrity metadata`);
    }
  }
  for (const name of DIRECT_PI_PACKAGES) {
    const topLevelPath = `node_modules/${name}`;
    if (!lockJson.packages?.[topLevelPath]) addIssue(issues, `package-lock.json is missing top-level direct Pi package ${name}`);
  }
  for (const name of PI_PACKAGES) if (!seen.has(name)) addIssue(issues, `package-lock.json is missing resolved Pi package ${name}`);
  for (const name of seen) if (!PI_PACKAGES.includes(name)) {
    addIssue(issues, `unexpected ${name} package in package-lock.json; research the release and add it to PI_PACKAGES before acceptance`);
  }
  if (checkInstalled) validateInstalled(root, lockPackages, version, issues);
  return {
    ok: issues.length === 0,
    version,
    rollbackVersion: baseline.value?.rollbackVersion,
    packages: [...seen].sort(),
    installedChecked: checkInstalled && existsSync(join(root, "node_modules")),
    issues,
  };
}

export function formatPiSdkReport(report) {
  if (report.ok) return `Pi SDK cohort ${report.version} is coherent (${report.packages.length} resolved entries${report.installedChecked ? ", installed tree checked" : ""})`;
  return ["Pi SDK coherence check failed:", ...report.issues.map((issue) => `- ${issue}`)].join("\n");
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const runtimeTree = process.argv.includes("--runtime-tree");
  const gatewayArg = process.argv.slice(2).find((argument) => argument !== "--runtime-tree");
  const gatewayDir = gatewayArg ? resolve(gatewayArg) : resolve(dirname(fileURLToPath(import.meta.url)), "..");
  const report = validatePiSdk({ gatewayDir, requireBaseline: !runtimeTree });
  console.log(formatPiSdkReport(report));
  process.exitCode = report.ok ? 0 : 1;
}
