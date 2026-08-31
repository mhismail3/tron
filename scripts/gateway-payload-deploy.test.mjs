import { strict as assert } from "node:assert";
import { chmod, cp, mkdir, mkdtemp, readFile, readlink, rename, rm, symlink, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import {
  deploymentTransition,
  deploymentTimeoutMs,
  commandTimeoutMs,
  publishSelection,
  rollbackSelection,
  rollbackSelectionAndClearAttempt,
  resolveDeploymentHost,
  isTailscaleAddress,
  protocolHandshakeCompatible,
  validateLocalCredentialDocument,
  loadRollbackTarget,
  validateApplyRequest,
  applyPayload,
  sourceBuildCommands,
  resolveNpmCommand,
  validateUpdateConfigDocument,
  validatePushServiceConfigurationText,
  validatePayload,
  payloadFingerprint,
  buildSourcePayload,
  resolveSourcePayloadBase,
  copyValidatedPayloadBase,
  preserveSignedNativeArtifacts,
  preflightPayload,
  proveDebugHandoffIdentity,
  handoffDebugCandidate,
  healthMatchesCandidate,
  stableSupervisorKickstartSpec,
  kickstartStableSupervisor,
  verifyReplacementIdentity,
  waitForReplacement,
  waitForDrainedReplacement,
  restoreAndVerifyReplacement,
  waitForDrainCompletion,
  captureLocalProcess,
  captureLocalListenerProcess,
  confirmAndClearPendingAttempt,
  verifyIdempotentPromotion,
  requireBundledPayload,
  resolveRecoveryPayload,
  restoreSelectionStateAndClearAttempt,
  stagePayload,
  stagedCandidate,
  runBounded,
  PINNED_XCODEGEN_VERSION,
} from "./gateway-payload-deploy.mjs";

const repositoryRoot = dirname(dirname(fileURLToPath(import.meta.url)));

test("deployment timeout defaults to a valid bounded millisecond value", () => {
  assert.equal(deploymentTimeoutMs({}), 60_000);
  assert.equal(deploymentTimeoutMs({ TRON_GATEWAY_UPDATE_TIMEOUT_MS: "120000" }), 120_000);
  assert.throws(() => deploymentTimeoutMs({ TRON_GATEWAY_UPDATE_TIMEOUT_MS: "60_000" }), /invalid update timeout/);
  assert.throws(() => deploymentTimeoutMs({ TRON_GATEWAY_UPDATE_TIMEOUT_MS: "1999" }), /invalid update timeout/);
});

test("candidate preflight XcodeGen version matches the repository pin", async () => {
  const toolchain = await readFile(join(repositoryRoot, "config", "ci-toolchain.env"), "utf8");
  assert.match(toolchain, new RegExp(`^TRON_CI_XCODEGEN_VERSION=${PINNED_XCODEGEN_VERSION}$`, "mu"));
});

test("command timeout defaults to a valid bounded millisecond value", () => {
  assert.equal(commandTimeoutMs(undefined), 60_000);
  assert.equal(commandTimeoutMs("120000"), 120_000);
  assert.throws(() => commandTimeoutMs("60_000"), /invalid timeout/);
  assert.throws(() => commandTimeoutMs("1999"), /invalid timeout/);
});

function selection(version, payloadFingerprint = "a".repeat(64)) {
  return { schema: 1, kind: "tron-gateway-selection", channel: "stable", version, payloadFingerprint };
}

async function addRuntimeNodeAliases(root) {
  const piCli = join(root, "app", "node_modules", "@earendil-works", "pi-coding-agent", "dist", "cli.js");
  await mkdir(dirname(piCli), { recursive: true });
  await writeFile(piCli, "#!/usr/bin/env node\n");
  await chmod(piCli, 0o755);
  const xcodegen = join(root, "runtime", "xcodegen", "bin", "xcodegen");
  await mkdir(dirname(xcodegen), { recursive: true });
  await writeFile(xcodegen, `#!/bin/sh\nprintf 'Version: 2.45.3\\n'\n#${"x".repeat(1_048_576)}\n`);
  await chmod(xcodegen, 0o755);
  const basePreset = join(root, "runtime", "xcodegen", "share", "xcodegen", "SettingPresets", "base.yml");
  await mkdir(dirname(basePreset), { recursive: true });
  await writeFile(basePreset, "PRODUCT_NAME: $TARGET_NAME\n");
  for (const architecture of ["arm64", "x64"]) {
    const directory = join(root, "runtime", `bin-${architecture}`);
    await mkdir(directory, { recursive: true });
    await symlink(`../node-${architecture}`, join(directory, "node"));
    await symlink("../../app/node_modules/@earendil-works/pi-coding-agent/dist/cli.js", join(directory, "pi"));
  }
}

async function paths(root) {
  const channelRoot = join(root, "gateway", "payloads", "stable");
  return {
    channel: "stable",
    channelRoot,
    versionsRoot: join(channelRoot, "versions"),
    current: join(channelRoot, "current.json"),
    previous: join(channelRoot, "previous.json"),
    state: join(channelRoot, "deployment-state.json"),
    pending: join(channelRoot, "pending-attempt.json"),
    lock: join(channelRoot, ".update.lock"),
  };
}

test("restored selection clears a mismatched candidate attempt marker", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-payload-restore-attempt-"));
  try {
    const store = await paths(root);
    await mkdir(store.channelRoot, { recursive: true });
    const current = selection("current", "a".repeat(64));
    const previous = selection("previous", "b".repeat(64));
    const candidate = selection("candidate", "c".repeat(64));
    await writeFile(store.current, `${JSON.stringify(candidate)}\n`);
    await writeFile(store.previous, `${JSON.stringify(current)}\n`);
    await writeFile(store.pending, `${JSON.stringify({
      schema: 1, kind: "tron-gateway-pending-attempt", channel: "stable", attempt: "pending",
      version: candidate.version, payloadFingerprint: candidate.payloadFingerprint,
      previousVersion: current.version, previousFingerprint: current.payloadFingerprint,
    })}\n`);

    const lock = `${store.pending}.lock`;
    await mkdir(lock);
    let restored = false;
    const restoring = restoreSelectionStateAndClearAttempt(store, {
      current: Buffer.from(`${JSON.stringify(current)}\n`),
      previous: Buffer.from(`${JSON.stringify(previous)}\n`),
    }).then(() => { restored = true; });
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.equal(restored, false);
    assert.deepEqual(JSON.parse(await readFile(store.current, "utf8")), candidate);
    await rm(lock, { recursive: true });
    await restoring;

    assert.deepEqual(JSON.parse(await readFile(store.current, "utf8")), current);
    assert.deepEqual(JSON.parse(await readFile(store.previous, "utf8")), previous);
    await assert.rejects(readFile(store.pending), { code: "ENOENT" });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("automatic rollback switches selection and clears its attempt under the shared lock", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-payload-rollback-attempt-"));
  try {
    const store = await paths(root);
    await mkdir(store.channelRoot, { recursive: true });
    const prior = selection("prior", "a".repeat(64));
    const candidate = selection("candidate", "b".repeat(64));
    await writeFile(store.current, `${JSON.stringify(candidate)}\n`);
    await writeFile(store.previous, `${JSON.stringify(prior)}\n`);
    await writeFile(store.pending, `${JSON.stringify({
      schema: 1, kind: "tron-gateway-pending-attempt", channel: "stable", attempt: "launched",
      version: candidate.version, payloadFingerprint: candidate.payloadFingerprint,
      previousVersion: prior.version, previousFingerprint: prior.payloadFingerprint,
    })}\n`);
    const lock = `${store.pending}.lock`;
    await mkdir(lock);
    let rolledBack = false;
    const rollingBack = rollbackSelectionAndClearAttempt(store).then(() => { rolledBack = true; });
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.equal(rolledBack, false);
    await rm(lock, { recursive: true });
    await rollingBack;
    assert.deepEqual(JSON.parse(await readFile(store.current, "utf8")), prior);
    assert.deepEqual(JSON.parse(await readFile(store.previous, "utf8")), candidate);
    await assert.rejects(readFile(store.pending), { code: "ENOENT" });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("selection publication is atomic in order and rollback preserves the prior pointer", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-payload-selection-"));
  try {
    const store = await paths(root);
    const first = selection("one");
    const second = selection("two", "b".repeat(64));
    await publishSelection(store, first);
    assert.deepEqual(JSON.parse(await readFile(store.current, "utf8")), first);
    await publishSelection(store, second);
    assert.deepEqual(JSON.parse(await readFile(store.previous, "utf8")), first);
    assert.deepEqual(JSON.parse(await readFile(store.current, "utf8")), second);
    const switched = await rollbackSelection(store);
    assert.deepEqual(switched.current, first);
    assert.deepEqual(JSON.parse(await readFile(store.previous, "utf8")), second);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("tailscale host selection and restart handshake are bounded and deterministic", () => {
  const interfaces = {
    en0: [{ address: "100.100.0.2", family: "IPv4", internal: false }],
    utun9: [{ address: "100.90.0.3", family: "IPv4", internal: false }],
  };
  assert.equal(resolveDeploymentHost("tailscale", interfaces), "100.90.0.3");
  assert.equal(resolveDeploymentHost("127.0.0.1", interfaces), "127.0.0.1");
  assert.throws(() => resolveDeploymentHost("tailscale", {}), /Tailscale is not connected/);
  for (const malformed of [
    "100.64.0.999", "100.64.0.1.example", "100.63.255.255", "100.128.0.1", "100.64.0.1%en0",
    "fd7a:115c:a1e0:garbage::1", "fd7a:115c:a1e1::1", "fd7a:115c:a1e0::1%utun0",
  ]) assert.equal(isTailscaleAddress(malformed), false, malformed);
  assert.equal(protocolHandshakeCompatible({ type: "hello", protocolVersion: 4, minProtocolVersion: 4 }), true);
  assert.equal(protocolHandshakeCompatible({ type: "hello", protocolVersion: 2, minProtocolVersion: 2 }), false);
  assert.equal(protocolHandshakeCompatible({ type: "hello", protocolVersion: 4 }), false);
});

test("local credential validation is exact and fails closed", () => {
  const valid = { version: 2, bearerToken: "t".repeat(32), purpose: "local-wrapper-health", lastUpdated: "2026-04-27T00:00:00Z" };
  assert.equal(validateLocalCredentialDocument(valid), true);
  assert.equal(validateLocalCredentialDocument({ ...valid, extra: true }), false);
  assert.equal(validateLocalCredentialDocument({ ...valid, version: 1 }), false);
  assert.equal(validateLocalCredentialDocument({ ...valid, bearerToken: "short" }), false);
});

test("rollback target validation fails before changing current selection", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-payload-rollback-target-"));
  try {
    const store = await paths(root);
    const current = selection("current", "b".repeat(64));
    const prior = selection("missing", "a".repeat(64));
    await mkdir(store.channelRoot, { recursive: true });
    await writeFile(store.current, `${JSON.stringify(current)}\n`, { flag: "w" });
    await writeFile(store.previous, `${JSON.stringify(prior)}\n`, { flag: "w" });
    await assert.rejects(loadRollbackTarget(store), /ENOENT|no such file/i);
    assert.deepEqual(JSON.parse(await readFile(store.current, "utf8")), current);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("payload fingerprints include safe internal node_modules symlinks", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-payload-symlink-"));
  try {
    const versionRoot = join(root, "payload");
    await mkdir(join(versionRoot, "app", "dist"), { recursive: true });
    await mkdir(join(versionRoot, "app", "scripts"), { recursive: true });
    await mkdir(join(versionRoot, "app", "node_modules", ".bin"), { recursive: true });
    await mkdir(join(versionRoot, "runtime"), { recursive: true });
    await writeFile(join(versionRoot, "app", "dist", "index.js"), `${"x".repeat(1_024)}\n`);
    await writeFile(join(versionRoot, "app", "package.json"), "{}\n");
    await writeFile(join(versionRoot, "app", "package-lock.json"), "{}\n");
    await writeFile(join(versionRoot, "app", "PushService.xcconfig"), "TRON_PUSH_SERVICE_ORIGIN = https:/$()/push.example.test\n");
    await writeFile(join(versionRoot, "app", "scripts", "ensure-node-pty-helper.mjs"), "// helper\n");
    await writeFile(join(versionRoot, "app", "scripts", "gateway-payload-deploy.mjs"), "// updater\n");
    await writeFile(join(versionRoot, "runtime", "node-arm64"), "n".repeat(1_048_576));
    await writeFile(join(versionRoot, "runtime", "node-x64"), "n".repeat(1_048_576));
    await chmod(join(versionRoot, "runtime", "node-arm64"), 0o755);
    await chmod(join(versionRoot, "runtime", "node-x64"), 0o755);
    await addRuntimeNodeAliases(versionRoot);
    await writeFile(join(versionRoot, "manifest.json"), "{}\n");
    await payloadFingerprint(versionRoot);
    await rm(join(versionRoot, "runtime", "bin-arm64", "node"));
    await symlink("../node-x64", join(versionRoot, "runtime", "bin-arm64", "node"));
    await assert.rejects(payloadFingerprint(versionRoot), /runtime Node alias target is invalid/);
    await rm(join(versionRoot, "runtime", "bin-arm64", "node"));
    await symlink("../node-arm64", join(versionRoot, "runtime", "bin-arm64", "node"));
    await symlink("../../dist/index.js", join(versionRoot, "app", "node_modules", ".bin", "tron"));
    const withLink = await payloadFingerprint(versionRoot);
    await rm(join(versionRoot, "app", "node_modules", ".bin", "tron"));
    const withoutLink = await payloadFingerprint(versionRoot);
    assert.notEqual(withLink, withoutLink);
    await symlink("../../../../../outside", join(versionRoot, "app", "node_modules", ".bin", "escape"));
    await assert.rejects(payloadFingerprint(versionRoot), /dangling|escapes root/);

    await rm(join(versionRoot, "app", "node_modules", ".bin", "escape"));
    await symlink("../../dist/index.js", join(versionRoot, "app", "node_modules", ".bin", "tron"));
    const sourceFingerprint = await payloadFingerprint(versionRoot);
    await writeFile(join(versionRoot, "manifest.json"), `${JSON.stringify({
      schema: 1, kind: "tron-gateway-payload", channel: "dev", version: "source",
      gatewayVersion: "1", protocolVersion: "4", minProtocolVersion: "4", nodeVersion: "22", sourceRevision: "source", runtimeEpoch: "source-epoch",
      payloadFingerprint: sourceFingerprint, dependencyTreeCoverage: "app/** and runtime/** regular files",
    })}\n`);

    const home = join(root, "home");
    const staleLink = join(home, "gateway", "payloads", "dev", "versions", ".staging-stale", "app", "node_modules", ".bin", "escape");
    const outside = join(root, "outside");
    await mkdir(join(staleLink, ".."), { recursive: true });
    await writeFile(outside, "must remain\n");
    await symlink(outside, staleLink);

    const staged = await stagePayload({ home, channel: "dev", source: versionRoot, version: "candidate" });
    assert.equal(await readlink(join(staged.root, "app", "node_modules", ".bin", "tron")), "../../dist/index.js");
    assert.equal(await readlink(join(staged.root, "runtime", "bin-arm64", "node")), "../node-arm64");
    assert.equal(await readlink(join(staged.root, "runtime", "bin-x64", "node")), "../node-x64");
    await assert.rejects(readlink(staleLink), /ENOENT/);
    assert.equal(await readFile(outside, "utf8"), "must remain\n");
    for (const directory of [
      join(staged.root, "app", "node_modules", ".bin"),
      join(staged.root, "app", "node_modules", "@earendil-works", "pi-coding-agent", "dist"),
      join(staged.root, "app", "node_modules", "@earendil-works", "pi-coding-agent"),
      join(staged.root, "app", "node_modules", "@earendil-works"), join(staged.root, "app", "node_modules"),
      join(staged.root, "app", "dist"), join(staged.root, "app", "scripts"),
      join(staged.root, "app"), join(staged.root, "runtime", "bin-arm64"),
      join(staged.root, "runtime", "bin-x64"),
      join(staged.root, "runtime", "xcodegen", "bin"),
      join(staged.root, "runtime", "xcodegen", "share", "xcodegen", "SettingPresets"),
      join(staged.root, "runtime", "xcodegen", "share", "xcodegen"),
      join(staged.root, "runtime", "xcodegen", "share"),
      join(staged.root, "runtime", "xcodegen"),
      join(staged.root, "runtime"), staged.root,
    ]) await chmod(directory, 0o755);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("source build failure leaves active selection and deployment state unchanged", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-source-failure-"));
  try {
    const store = await paths(root);
    const versionRoot = join(store.versionsRoot, "active");
    await mkdir(join(versionRoot, "app", "dist"), { recursive: true });
    await mkdir(join(versionRoot, "app", "scripts"), { recursive: true });
    await mkdir(join(versionRoot, "app", "node_modules"), { recursive: true });
    await mkdir(join(versionRoot, "runtime"), { recursive: true });
    await writeFile(join(versionRoot, "app", "dist", "index.js"), `${"x".repeat(1_024)}\n`);
    await writeFile(join(versionRoot, "app", "package.json"), "{}\n");
    await writeFile(join(versionRoot, "app", "package-lock.json"), "{}\n");
    await writeFile(join(versionRoot, "app", "PushService.xcconfig"), "TRON_PUSH_SERVICE_ORIGIN = https:/$()/push.example.test\n");
    await writeFile(join(versionRoot, "app", "scripts", "ensure-node-pty-helper.mjs"), "// helper\n");
    await writeFile(join(versionRoot, "app", "scripts", "gateway-payload-deploy.mjs"), "// updater\n");
    await writeFile(join(versionRoot, "runtime", "node-arm64"), "n".repeat(1_048_576));
    await writeFile(join(versionRoot, "runtime", "node-x64"), "n".repeat(1_048_576));
    await chmod(join(versionRoot, "runtime", "node-arm64"), 0o755);
    await chmod(join(versionRoot, "runtime", "node-x64"), 0o755);
    await addRuntimeNodeAliases(versionRoot);
    const fingerprint = await payloadFingerprint(versionRoot);
    const manifest = { schema: 1, kind: "tron-gateway-payload", channel: "stable", version: "active", gatewayVersion: "1", protocolVersion: "4", minProtocolVersion: "4", nodeVersion: "22", sourceRevision: "source", runtimeEpoch: "epoch", payloadFingerprint: fingerprint, dependencyTreeCoverage: "app/** and runtime/** regular files" };
    await writeFile(join(versionRoot, "manifest.json"), `${JSON.stringify(manifest)}\n`);
    await mkdir(store.channelRoot, { recursive: true });
    await writeFile(store.current, `${JSON.stringify(selection("active", fingerprint))}\n`);
    const before = `${JSON.stringify({ untouched: true })}\n`;
    await writeFile(store.state, before);
    await assert.rejects(buildSourcePayload({ paths: store, config: { sourceRoot: root }, runCommand: async () => { throw new Error("build failed"); } }), /build failed/);
    assert.equal(await readFile(store.state, "utf8"), before);
    assert.deepEqual(JSON.parse(await readFile(store.current, "utf8")), selection("active", fingerprint));
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("source runtime base falls back only to fully validated migration payloads", async (context) => {
  for (const kind of ["configured artifact", "launcher bundle", "prepared source bundle"]) {
    await context.test(kind, async () => {
      const root = await mkdtemp(join(tmpdir(), "tron-source-runtime-base-"));
      try {
        const store = await paths(root);
        await mkdir(store.channelRoot, { recursive: true });
        await writeFile(store.current, `${JSON.stringify(selection("missing"))}\n`);
        const sourceRoot = join(root, "source");
        await mkdir(sourceRoot, { recursive: true });
        let payload = await makePreflightFixture(join(root, "fixture"));
        const config = { sourceRoot };
        const environment = {};
        if (kind === "configured artifact") config.artifactRoot = payload;
        if (kind === "launcher bundle") environment.TRON_GATEWAY_BUNDLED_PAYLOAD_ROOT = payload;
        if (kind === "prepared source bundle") {
          const prepared = join(sourceRoot, "packages", "mac-app", "Sources", "Resources", "Gateway");
          await mkdir(dirname(prepared), { recursive: true });
          await rename(payload, prepared);
          payload = prepared;
        }
        const base = await resolveSourcePayloadBase(store, config, environment);
        assert.equal(base.root, payload);
        assert.equal(base.manifest.payloadFingerprint, await payloadFingerprint(payload));
      } finally { await rm(root, { recursive: true, force: true }); }
    });
  }
});

test("source runtime base fails closed when every migration payload is invalid", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-source-runtime-base-invalid-"));
  try {
    const store = await paths(root);
    await mkdir(store.channelRoot, { recursive: true });
    await writeFile(store.current, `${JSON.stringify(selection("missing"))}\n`);
    const invalid = join(root, "invalid");
    await mkdir(invalid, { recursive: true });
    await assert.rejects(
      resolveSourcePayloadBase(store, { sourceRoot: join(root, "source"), artifactRoot: invalid }, {
        TRON_GATEWAY_BUNDLED_PAYLOAD_ROOT: "relative",
      }),
      /prepare the bundled payload or reinstall Tron/,
    );
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("source runtime base copy rejects a projection changed after admission", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-source-runtime-base-race-"));
  try {
    const payload = await makePreflightFixture(join(root, "fixture"));
    const manifest = await validatePayload(payload, {}, true);
    const destination = join(root, "copied");
    await assert.rejects(
      copyValidatedPayloadBase({ root: payload, manifest }, destination, async (source, target, options) => {
        await cp(source, target, options);
        await writeFile(join(target, "app", "dist", "index.js"), `${"z".repeat(1_024)}\n`);
      }),
      /fingerprint does not match/,
    );
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("source builds compile privately and leave the trusted source tree unchanged", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-source-private-build-"));
  try {
    const store = await paths(root);
    const sourceRoot = join(root, "source");
    const gatewayRoot = join(sourceRoot, "packages", "gateway");
    await mkdir(join(gatewayRoot, "src"), { recursive: true });
    await mkdir(join(sourceRoot, "scripts"), { recursive: true });
    await mkdir(join(gatewayRoot, "scripts"), { recursive: true });
    await writeFile(join(sourceRoot, "scripts", "gateway-payload-deploy.mjs"), "// trusted updater\n");
    await writeFile(join(gatewayRoot, "scripts", "ensure-node-pty-helper.mjs"), "// trusted helper\n");
    const sourceFiles = {
      "package.json": JSON.stringify({ version: "1.0.0" }),
      "package-lock.json": "{}\n",
      "tsconfig.json": "{}\n",
      "src/index.ts": "export const source = true;\n",
    };
    for (const [path, content] of Object.entries(sourceFiles)) {
      await writeFile(join(gatewayRoot, path), content);
    }
    const versionRoot = join(store.versionsRoot, "active");
    await mkdir(join(versionRoot, "app", "dist"), { recursive: true });
    await mkdir(join(versionRoot, "app", "scripts"), { recursive: true });
    await mkdir(join(versionRoot, "app", "node_modules"), { recursive: true });
    await mkdir(join(versionRoot, "runtime"), { recursive: true });
    await writeFile(join(versionRoot, "app", "dist", "index.js"), `${"x".repeat(1_024)}\n`);
    await writeFile(join(versionRoot, "app", "package.json"), "{}\n");
    await writeFile(join(versionRoot, "app", "package-lock.json"), "{}\n");
    await writeFile(join(versionRoot, "app", "PushService.xcconfig"), "TRON_PUSH_SERVICE_ORIGIN = https:/$()/push.example.test\n");
    await writeFile(join(versionRoot, "app", "scripts", "ensure-node-pty-helper.mjs"), "// helper\n");
    await writeFile(join(versionRoot, "app", "scripts", "gateway-payload-deploy.mjs"), "// updater\n");
    await writeFile(join(versionRoot, "runtime", "node-arm64"), "n".repeat(1_048_576));
    await writeFile(join(versionRoot, "runtime", "node-x64"), "n".repeat(1_048_576));
    await chmod(join(versionRoot, "runtime", "node-arm64"), 0o755);
    await chmod(join(versionRoot, "runtime", "node-x64"), 0o755);
    await addRuntimeNodeAliases(versionRoot);
    const fingerprint = await payloadFingerprint(versionRoot);
    const activeManifest = { schema: 1, kind: "tron-gateway-payload", channel: "stable", version: "active", gatewayVersion: "1", protocolVersion: "4", minProtocolVersion: "4", nodeVersion: "22", sourceRevision: "source", runtimeEpoch: "epoch", payloadFingerprint: fingerprint, dependencyTreeCoverage: "app/** and runtime/** regular files" };
    await writeFile(join(versionRoot, "manifest.json"), `${JSON.stringify(activeManifest)}\n`);
    await mkdir(store.channelRoot, { recursive: true });
    await writeFile(store.current, `${JSON.stringify(selection("active", fingerprint))}\n`);
    const before = new Map(await Promise.all(Object.keys(sourceFiles).map(async (path) => [path, await readFile(join(gatewayRoot, path))])));
    const commands = [];
    const result = await buildSourcePayload({
      paths: store, config: { sourceRoot }, candidateVersion: "candidate",
      runCommand: async (tool, args, options) => {
        commands.push({ tool, args, options });
        if (tool === process.execPath && args[0].endsWith("/tsc")) {
          await mkdir(args.at(-1), { recursive: true });
          await writeFile(join(args.at(-1), "index.js"), `${"c".repeat(1_024)}\n`);
        } else {
          const piCli = join(options.cwd, "node_modules", "@earendil-works", "pi-coding-agent", "dist", "cli.js");
          await mkdir(dirname(piCli), { recursive: true });
          await writeFile(piCli, "#!/usr/bin/env node\n");
          await chmod(piCli, 0o755);
        }
      },
    });
    assert.equal(result.manifest.version, "candidate");
    assert.equal(commands[0].tool, process.execPath);
    assert.equal(commands[0].args.includes("run"), false);
    assert.equal(await readFile(join(gatewayRoot, "dist", "index.js")).catch(() => undefined), undefined);
    for (const [path, content] of before) assert.deepEqual(await readFile(join(gatewayRoot, path)), content);
    assert.equal(await readFile(join(result.root, "app", "scripts", "gateway-payload-deploy.mjs"), "utf8"), "// trusted updater\n");
    assert.equal(await readFile(join(result.root, "app", "scripts", "ensure-node-pty-helper.mjs"), "utf8"), "// trusted helper\n");
    assert.equal(
      await readFile(join(result.root, "app", "PushService.xcconfig"), "utf8"),
      "TRON_PUSH_SERVICE_ORIGIN = https:/$()/push.example.test\n",
    );
    for (const directory of [
      join(store.versionsRoot, "candidate"), join(store.versionsRoot, "candidate", "app"),
      join(store.versionsRoot, "candidate", "app", "dist"), join(store.versionsRoot, "candidate", "app", "scripts"),
      join(store.versionsRoot, "candidate", "app", "node_modules", "@earendil-works", "pi-coding-agent", "dist"),
      join(store.versionsRoot, "candidate", "app", "node_modules", "@earendil-works", "pi-coding-agent"),
      join(store.versionsRoot, "candidate", "app", "node_modules", "@earendil-works"),
      join(store.versionsRoot, "candidate", "app", "node_modules"),
      join(store.versionsRoot, "candidate", "runtime", "bin-arm64"),
      join(store.versionsRoot, "candidate", "runtime", "bin-x64"),
      join(store.versionsRoot, "candidate", "runtime", "xcodegen", "bin"),
      join(store.versionsRoot, "candidate", "runtime", "xcodegen", "share", "xcodegen", "SettingPresets"),
      join(store.versionsRoot, "candidate", "runtime", "xcodegen", "share", "xcodegen"),
      join(store.versionsRoot, "candidate", "runtime", "xcodegen", "share"),
      join(store.versionsRoot, "candidate", "runtime", "xcodegen"),
      join(store.versionsRoot, "candidate", "runtime"),
    ]) await chmod(directory, 0o755);
  } finally { await rm(root, { recursive: true, force: true }); }
});

async function makePreflightFixture(root) {
  const payload = join(root, "payload");
  await mkdir(join(payload, "app", "dist"), { recursive: true });
  await mkdir(join(payload, "app", "scripts"), { recursive: true });
  await mkdir(join(payload, "app", "node_modules"), { recursive: true });
  await mkdir(join(payload, "app", "node_modules", "node-pty", "prebuilds", `darwin-${process.arch}`), { recursive: true });
  await mkdir(join(payload, "runtime"), { recursive: true });
  await writeFile(join(payload, "app", "dist", "index.js"), "x".repeat(1_024));
  await writeFile(join(payload, "app", "dist", "version.js"), "export const PROTOCOL_VERSION = 4; export const MIN_PROTOCOL_VERSION = 4;\n");
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
    gatewayVersion: "1", protocolVersion: "4", minProtocolVersion: "4", nodeVersion: "22", sourceRevision: "source", runtimeEpoch: "epoch",
    payloadFingerprint: fingerprint, dependencyTreeCoverage: "app/** and runtime/** regular files",
  }));
  return payload;
}

test("promotion recovery admits a launcher-rejected external selection as bundled fallback", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-recovery-bundled-fallback-"));
  try {
    const store = await paths(root);
    await mkdir(store.versionsRoot, { recursive: true });
    const externalFixture = await makePreflightFixture(join(root, "external"));
    const externalRoot = join(store.versionsRoot, "old-v3");
    await rename(externalFixture, externalRoot);
    const externalManifestPath = join(externalRoot, "manifest.json");
    const externalManifest = JSON.parse(await readFile(externalManifestPath, "utf8"));
    externalManifest.version = "old-v3";
    delete externalManifest.protocolVersion;
    delete externalManifest.minProtocolVersion;
    await writeFile(externalManifestPath, JSON.stringify(externalManifest));
    const staleSelection = selection("old-v3", externalManifest.payloadFingerprint);
    await writeFile(store.current, `${JSON.stringify(staleSelection)}\n`);

    const bundled = await makePreflightFixture(join(root, "bundled"));
    const bundledManifest = JSON.parse(await readFile(join(bundled, "manifest.json"), "utf8"));
    const recovery = await resolveRecoveryPayload(store, staleSelection, [bundled]);
    assert.equal(recovery.usesBundledFallback, true);
    assert.deepEqual(recovery.manifest, bundledManifest);
    await requireBundledPayload(store, bundledManifest, [bundled]);

    externalManifest.protocolVersion = "4";
    externalManifest.minProtocolVersion = "4";
    await writeFile(externalManifestPath, JSON.stringify(externalManifest));
    const admissible = await resolveRecoveryPayload(store, staleSelection, [bundled]);
    assert.equal(admissible.usesBundledFallback, false);
    assert.equal(admissible.manifest.version, "old-v3");
    await assert.rejects(
      requireBundledPayload(store, bundledManifest, [bundled]),
      /admissible external payload selection/,
    );
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("source rebuild preserves signed native artifacts only with an unchanged dependency lock", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-source-native-signatures-"));
  try {
    const active = join(root, "active");
    const candidate = join(root, "candidate");
    const nativePaths = [
      "app/node_modules/node-pty/prebuilds/darwin-arm64/pty.node",
      "app/node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper",
      "app/node_modules/example/prebuilds/darwin-x64/addon.node",
    ];
    for (const payload of [active, candidate]) {
      await mkdir(join(payload, "app", "node_modules"), { recursive: true });
      await writeFile(join(payload, "app", "package-lock.json"), "same-lock\n");
      for (const path of nativePaths) {
        await mkdir(dirname(join(payload, path)), { recursive: true });
        await writeFile(join(payload, path), payload === active ? `signed:${path}\n` : `adhoc:${path}\n`);
      }
    }
    assert.deepEqual(await preserveSignedNativeArtifacts(active, candidate), nativePaths.sort());
    for (const path of nativePaths) assert.equal(await readFile(join(candidate, path), "utf8"), `signed:${path}\n`);
    await writeFile(join(candidate, "app", "package-lock.json"), "changed-lock\n");
    await assert.rejects(
      preserveSignedNativeArtifacts(active, candidate),
      /dependency lock changed/,
    );
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("stable payload push configuration rejects missing empty malformed and symlinked files", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-push-payload-policy-"));
  try {
    assert.equal(validatePushServiceConfigurationText("TRON_PUSH_SERVICE_ORIGIN =\n", "dev"), "");
    assert.throws(() => validatePushServiceConfigurationText("TRON_PUSH_SERVICE_ORIGIN =\n", "stable"), /non-empty/);
    assert.throws(() => validatePushServiceConfigurationText("TRON_PUSH_SERVICE_ORIGIN = http:\/$()\/push.example.test\n", "stable"), /public HTTPS/);

    for (const kind of ["missing", "empty", "malformed", "symlink"]) {
      const payload = await makePreflightFixture(join(root, kind));
      const config = join(payload, "app", "PushService.xcconfig");
      if (kind === "missing") await rm(config);
      if (kind === "empty") await writeFile(config, "TRON_PUSH_SERVICE_ORIGIN =\n");
      if (kind === "malformed") await writeFile(config, "TRON_PUSH_SERVICE_ORIGIN = http:/$()/push.example.test\n");
      if (kind === "symlink") { await rm(config); await symlink("package.json", config); }
      await assert.rejects(validatePayload(payload, { channel: "stable" }, true), /PushService|incomplete/);
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("runtime Node and Pi aliases are exact required command links", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-runtime-node-alias-policy-"));
  try {
    for (const kind of ["missing", "regular", "wrong-target", "absolute-target"]) {
      const payload = await makePreflightFixture(join(root, kind));
      const alias = join(payload, "runtime", "bin-arm64", "node");
      await rm(alias);
      if (kind === "regular") {
        await writeFile(alias, "#!/bin/sh\nexit 0\n");
        await chmod(alias, 0o755);
      } else if (kind === "wrong-target") {
        await symlink("../node-x64", alias);
      } else if (kind === "absolute-target") {
        await symlink(join(payload, "runtime", "node-arm64"), alias);
      }
      await assert.rejects(validatePayload(payload, { channel: "stable" }, true), /runtime Node alias|ENOENT/);
    }
    for (const kind of ["missing", "regular", "wrong-target", "absolute-target"]) {
      const payload = await makePreflightFixture(join(root, `pi-${kind}`));
      const alias = join(payload, "runtime", "bin-arm64", "pi");
      await rm(alias);
      if (kind === "regular") {
        await writeFile(alias, "#!/bin/sh\nexit 0\n");
        await chmod(alias, 0o755);
      } else if (kind === "wrong-target") {
        await symlink("../node-arm64", alias);
      } else if (kind === "absolute-target") {
        await symlink(join(payload, "app", "node_modules", "@earendil-works", "pi-coding-agent", "dist", "cli.js"), alias);
      }
      await assert.rejects(validatePayload(payload, { channel: "stable" }, true), /runtime Pi alias|ENOENT/);
    }
    const missingCoverage = await makePreflightFixture(join(root, "missing-coverage"));
    const manifestPath = join(missingCoverage, "manifest.json");
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    delete manifest.dependencyTreeCoverage;
    await writeFile(manifestPath, JSON.stringify(manifest));
    await assert.rejects(validatePayload(missingCoverage, { channel: "stable" }, true), /manifest identity/);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("dev empty push configuration cannot be promoted into Stable", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-push-dev-promotion-"));
  try {
    const payload = await makePreflightFixture(join(root, "source"));
    await writeFile(join(payload, "app", "PushService.xcconfig"), "TRON_PUSH_SERVICE_ORIGIN =\n");
    const manifestPath = join(payload, "manifest.json");
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    const devFingerprint = await payloadFingerprint(payload);
    await writeFile(manifestPath, JSON.stringify({ ...manifest, channel: "dev", payloadFingerprint: devFingerprint }));
    const devHome = join(root, "dev-home");
    const stagedDev = await stagePayload({ home: devHome, channel: "dev", source: payload, version: "dev-empty" });
    await assert.rejects(
      stagePayload({ home: join(root, "stable-home"), channel: "stable", source: stagedDev.root, version: "stable-candidate" }),
      /stable payload PushService.xcconfig requires a non-empty origin/,
    );
  } finally {
    await runBounded("/bin/chmod", ["-R", "u+w", root], { timeoutMs: 5_000, maxOutputBytes: 8_192 }).catch(() => {});
    await rm(root, { recursive: true, force: true });
  }
});

test("preflight imports candidate protocol values and rejects incompatible ranges", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-preflight-protocol-"));
  try {
    const payload = await makePreflightFixture(root);
    const run = async (_tool, args) => args[0] === "-e"
      ? { code: 0, output: JSON.stringify({ protocolVersion: 4, minProtocolVersion: 4 }) }
      : args[0] === "--version"
        ? { code: 0, output: `Version: ${PINNED_XCODEGEN_VERSION}\n` }
        : { code: 0, output: "" };
    await preflightPayload(payload, run);
    await assert.rejects(
      preflightPayload(payload, async (_tool, args) => args[0] === "-e"
        ? { code: 0, output: JSON.stringify({ protocolVersion: 3, minProtocolVersion: 3 }) }
        : args[0] === "--version"
          ? { code: 0, output: `Version: ${PINNED_XCODEGEN_VERSION}\n` }
          : { code: 0, output: "" }),
      /protocol range is incompatible/
    );
    await assert.rejects(
      preflightPayload(payload, async (_tool, args) => args[0] === "-e"
        ? { code: 0, output: JSON.stringify({ protocolVersion: 4, minProtocolVersion: 4 }) }
        : args[0] === "--version"
          ? { code: 0, output: "Version: 0.0.0\n" }
          : { code: 0, output: "" }),
      /bundled XcodeGen must be version/
    );
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("source npm resolution uses the exact Node runtime", () => {
  const command = resolveNpmCommand({
    HOME: process.env.HOME,
    PATH: process.env.PATH,
    NVM_DIR: process.env.NVM_DIR,
  });
  assert.equal(command.tool, process.execPath);
  assert.match(command.script, /npm-cli\.js$/u);
});

test("trusted source policy is stored-only and source commands are bounded", async () => {
  const config = { schema: 1, kind: "tron-gateway-update-config", sourceRoot: "/Users/tron/repo", updatedAt: "2026-04-27T00:00:00Z" };
  assert.equal(validateUpdateConfigDocument(config), true);
  assert.equal(validateUpdateConfigDocument({ ...config, sourceRoot: "relative" }), false);
  assert.deepEqual(sourceBuildCommands("/Users/tron/repo"), [
    {
      tool: process.execPath,
      args: [
        "/Users/tron/repo/packages/gateway/node_modules/typescript/bin/tsc",
        "-p", "/Users/tron/repo/packages/gateway/tsconfig.json", "--outDir", "<private-output>",
      ],
      cwd: "/Users/tron/repo/packages/gateway",
    },
    { tool: "npm", args: ["ci", "--omit=dev", "--ignore-scripts=false"], cwd: "<candidate>/app" },
  ]);
});

test("Debug handoff pins authenticated dev-channel pre/post identity to the selected manifest", () => {
  const manifest = { payloadFingerprint: "a".repeat(64), sourceRevision: "revision-1", runtimeEpoch: "epoch-1" };
  const info = { gatewayChannel: "dev", buildFingerprint: manifest.payloadFingerprint, sourceRevision: manifest.sourceRevision, runtimeEpoch: manifest.runtimeEpoch };
  assert.deepEqual(proveDebugHandoffIdentity(info, info, manifest), manifest);
  assert.throws(() => proveDebugHandoffIdentity({ ...info, gatewayChannel: undefined }, info, manifest), /wrong channel/);
  assert.throws(() => proveDebugHandoffIdentity({ ...info, gatewayChannel: "stable" }, info, manifest), /wrong channel/);
  assert.throws(() => proveDebugHandoffIdentity(info, { ...info, buildFingerprint: "b".repeat(64) }, manifest), /changed while/);
});

test("planned drain polls the exact old PID after its listener disappears", async () => {
  const oldProcess = { pid: 1234, startIdentity: "old-start" };
  let processReads = 0; let sleeps = 0;
  const listenerPresent = false;
  const replacement = await waitForDrainCompletion(
    oldProcess,
    async (pid) => {
      assert.equal(pid, oldProcess.pid);
      assert.equal(listenerPresent, false);
      processReads += 1;
      // The port is already unbound, but the draining process is still alive.
      // Completion is admitted only when this exact PID/start pair changes.
      return processReads > 5 ? { pid, startIdentity: "replacement-start" } : oldProcess;
    },
    async () => { sleeps += 1; },
  );
  assert.deepEqual(replacement, { pid: 1234, startIdentity: "replacement-start" });
  assert.equal(sleeps, 5);
  assert.equal(processReads, 6);

  let exitedReads = 0;
  const exited = await waitForDrainCompletion(oldProcess, async (pid) => {
    assert.equal(pid, oldProcess.pid);
    exitedReads += 1;
    return exitedReads > 4 ? undefined : oldProcess;
  }, async () => {});
  assert.equal(exited, undefined);
  assert.equal(exitedReads, 5);
});

test("startup timing and kickstart do not begin while the exact old process remains", async () => {
  const oldProcess = { pid: 10, startIdentity: "old" };
  const expected = { payloadFingerprint: "a".repeat(64), sourceRevision: "revision", runtimeEpoch: "new-epoch" };
  let releaseDrain; let launches = 0; let clockReads = 0;
  const drained = new Promise((resolve) => { releaseDrain = resolve; });
  const pending = waitForDrainedReplacement({
    oldProcess,
    expected,
    oldEpoch: "old-epoch",
    timeoutMs: 2_000,
    replacement: {
      readExactProcess: async () => { await drained; return undefined; },
      readListener: async () => ({ pid: 11, startIdentity: "new" }),
      readHealth: async () => ({
        buildFingerprint: expected.payloadFingerprint,
        sourceRevision: expected.sourceRevision,
        runtimeEpoch: expected.runtimeEpoch,
      }),
      launchSupervisor: async () => { launches += 1; },
      now: () => { clockReads += 1; return 0; },
      sleep: async () => {},
    },
  });
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(clockReads, 0);
  assert.equal(launches, 0);
  releaseDrain();
  await pending;
  assert.equal(launches, 0);

  clockReads = 0;
  await assert.rejects(waitForDrainedReplacement({
    oldProcess, expected, oldEpoch: "old-epoch", timeoutMs: 2_000,
    replacement: {
      readExactProcess: async () => { throw new Error("process probe failed"); },
      readListener: async () => undefined,
      readHealth: async () => ({}),
      launchSupervisor: async () => { launches += 1; },
      now: () => { clockReads += 1; return 0; },
      sleep: async () => {},
    },
  }), /process probe failed/);
  assert.equal(clockReads, 0);
  assert.equal(launches, 0);
});

test("production process probes distinguish proven absence from probe failure", async () => {
  const absent = Object.assign(new Error("exit 1"), { exitCode: 1, commandOutput: "" });
  assert.equal(await captureLocalListenerProcess(1234, async () => { throw absent; }), undefined);

  const start = "Mon Aug 25 11:00:00 2026";
  assert.deepEqual(await captureLocalProcess(123, async (tool, args) => {
    assert.equal(tool, "/bin/ps");
    assert.deepEqual(args, ["-axo", "pid=,lstart="]);
    return { output: `  12 Sun Aug 24 10:00:00 2026\n 123 ${start}\n` };
  }), { pid: 123, startIdentity: start });
  assert.equal(await captureLocalProcess(123, async () => ({
    output: "  12 Sun Aug 24 10:00:00 2026\n",
  })), undefined);

  const listener = await captureLocalListenerProcess(1234, async (tool, args) => {
    if (tool === "/usr/sbin/lsof") {
      assert.deepEqual(args, ["-nP", "-w", "-t", "-iTCP:1234", "-sTCP:LISTEN"]);
      return { output: "123\n" };
    }
    assert.equal(tool, "/bin/ps");
    return { output: ` 123 ${start}\n` };
  });
  assert.deepEqual(listener, { pid: 123, startIdentity: start });

  const failure = new Error("spawn failed");
  await assert.rejects(captureLocalProcess(123, async () => { throw failure; }), /spawn failed/);
  await assert.rejects(captureLocalProcess(123, async () => ({ output: "" })), /empty process table/);
  await assert.rejects(captureLocalProcess(123, async () => ({ output: "malformed\n" })), /malformed/);
  await assert.rejects(captureLocalListenerProcess(1234, async () => ({ output: "p123\n" })), /malformed/);
  await assert.rejects(captureLocalListenerProcess(1234, async () => ({ output: "" })), /empty successful result/);
  await assert.rejects(captureLocalListenerProcess(1234, async () => ({ output: "123\n456\n" })), /multiple listeners/);
  const denied = Object.assign(new Error("permission denied"), { exitCode: 1, commandOutput: "permission denied" });
  await assert.rejects(captureLocalListenerProcess(1234, async () => { throw denied; }), /permission denied/);
});

test("Stable kickstart is fixed and fails closed outside supervised Stable", async () => {
  const environment = { TRON_GATEWAY_SUPERVISED: "1", TRON_GATEWAY_CHANNEL: "stable" };
  assert.deepEqual(stableSupervisorKickstartSpec("stable", environment, "darwin", 501), {
    tool: "/bin/launchctl",
    args: ["kickstart", "-k", "gui/501/com.tron.server"],
  });
  for (const input of [
    ["dev", environment, "darwin", 501],
    ["stable", {}, "darwin", 501],
    ["stable", { ...environment, TRON_GATEWAY_CHANNEL: "dev" }, "darwin", 501],
    ["stable", environment, "linux", 501],
  ]) assert.throws(() => stableSupervisorKickstartSpec(...input), /supervisor recovery|unavailable/);

  const calls = [];
  await kickstartStableSupervisor("stable", async (tool, args, options) => {
    calls.push({ tool, args, options });
    return { output: "" };
  }, environment, "darwin", 501);
  assert.deepEqual(calls, [{
    tool: "/bin/launchctl",
    args: ["kickstart", "-k", "gui/501/com.tron.server"],
    options: { timeoutMs: 10_000, maxOutputBytes: 16 * 1024 },
  }]);
  await assert.rejects(kickstartStableSupervisor("stable", async () => {
    throw new Error("launchctl refused");
  }, environment, "darwin", 501), /launchctl refused/);
});

test("replacement waits for coherent new process and kickstarts only with an explicit recovery grace", async () => {
  const oldProcess = { pid: 10, startIdentity: "old" };
  const nextProcess = { pid: 11, startIdentity: "new" };
  const expected = { payloadFingerprint: "a".repeat(64), sourceRevision: "revision", runtimeEpoch: "new-epoch" };
  const health = { buildFingerprint: expected.payloadFingerprint, sourceRevision: expected.sourceRevision, runtimeEpoch: expected.runtimeEpoch };

  let launches = 0;
  const natural = await waitForReplacement({
    oldProcess, expected, oldEpoch: "old-epoch", timeoutMs: 2_000,
    readListener: async () => nextProcess,
    readHealth: async () => health,
    launchSupervisor: async () => { launches += 1; },
  });
  assert.deepEqual(natural, { process: nextProcess, health });
  assert.equal(launches, 0);

  // A launchd-owned process can take longer than the old 1.5-second grace to
  // bind its listener. Default promotion must wait rather than kickstarting
  // and killing that unobserved startup process.
  let now = 0;
  const delayedNatural = await waitForReplacement({
    oldProcess, expected, oldEpoch: "old-epoch", timeoutMs: 5_000,
    readListener: async () => now < 3_000 ? undefined : nextProcess,
    readHealth: async () => health,
    launchSupervisor: async () => { launches += 1; },
    now: () => now,
    sleep: async (milliseconds) => { now += milliseconds; },
  });
  assert.deepEqual(delayedNatural, { process: nextProcess, health });
  assert.equal(launches, 0);

  now = 0; let launched = false;
  const kicked = await waitForReplacement({
    oldProcess, expected, oldEpoch: "old-epoch", timeoutMs: 2_000, naturalGraceMs: 500,
    readListener: async () => launched ? nextProcess : undefined,
    readHealth: async () => health,
    launchSupervisor: async () => { launches += 1; launched = true; },
    now: () => now,
    sleep: async (milliseconds) => { now += milliseconds; },
  });
  assert.deepEqual(kicked.process, nextProcess);
  assert.equal(launches, 1);

  now = 0; launches = 0;
  const slowLive = await waitForReplacement({
    oldProcess, expected, oldEpoch: "old-epoch", timeoutMs: 2_000, naturalGraceMs: 500,
    readListener: async () => nextProcess,
    readHealth: async () => {
      if (now < 1_500) throw new Error("still starting");
      return health;
    },
    launchSupervisor: async () => { launches += 1; },
    now: () => now,
    sleep: async (milliseconds) => { now += milliseconds; },
  });
  assert.deepEqual(slowLive.process, nextProcess);
  assert.equal(launches, 0);

  now = 0; launches = 0;
  let listenerReads = 0;
  const appearedAtBoundary = await waitForReplacement({
    oldProcess, expected, oldEpoch: "old-epoch", timeoutMs: 2_000, naturalGraceMs: 0,
    readListener: async () => (++listenerReads === 1 ? undefined : nextProcess),
    readHealth: async () => health,
    launchSupervisor: async () => { launches += 1; },
    now: () => now,
    sleep: async (milliseconds) => { now += milliseconds; },
  });
  assert.deepEqual(appearedAtBoundary.process, nextProcess);
  assert.equal(launches, 0);

  launches = 0;
  await assert.rejects(waitForReplacement({
    oldProcess, expected, oldEpoch: "old-epoch", timeoutMs: 2_000, naturalGraceMs: 0,
    readListener: async () => { throw new Error("listener probe denied"); },
    readHealth: async () => health,
    launchSupervisor: async () => { launches += 1; },
  }), /listener probe denied/);
  assert.equal(launches, 0);
});

test("same or unstable listener and stale health cannot satisfy replacement", async () => {
  const oldProcess = { pid: 10, startIdentity: "old" };
  const expected = { payloadFingerprint: "a".repeat(64), sourceRevision: "revision", runtimeEpoch: "new-epoch" };
  const stale = { buildFingerprint: expected.payloadFingerprint, sourceRevision: expected.sourceRevision, runtimeEpoch: "old-epoch" };
  assert.equal(await verifyReplacementIdentity({
    oldProcess, expected, oldEpoch: "old-epoch",
    readListener: async () => oldProcess,
    readHealth: async () => stale,
  }), undefined);

  let reads = 0;
  assert.equal(await verifyReplacementIdentity({
    oldProcess, expected, oldEpoch: "old-epoch",
    readListener: async () => (++reads === 1
      ? { pid: 11, startIdentity: "one" }
      : { pid: 12, startIdentity: "two" }),
    readHealth: async () => ({ ...stale, runtimeEpoch: expected.runtimeEpoch }),
  }), undefined);

  let now = 0;
  let foreignError;
  try {
    await waitForReplacement({
      oldProcess, expected, oldEpoch: "old-epoch", timeoutMs: 500, naturalGraceMs: 0,
      readListener: async () => ({ pid: 99, startIdentity: "foreign" }),
      readHealth: async () => ({ ...stale, buildFingerprint: "b".repeat(64) }),
      launchSupervisor: async () => assert.fail("foreign listener must not be kickstarted"),
      now: () => now,
      sleep: async (milliseconds) => { now += milliseconds; },
    });
  } catch (error) { foreignError = error; }
  assert.match(foreignError.message, /coherent replacement/);
  assert.equal(foreignError.observedProcess, undefined);
});

test("recovery coordinates an existing restored listener and fails closed on unknown listeners", async () => {
  const expected = { payloadFingerprint: "a".repeat(64), sourceRevision: "old-revision", runtimeEpoch: "old-epoch" };
  const health = { buildFingerprint: expected.payloadFingerprint, sourceRevision: expected.sourceRevision, runtimeEpoch: expected.runtimeEpoch };
  const candidate = { pid: 12, startIdentity: "candidate" };
  const restored = { pid: 13, startIdentity: "restored" };
  const order = [];
  let launched = false; let now = 0;
  const replacement = {
    readListener: async () => launched ? restored : candidate,
    readHealth: async () => launched ? health : { ...health, buildFingerprint: "b".repeat(64) },
    launchSupervisor: async () => { order.push("launch"); launched = true; },
    now: () => now,
    sleep: async (milliseconds) => { now += milliseconds; },
  };
  const result = await restoreAndVerifyReplacement({
    restore: async () => { order.push("restore"); },
    validateRestored: async () => { order.push("validate"); },
    beforeLaunch: async () => { order.push("rollback-requested"); },
    replacement, expected, oldEpoch: "candidate-epoch", timeoutMs: 2_000,
    replaceableProcess: candidate,
  });
  assert.deepEqual(order, ["restore", "validate", "rollback-requested", "launch"]);
  assert.deepEqual(result.process, restored);

  let launches = 0;
  const alreadyRestored = await restoreAndVerifyReplacement({
    restore: async () => {}, validateRestored: async () => {},
    replacement: {
      readListener: async () => restored,
      readHealth: async () => health,
      launchSupervisor: async () => { launches += 1; },
    },
    expected, oldEpoch: "candidate-epoch", timeoutMs: 500,
    replaceableProcess: candidate,
  });
  assert.deepEqual(alreadyRestored.process, restored);
  assert.equal(launches, 0);

  await assert.rejects(restoreAndVerifyReplacement({
    restore: async () => {}, validateRestored: async () => {},
    replacement: {
      readListener: async () => ({ pid: 99, startIdentity: "unknown" }),
      readHealth: async () => ({ ...health, buildFingerprint: "b".repeat(64) }),
      launchSupervisor: async () => { launches += 1; },
    },
    expected, oldEpoch: "candidate-epoch", timeoutMs: 500,
    replaceableProcess: candidate,
  }), /unknown live listener/);
  assert.equal(launches, 0);

  let selectionRestored = false;
  await assert.rejects(restoreAndVerifyReplacement({
    restore: async () => { selectionRestored = true; },
    validateRestored: async () => assert.equal(selectionRestored, true),
    replacement: {
      readListener: async () => undefined,
      readHealth: async () => health,
      launchSupervisor: async () => { throw new Error("launchctl refused"); },
    },
    expected, oldEpoch: "candidate-epoch", timeoutMs: 500,
  }), /launchctl refused/);
  assert.equal(selectionRestored, true);

  launched = false; now = 0;
  await assert.rejects(restoreAndVerifyReplacement({
    restore: async () => {}, validateRestored: async () => {},
    replacement: {
      ...replacement,
      readListener: async () => launched ? restored : undefined,
      readHealth: async () => ({ ...health, buildFingerprint: "b".repeat(64) }),
      launchSupervisor: async () => { launched = true; },
    },
    expected, oldEpoch: "candidate-epoch", timeoutMs: 500,
  }), /coherent replacement/);
});

test("committed marker consumed by launcher requires exact selection and live identity revalidation", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-pending-interleave-"));
  try {
    const store = await paths(root);
    await mkdir(store.channelRoot, { recursive: true });
    const target = selection("candidate", "b".repeat(64));
    const manifest = {
      ...target, sourceRevision: "tested-revision", runtimeEpoch: "candidate-epoch",
    };
    await writeFile(store.current, `${JSON.stringify(target)}\n`);
    await writeFile(store.pending, `${JSON.stringify({
      schema: 1, kind: "tron-gateway-pending-attempt", channel: "stable", attempt: "committed",
      version: target.version, payloadFingerprint: target.payloadFingerprint,
      previousVersion: "old", previousFingerprint: "a".repeat(64),
    })}\n`);
    // The launcher consumes the committed marker before the helper clears it.
    await rm(store.pending);
    const confirmed = await confirmAndClearPendingAttempt(
      store, target, manifest, "old-epoch",
      { host: "127.0.0.1", port: 9847, timeoutMs: 2_000 },
      async () => ({
        buildFingerprint: manifest.payloadFingerprint,
        sourceRevision: manifest.sourceRevision,
        runtimeEpoch: manifest.runtimeEpoch,
      }),
    );
    assert.equal(confirmed.runtimeEpoch, manifest.runtimeEpoch);
    await assert.rejects(confirmAndClearPendingAttempt(
      store, target, manifest, "old-epoch",
      { host: "127.0.0.1", port: 9847, timeoutMs: 2_000 },
      async () => ({
        buildFingerprint: "c".repeat(64), sourceRevision: manifest.sourceRevision,
        runtimeEpoch: manifest.runtimeEpoch,
      }),
    ), /identity changed/);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("promotion readiness requires exact candidate epoch and an epoch transition", () => {
  const expected = { payloadFingerprint: "a".repeat(64), sourceRevision: "revision", runtimeEpoch: "candidate-epoch" };
  assert.equal(healthMatchesCandidate({
    buildFingerprint: expected.payloadFingerprint, sourceRevision: expected.sourceRevision, runtimeEpoch: expected.runtimeEpoch,
  }, expected, "old-epoch"), true);
  assert.equal(healthMatchesCandidate({
    buildFingerprint: expected.payloadFingerprint, sourceRevision: expected.sourceRevision, runtimeEpoch: "wrong-epoch",
  }, expected, "old-epoch"), false);
  assert.equal(healthMatchesCandidate({
    buildFingerprint: expected.payloadFingerprint, sourceRevision: expected.sourceRevision, runtimeEpoch: expected.runtimeEpoch,
  }, expected, expected.runtimeEpoch), false);
});

test("duplicate promotion of the exact selected live candidate is verified and idempotent", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-idempotent-promote-"));
  try {
    const store = await paths(root);
    await mkdir(store.channelRoot, { recursive: true });
    const manifest = {
      schema: 1, kind: "tron-gateway-payload", channel: "stable", version: "candidate",
      gatewayVersion: "1.2.3", protocolVersion: "4", minProtocolVersion: "4", sourceRevision: "tested-revision", runtimeEpoch: "candidate-epoch",
      payloadFingerprint: "b".repeat(64),
    };
    const current = selection(manifest.version, manifest.payloadFingerprint);
    const previous = selection("previous", "a".repeat(64));
    await writeFile(store.current, `${JSON.stringify(current)}\n`);
    await writeFile(store.previous, `${JSON.stringify(previous)}\n`);
    await writeFile(store.state, `${JSON.stringify({
      state: "ready", channel: "stable", version: manifest.version,
      payloadFingerprint: manifest.payloadFingerprint, sourceRevision: manifest.sourceRevision,
      runtimeEpoch: manifest.runtimeEpoch,
    })}\n`);
    let reads = 0;
    const result = await verifyIdempotentPromotion({
      paths: store, channel: "stable", manifest, current,
      requestInfo: async () => {
        reads += 1;
        return {
          gatewayChannel: "stable", buildFingerprint: manifest.payloadFingerprint,
          sourceRevision: manifest.sourceRevision, runtimeEpoch: manifest.runtimeEpoch,
        };
      },
    });
    assert.equal(result?.state, "ready");
    assert.equal(result?.idempotent, true);
    assert.equal(reads, 1);
    assert.deepEqual(JSON.parse(await readFile(store.previous, "utf8")), previous);
    await assert.rejects(readFile(store.pending, "utf8"), { code: "ENOENT" });
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("Debug handoff copies exact bytes only after post-proof and leaves Stable inactive", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-debug-handoff-"));
  try {
    const bundledStable = await makePreflightFixture(join(root, "installed"));
    const devHome = join(root, "dev-home");
    const stableHome = join(root, "stable-home");
    const stagedDev = await stagePayload({
      home: devHome, channel: "dev", source: bundledStable,
      version: "tested-debug", sourceRevision: "tested-revision",
    });
    const devChannel = join(devHome, "gateway", "payloads", "dev");
    await writeFile(join(devChannel, "current.json"), `${JSON.stringify({
      schema: 1, kind: "tron-gateway-selection", channel: "dev",
      version: stagedDev.manifest.version, payloadFingerprint: stagedDev.manifest.payloadFingerprint,
    })}\n`);
    const info = {
      gatewayChannel: "dev",
      buildFingerprint: stagedDev.manifest.payloadFingerprint,
      sourceRevision: stagedDev.manifest.sourceRevision,
      runtimeEpoch: stagedDev.manifest.runtimeEpoch,
    };
    const result = await handoffDebugCandidate({
      devHome, stableHome, stableBundledRoot: bundledStable,
      host: "127.0.0.1", token: "t".repeat(32), requestInfo: async () => info,
      preflight: async () => stagedDev.manifest,
    });
    assert.equal(result.debugOriginIdentity.testedRuntimeEpoch, stagedDev.manifest.runtimeEpoch);
    const stableChannel = join(stableHome, "gateway", "payloads", "stable");
    await assert.rejects(readFile(join(stableChannel, "current.json")), /ENOENT/);
    const state = JSON.parse(await readFile(join(stableChannel, "deployment-state.json"), "utf8"));
    assert.equal(state.candidateOrigin, "debug");
    assert.deepEqual(state.debugOriginIdentity, {
      version: state.candidateIdentity.version,
      payloadFingerprint: state.candidateIdentity.payloadFingerprint,
      testedPayloadFingerprint: info.buildFingerprint,
      sourceRevision: info.sourceRevision,
      testedRuntimeEpoch: info.runtimeEpoch,
      candidateRuntimeEpoch: state.candidateIdentity.runtimeEpoch,
    });
    assert.equal(
      await readFile(join(stableChannel, "versions", result.version, "app", "dist", "index.js"), "utf8"),
      await readFile(join(devChannel, "versions", stagedDev.manifest.version, "app", "dist", "index.js"), "utf8"),
    );

    const stableStore = await paths(stableHome);
    assert.equal(
      await stagedCandidate(stableStore, undefined, undefined),
      undefined,
      "generic auto must not infer a Debug-origin candidate",
    );
    assert.equal(
      await stagedCandidate(stableStore, result.version, result.payloadFingerprint),
      result.version,
      "exact pinned promotion admits complete Debug provenance",
    );
    await writeFile(stableStore.state, `${JSON.stringify({
      ...state,
      debugOriginIdentity: { ...state.debugOriginIdentity, testedPayloadFingerprint: undefined },
    })}\n`);
    await assert.rejects(
      stagedCandidate(stableStore, result.version, result.payloadFingerprint),
      /provenance/,
    );

    const racedStableHome = join(root, "raced-stable-home");
    let reads = 0;
    await assert.rejects(handoffDebugCandidate({
      devHome, stableHome: racedStableHome, stableBundledRoot: bundledStable,
      host: "127.0.0.1", token: "t".repeat(32), preflight: async () => stagedDev.manifest,
      requestInfo: async () => (++reads === 1 ? info : { ...info, runtimeEpoch: "replacement-epoch" }),
    }), /changed while/);
    await assert.rejects(
      readFile(join(racedStableHome, "gateway", "payloads", "stable", "deployment-state.json")), /ENOENT/,
    );
  } finally {
    await runBounded("/bin/chmod", ["-R", "u+w", root], { timeoutMs: 5_000, maxOutputBytes: 8_192 }).catch(() => {});
    await rm(root, { recursive: true, force: true });
  }
});

test("apply accepts only bounded update controls and fails closed for source mode", async () => {
  assert.throws(() => validateApplyRequest({ channel: "dev", mode: "artifact", candidateVersion: "v1", commandId: "command-1" }), /fingerprint/);
  assert.deepEqual(validateApplyRequest({ channel: "dev", mode: "artifact", candidateVersion: "v1", candidateFingerprint: "a".repeat(64), commandId: "command-1" }), {
    channel: "dev", mode: "artifact", candidateVersion: "v1", candidateFingerprint: "a".repeat(64), commandId: "command-1",
  });
  assert.throws(() => validateApplyRequest({ channel: "stable", mode: "artifact", commandId: "command-1", source: "/tmp" }), /unsupported field/);
  assert.throws(() => validateApplyRequest({ channel: "stable", mode: "source", commandId: "short" }), /command ID/);
  const supervised = process.env.TRON_GATEWAY_SUPERVISED;
  const runtimeChannel = process.env.TRON_GATEWAY_CHANNEL;
  const dataDirectory = process.env.TRON_DATA_DIR;
  const isolatedHome = await mkdtemp(join(tmpdir(), "tron-apply-policy-"));
  process.env.TRON_GATEWAY_SUPERVISED = "1";
  process.env.TRON_GATEWAY_CHANNEL = "stable";
  process.env.TRON_DATA_DIR = isolatedHome;
  try {
    await assert.rejects(applyPayload({ channel: "dev", mode: "source", commandId: "command-1" }), /cannot update dev/);
    await assert.rejects(applyPayload({ channel: "stable", mode: "source", commandId: "command-1" }), /trusted Gateway update config/);
  } finally {
    if (supervised === undefined) delete process.env.TRON_GATEWAY_SUPERVISED;
    else process.env.TRON_GATEWAY_SUPERVISED = supervised;
    if (runtimeChannel === undefined) delete process.env.TRON_GATEWAY_CHANNEL;
    else process.env.TRON_GATEWAY_CHANNEL = runtimeChannel;
    if (dataDirectory === undefined) delete process.env.TRON_DATA_DIR;
    else process.env.TRON_DATA_DIR = dataDirectory;
    await rm(isolatedHome, { recursive: true, force: true });
  }
});

test("runBounded settles at the kill deadline when a descendant retains pipes", async () => {
  const started = Date.now();
  await assert.rejects(
    runBounded(process.execPath, ["-e", "require('node:child_process').spawn(process.execPath,['-e','setInterval(()=>{},100000)'],{stdio:'inherit'}); setInterval(()=>{},100000)"], { timeoutMs: 50, maxOutputBytes: 1024 }),
    /timed out/
  );
  assert.ok(Date.now() - started < 4_000);
});

test("deployment transitions reject skipping identity proof", () => {
  assert.equal(deploymentTransition("prepared", "published"), "published");
  assert.equal(deploymentTransition("published", "restartRequested"), "restart-requested");
  assert.equal(deploymentTransition("restart-requested", "ready"), "ready");
  assert.throws(() => deploymentTransition("published", "ready"), /invalid deployment transition/);
});
