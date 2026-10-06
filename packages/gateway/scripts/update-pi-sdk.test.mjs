import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { realpathSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { DIRECT_PI_PACKAGES, PI_PACKAGES, validSha512Integrity } from "./check-pi-sdk.mjs";
import { auditCommand, changelogEvidencePath, compareVersions, exactVersion, extractChangelogDelta, metadataCommand, readMetadata, runUpdate, updateCommand } from "./update-pi-sdk.mjs";

const version = "1.2.3";
const currentVersion = "1.0.0";
const integrity = `sha512-${Buffer.alloc(64).toString("base64")}`;
const gitHead = "0123456789abcdef0123456789abcdef01234567";
const short = (name) => name.slice(name.indexOf("/") + 1);
const tarball = (name) => `https://registry.npmjs.org/${name}/-/${short(name)}-${version}.tgz`;
const lockPath = (name, nested = false) => nested
  ? `node_modules/@earendil-works/pi-coding-agent/node_modules/${name}`
  : `node_modules/${name}`;

/** The package lives under `packages/gateway` of a git repository whose root is
 * above it, as the real checkout does. The evidence path is only meaningfully
 * "outside the package tree" when the git directory is not inside that tree. */
async function makeRepo() {
  const repo = await mkdtemp(join(tmpdir(), "tron-pi-sdk-update-"));
  const root = join(repo, "packages", "gateway");
  await mkdir(root, { recursive: true });
  const dependencies = Object.fromEntries(DIRECT_PI_PACKAGES.map((name) => [name, currentVersion]));
  const packages = { "": { dependencies } };
  for (const name of PI_PACKAGES) {
    const nested = !DIRECT_PI_PACKAGES.includes(name);
    packages[lockPath(name, nested)] = { version: currentVersion, resolved: tarball(name).replace(version, currentVersion), ...(nested ? {} : { integrity }) };
  }
  await writeFile(join(root, "package.json"), JSON.stringify({ name: "fixture", private: true, dependencies }));
  await writeFile(join(root, "package-lock.json"), JSON.stringify({ lockfileVersion: 3, packages }));
  await writeFile(join(root, "pi-sdk-baseline.json"), JSON.stringify({ schema: 1, rollbackVersion: "0.84.0" }));
  await writeFile(join(repo, ".gitignore"), "node_modules/\n");
  execFileSync("git", ["init", "-q"], { cwd: repo });
  execFileSync("git", ["add", ".gitignore", "packages/gateway/package.json", "packages/gateway/package-lock.json", "packages/gateway/pi-sdk-baseline.json"], { cwd: repo });
  execFileSync("git", ["-c", "user.name=Tron Test", "-c", "user.email=tron-test@example.invalid", "commit", "-qm", "fixture"], { cwd: repo });
  return { repo, root };
}

const changelogFixture = `# Changelog

## [1.3.0] - 2026-11-01

### Fixed

- Released after the target.

## [1.2.3] - 2026-10-05

### Fixed

- The target release.

## [1.2.0] - 2026-09-20

### New Features

- Inside the range.

## [Unreleased]

- Not a release yet.

## [1.0.0] - 2026-08-01

### New Features

- The lower bound itself.
`;

/** Stage the installed tree the fake npm's successful install would leave, so
 * post-install validation and the changelog extract read a real package. */
async function stageInstalledTree(root, changelog = changelogFixture) {
  // `null` stages the installed tree a package that publishes no CHANGELOG.md leaves.
  for (const name of PI_PACKAGES) {
    const packageRoot = join(root, lockPath(name, !DIRECT_PI_PACKAGES.includes(name)));
    await mkdir(packageRoot, { recursive: true });
    const manifest = { name, version: currentVersion, ...(name === "@earendil-works/pi-coding-agent" ? { bin: { pi: "dist/bundle/cli.js" } } : {}) };
    await writeFile(join(packageRoot, "package.json"), JSON.stringify(manifest));
  }
  const agentRoot = join(root, lockPath("@earendil-works/pi-coding-agent"));
  await mkdir(join(agentRoot, "dist", "bundle"), { recursive: true });
  await writeFile(join(agentRoot, "dist", "bundle", "cli.js"), "#!/usr/bin/env node\n");
  await chmod(join(agentRoot, "dist", "bundle", "cli.js"), 0o755);
  if (changelog !== null) await writeFile(join(agentRoot, "CHANGELOG.md"), changelog);
  await mkdir(join(root, "node_modules", ".bin"), { recursive: true });
  await symlink("../@earendil-works/pi-coding-agent/dist/bundle/cli.js", join(root, "node_modules", ".bin", "pi"));
}

/** The fake npm lives inside the repository's private directory, outside the
 * working tree, so `git status` reports only what `runUpdate` itself touched. */
async function fakeNpm(repo, mode = "success") {
  const tooling = join(repo, ".git", "fixture-tooling");
  await mkdir(tooling, { recursive: true });
  const log = join(tooling, "fake-npm.log");
  const script = join(tooling, "fake-npm.mjs");
  await writeFile(script, `#!/usr/bin/env node
import { appendFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
const args = process.argv.slice(2); const log = ${JSON.stringify(log)}; const mode = ${JSON.stringify(mode)};
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

test("refuses dirty manifest state before any metadata request", async () => {
  const { repo, root } = await makeRepo();
  try {
    await writeFile(join(root, "package.json"), "dirty");
    const { script, log } = await fakeNpm(repo);
    assert.throws(() => runUpdate({ gatewayDir: root, version, npmBin: script }), /uncommitted changes/);
    assert.equal(await readFile(log, "utf8").catch(() => ""), "");
  } finally { await cleanup(repo); }
});

test("rejects mixed provenance before install", async () => {
  const { repo, root } = await makeRepo();
  try {
    const { script, log } = await fakeNpm(repo, "git-mismatch");
    assert.throws(() => runUpdate({ gatewayDir: root, version, npmBin: script }), /mixed gitHead/);
    assert.equal((await readFile(log, "utf8")).split("\n").filter(Boolean).length, PI_PACKAGES.length);
    assert.doesNotMatch(await readFile(log, "utf8"), /^install/m);
  } finally { await cleanup(repo); }
});

test("compares preflight integrity with resulting top-level lock metadata", async () => {
  const { repo, root } = await makeRepo();
  try {
    const originalPackage = await readFile(join(root, "package.json"));
    const originalLock = await readFile(join(root, "package-lock.json"));
    const { script } = await fakeNpm(repo, "integrity-mismatch");
    assert.throws(() => runUpdate({ gatewayDir: root, version, npmBin: script }), /preflight integrity disagrees/);
    assert.deepEqual(await readFile(join(root, "package.json")), originalPackage);
    assert.deepEqual(await readFile(join(root, "package-lock.json")), originalLock);
  } finally { await cleanup(repo); }
});

test("restores manifests and runs npm ci after failed install", async () => {
  const { repo, root } = await makeRepo();
  try {
    const originalPackage = await readFile(join(root, "package.json"));
    const originalLock = await readFile(join(root, "package-lock.json"));
    const { script, log } = await fakeNpm(repo, "install-fail");
    assert.throws(() => runUpdate({ gatewayDir: root, version, npmBin: script }), /restored package\.json\/package-lock\.json and ran npm ci/);
    assert.deepEqual(await readFile(join(root, "package.json")), originalPackage);
    assert.deepEqual(await readFile(join(root, "package-lock.json")), originalLock);
    assert.match(await readFile(log, "utf8"), /ci --engine-strict/);
    assert.equal(await readFile(join(root, "node_modules/recovered"), "utf8"), "baseline\n");
  } finally { await cleanup(repo); }
});

test("reports both update and recovery failures", async () => {
  const { repo, root } = await makeRepo();
  try {
    const { script } = await fakeNpm(repo, "recovery-fail");
    assert.throws(() => runUpdate({ gatewayDir: root, version, npmBin: script }), /npm install.*update failed and recovery was incomplete.*npm ci recovery/);
  } finally { await cleanup(repo); }
});

test("snapshots the current package version as rollback metadata before install", async () => {
  const { repo, root } = await makeRepo();
  try {
    await stageInstalledTree(root);
    const { script } = await fakeNpm(repo);
    runUpdate({ gatewayDir: root, version, npmBin: script });
    assert.deepEqual(JSON.parse(await readFile(join(root, "pi-sdk-baseline.json"), "utf8")), { schema: 1, rollbackVersion: currentVersion });
  } finally { await cleanup(repo); }
});

test("runs metadata, native install, coherence, and signature audit in order", async () => {
  const { repo, root } = await makeRepo();
  try {
    await stageInstalledTree(root);
    const { script, log } = await fakeNpm(repo);
    const result = runUpdate({ gatewayDir: root, version, npmBin: script });
    const commands = (await readFile(log, "utf8")).trim().split("\n");
    assert.equal(commands.slice(0, PI_PACKAGES.length).every((command) => command.startsWith("view ")), true);
    assert.match(commands[PI_PACKAGES.length], /^install /);
    assert.match(commands[PI_PACKAGES.length + 1], /^audit signatures /);
    assert.equal(result.metadata.length, PI_PACKAGES.length);
  } finally { await cleanup(repo); }
});

test("extracts exactly the released changelog sections between the two versions", () => {
  const delta = extractChangelogDelta(changelogFixture, currentVersion, version);
  assert.match(delta, /## \[1\.2\.3\]/u);
  assert.match(delta, /## \[1\.2\.0\]/u);
  assert.doesNotMatch(delta, /## \[1\.3\.0\]/u, "a release after the target is not part of this update's inventory");
  assert.doesNotMatch(delta, /## \[1\.0\.0\]/u, "the current version is already in use, so its notes are not a delta");
  assert.doesNotMatch(delta, /Not a release yet\./u, "an unreleased section is not a release's notes");
  assert.match(delta, /- Inside the range\./u, "the section body is kept, not just its heading");
  assert.equal(compareVersions("1.2.0-beta.1", "1.2.0"), -1, "a prerelease sorts before its release");
  assert.equal(compareVersions("1.2.0-beta.10", "1.2.0-beta.9"), 1, "numeric prerelease identifiers compare numerically");
  assert.equal(compareVersions("1.2.0-rc-1", "1.2.0-rc-2"), -1, "a hyphen inside the prerelease is not a version separator");
  assert.equal(compareVersions("1.2.0-beta", "1.2.0-beta.1"), -1, "a shorter prerelease loses when its identifiers match");
  assert.equal(compareVersions("1.2.0-alpha", "1.2.0-beta"), -1, "alphanumeric prerelease identifiers compare as strings");
  assert.throws(() => extractChangelogDelta(changelogFixture, "1.3.0", "1.3.0"), /no release section/u);
  assert.throws(() => extractChangelogDelta(changelogFixture, version, "^1.3.0"), /exact semver bounds/u);
});

test("writes the changelog delta into this run's evidence outside the checkout", async () => {
  const { repo, root } = await makeRepo();
  try {
    await stageInstalledTree(root);
    const { script } = await fakeNpm(repo);
    const result = runUpdate({ gatewayDir: root, version, npmBin: script });
    // `git rev-parse --absolute-git-dir` resolves symlinks (`/var` on macOS is
    // `/private/var`), so both sides are resolved before they are compared.
    const gitDir = realpathSync(join(repo, ".git"));
    const resolvedRoot = realpathSync(root);
    assert.equal(execFileSync("git", ["-C", root, "rev-parse", "--absolute-git-dir"], { encoding: "utf8" }).trim(), gitDir);
    assert.equal(resolvedRoot.startsWith(`${gitDir}/`), false, "the fixture's git directory is above the package tree, so the path assertion below is real");
    assert.equal(result.changelog.from, currentVersion);
    assert.equal(result.changelog.to, version);
    assert.equal(result.changelog.path, changelogEvidencePath(root, currentVersion, version));
    assert.equal(result.changelog.path.startsWith(`${join(gitDir, "work")}/`), true, "evidence lands under the git directory's work tree");
    assert.equal(result.changelog.path.startsWith(`${resolvedRoot}/`), false, "evidence is never written into the package tree");
    const changed = execFileSync("git", ["-C", root, "status", "--porcelain"], { encoding: "utf8" }).split("\n").filter(Boolean)
      .map((entry) => entry.slice(3));
    assert.deepEqual(changed, ["packages/gateway/pi-sdk-baseline.json"], "the update rewrites only its owned manifests");
    const owned = new Set(["packages/gateway/package.json", "packages/gateway/package-lock.json", "packages/gateway/pi-sdk-baseline.json"]);
    assert.equal(changed.every((entry) => owned.has(entry)), true, "recording the evidence adds nothing to the checkout");
    const evidence = await readFile(result.changelog.path, "utf8");
    assert.match(evidence, /## \[1\.2\.3\] - 2026-10-05/u);
    assert.match(evidence, /## \[1\.2\.0\] - 2026-09-20/u);
    assert.doesNotMatch(evidence, /## \[1\.3\.0\]/u);
    assert.match(evidence, /Source: @earendil-works\/pi-coding-agent@1\.2\.3 CHANGELOG\.md/u);
  } finally { await cleanup(repo); }
});

test("refuses an update whose installed package publishes no changelog", async () => {
  const { repo, root } = await makeRepo();
  try {
    await stageInstalledTree(root, null);
    const { script } = await fakeNpm(repo);
    assert.throws(() => runUpdate({ gatewayDir: root, version, npmBin: script }), /has no CHANGELOG\.md, so this update has no upstream inventory to record/u);
    assert.equal(await readFile(join(root, "node_modules", "recovered"), "utf8"), "baseline\n", "the missing changelog restores the disposable installed tree");
  } finally { await cleanup(repo); }
});

test("carries the accepted one-way delta ledger forward across an update", async () => {
  const { repo, root } = await makeRepo();
  try {
    const delta = { store: "mcp-auth", from: "0.99.1", to: currentVersion, reason: "accepted one-way re-key", rollbackState: "needs-auth", credentialKey: { from: "{url}", to: "{namespace}|{url}" } };
    await writeFile(join(root, "pi-sdk-baseline.json"), JSON.stringify({ schema: 1, rollbackVersion: "0.84.0", knownOneWayDeltas: [delta] }));
    execFileSync("git", ["-C", repo, "add", "packages/gateway/pi-sdk-baseline.json"]);
    execFileSync("git", ["-C", repo, "-c", "user.name=Tron Test", "-c", "user.email=tron-test@example.invalid", "commit", "-qm", "ledger"]);
    await stageInstalledTree(root);
    const { script } = await fakeNpm(repo);
    runUpdate({ gatewayDir: root, version, npmBin: script });
    assert.deepEqual(JSON.parse(await readFile(join(root, "pi-sdk-baseline.json"), "utf8")), { schema: 1, rollbackVersion: currentVersion, knownOneWayDeltas: [delta] });
  } finally { await cleanup(repo); }
});

test("refuses to report an update whose changelog carries no delta", async () => {
  const { repo, root } = await makeRepo();
  try {
    await stageInstalledTree(root, "# Changelog\n\n## [1.0.0] - 2026-08-01\n\n- Nothing new.\n");
    const { script } = await fakeNpm(repo);
    assert.throws(() => runUpdate({ gatewayDir: root, version, npmBin: script }), /restored package\.json\/package-lock\.json and ran npm ci/u);
  } finally { await cleanup(repo); }
});
