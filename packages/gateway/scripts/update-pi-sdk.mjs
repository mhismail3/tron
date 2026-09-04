#!/usr/bin/env node
/**
 * Prepare one atomic Pi SDK cohort update. This command changes only the
 * Gateway manifests/lockfile and disposable installed tree; it never publishes,
 * deploys, or starts Tron.
 */
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { BASELINE_FILE, DIRECT_PI_PACKAGES, PI_PACKAGES, formatPiSdkReport, readPiSdkBaseline, validatePiSdk, validSha512Integrity } from "./check-pi-sdk.mjs";

const REGISTRY_ARGS = Object.freeze(["--registry=https://registry.npmjs.org/"]);

export function exactVersion(value) {
  return typeof value === "string" && /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(value);
}

export function updateCommand(version) {
  if (!exactVersion(version)) throw new Error(`Pi SDK version must be one exact semver (received ${version ?? "missing"})`);
  return ["install", "--save-exact", "--engine-strict", ...REGISTRY_ARGS, ...DIRECT_PI_PACKAGES.map((name) => `${name}@${version}`)];
}

export function auditCommand() {
  return ["audit", "signatures", ...REGISTRY_ARGS];
}

export function metadataCommand(name, version) {
  if (!PI_PACKAGES.includes(name)) throw new Error(`unknown Pi package: ${name}`);
  if (!exactVersion(version)) throw new Error(`Pi SDK version must be one exact semver (received ${version ?? "missing"})`);
  return ["view", `${name}@${version}`, "version", "gitHead", "dist.integrity", "engines", "--json", "--prefer-online", "--offline=false", ...REGISTRY_ARGS];
}

function commandFailure(label, result) {
  return `${label} (exit ${result.status ?? "unknown"})${result.signal ? ` after ${result.signal}` : ""}: ${(result.stderr || result.stdout || "").trim()}`;
}

export function readMetadata(version, gatewayDir, npmBin = "npm", spawn = spawnSync) {
  const records = PI_PACKAGES.map((name) => {
    const result = spawn(npmBin, metadataCommand(name, version), {
      cwd: gatewayDir, encoding: "utf8", env: { ...process.env, npm_config_offline: "false" }, maxBuffer: 4 * 1024 * 1024,
    });
    if (result.status !== 0) throw new Error(`npm metadata preflight failed for ${name}@${version}: ${commandFailure("npm view", result)}`);
    let record;
    try { record = JSON.parse(result.stdout); } catch { throw new Error(`npm metadata preflight returned invalid JSON for ${name}@${version}`); }
    const metadata = {
      package: name, version: record?.version, gitHead: record?.gitHead,
      integrity: record?.["dist.integrity"] ?? record?.dist?.integrity, nodeEngine: record?.engines?.node,
    };
    if (metadata.version !== version || typeof metadata.gitHead !== "string" || typeof metadata.integrity !== "string"
      || !validSha512Integrity(metadata.integrity) || typeof metadata.nodeEngine !== "string") {
      throw new Error(`npm metadata for ${name}@${version} is incomplete or invalid: ${JSON.stringify(metadata)}`);
    }
    return metadata;
  });
  const gitHeads = new Set(records.map(({ gitHead }) => gitHead));
  if (gitHeads.size !== 1) throw new Error(`Pi SDK family metadata has mixed gitHead values: ${[...gitHeads].join(", ")}`);
  return records;
}

function manifestsDirty(gatewayDir, spawn = spawnSync) {
  const check = (args) => spawn("git", ["-C", gatewayDir, ...args], { stdio: "ignore" }).status !== 0;
  return check(["diff", "--quiet", "--", "package.json", "package-lock.json", BASELINE_FILE])
    || check(["diff", "--cached", "--quiet", "--", "package.json", "package-lock.json", BASELINE_FILE]);
}

function compareLockIntegrities(gatewayDir, metadata) {
  const lock = JSON.parse(readFileSync(resolve(gatewayDir, "package-lock.json"), "utf8"));
  const mismatches = [];
  for (const record of metadata) {
    const entry = lock.packages?.[`node_modules/${record.package}`];
    if (entry?.integrity !== undefined && entry.integrity !== record.integrity) {
      mismatches.push(`${record.package}: preflight ${record.integrity}, lock ${entry.integrity}`);
    }
  }
  if (mismatches.length > 0) throw new Error(`preflight integrity disagrees with top-level lock entries:\n- ${mismatches.join("\n- ")}`);
}

function restoreOwnedState(root, original, npmBin, spawn) {
  let manifestError;
  try {
    writeFileSync(resolve(root, "package.json"), original.package);
    writeFileSync(resolve(root, "package-lock.json"), original.lock);
    writeFileSync(resolve(root, BASELINE_FILE), original.baseline);
  } catch (error) {
    manifestError = error instanceof Error ? error.message : String(error);
  }
  const recovery = spawn(npmBin, ["ci", "--engine-strict", ...REGISTRY_ARGS], {
    cwd: root, stdio: "inherit", env: { ...process.env, npm_config_offline: "false", npm_config_engine_strict: "true" },
  });
  const recoveryError = recovery.status === 0 ? undefined : commandFailure("npm ci recovery", recovery);
  if (manifestError || recoveryError) {
    throw new Error(`update failed and recovery was incomplete${manifestError ? `; manifest restore failed: ${manifestError}` : ""}${recoveryError ? `; ${recoveryError}` : ""}`);
  }
}

export function runUpdate({ gatewayDir = resolve(dirname(fileURLToPath(import.meta.url)), ".."), version, npmBin = "npm", spawn = spawnSync } = {}) {
  if (!exactVersion(version)) throw new Error(`Pi SDK version must be one exact semver (received ${version ?? "missing"})`);
  const root = resolve(gatewayDir);
  if (manifestsDirty(root, spawn)) throw new Error("refusing update: packages/gateway/package.json or package-lock.json has uncommitted changes");
  const packagePath = resolve(root, "package.json");
  const lockPath = resolve(root, "package-lock.json");
  const baselinePath = resolve(root, BASELINE_FILE);
  const original = {
    package: readFileSync(packagePath),
    lock: readFileSync(lockPath),
    baseline: readFileSync(baselinePath),
  };
  let installStarted = false;
  try {
    const metadata = readMetadata(version, root, npmBin, spawn);
    const current = validatePiSdk({ gatewayDir: root, checkInstalled: false });
    if (!current.ok || !current.version) throw new Error(`cannot snapshot an incoherent current Pi SDK: ${formatPiSdkReport(current)}`);
    const baseline = readPiSdkBaseline(root);
    if (baseline.issues.length > 0) throw new Error(`cannot snapshot Pi SDK rollback metadata: ${baseline.issues.join("; ")}`);
    writeFileSync(baselinePath, `${JSON.stringify({ schema: 1, rollbackVersion: current.version }, null, 2)}\n`);
    const command = updateCommand(version);
    installStarted = true;
    const install = spawn(npmBin, command, { cwd: root, stdio: "inherit", env: { ...process.env, npm_config_offline: "false", npm_config_engine_strict: "true" } });
    if (install.status !== 0) throw new Error(commandFailure("npm install", install));
    const report = validatePiSdk({ gatewayDir: root });
    if (!report.ok) throw new Error(formatPiSdkReport(report));
    compareLockIntegrities(root, metadata);
    const audit = spawn(npmBin, auditCommand(), { cwd: root, stdio: "inherit", env: { ...process.env, npm_config_offline: "false" } });
    if (audit.status !== 0) throw new Error(commandFailure("npm audit signatures", audit));
    return { version, metadata, command, auditCommand: auditCommand(), report };
  } catch (error) {
    if (!installStarted) throw error;
    const originalError = error instanceof Error ? error.message : String(error);
    try { restoreOwnedState(root, original, npmBin, spawn); }
    catch (recoveryError) { throw new Error(`${originalError}; ${recoveryError instanceof Error ? recoveryError.message : String(recoveryError)}`); }
    throw new Error(`${originalError}; restored package.json/package-lock.json and ran npm ci`);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = runUpdate({ version: process.argv[2] });
    console.log(JSON.stringify({ version: result.version, metadata: result.metadata, packages: result.report.packages }, null, 2));
  } catch (error) {
    console.error(`Pi SDK update failed: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}
