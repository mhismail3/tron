#!/usr/bin/env node
/**
 * Prepare one atomic Pi SDK cohort update. This command changes only the
 * Gateway manifests/lockfile and disposable installed tree; it never publishes,
 * deploys, or starts Tron.
 */
import { spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { BASELINE_FILE, DIRECT_PI_PACKAGES, PATCH_PIN_FILE, formatPiSdkReport, readPiCodingAgentPatch, readPiSdkBaseline, validatePiSdk, validSha512Integrity } from "./check-pi-sdk.mjs";

const REGISTRY_ARGS = Object.freeze(["--registry=https://registry.npmjs.org/"]);
const CODING_AGENT = "@earendil-works/pi-coding-agent";
const CHANGELOG_FILE = "CHANGELOG.md";

export function exactVersion(value) {
  return typeof value === "string" && /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(value);
}

/** The install for one cohort. A patched pi-coding-agent installs from its
 * declared tarball, which npm records as `file:<artifact path>`; the rest of the
 * family comes from the registry at the same version. */
export function updateCommand(version, patchedArtifact) {
  if (!exactVersion(version)) throw new Error(`Pi SDK version must be one exact semver (received ${version ?? "missing"})`);
  const spec = (name) => (patchedArtifact && name === CODING_AGENT ? `./${patchedArtifact}` : `${name}@${version}`);
  return ["install", "--save-exact", "--engine-strict", ...REGISTRY_ARGS, ...DIRECT_PI_PACKAGES.map(spec)];
}

export function auditCommand() {
  return ["audit", "signatures", ...REGISTRY_ARGS];
}

export function metadataCommand(name, version) {
  if (!DIRECT_PI_PACKAGES.includes(name)) throw new Error(`unknown direct Pi package: ${name}`);
  if (!exactVersion(version)) throw new Error(`Pi SDK version must be one exact semver (received ${version ?? "missing"})`);
  return ["view", `${name}@${version}`, "version", "gitHead", "dist.integrity", "engines", "--json", "--prefer-online", "--offline=false", ...REGISTRY_ARGS];
}

function commandFailure(label, result) {
  return `${label} (exit ${result.status ?? "unknown"})${result.signal ? ` after ${result.signal}` : ""}: ${(result.stderr || result.stdout || "").trim()}`;
}

/**
 * Registry metadata for the direct family. Release provenance is the published
 * `gitHead`, which must be one commit across the family. Pi stopped publishing
 * `gitHead` with 1.1.0; a patched cohort then supplies its own provenance: the
 * declaration's tag commit, from which `reproduce:pi-coding-agent` packed the
 * unpatched pi-coding-agent byte for byte as the registry's, so the registry
 * integrities here must be the ones the declaration recorded.
 */
export function readMetadata(version, gatewayDir, npmBin = "npm", spawn = spawnSync, patch = undefined) {
  const records = DIRECT_PI_PACKAGES.map((name) => {
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
    if (metadata.version !== version || (typeof metadata.gitHead !== "string" && !patch) || typeof metadata.integrity !== "string"
      || !validSha512Integrity(metadata.integrity) || typeof metadata.nodeEngine !== "string") {
      throw new Error(`npm metadata for ${name}@${version} is incomplete or invalid: ${JSON.stringify(metadata)}`);
    }
    return metadata;
  });
  if (patch) {
    const declared = { [CODING_AGENT]: patch.upstream.registryIntegrity, [patch.modelData.package]: patch.modelData.integrity };
    for (const record of records) {
      if (record.gitHead !== undefined && record.gitHead !== patch.upstream.tagCommit) {
        throw new Error(`${record.package}@${version} gitHead ${record.gitHead} is not the declared tag commit ${patch.upstream.tagCommit}`);
      }
      if (declared[record.package] !== undefined && declared[record.package] !== record.integrity) {
        throw new Error(`${record.package}@${version} registry integrity ${record.integrity} differs from ${PATCH_PIN_FILE}'s ${declared[record.package]}`);
      }
    }
    // A declared gitHead is the release tag commit the family shares, not registry metadata.
    return records.map((record) => record.gitHead !== undefined ? record : { ...record, gitHead: patch.upstream.tagCommit, gitHeadSource: "declared tag commit" });
  }
  const gitHeads = new Set(records.map(({ gitHead }) => gitHead));
  if (gitHeads.size !== 1) throw new Error(`Pi SDK family metadata has mixed gitHead values: ${[...gitHeads].join(", ")}`);
  return records;
}

function manifestsDirty(gatewayDir, spawn = spawnSync) {
  const check = (args) => spawn("git", ["-C", gatewayDir, ...args], { stdio: "ignore" }).status !== 0;
  return check(["diff", "--quiet", "--", "package.json", "package-lock.json", BASELINE_FILE])
    || check(["diff", "--cached", "--quiet", "--", "package.json", "package-lock.json", BASELINE_FILE]);
}

/** Release order of two exact semvers, by semver precedence: numeric cores,
 * then prerelease identifiers, which order numerically when both are numeric and
 * outrank nothing when the other side is a release. */
export function compareVersions(left, right) {
  const parse = (value) => {
    const separator = value.indexOf("-");
    return separator < 0
      ? { core: value.split(".").map(Number), prerelease: [] }
      : { core: value.slice(0, separator).split(".").map(Number), prerelease: value.slice(separator + 1).split(".") };
  };
  const leftVersion = parse(left);
  const rightVersion = parse(right);
  for (let index = 0; index < 3; index += 1) {
    if (leftVersion.core[index] !== rightVersion.core[index]) return leftVersion.core[index] < rightVersion.core[index] ? -1 : 1;
  }
  if (leftVersion.prerelease.length === 0 || rightVersion.prerelease.length === 0) {
    return leftVersion.prerelease.length === rightVersion.prerelease.length ? 0 : (leftVersion.prerelease.length === 0 ? 1 : -1);
  }
  for (let index = 0; index < Math.max(leftVersion.prerelease.length, rightVersion.prerelease.length); index += 1) {
    const leftPart = leftVersion.prerelease[index];
    const rightPart = rightVersion.prerelease[index];
    if (leftPart === rightPart) continue;
    if (leftPart === undefined) return -1;
    if (rightPart === undefined) return 1;
    const leftNumeric = /^\d+$/u.test(leftPart);
    const rightNumeric = /^\d+$/u.test(rightPart);
    if (leftNumeric && rightNumeric) return Number(leftPart) < Number(rightPart) ? -1 : 1;
    if (leftNumeric !== rightNumeric) return leftNumeric ? -1 : 1;
    return leftPart < rightPart ? -1 : 1;
  }
  return 0;
}

/**
 * The released CHANGELOG.md sections strictly after `from` and at most `to`,
 * newest first, byte-for-byte as the installed coding-agent package publishes
 * them. This is what makes the per-seam inventory mechanical: the upgrade task
 * reads the upstream release notes instead of a hand-read changelog.
 */
export function extractChangelogDelta(changelog, from, to) {
  if (!exactVersion(from) || !exactVersion(to)) throw new Error(`changelog delta needs exact semver bounds (received ${from ?? "missing"} -> ${to ?? "missing"})`);
  const sections = [];
  let current;
  for (const line of changelog.split("\n")) {
    if (line.startsWith("## ")) {
      const version = /^##\s+\[?([0-9A-Za-z.+-]+)\]?/u.exec(line)?.[1];
      current = version !== undefined && exactVersion(version) ? { version, lines: [line] } : undefined;
      if (current) sections.push(current);
      continue;
    }
    if (current) current.lines.push(line);
  }
  const selected = sections.filter(({ version }) => compareVersions(version, from) > 0 && compareVersions(version, to) <= 0);
  if (selected.length === 0) throw new Error(`CHANGELOG.md has no release section between ${from} and ${to}`);
  return `${selected.map(({ lines }) => lines.join("\n").trimEnd()).join("\n\n")}\n`;
}

function gitOutput(gatewayDir, args, spawn) {
  const result = spawn("git", ["-C", gatewayDir, ...args], { encoding: "utf8" });
  return result.status === 0 ? (result.stdout ?? "").trim() : undefined;
}

/**
 * Where this run's changelog evidence goes: the work item's directory under the
 * git directory, beside the rest of the run's evidence. It is never committed,
 * so it cannot mark the checkout dirty, and a run outside a task branch still
 * keeps its extract under `work/pi-sdk-update/`.
 */
export function changelogEvidencePath(gatewayDir, from, to, spawn = spawnSync) {
  const gitDir = gitOutput(gatewayDir, ["rev-parse", "--absolute-git-dir"], spawn);
  if (!gitDir) throw new Error("cannot locate the git directory that holds this Pi SDK update's evidence");
  const issue = gitOutput(gatewayDir, ["rev-parse", "--abbrev-ref", "HEAD"], spawn)?.match(/^[a-z]+\/(\d+)-/u)?.[1];
  return join(gitDir, "work", issue ? `issue-${issue}` : "pi-sdk-update", `pi-sdk-changelog-${from}-to-${to}.md`);
}

/** Read the installed coding-agent changelog and write this run's extract. */
export function writeChangelogEvidence({ gatewayDir, from, to, spawn = spawnSync } = {}) {
  const path = changelogEvidencePath(gatewayDir, from, to, spawn);
  const changelogPath = join(gatewayDir, "node_modules", CODING_AGENT, CHANGELOG_FILE);
  let changelog;
  try {
    changelog = readFileSync(changelogPath, "utf8");
  } catch {
    throw new Error(`installed ${CODING_AGENT} has no ${CHANGELOG_FILE}, so this update has no upstream inventory to record`);
  }
  const delta = extractChangelogDelta(changelog, from, to);
  const header = `# ${CODING_AGENT} upstream changelog: ${from} -> ${to}\n\nSource: ${CODING_AGENT}@${to} ${CHANGELOG_FILE}\n\n`;
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, header + delta);
  return { from, to, path, bytes: Buffer.byteLength(delta) };
}

function compareLockIntegrities(gatewayDir, metadata, patched) {
  const lock = JSON.parse(readFileSync(resolve(gatewayDir, "package-lock.json"), "utf8"));
  const mismatches = [];
  for (const record of metadata) {
    // The patched package's lock entry is its tarball's, which validatePiSdk checks.
    if (patched && record.package === CODING_AGENT) continue;
    const entry = lock.packages?.[`node_modules/${record.package}`];
    if (entry?.integrity !== undefined && entry.integrity !== record.integrity) {
      mismatches.push(`${record.package}: preflight ${record.integrity}, lock ${entry.integrity}`);
    }
  }
  if (mismatches.length > 0) throw new Error(`preflight integrity disagrees with top-level lock entries:\n- ${mismatches.join("\n- ")}`);
}

/** The cohort being replaced. A rebuilt patch declaration already names the
 * target, so the installed version is then the manifest's registry family. */
function currentCohort(root, original, patch) {
  if (!patch) {
    const current = validatePiSdk({ gatewayDir: root, checkInstalled: false });
    if (!current.ok || !current.version) throw new Error(`cannot snapshot an incoherent current Pi SDK: ${formatPiSdkReport(current)}`);
    return current;
  }
  const dependencies = JSON.parse(original.package.toString("utf8")).dependencies ?? {};
  const versions = new Set(DIRECT_PI_PACKAGES.filter((name) => name !== CODING_AGENT).map((name) => dependencies[name]));
  const [version] = versions;
  if (versions.size !== 1 || !exactVersion(version)) throw new Error(`cannot snapshot an incoherent current Pi SDK: registry family is ${[...versions].join(", ")}`);
  return { version };
}

/** After success, the tarball the previous cohort installed is no longer
 * referenced; until then it stays, so a failed update can restore with npm ci. */
function removeSupersededTarball(root, original, patch) {
  const previous = JSON.parse(original.package.toString("utf8")).dependencies?.[CODING_AGENT];
  const path = typeof previous === "string" && previous.startsWith("file:") ? previous.slice("file:".length) : undefined;
  if (path && path !== patch?.artifact.path && dirname(path) === "third_party/pi-coding-agent" && path.endsWith(".tgz")) {
    rmSync(resolve(root, path), { force: true });
    return path;
  }
  return undefined;
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
    cwd: root, stdio: "inherit", env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1", npm_config_offline: "false", npm_config_engine_strict: "true" }
  });
  const recoveryError = recovery.status === 0 ? undefined : commandFailure("npm ci recovery", recovery);
  if (manifestError || recoveryError) {
    throw new Error(`update failed and recovery was incomplete${manifestError ? `; manifest restore failed: ${manifestError}` : ""}${recoveryError ? `; ${recoveryError}` : ""}`);
  }
}

export function runUpdate({ gatewayDir = resolve(dirname(fileURLToPath(import.meta.url)), ".."), version, npmBin = "npm", spawn = spawnSync } = {}) {
  if (!exactVersion(version)) throw new Error(`Pi SDK version must be one exact semver (received ${version ?? "missing"})`);
  const root = resolve(gatewayDir);
  // The patched pi-coding-agent has one owner. A registry install would
  // silently drop it, so the patch is first rebased onto the target release and
  // its tarball rebuilt (`reproduce:pi-coding-agent -- --write`), or deleted once
  // upstream ships the API (see its removeWhen); the cohort then installs it.
  const patch = readPiCodingAgentPatch(root, { requireSources: true });
  if (patch.present && !patch.value) throw new Error(`refusing update: ${PATCH_PIN_FILE} is not valid: ${patch.issues.join("; ")}`);
  if (patch.value && patch.value.version !== version) {
    throw new Error(`refusing update: ${PATCH_PIN_FILE} declares a Tron-patched pi-coding-agent ${patch.value.version}; rebuild it for ${version} or delete it and third_party/pi-coding-agent/ first`);
  }
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
    const metadata = readMetadata(version, root, npmBin, spawn, patch.value);
    const current = currentCohort(root, original, patch.value);
    const baseline = readPiSdkBaseline(root);
    if (baseline.issues.length > 0) throw new Error(`cannot snapshot Pi SDK rollback metadata: ${baseline.issues.join("; ")}`);
    // Accepted one-way deltas are keyed by the version range they were accepted
    // for, so they are carried forward rather than erased by this rewrite.
    const knownOneWayDeltas = baseline.value.knownOneWayDeltas ?? [];
    // From the baseline write on, a failure restores the owned manifests.
    installStarted = true;
    writeFileSync(baselinePath, `${JSON.stringify({ schema: 1, rollbackVersion: current.version, ...(knownOneWayDeltas.length > 0 ? { knownOneWayDeltas } : {}) }, null, 2)}\n`);
    const command = updateCommand(version, patch.value?.artifact.path);
    const install = spawn(npmBin, command, { cwd: root, stdio: "inherit", env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1", npm_config_offline: "false", npm_config_engine_strict: "true" } });
    if (install.status !== 0) throw new Error(commandFailure("npm install", install));
    const report = validatePiSdk({ gatewayDir: root });
    if (!report.ok) throw new Error(formatPiSdkReport(report));
    compareLockIntegrities(root, metadata, patch.value !== undefined);
    const audit = spawn(npmBin, auditCommand(), { cwd: root, stdio: "inherit", env: { ...process.env, npm_config_offline: "false" } });
    if (audit.status !== 0) throw new Error(commandFailure("npm audit signatures", audit));
    const changelog = writeChangelogEvidence({ gatewayDir: root, from: current.version, to: version, spawn });
    const removedTarball = removeSupersededTarball(root, original, patch.value);
    return { version, metadata, command, auditCommand: auditCommand(), report, changelog, removedTarball };
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
    console.log(JSON.stringify({ version: result.version, metadata: result.metadata, packages: result.report.packages, changelog: result.changelog, removedTarball: result.removedTarball }, null, 2));
  } catch (error) {
    console.error(`Pi SDK update failed: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}
