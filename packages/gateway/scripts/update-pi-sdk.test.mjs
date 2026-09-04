import assert from "node:assert/strict";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { DIRECT_PI_PACKAGES, PI_PACKAGES, validSha512Integrity } from "./check-pi-sdk.mjs";
import { auditCommand, exactVersion, metadataCommand, readMetadata, runUpdate, updateCommand } from "./update-pi-sdk.mjs";

const version = "1.2.3";
const integrity = `sha512-${Buffer.alloc(64).toString("base64")}`;
const gitHead = "0123456789abcdef0123456789abcdef01234567";
const short = (name) => name.slice(name.indexOf("/") + 1);
const tarball = (name) => `https://registry.npmjs.org/${name}/-/${short(name)}-${version}.tgz`;
const lockPath = (name, nested = false) => nested
  ? `node_modules/@earendil-works/pi-coding-agent/node_modules/${name}`
  : `node_modules/${name}`;

async function makeRepo() {
  const root = await mkdtemp(join(tmpdir(), "tron-pi-sdk-update-"));
  const dependencies = Object.fromEntries(DIRECT_PI_PACKAGES.map((name) => [name, version]));
  const packages = { "": { dependencies } };
  for (const name of PI_PACKAGES) {
    const nested = !DIRECT_PI_PACKAGES.includes(name);
    packages[lockPath(name, nested)] = { version, resolved: tarball(name), ...(nested ? {} : { integrity }) };
  }
  await writeFile(join(root, "package.json"), JSON.stringify({ name: "fixture", private: true, dependencies }));
  await writeFile(join(root, "package-lock.json"), JSON.stringify({ lockfileVersion: 3, packages }));
  await writeFile(join(root, "pi-sdk-baseline.json"), JSON.stringify({ schema: 1, rollbackVersion: "0.84.0" }));
  execFileSync("git", ["init", "-q"], { cwd: root });
  execFileSync("git", ["add", "package.json", "package-lock.json", "pi-sdk-baseline.json"], { cwd: root });
  execFileSync("git", ["-c", "user.name=Tron Test", "-c", "user.email=tron-test@example.invalid", "commit", "-qm", "fixture"], { cwd: root });
  return root;
}

async function fakeNpm(root, mode = "success") {
  const log = join(root, "fake-npm.log");
  const script = join(root, "fake-npm.mjs");
  await writeFile(script, `#!/usr/bin/env node
import { appendFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
const args = process.argv.slice(2); const log = "fake-npm.log"; const mode = ${JSON.stringify(mode)};
appendFileSync(log, args.join(" ") + "\\n");
if (args[0] === "view") {
  const spec = args[1]; const name = spec.slice(0, spec.lastIndexOf("@"));
  const head = mode === "git-mismatch" && name.endsWith("pi-protocol") ? "fedcba9876543210fedcba9876543210fedcba98" : ${JSON.stringify(gitHead)};
  process.stdout.write(JSON.stringify({version: ${JSON.stringify(version)}, gitHead: head, "dist.integrity": ${JSON.stringify(integrity)}, engines: {node: ">=22.19.0"}}));
  process.exit(0);
}
if (args[0] === "install") {
  if (mode === "integrity-mismatch") {
    const lock = JSON.parse(readFileSync("package-lock.json"));
    lock.packages[${JSON.stringify(lockPath(DIRECT_PI_PACKAGES[0]))}].integrity = ${JSON.stringify(`sha512-${Buffer.alloc(64, 1).toString("base64")}`)};
    writeFileSync("package-lock.json", JSON.stringify(lock));
  }
  if (mode === "install-fail" || mode === "recovery-fail") {
    const pkg = JSON.parse(readFileSync("package.json")); pkg.dependencies[${JSON.stringify(DIRECT_PI_PACKAGES[0])}] = "9.9.9"; writeFileSync("package.json", JSON.stringify(pkg));
    mkdirSync("node_modules", { recursive: true }); writeFileSync("node_modules/mutated", "candidate\\n");
    process.exit(7);
  }
  process.exit(0);
}
if (args[0] === "ci") { appendFileSync(log, "RECOVERY_CI\\n"); rmSync("node_modules", { recursive: true, force: true }); mkdirSync("node_modules"); writeFileSync("node_modules/recovered", "baseline\\n"); process.exit(mode === "recovery-fail" ? 9 : 0); }
if (args[0] === "audit") process.exit(mode === "audit-fail" ? 8 : 0);
process.exit(64);
`, { mode: 0o755 });
  await chmod(script, 0o755);
  return { script, log };
}

async function cleanup(root) { await rm(root, { recursive: true, force: true }); }

test("accepts only one exact Pi release", () => {
  assert.equal(exactVersion("1.2.3"), true);
  assert.equal(exactVersion("1.2.3-beta.1"), true);
  for (const value of ["^1.2.3", "~1.2.3", "latest", "1.2", ""]) assert.equal(exactVersion(value), false);
});

test("plans native lifecycle install with engine enforcement and signature audit", () => {
  assert.deepEqual(updateCommand("1.2.3"), [
    "install", "--save-exact", "--engine-strict", "--registry=https://registry.npmjs.org/", ...DIRECT_PI_PACKAGES.map((name) => `${name}@1.2.3`),
  ]);
  assert.deepEqual(auditCommand(), ["audit", "signatures", "--registry=https://registry.npmjs.org/"]);
  assert.throws(() => updateCommand("^1.2.3"), /exact semver/);
});

test("plans one metadata request per complete seven-package family", () => {
  assert.deepEqual(metadataCommand(PI_PACKAGES[0], "1.2.3"), [
    "view", "@earendil-works/pi-agent-core@1.2.3", "version", "gitHead", "dist.integrity", "engines", "--json", "--prefer-online", "--offline=false", "--registry=https://registry.npmjs.org/",
  ]);
  assert.equal(validSha512Integrity(integrity), true);
  assert.throws(() => metadataCommand("other", "1.2.3"), /unknown Pi package/);
});

test("refuses dirty manifest state before any metadata request", async () => {
  const root = await makeRepo();
  try {
    await writeFile(join(root, "package.json"), "dirty");
    const { script, log } = await fakeNpm(root);
    assert.throws(() => runUpdate({ gatewayDir: root, version, npmBin: script }), /uncommitted changes/);
    assert.equal(await readFile(log, "utf8").catch(() => ""), "");
  } finally { await cleanup(root); }
});

test("rejects mixed provenance before install", async () => {
  const root = await makeRepo();
  try {
    const { script, log } = await fakeNpm(root, "git-mismatch");
    assert.throws(() => runUpdate({ gatewayDir: root, version, npmBin: script }), /mixed gitHead/);
    assert.equal((await readFile(log, "utf8")).split("\n").filter(Boolean).length, PI_PACKAGES.length);
    assert.doesNotMatch(await readFile(log, "utf8"), /^install/m);
  } finally { await cleanup(root); }
});

test("compares preflight integrity with resulting top-level lock metadata", async () => {
  const root = await makeRepo();
  try {
    const originalPackage = await readFile(join(root, "package.json"));
    const originalLock = await readFile(join(root, "package-lock.json"));
    const { script } = await fakeNpm(root, "integrity-mismatch");
    assert.throws(() => runUpdate({ gatewayDir: root, version, npmBin: script }), /preflight integrity disagrees/);
    assert.deepEqual(await readFile(join(root, "package.json")), originalPackage);
    assert.deepEqual(await readFile(join(root, "package-lock.json")), originalLock);
  } finally { await cleanup(root); }
});

test("restores manifests and runs npm ci after failed install", async () => {
  const root = await makeRepo();
  try {
    const originalPackage = await readFile(join(root, "package.json"));
    const originalLock = await readFile(join(root, "package-lock.json"));
    const { script, log } = await fakeNpm(root, "install-fail");
    assert.throws(() => runUpdate({ gatewayDir: root, version, npmBin: script }), /restored package\.json\/package-lock\.json and ran npm ci/);
    assert.deepEqual(await readFile(join(root, "package.json")), originalPackage);
    assert.deepEqual(await readFile(join(root, "package-lock.json")), originalLock);
    assert.match(await readFile(log, "utf8"), /ci --engine-strict/);
    assert.equal(await readFile(join(root, "node_modules/recovered"), "utf8"), "baseline\n");
  } finally { await cleanup(root); }
});

test("reports both update and recovery failures", async () => {
  const root = await makeRepo();
  try {
    const { script } = await fakeNpm(root, "recovery-fail");
    assert.throws(() => runUpdate({ gatewayDir: root, version, npmBin: script }), /npm install.*update failed and recovery was incomplete.*npm ci recovery/);
  } finally { await cleanup(root); }
});

test("snapshots the current package version as rollback metadata before install", async () => {
  const root = await makeRepo();
  try {
    const { script } = await fakeNpm(root);
    runUpdate({ gatewayDir: root, version, npmBin: script });
    assert.deepEqual(JSON.parse(await readFile(join(root, "pi-sdk-baseline.json"), "utf8")), { schema: 1, rollbackVersion: version });
  } finally { await cleanup(root); }
});

test("runs metadata, native install, coherence, and signature audit in order", async () => {
  const root = await makeRepo();
  try {
    const { script, log } = await fakeNpm(root);
    const result = runUpdate({ gatewayDir: root, version, npmBin: script });
    const commands = (await readFile(log, "utf8")).trim().split("\n");
    assert.equal(commands.slice(0, PI_PACKAGES.length).every((command) => command.startsWith("view ")), true);
    assert.match(commands[PI_PACKAGES.length], /^install /);
    assert.match(commands[PI_PACKAGES.length + 1], /^audit signatures /);
    assert.equal(result.metadata.length, PI_PACKAGES.length);
  } finally { await cleanup(root); }
});

test("parses deterministic fake metadata without network", async () => {
  const root = await makeRepo();
  try {
    const { script } = await fakeNpm(root);
    const records = readMetadata(version, root, script);
    assert.equal(records.length, PI_PACKAGES.length);
    assert.equal(new Set(records.map((record) => record.gitHead)).size, 1);
  } finally { await cleanup(root); }
});
