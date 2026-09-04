#!/usr/bin/env node
/**
 * Sequential old/candidate persistence compatibility check. All files and
 * credentials are created beneath a disposable temp directory.
 */
import { spawnSync } from "node:child_process";
import { isDeepStrictEqual } from "node:util";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { PI_PACKAGES, readPiSdkBaseline, validSha512Integrity, validatePiSdk } from "./check-pi-sdk.mjs";

const MAX_OUTPUT_BYTES = 256 * 1024;
const PROCESS_TIMEOUT_MS = 120_000;
const PACKAGE_NAME = "@earendil-works/pi-coding-agent";

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd, env: { ...process.env, npm_config_offline: "false", PI_CODING_AGENT_DIR: options.agentDir ?? join(options.cwd ?? tmpdir(), "unused-agent") },
    encoding: "utf8", timeout: options.timeoutMs ?? PROCESS_TIMEOUT_MS, maxBuffer: MAX_OUTPUT_BYTES, stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.error || result.status !== 0) throw new Error(`${command} ${args.join(" ")} failed: ${result.error?.message ?? result.stderr ?? `exit ${result.status}`}`);
  if (Buffer.byteLength(result.stdout ?? "") > MAX_OUTPUT_BYTES) throw new Error("rollback probe output exceeded bound");
  return result.stdout;
}

function packageRoot(gatewayDir) {
  const root = resolve(gatewayDir, "node_modules/@earendil-works/pi-coding-agent");
  if (!existsSync(join(root, "package.json"))) throw new Error(`candidate Pi package is missing: ${root}`);
  return root;
}

export function rollbackInstallCommand(version) {
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(version)) throw new Error("rollback version must be exact semver");
  return ["install", "--save-exact", "--ignore-scripts", "--engine-strict", "--omit=optional", "--no-audit", "--no-fund", "--registry=https://registry.npmjs.org/", "--offline=false", `${PACKAGE_NAME}@${version}`];
}
export function rollbackAuditCommand() { return ["audit", "signatures", "--registry=https://registry.npmjs.org/", "--offline=false", "--prefer-online"]; }

function validateRollbackInstalled(project, version) {
  const root = resolve(project);
  const packageJson = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
  if (packageJson.dependencies?.[PACKAGE_NAME] !== version) throw new Error("rollback project does not pin exact pi-coding-agent");
  const lock = JSON.parse(readFileSync(join(root, "package-lock.json"), "utf8"));
  const rootReal = realpathSync(root);
  const found = new Set();
  for (const [relativePath, entry] of Object.entries(lock.packages ?? {})) {
    const match = relativePath.match(/(?:^|\/)node_modules\/(?:@earendil-works\/)?(pi-[^/]+)$/u);
    if (!match || !entry || typeof entry !== "object") continue;
    const name = `@earendil-works/${match[1]}`;
    if (!PI_PACKAGES.includes(name)) throw new Error(`rollback install contains unexpected Pi package: ${name}`);
    found.add(name);
    const absolute = resolve(root, relativePath);
    if (absolute !== root && !absolute.startsWith(`${root}/`)) throw new Error(`rollback lock path escapes project: ${relativePath}`);
    const info = lstatSync(absolute);
    if (!info.isDirectory() || info.isSymbolicLink()) throw new Error(`rollback Pi package root is substituted: ${relativePath}`);
    const real = realpathSync(absolute);
    if (!real.startsWith(`${rootReal}/`)) throw new Error(`rollback Pi package root escapes project: ${relativePath}`);
    const nestedShrinkwrap = relativePath.startsWith("node_modules/@earendil-works/pi-coding-agent/node_modules/");
    if (entry.version !== version || entry.resolved !== `https://registry.npmjs.org/${name}/-/${name.slice(name.indexOf("/") + 1)}-${version}.tgz`
      || (entry.integrity !== undefined && !validSha512Integrity(entry.integrity))
      || (entry.integrity === undefined && !nestedShrinkwrap)) throw new Error(`rollback Pi package metadata is incoherent: ${relativePath}`);
  }
  for (const name of PI_PACKAGES) if (!found.has(name)) throw new Error(`rollback install omitted ${name}`);
}

function installRollback(gatewayDir, version, temp) {
  const project = join(temp, "rollback-project");
  mkdirSync(project, { recursive: true });
  const packageManifest = { name: "tron-pi-rollback-fixture", private: true, version: "1.0.0" };
  writeFileSync(join(project, "package.json"), `${JSON.stringify(packageManifest, null, 2)}\n`);
  const args = rollbackInstallCommand(version);
  const cache = process.env.npm_config_cache;
  if (cache) args.push("--cache", cache);
  run("npm", args, { cwd: project, agentDir: join(temp, "rollback-agent"), timeoutMs: 300_000 });
  validateRollbackInstalled(project, version);
  run("npm", rollbackAuditCommand(), { cwd: project, agentDir: join(temp, "rollback-agent"), timeoutMs: 300_000 });
  return packageRoot(project);
}

function probe(probePath, root, action, temp) {
  mkdirSync(temp, { recursive: true });
  return JSON.parse(run(process.execPath, [probePath, root, action, temp], { cwd: temp, agentDir: join(temp, "agent") }).trim());
}

function assertSequence([written, appended, final], direction) {
  if (appended.entries.length !== written.entries.length + 1) throw new Error(`${direction} compatibility did not preserve exactly one appended JSONL entry`);
  if (!isDeepStrictEqual(appended.entries.slice(0, -1), written.entries)) throw new Error(`${direction} compatibility changed pre-existing JSONL entries`);
  if (!isDeepStrictEqual(final.entries, appended.entries)) throw new Error(`${direction} final reader disagrees with the append reader`);
  if (!isDeepStrictEqual(final.settingsAuth, appended.settingsAuth)) throw new Error(`${direction} final reader disagrees with settings/auth state`);
  if (appended.settingsAuth.settings.theme !== "dark" || !appended.settingsAuth.auth.includes("anthropic")) throw new Error(`${direction} settings/auth append was lost`);
}

export function runRollbackCheck({ gatewayDir = resolve(dirname(fileURLToPath(import.meta.url)), "..") } = {}) {
  const root = resolve(gatewayDir);
  const current = validatePiSdk({ gatewayDir: root, checkInstalled: true });
  if (!current.ok || !current.version) throw new Error(`current Pi SDK is not coherent: ${current.issues.join("; ")}`);
  const baseline = readPiSdkBaseline(root);
  if (baseline.issues.length > 0 || !baseline.value) throw new Error(`rollback metadata is invalid: ${baseline.issues.join("; ")}`);
  const temp = mkdtempSync(join(tmpdir(), "tron-pi-rollback-"));
  try {
    const rollbackRoot = current.version === baseline.value.rollbackVersion
      ? packageRoot(root)
      : installRollback(root, baseline.value.rollbackVersion, temp);
    const probePath = join(root, "scripts/pi-session-compatibility-probe.mjs");
    // Each action is a separate Node process, so module caches and open files
    // cannot mask a format or migration incompatibility.
    const forwardWrite = probe(probePath, rollbackRoot, "write", join(temp, "forward"));
    const forwardAppend = probe(probePath, packageRoot(root), "read-append", join(temp, "forward"));
    const forwardRead = probe(probePath, rollbackRoot, "read", join(temp, "forward"));
    const reverseWrite = probe(probePath, packageRoot(root), "write", join(temp, "reverse"));
    const reverseAppend = probe(probePath, rollbackRoot, "read-append", join(temp, "reverse"));
    const reverseRead = probe(probePath, packageRoot(root), "read", join(temp, "reverse"));
    assertSequence([forwardWrite, forwardAppend, forwardRead], "forward");
    assertSequence([reverseWrite, reverseAppend, reverseRead], "reverse");
    return { currentVersion: current.version, rollbackVersion: baseline.value.rollbackVersion, forward: [forwardWrite, forwardAppend, forwardRead], reverse: [reverseWrite, reverseAppend, reverseRead] };
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const gatewayDir = process.argv[2] ? resolve(process.argv[2]) : resolve(dirname(fileURLToPath(import.meta.url)), "..");
    const result = runRollbackCheck({ gatewayDir });
    console.log(`Pi SDK rollback compatibility passed (${result.rollbackVersion} -> ${result.currentVersion}; isolated JSONL/settings/auth subprocesses)`);
  } catch (error) {
    console.error(`Pi SDK rollback compatibility failed: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}
