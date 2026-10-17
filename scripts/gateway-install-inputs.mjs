#!/usr/bin/env node
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { lstat, readFile, readdir, writeFile } from "node:fs/promises";
import { join, relative, resolve, sep } from "node:path";
import { isDeepStrictEqual } from "node:util";

const LOCK_LIMIT = 16 * 1024 * 1024;
const PACKAGE_LIMIT = 1024 * 1024;
const SOURCE_FILE_LIMIT = 16 * 1024 * 1024;
const SOURCE_TOTAL_LIMIT = 256 * 1024 * 1024;
const SOURCE_ENTRY_LIMIT = 20_000;
const RECEIPT_NAME = "build-inputs.json";
const MANAGED_FIELDS = ["version", "resolved", "integrity", "link", "dev", "optional", "devOptional", "inBundle", "os", "cpu", "dependencies", "optionalDependencies", "peerDependencies", "peerDependenciesMeta"];
const BUILD_INPUT_FILES = [
  ".node-version",
  "config/ci-toolchain.env",
  "config/GatewayProtocol.json",
  "config/PushService.xcconfig",
  "packages/gateway/package.json",
  "packages/gateway/package-lock.json",
  "packages/gateway/tsconfig.json",
  "packages/gateway/scripts/check-pi-sdk.mjs",
  "packages/gateway/scripts/check-pi-subagents.mjs",
  "packages/gateway/scripts/ensure-node-pty-helper.mjs",
  "packages/gateway/scripts/install-pi-subagents.mjs",
  "packages/gateway/pi-subagents-pin.json",
  "packages/gateway/pi-coding-agent-patch.json",
  "packages/mac-app/scripts/bundle-gateway.sh",
  "scripts/gateway-payload-deploy.mjs",
  "scripts/gateway-install-inputs.mjs",
  "scripts/gateway_protocol_contract.py",
  "scripts/hash-npm-runtime.py",
  "scripts/install-ci-tools.sh",
  "scripts/tron-node",
  "scripts/validate-push-service-config.sh",
  "scripts/verify-gateway-protocol-contract.py",
];

const INSTALL_DRIFT = "TRON_GATEWAY_INSTALL_DRIFT";
const REPAIR_TIMEOUT_MS = 10 * 60_000;
const REPAIR_OUTPUT_TAIL = 4_096;

// Every refusal raised through lockError means "the install does not match the
// lock", which `npm ci` is the canonical repair for. Structural refusals (symlinked
// package directories, unsafe scopes) are plain errors and are never auto-repaired.
function lockError(message, mode) {
  const remedy = mode === "production" ? "npm ci --omit=dev" : "npm ci";
  const error = new Error(`${message}; restore the canonical Gateway install with ${remedy}`);
  error.code = INSTALL_DRIFT;
  error.drift = message;
  throw error;
}

async function readJson(path, maximum, mode, description) {
  let info;
  try { info = await lstat(path); } catch { lockError(`${description} is missing`, mode); }
  if (!info.isFile() || info.isSymbolicLink() || info.size > maximum) {
    lockError(`${description} is not a bounded regular file`, mode);
  }
  try { return JSON.parse(await readFile(path, "utf8")); }
  catch { lockError(`${description} is malformed`, mode); }
}

function supports(value, current) {
  if (value === undefined) return true;
  const choices = Array.isArray(value) ? value : [value];
  const positive = choices.filter((entry) => !entry.startsWith("!"));
  const negative = choices.filter((entry) => entry.startsWith("!")).map((entry) => entry.slice(1));
  return !negative.includes(current) && (positive.length === 0 || positive.includes(current));
}

function compatible(record) {
  return supports(record.os, process.platform) && supports(record.cpu, process.arch);
}

function packageNameFromPath(packagePath) {
  const parts = packagePath.split("/");
  const leaf = parts.at(-1);
  const scope = parts.at(-2);
  return scope?.startsWith("@") ? `${scope}/${leaf}` : leaf;
}

async function walkInstalledPackages(root, nodeModulesPath, result = new Map()) {
  const entries = await readdir(nodeModulesPath, { withFileTypes: true });
  for (const entry of entries) {
    if (entry.name === ".bin" || entry.name === ".cache" || entry.name.startsWith(".")) continue;
    if (entry.name.startsWith("@")) {
      const scopePath = join(nodeModulesPath, entry.name);
      if (!entry.isDirectory() || entry.isSymbolicLink()) throw new Error(`unsafe installed package scope: ${scopePath}`);
      for (const child of await readdir(scopePath, { withFileTypes: true })) {
        if (child.isSymbolicLink()) throw new Error(`installed package ${relative(root, join(scopePath, child.name)).split(sep).join("/")} is a symlink`);
        if (!child.isDirectory()) continue;
        const packageRoot = join(scopePath, child.name);
        const packagePath = relative(root, packageRoot).split(sep).join("/");
        result.set(packagePath, packageRoot);
        await walkNested(root, packageRoot, result);
      }
      continue;
    }
    if (entry.isSymbolicLink()) throw new Error(`installed package ${relative(root, join(nodeModulesPath, entry.name)).split(sep).join("/")} is a symlink`);
    if (!entry.isDirectory()) continue;
    const packageRoot = join(nodeModulesPath, entry.name);
    const packagePath = relative(root, packageRoot).split(sep).join("/");
    result.set(packagePath, packageRoot);
    await walkNested(root, packageRoot, result);
  }
  return result;
}

async function walkNested(root, packageRoot, result) {
  const nested = join(packageRoot, "node_modules");
  try {
    const nestedInfo = await lstat(nested);
    if (nestedInfo.isDirectory() && !nestedInfo.isSymbolicLink()) await walkInstalledPackages(root, nested, result);
    else if (nestedInfo.isSymbolicLink()) throw new Error(`unsafe nested node_modules: ${nested}`);
  } catch (error) { if (error?.code !== "ENOENT") throw error; }
}

/**
 * Prove a conventional npm ci install against this Gateway's lockfile. npm's
 * hidden lock intentionally omits root metadata and platform-inapplicable
 * optional packages, so compare its applicable package records, then check the
 * package folders and their actual name/version metadata rather than trusting
 * npm ls or the hidden lock alone. The hidden-lock mtime is only npm's own
 * fast-path heuristic; this function always walks the installed package tree.
 */
export async function verifyGatewayInstallInputs(gatewayRoot, { mode = "full" } = {}) {
  if (mode !== "full" && mode !== "production") throw new TypeError(`unsupported Gateway install mode: ${mode}`);
  const root = resolve(gatewayRoot);
  const manifest = await readJson(join(root, "package.json"), PACKAGE_LIMIT, mode, "Gateway package.json");
  const lock = await readJson(join(root, "package-lock.json"), LOCK_LIMIT, mode, "Gateway package-lock.json");
  const modulesPath = join(root, "node_modules");
  const hidden = await readJson(join(modulesPath, ".package-lock.json"), LOCK_LIMIT, mode, "npm hidden lockfile node_modules/.package-lock.json");
  const lockedRoot = lock.packages?.[""];
  const rootDependencyFields = ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies", "peerDependenciesMeta", "engines", "bin"];
  if (lock.lockfileVersion !== 3 || hidden.lockfileVersion !== 3 || !lock.packages || !hidden.packages
    || lockedRoot?.name !== manifest.name || lockedRoot?.version !== manifest.version
    || rootDependencyFields.some((field) => !isDeepStrictEqual(lockedRoot?.[field], manifest[field]))) {
    lockError("Gateway lockfile format, root identity, or dependency manifest is unsupported or stale", mode);
  }
  if (manifest.workspaces !== undefined || Object.values(lock.packages).some((record) => record?.link)) {
    lockError("Gateway workspace or link installs are not a supported canonical build input", mode);
  }

  const omitDev = mode === "production";
  const expected = new Map();
  for (const [path, record] of Object.entries(lock.packages)) {
    if (!path) continue;
    if (omitDev && record.dev === true) continue;
    if ((record.optional === true || record.devOptional === true) && !compatible(record)) continue;
    expected.set(path, record);
  }
  const actualLockRecords = Object.keys(hidden.packages).filter(Boolean);
  if (actualLockRecords.length !== expected.size) {
    lockError(`npm hidden lock has ${actualLockRecords.length} packages but ${expected.size} are expected for the ${mode} install on ${process.platform}/${process.arch}`, mode);
  }
  for (const [path, expectedRecord] of expected) {
    const hiddenRecord = hidden.packages[path];
    if (!hiddenRecord || !isDeepStrictEqual(
      Object.fromEntries(MANAGED_FIELDS.filter((key) => key in expectedRecord).map((key) => [key, expectedRecord[key]])),
      Object.fromEntries(MANAGED_FIELDS.filter((key) => key in (hiddenRecord ?? {})).map((key) => [key, hiddenRecord[key]])),
    )) {
      lockError(`npm hidden lock package ${path} does not match package-lock`, mode);
    }
  }

  const installed = await walkInstalledPackages(root, modulesPath);
  for (const path of expected.keys()) {
    if (!installed.has(path)) lockError(`installed package ${path} is missing`, mode);
  }
  for (const path of installed.keys()) {
    if (!expected.has(path)) lockError(`unlocked package directory ${path}`, mode);
  }
  for (const [path, record] of expected) {
    const packageRoot = installed.get(path);
    if (!packageRoot) lockError(`installed package ${path} is missing`, mode);
    let directoryInfo;
    try { directoryInfo = await lstat(packageRoot); } catch { lockError(`installed package ${path} is missing`, mode); }
    if (!directoryInfo.isDirectory() || directoryInfo.isSymbolicLink()) {
      lockError(`installed package ${path} is not a regular package directory`, mode);
    }
    const actual = await readJson(join(packageRoot, "package.json"), PACKAGE_LIMIT, mode, `installed package ${path} package.json`);
    if (actual.name !== packageNameFromPath(path.slice("node_modules/".length)) || actual.version !== record.version) {
      lockError(`actual package ${path} is ${actual.name ?? "unnamed"}@${actual.version ?? "unknown"}, expected ${packageNameFromPath(path.slice("node_modules/".length))}@${record.version}`, mode);
    }
  }
  return { valid: true, mode };
}

function shellQuote(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}

/** The exact manual repair, runnable from any shell, with the same pinned Node/npm. */
export function gatewayInstallRepairCommand(gatewayRoot, runtimeBin) {
  return `cd ${shellQuote(resolve(gatewayRoot))} && PATH=${shellQuote(resolve(runtimeBin))}:"$PATH" npm ci`;
}

function runNpmCi(root, runtimeBin, timeoutMs) {
  return new Promise((resolvePromise) => {
    let output = "";
    const keep = (chunk) => { output = (output + chunk.toString()).slice(-REPAIR_OUTPUT_TAIL); };
    const child = spawn(join(runtimeBin, "node"), [join(runtimeBin, "npm"), "ci", "--no-audit", "--no-fund", "--prefer-offline"], {
      cwd: root,
      // Lifecycle scripts (the node-pty helper postinstall) resolve `node` from
      // PATH; put the pinned runtime first so they never pick an ambient Node.
      env: { ...process.env, PATH: `${runtimeBin}:${process.env.PATH ?? "/usr/bin:/bin"}` },
      stdio: ["ignore", "pipe", "pipe"],
      detached: true,
    });
    child.stdout.on("data", keep);
    child.stderr.on("data", keep);
    const timer = setTimeout(() => {
      try { process.kill(-child.pid, "SIGKILL"); } catch { child.kill("SIGKILL"); }
      resolvePromise({ ok: false, reason: `timed out after ${Math.round(timeoutMs / 1000)} s`, output });
    }, timeoutMs);
    child.on("error", (error) => { clearTimeout(timer); resolvePromise({ ok: false, reason: error.message, output }); });
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      resolvePromise(code === 0 ? { ok: true, output } : { ok: false, reason: signal ? `killed by ${signal}` : `exit ${code}`, output });
    });
  });
}

/**
 * Prove the full (compile) install, repairing lock drift with `npm ci` first.
 *
 * A checkout's `node_modules` drifts whenever `main` moves the lock without a
 * reinstall, and Rebuild from Source used to refuse on it (#1010). Only this
 * development install is repaired, with the given pinned runtime (`node` and
 * `npm` in runtimeBin); a payload's runtime tree is never installed here. npm ci
 * replaces only `node_modules`: the manifest and lock must stay byte-identical,
 * and the install must verify afterwards, or this fails with the exact command.
 */
export async function ensureGatewayInstallInputs(gatewayRoot, { runtimeBin, timeoutMs = REPAIR_TIMEOUT_MS, onRepair = () => {} } = {}) {
  const root = resolve(gatewayRoot);
  try {
    return { ...(await verifyGatewayInstallInputs(root)), repaired: false };
  } catch (error) {
    if (error?.code !== INSTALL_DRIFT || !runtimeBin) throw error;
    const command = gatewayInstallRepairCommand(root, runtimeBin);
    const inputs = ["package.json", "package-lock.json"];
    const before = await Promise.all(inputs.map((name) => readFile(join(root, name))));
    await onRepair({ drift: error.drift, command });
    const result = await runNpmCi(root, runtimeBin, timeoutMs);
    if (!result.ok) {
      const tail = result.output.trim().split("\n").slice(-6).join("\n");
      throw new Error(`Gateway install drifted from package-lock (${error.drift}); automatic npm ci failed (${result.reason}). Run: ${command}${tail ? `\n${tail}` : ""}`);
    }
    const after = await Promise.all(inputs.map((name) => readFile(join(root, name))));
    if (inputs.some((_, index) => !before[index].equals(after[index]))) {
      throw new Error(`automatic npm ci changed Gateway ${inputs.join(" or ")}; inspect the checkout, then run: ${command}`);
    }
    try {
      await verifyGatewayInstallInputs(root);
    } catch (verifyError) {
      throw new Error(`Gateway install still does not match package-lock after npm ci (${verifyError.drift ?? verifyError.message}). Run: ${command}`);
    }
    return { valid: true, mode: "full", repaired: true, drift: error.drift };
  }
}

async function sourceInputFiles(repositoryRoot) {
  const files = [...BUILD_INPUT_FILES];
  const sourceRoot = join(repositoryRoot, "packages/gateway/src");
  async function walk(directory) {
    const entries = await readdir(directory, { withFileTypes: true });
    for (const entry of entries) {
      const path = join(directory, entry.name);
      if (entry.isSymbolicLink()) throw new Error(`Gateway build input contains a symlink: ${relative(repositoryRoot, path)}`);
      if (entry.isDirectory()) await walk(path);
      else if (entry.isFile() && !entry.name.endsWith(".test.ts")) files.push(relative(repositoryRoot, path).split(sep).join("/"));
      else if (!entry.isFile()) throw new Error(`Gateway build input is not a regular file: ${relative(repositoryRoot, path)}`);
    }
  }
  await walk(sourceRoot);
  return [...new Set(files)].sort();
}

/** Digest the explicit source inputs that are compiled, copied or validated. */
export async function gatewayBuildInputFingerprint(repositoryRoot) {
  const root = resolve(repositoryRoot);
  const hash = createHash("sha256");
  let totalBytes = 0;
  const files = await sourceInputFiles(root);
  if (files.length > SOURCE_ENTRY_LIMIT) throw new Error("Gateway build input count exceeds its bound");
  for (const path of files) {
    const absolute = join(root, path);
    let info;
    try { info = await lstat(absolute); } catch { throw new Error(`Gateway build input is missing: ${path}`); }
    if (!info.isFile() || info.isSymbolicLink() || info.size > SOURCE_FILE_LIMIT) {
      throw new Error(`Gateway build input is not a bounded regular file: ${path}`);
    }
    totalBytes += info.size;
    if (totalBytes > SOURCE_TOTAL_LIMIT) throw new Error("Gateway build input bytes exceed their bound");
    const bytes = await readFile(absolute);
    hash.update(path).update("\0").update(String(bytes.length)).update("\0").update(bytes);
  }
  return hash.digest("hex");
}

function validRevision(value) { return typeof value === "string" && /^[0-9a-f]{40}$/u.test(value); }
function validFingerprint(value) { return typeof value === "string" && /^[a-f0-9]{64}$/u.test(value); }

async function readReceipt(appRoot) {
  const receiptPath = join(resolve(appRoot), RECEIPT_NAME);
  let info;
  try { info = await lstat(receiptPath); } catch { throw new Error("Gateway build-input receipt is missing; rebuild the payload"); }
  if (!info.isFile() || info.isSymbolicLink() || info.size > PACKAGE_LIMIT) throw new Error("Gateway build-input receipt is not a bounded regular file");
  let receipt;
  try { receipt = JSON.parse(await readFile(receiptPath, "utf8")); }
  catch { throw new Error("Gateway build-input receipt is malformed; rebuild the payload"); }
  const keys = ["schema", "sourceRevision", "sourceInputFingerprint"];
  if (!receipt || typeof receipt !== "object" || Array.isArray(receipt)
    || !isDeepStrictEqual(Object.keys(receipt).sort(), keys.sort())
    || receipt.schema !== 1 || !validRevision(receipt.sourceRevision) || !validFingerprint(receipt.sourceInputFingerprint)) {
    throw new Error("Gateway build-input receipt has an unsupported or malformed identity");
  }
  return receipt;
}

export async function writeGatewayBuildInputReceipt(repositoryRoot, appRoot, sourceRevision, expectedFingerprint) {
  if (!validRevision(sourceRevision)) throw new Error("Gateway build-input receipt requires a full source revision");
  const sourceInputFingerprint = await gatewayBuildInputFingerprint(repositoryRoot);
  if (expectedFingerprint !== undefined && sourceInputFingerprint !== expectedFingerprint) {
    throw new Error("Gateway build inputs changed during staging; discard this candidate and rebuild from the current inputs");
  }
  const receiptPath = join(resolve(appRoot), RECEIPT_NAME);
  let existing;
  try { existing = await lstat(receiptPath); } catch (error) { if (error?.code !== "ENOENT") throw error; }
  if (existing?.isSymbolicLink() || (existing && !existing.isFile())) throw new Error("Gateway build-input receipt destination is unsafe");
  const receipt = { schema: 1, sourceRevision, sourceInputFingerprint };
  await writeFile(receiptPath, `${JSON.stringify(receipt)}\n`, { mode: 0o600 });
  return receipt;
}

export async function verifyGatewayBuildInputReceipt(repositoryRoot, appRoot, sourceRevision, expectedFingerprint) {
  const receipt = await readReceipt(appRoot);
  if (!validRevision(sourceRevision) || receipt.sourceRevision !== sourceRevision) {
    throw new Error("staged Gateway build-input receipt names another source revision; rebuild the payload");
  }
  const actualFingerprint = await gatewayBuildInputFingerprint(repositoryRoot);
  if (receipt.sourceInputFingerprint !== actualFingerprint || (expectedFingerprint !== undefined && actualFingerprint !== expectedFingerprint)) {
    throw new Error("staged Gateway build-input receipt does not match current build inputs; rebuild the payload");
  }
  return receipt;
}

async function main(argumentsList) {
  const [command, ...args] = argumentsList;
  if (command === "check") {
    const [root, mode = "full"] = args;
    if (!root) throw new Error("usage: gateway-install-inputs.mjs check GATEWAY_ROOT [full|production]");
    const result = await verifyGatewayInstallInputs(root, { mode });
    console.log(`Gateway ${result.mode} installed inputs match package-lock.json`);
  } else if (command === "ensure") {
    const [root, runtimeBin] = args;
    if (!root || !runtimeBin) throw new Error("usage: gateway-install-inputs.mjs ensure GATEWAY_ROOT RUNTIME_BIN");
    const result = await ensureGatewayInstallInputs(root, {
      runtimeBin,
      onRepair: ({ drift }) => console.log(`Gateway install drifted (${drift}); running npm ci`),
    });
    console.log(`Gateway full installed inputs match package-lock.json${result.repaired ? " after npm ci" : ""}`);
  } else if (command === "fingerprint") {
    if (!args[0]) throw new Error("usage: gateway-install-inputs.mjs fingerprint REPOSITORY_ROOT");
    console.log(await gatewayBuildInputFingerprint(args[0]));
  } else if (command === "write-receipt") {
    if (args.length < 3) throw new Error("usage: gateway-install-inputs.mjs write-receipt REPOSITORY_ROOT APP_ROOT SOURCE_REVISION [EXPECTED_FINGERPRINT]");
    console.log(JSON.stringify(await writeGatewayBuildInputReceipt(args[0], args[1], args[2], args[3])));
  } else if (command === "verify-receipt") {
    if (args.length < 3) throw new Error("usage: gateway-install-inputs.mjs verify-receipt REPOSITORY_ROOT APP_ROOT SOURCE_REVISION [EXPECTED_FINGERPRINT]");
    console.log(JSON.stringify(await verifyGatewayBuildInputReceipt(args[0], args[1], args[2], args[3])));
  } else {
    throw new Error("usage: gateway-install-inputs.mjs check|ensure|fingerprint|write-receipt|verify-receipt ...");
  }
}

if (import.meta.url === new URL(process.argv[1] ?? "", "file:").href) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(error.message);
    process.exitCode = 78;
  });
}
