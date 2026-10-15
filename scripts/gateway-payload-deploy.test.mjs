import { strict as assert } from "node:assert";

import { chmod, cp, lstat, mkdir, mkdtemp, readFile, realpath, rename, rm, symlink, writeFile } from "node:fs/promises";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execFile } from "node:child_process";

import { promisify } from "node:util";
import { tmpdir } from "node:os";
import { after, test } from "node:test";

import {
  payloadFingerprint, buildSourcePayload, stagePayload, runBounded,
  captureLocalProcess, captureLocalListenerProcess, waitForDrainCompletion,
} from "./gateway-payload-deploy.mjs";
import { spawn } from "node:child_process";
import { once } from "node:events";

// One chmod process per tree: a per-entry walk of a fixture's ~9k npm files
// costs more than the test it cleans up after.
async function makeTreeWritable(root) {
  await runBounded("/bin/chmod", ["-R", "u+w", root], { timeoutMs: 30_000 }).catch(() => {});
}

// Fixture bases are built once per file and never handed to a test. Each test
// receives a copy-on-write clone (`cp -c` keeps modes and relative symlinks), so
// one test's mutation cannot reach a later test or the base.
let fixtureBaseRootPromise;
const fixtureBases = new Map();
after(async () => {
  if (fixtureBaseRootPromise) await rm(await fixtureBaseRootPromise, { recursive: true, force: true });
});

async function cloneFixture(name, root, build) {
  if (!fixtureBases.has(name)) {
    fixtureBaseRootPromise ??= mkdtemp(join(tmpdir(), "tron-payload-fixture-bases-"));
    fixtureBases.set(name, (async () => {
      const base = join(await fixtureBaseRootPromise, name);
      await build(base);
      return base;
    })());
  }
  const base = await fixtureBases.get(name);
  await mkdir(root, { recursive: true });
  await runBounded("/bin/cp", ["-c", "-R", join(base, "payload"), join(root, "payload")], { timeoutMs: 120_000 });
  return join(root, "payload");
}

let pinnedNpmRootPromise;
async function pinnedNpmRoot() {
  if (pinnedNpmRootPromise) return pinnedNpmRootPromise;
  pinnedNpmRootPromise = (async () => {
    const repoRoot = fileURLToPath(new URL("../", import.meta.url));
    const nodeVersion = (await readFile(join(repoRoot, ".node-version"), "utf8")).trim();
    assert.equal(process.version, `v${nodeVersion}`, "payload tests require the repository-pinned Node version");
    // The npm tree that ships with the running pinned Node (asserted above); the
    // digest below proves it is the archive tree. No separate toolchain install
    // is a hidden prerequisite (a missing .ci-tools failed tests 15-22 together).
    const nodeRoot = process.env.TRON_NODE_ROOT
      ? resolve(process.env.TRON_NODE_ROOT)
      : resolve(dirname(process.execPath), "..");
    const archiveNpmRoot = join(nodeRoot, "lib", "node_modules", "npm");
    let npmRoot = archiveNpmRoot;
    try { await lstat(npmRoot); }
    catch (error) {
      if (error?.code !== "ENOENT" || !nodeRoot.includes("/Contents/Resources/Gateway/runtime")) throw error;
      // The signed app runtime keeps the verified npm tree next to its Node binary.
      npmRoot = join(nodeRoot, `npm-${process.arch}`);
      await lstat(npmRoot);
    }
    const toolchain = await readFile(fileURLToPath(new URL("../config/ci-toolchain.env", import.meta.url)), "utf8");
    const expected = toolchain.match(/^TRON_NODE_NPM_TREE_SHA256=([a-f0-9]{64})$/mu)?.[1];
    assert.ok(expected, "pinned Node npm-tree digest is missing from config/ci-toolchain.env");
    const actual = (await execFileAsync("python3", [
      fileURLToPath(new URL("./hash-npm-runtime.py", import.meta.url)), npmRoot,
    ])).stdout.trim();
    assert.equal(actual, expected, `npm tree at ${npmRoot} must match the pinned Node archive tree`);
    return npmRoot;
  })();
  return pinnedNpmRootPromise;
}

async function addRuntimeNodeAliases(root) {
  const piPackage = join(root, "app", "node_modules", "@earendil-works", "pi-coding-agent");
  const piCli = join(piPackage, "dist", "cli.js");
  await mkdir(dirname(piCli), { recursive: true });
  await mkdir(join(root, "app", "node_modules", ".bin"), { recursive: true });
  await writeFile(join(piPackage, "package.json"), JSON.stringify({ name: "@earendil-works/pi-coding-agent", bin: { pi: "dist/cli.js" } }));
  await writeFile(piCli, "#!/usr/bin/env node\n");
  await chmod(piCli, 0o755);
  try {
    await symlink("../@earendil-works/pi-coding-agent/dist/cli.js", join(root, "app", "node_modules", ".bin", "pi"));
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
  }
  const xcodegen = join(root, "runtime", "xcodegen", "bin", "xcodegen");
  await mkdir(dirname(xcodegen), { recursive: true });
  await writeFile(xcodegen, `#!/bin/sh\nprintf 'Version: 2.45.3\\n'\n#${"x".repeat(1_048_576)}\n`);
  await chmod(xcodegen, 0o755);
  const basePreset = join(root, "runtime", "xcodegen", "share", "xcodegen", "SettingPresets", "base.yml");
  await mkdir(dirname(basePreset), { recursive: true });
  await writeFile(basePreset, "PRODUCT_NAME: $TARGET_NAME\n");
  const officialNpmRoot = await pinnedNpmRoot();
  for (const architecture of ["arm64", "x64"]) {
    const directory = join(root, "runtime", `bin-${architecture}`);
    const npmRoot = join(root, "runtime", `npm-${architecture}`);
    await mkdir(directory, { recursive: true });
    await runBounded("/bin/cp", ["-c", "-R", officialNpmRoot, npmRoot], { timeoutMs: 120_000 });
    await symlink(`../node-${architecture}`, join(directory, "node"));
    await symlink(`../npm-${architecture}/bin/npm-cli.js`, join(directory, "npm"));
    await symlink("../../app/node_modules/.bin/pi", join(directory, "pi"));
  }
}

const execFileAsync = promisify(execFile);

// macOS 15 refuses rename(2) of a directory its non-root owner cannot write
// (EACCES); macOS 26 permits it, so a plain run on a newer host cannot see the
// kernel check. Enforce that rule on every directory rename the deploy module
// makes for the duration of one operation.

// Entry modes keyed by path relative to root. Links are recorded without a mode:
// their own inode mode is not a payload authority and must not be touched.

// Representative payload entries: executables with and without owner-only bits,
// setuid/setgid, read-only and unreadable files, nested directories with restrictive
// modes, and an in-tree link. An out-of-tree link target lives beside the root.

// Sealing sets exactly these modes and never follows or re-modes a link: an
// out-of-tree target keeps its mode, and a refused escaping link leaves the tree
// unsealed instead of half-sealed.

// Sealing refuses an unsupported entry before any mode changes. Unsealing opens
// each directory before reading it, so it may already have opened directories
// when it refuses; cleanup removes that tree either way. A failed staging tree
// with an unreadable directory must still unseal, or cleanup cannot remove it.

// Modes are not part of the fingerprint, so sealing a real payload must keep its
// fingerprint, and its runtime executables must stay executable for admission.

// Failure modes (#116), each observed through the real publication paths:
// 1. stagePayload freezes its staging root before renaming it into versions/,
//    so macOS 15 refuses the rename and dev/Stable staging cannot publish.
// 2. buildSourcePayload regresses to the same freeze-then-rename order.
// 3. keeping the root writable across the rename but not sealing it afterwards
//    publishes a version whose root stays writable.
// 4. any nested directory or file stays writable after publication.

// A source build that compiles to an import outside app/ must fail before it
// is published, so it never becomes a selectable candidate.

async function makePreflightFixture(root) {
  return cloneFixture("preflight", root, buildPreflightFixture);
}

async function buildPreflightFixture(root) {
  const payload = join(root, "payload");
  await mkdir(join(payload, "app", "dist"), { recursive: true });
  await mkdir(join(payload, "app", "scripts"), { recursive: true });
  await mkdir(join(payload, "app", "node_modules"), { recursive: true });
  await mkdir(join(payload, "app", "node_modules", "node-pty", "prebuilds", `darwin-${process.arch}`), { recursive: true });
  await mkdir(join(payload, "runtime"), { recursive: true });
  await writeFile(join(payload, "app", "dist", "index.js"), "x".repeat(1_024));
  await writeFile(join(payload, "app", "dist", "version.js"), "export const PROTOCOL_VERSION = 8; export const MIN_PROTOCOL_VERSION = 8;\n");
  await writeFile(join(payload, "app", "package.json"), "{}\n");
  await writeFile(join(payload, "app", "package-lock.json"), "{}\n");
  await writeFile(join(payload, "app", "PushService.xcconfig"), "TRON_PUSH_SERVICE_ORIGIN = https:/$()/push.example.test\n");
  await writeFile(join(payload, "app", "scripts", "ensure-node-pty-helper.mjs"), "// helper\n");
  await writeFile(join(payload, "app", "scripts", "gateway-payload-deploy.mjs"), "// updater\n");
  await writeFile(join(payload, "app", "node_modules", "node-pty", "prebuilds", `darwin-${process.arch}`, "pty.node"), "native-fixture\n");
  await writeFile(join(payload, "runtime", "node-arm64"), "n".repeat(1_048_576));
  await writeFile(join(payload, "runtime", "node-x64"), "n".repeat(1_048_576));
  await chmod(join(payload, "runtime", "node-arm64"), 0o755);
  await chmod(join(payload, "runtime", "node-x64"), 0o755);
  await addRuntimeNodeAliases(payload);
  const fingerprint = await payloadFingerprint(payload);
  await writeFile(join(payload, "manifest.json"), JSON.stringify({
    schema: 1, kind: "tron-gateway-payload", channel: "stable", version: "preflight",
    gatewayVersion: "1", protocolVersion: "8", minProtocolVersion: "8", nodeVersion: "22",
    sourceRevision: "0123456789abcdef0123456789abcdef01234567", runtimeEpoch: "01234567-89ab-cdef-0123-456789abcdef",
    payloadFingerprint: fingerprint, dependencyTreeCoverage: "app/** and runtime/** regular files",
  }));
  return payload;
}

// Failure mode (#107): `scripts/tron dev` computes the stage arguments in
// tron-dev-state.mjs `candidate-source` while this module owns the manifest
// validator; when the two drift (a short or `-dirty` revision), start/restart
// cannot stage any candidate. Run the real stage CLI with exactly what
// tron-dev passes, from a dirty and a clean checkout.
test("tron-dev candidate source stages through the real payload manifest validator", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-dev-candidate-stage-"));
  try {
    const payload = await makePreflightFixture(join(root, "source"));
    const manifestPath = join(payload, "manifest.json");
    await writeFile(manifestPath, JSON.stringify({ ...JSON.parse(await readFile(manifestPath, "utf8")), channel: "dev" }));
    const checkout = join(root, "checkout");
    await mkdir(checkout);
    await writeFile(join(checkout, "tracked.ts"), "export {};\n");
    await execFileAsync("git", ["init", "-q"], { cwd: checkout });
    await execFileAsync("git", ["add", "."], { cwd: checkout });
    await execFileAsync("git", ["-c", "user.email=fixture@example.test", "-c", "user.name=Fixture", "commit", "-q", "-m", "fixture"], { cwd: checkout });
    const head = (await execFileAsync("git", ["rev-parse", "HEAD"], { cwd: checkout })).stdout.trim();
    const helper = new URL("./tron-dev-state.mjs", import.meta.url).pathname;
    const deploy = new URL("./gateway-payload-deploy.mjs", import.meta.url).pathname;
    const home = join(root, "dev-home");
    await writeFile(join(checkout, "tracked.ts"), "export const edited = true;\n");
    for (const expectedDirty of ["true", "false"]) {
      if (expectedDirty === "false") await execFileAsync("git", ["checkout", "-q", "--", "tracked.ts"], { cwd: checkout });
      const [revision, dirty, version] = (await execFileAsync(process.execPath, [helper, "candidate-source", checkout])).stdout.trim().split(" ");
      assert.equal(dirty, expectedDirty);
      const { stdout } = await execFileAsync(process.execPath, [
        deploy, "stage", "--channel", "dev", "--home", home, "--source", payload, "--version", version, "--source-revision", revision,
      ]);
      const staged = JSON.parse(stdout).manifest;
      assert.equal(staged.sourceRevision, head);
      assert.equal(staged.version, version);
    }
  } finally {
    await makeTreeWritable(root);
    await rm(root, { recursive: true, force: true });
  }
});

// #722: the installed apply CLI must use today's trusted source builder, not
// yesterday's copied build implementation. The fixture builder stages a real
// immutable payload; the installed helper still owns credential and promotion
// admission. No listener, launcher, or live home is involved.
test("source apply uses the trusted checkout builder and retains installed promotion admission", async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-source-updater-")));
  try {
    const payload = await makePreflightFixture(join(root, "source-payload"));
    const checkout = join(root, "checkout");
    const home = join(root, "home");
    const scratch = join(root, "tmp");
    const deploy = fileURLToPath(new URL("./gateway-payload-deploy.mjs", import.meta.url));
    await mkdir(scratch);
    for (const marker of ["packages/gateway/package.json", "packages/gateway/package-lock.json",
      "packages/gateway/scripts/ensure-node-pty-helper.mjs", "scripts/gateway-install-inputs.mjs"]) {
      await mkdir(dirname(join(checkout, marker)), { recursive: true });
      await writeFile(join(checkout, marker), "{}\n");
    }
    const sourceBuilder = join(checkout, "scripts/gateway-payload-deploy.mjs");
    await writeFile(sourceBuilder, `
      import { stagePayload } from ${JSON.stringify(new URL("./gateway-payload-deploy.mjs", import.meta.url).href)};
      export async function buildSourcePayload({ paths, candidateVersion }) {
        return stagePayload({ home: paths.home, channel: paths.channel,
          source: ${JSON.stringify(payload)}, version: candidateVersion });
      }
      export function applyPayload() { throw new Error("source must not own apply"); }
    `);
    await mkdir(join(home, "gateway"), { recursive: true });
    await writeFile(join(home, "gateway/update-config.json"), JSON.stringify({
      schema: 1, kind: "tron-gateway-update-config", sourceRoot: checkout,
      updatedAt: new Date().toISOString(),
    }));
    const channelRoot = join(home, "gateway/payloads/stable");
    const environment = {
      PATH: process.env.PATH, HOME: home, TMPDIR: scratch,
      TRON_DATA_DIR: home, TRON_GATEWAY_SUPERVISED: "1", TRON_GATEWAY_CHANNEL: "stable",
      TRON_GATEWAY_HEALTH_HOST: "127.0.0.1",
    };
    const invoke = version => execFileAsync(process.execPath, [deploy, "apply", "--channel", "stable",
      "--mode", "source", "--candidate-version", version, "--command-id", `source-build-${version}`],
    { env: environment, timeout: 120_000 });
    // It must reach the installed credential gate after the source's new build
    // behavior has published a candidate. The old helper fails before staging.
    await assert.rejects(invoke("new-builder"), error => {
      assert.match(error.stderr, /local Gateway credential is missing or unsafe/);
      return true;
    });
    const candidate = JSON.parse(await readFile(join(channelRoot, "versions/new-builder/manifest.json"), "utf8"));
    assert.equal(candidate.version, "new-builder");
    assert.equal(candidate.payloadFingerprint, await payloadFingerprint(join(channelRoot, "versions/new-builder")));
    assert.equal((await lstat(join(channelRoot, "versions/new-builder"))).mode & 0o222, 0);
    await assert.rejects(readFile(join(channelRoot, "current.json")), { code: "ENOENT" });
    let progress = JSON.parse(await readFile(join(channelRoot, "update-progress.json"), "utf8"));
    assert.equal(progress.state, "failure");
    assert.equal(progress.commandId, "source-build-new-builder");
    const records = (await readFile(join(home, "logs/deploy.jsonl"), "utf8")).trim().split("\n").map(JSON.parse);
    const builderRecord = records.find(record => record.event === "deploy.source-builder");
    assert.ok(builderRecord, "the build owner must be diagnosable in the deployment timeline");
    assert.equal(builderRecord.commandId, "source-build-new-builder");
    assert.match(builderRecord.builderSha256, /^[a-f0-9]{64}$/);

    // Even a source builder returning a real but subsequently corrupted artifact
    // cannot bypass the installed helper's fingerprint check or publish selection.
    await writeFile(join(home, "gateway/local-auth.json"), JSON.stringify({
      version: 2, purpose: "local-wrapper-health", bearerToken: "f".repeat(32), lastUpdated: new Date().toISOString(),
    }), { mode: 0o600 });
    await writeFile(sourceBuilder, `
      import { stagePayload } from ${JSON.stringify(new URL("./gateway-payload-deploy.mjs", import.meta.url).href)};
      import { chmod, writeFile } from "node:fs/promises";
      import { join } from "node:path";
      export async function buildSourcePayload({ paths, candidateVersion }) {
        const result = await stagePayload({ home: paths.home, channel: paths.channel,
          source: ${JSON.stringify(payload)}, version: candidateVersion });
        const file = join(result.root, "app/dist/index.js");
        await chmod(file, 0o600);
        await writeFile(file, "tampered".repeat(200));
        await chmod(file, 0o444);
        return result;
      }
    `);
    await assert.rejects(invoke("corrupt-builder"), error => {
      assert.match(error.stderr, /fingerprint/);
      return true;
    });
    await assert.rejects(readFile(join(channelRoot, "current.json")), { code: "ENOENT" });
    progress = JSON.parse(await readFile(join(channelRoot, "update-progress.json"), "utf8"));
    assert.equal(progress.state, "failure");
    assert.equal(progress.commandId, "source-build-corrupt-builder");
  } finally {
    await makeTreeWritable(root);
    await rm(root, { recursive: true, force: true });
  }
});

// Failure mode (#124): `scripts/tron dev handoff` admits the selected candidate
// from its clean source record before this helper takes the dev operation
// lock. A Debug apply or rollback accepted from iOS in between can select
// another (dirty or unrecorded) payload that is running and ready, so the
// pre/post identity proof passes for it. The handoff must copy only the exact
// admitted version and fingerprint, re-checked under the lock.

// #515: stage Debug on the installed signed runtime only when its validated
// Node contract matches; the handoff continues to compare runtime bytes exactly.

// Native fixtures model changed signature bytes without requiring signing keys.
// All Mach-O magic forms and extensionless executables share the same stage owner.

test("runBounded settles at the kill deadline when a descendant retains pipes", async () => {
  const started = Date.now();
  await assert.rejects(
    runBounded(process.execPath, ["-e", "require('node:child_process').spawn(process.execPath,['-e','setInterval(()=>{},100000)'],{stdio:'inherit'}); setInterval(()=>{},100000)"], { timeoutMs: 50, maxOutputBytes: 1024 }),
    /timed out/
  );
  assert.ok(Date.now() - started < 4_000);
});

// #729: an old Gateway that finished its shutdown but stayed inside its own
// exit kept the deploy at `draining` forever. Each case below is a real
// process with a real TCP listener, read through the deploy's own ps/lsof
// probes. The old Gateway's port stays open while it drains accepted work and
// closes only when its shutdown begins.
async function oldGatewayFixture({ releaseAfterMs, then }) {
  const program = `
    const server = require("node:net").createServer().listen(0, "127.0.0.1", () => {
      process.stdout.write(server.address().port + "\\n");
      setTimeout(() => server.close(() => {
        if (${JSON.stringify(then)} === "exit") process.exit(0);
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);
      }), ${releaseAfterMs});
    });`;
  const child = spawn(process.execPath, ["-e", program], { stdio: ["ignore", "pipe", "ignore"] });
  const exited = once(child, "exit");
  const [line] = await once(child.stdout, "data");
  const port = Number(String(line).trim());
  let identity;
  for (let attempt = 0; attempt < 50 && !identity; attempt++) {
    identity = await captureLocalListenerProcess(port);
    if (!identity) await new Promise((resolve) => setTimeout(resolve, 20));
  }
  assert.equal(identity?.pid, child.pid);
  return { child, exited, port, identity };
}

async function waitWithin(promise, boundMs, label) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${label} did not settle within ${boundMs} ms`)), boundMs); })]);
  } finally { clearTimeout(timer); }
}

for (const scenario of [
  { name: "a draining old Gateway is never killed while it still holds its port", releaseAfterMs: 2_500, then: "exit", killed: false },
  { name: "an old Gateway that exits after releasing its port is not signalled", releaseAfterMs: 100, then: "exit", killed: false },
  { name: "an old Gateway stuck in exit after releasing its port is killed once its stall limit passes", releaseAfterMs: 100, then: "hang", killed: true },
]) {
  test(`drain wait: ${scenario.name}`, async () => {
    const fixture = await oldGatewayFixture(scenario);
    const stalls = [];
    try {
      await waitWithin(waitForDrainCompletion(fixture.identity, (pid) => captureLocalProcess(pid), undefined, {
        readListener: () => captureLocalListenerProcess(fixture.port),
        stallLimitMs: 1_000,
        onExitStalled: (stall) => stalls.push(stall),
      }), 20_000, "drain wait");
      const [code, signal] = await waitWithin(fixture.exited, 5_000, "old Gateway exit");
      if (scenario.killed) {
        assert.equal(signal, "SIGKILL");
        assert.equal(stalls.length, 1);
        assert.equal(stalls[0].pid, fixture.identity.pid);
        assert.ok(stalls[0].releasedForMs >= 1_000);
      } else {
        assert.deepEqual([code, signal], [0, null]);
        assert.deepEqual(stalls, []);
      }
    } finally {
      if (fixture.child.exitCode === null && fixture.child.signalCode === null) fixture.child.kill("SIGKILL");
    }
  });
}
