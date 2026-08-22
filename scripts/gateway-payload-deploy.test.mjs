import { strict as assert } from "node:assert";
import { chmod, mkdir, mkdtemp, readFile, readlink, rm, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { test } from "node:test";
import {
  deploymentTransition,
  deploymentTimeoutMs,
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
  payloadFingerprint,
  buildSourcePayload,
  preflightPayload,
  proveDebugHandoffIdentity,
  handoffDebugCandidate,
  healthMatchesCandidate,
  waitForDrainCompletion,
  confirmAndClearPendingAttempt,
  verifyIdempotentPromotion,
  restoreSelectionStateAndClearAttempt,
  stagePayload,
  stagedCandidate,
  runBounded,
} from "./gateway-payload-deploy.mjs";

test("deployment timeout defaults to a valid bounded millisecond value", () => {
  assert.equal(deploymentTimeoutMs({}), 60_000);
  assert.equal(deploymentTimeoutMs({ TRON_GATEWAY_UPDATE_TIMEOUT_MS: "120000" }), 120_000);
  assert.throws(() => deploymentTimeoutMs({ TRON_GATEWAY_UPDATE_TIMEOUT_MS: "60_000" }), /invalid update timeout/);
  assert.throws(() => deploymentTimeoutMs({ TRON_GATEWAY_UPDATE_TIMEOUT_MS: "1999" }), /invalid update timeout/);
});

function selection(version, payloadFingerprint = "a".repeat(64)) {
  return { schema: 1, kind: "tron-gateway-selection", channel: "stable", version, payloadFingerprint };
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
  assert.equal(protocolHandshakeCompatible({ type: "hello", protocolVersion: 3, minProtocolVersion: 3 }), true);
  assert.equal(protocolHandshakeCompatible({ type: "hello", protocolVersion: 2, minProtocolVersion: 2 }), false);
  assert.equal(protocolHandshakeCompatible({ type: "hello", protocolVersion: 3 }), false);
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
    await writeFile(join(versionRoot, "app", "scripts", "ensure-node-pty-helper.mjs"), "// helper\n");
    await writeFile(join(versionRoot, "app", "scripts", "gateway-payload-deploy.mjs"), "// updater\n");
    await writeFile(join(versionRoot, "runtime", "node-arm64"), "n".repeat(1_048_576));
    await writeFile(join(versionRoot, "runtime", "node-x64"), "n".repeat(1_048_576));
    await chmod(join(versionRoot, "runtime", "node-arm64"), 0o755);
    await chmod(join(versionRoot, "runtime", "node-x64"), 0o755);
    await writeFile(join(versionRoot, "manifest.json"), "{}\n");
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
      gatewayVersion: "1", nodeVersion: "22", sourceRevision: "source", runtimeEpoch: "source-epoch",
      payloadFingerprint: sourceFingerprint,
    })}\n`);

    const home = join(root, "home");
    const staleLink = join(home, "gateway", "payloads", "dev", "versions", ".staging-stale", "app", "node_modules", ".bin", "escape");
    const outside = join(root, "outside");
    await mkdir(join(staleLink, ".."), { recursive: true });
    await writeFile(outside, "must remain\n");
    await symlink(outside, staleLink);

    const staged = await stagePayload({ home, channel: "dev", source: versionRoot, version: "candidate" });
    assert.equal(await readlink(join(staged.root, "app", "node_modules", ".bin", "tron")), "../../dist/index.js");
    await assert.rejects(readlink(staleLink), /ENOENT/);
    assert.equal(await readFile(outside, "utf8"), "must remain\n");
    for (const directory of [
      join(staged.root, "app", "node_modules", ".bin"), join(staged.root, "app", "node_modules"),
      join(staged.root, "app", "dist"), join(staged.root, "app", "scripts"),
      join(staged.root, "app"), join(staged.root, "runtime"), staged.root,
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
    await writeFile(join(versionRoot, "app", "scripts", "ensure-node-pty-helper.mjs"), "// helper\n");
    await writeFile(join(versionRoot, "app", "scripts", "gateway-payload-deploy.mjs"), "// updater\n");
    await writeFile(join(versionRoot, "runtime", "node-arm64"), "n".repeat(1_048_576));
    await writeFile(join(versionRoot, "runtime", "node-x64"), "n".repeat(1_048_576));
    await chmod(join(versionRoot, "runtime", "node-arm64"), 0o755);
    await chmod(join(versionRoot, "runtime", "node-x64"), 0o755);
    const fingerprint = await payloadFingerprint(versionRoot);
    const manifest = { schema: 1, kind: "tron-gateway-payload", channel: "stable", version: "active", gatewayVersion: "1", nodeVersion: "22", sourceRevision: "source", runtimeEpoch: "epoch", payloadFingerprint: fingerprint };
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
    await writeFile(join(versionRoot, "app", "scripts", "ensure-node-pty-helper.mjs"), "// helper\n");
    await writeFile(join(versionRoot, "app", "scripts", "gateway-payload-deploy.mjs"), "// updater\n");
    await writeFile(join(versionRoot, "runtime", "node-arm64"), "n".repeat(1_048_576));
    await writeFile(join(versionRoot, "runtime", "node-x64"), "n".repeat(1_048_576));
    await chmod(join(versionRoot, "runtime", "node-arm64"), 0o755);
    await chmod(join(versionRoot, "runtime", "node-x64"), 0o755);
    const fingerprint = await payloadFingerprint(versionRoot);
    const activeManifest = { schema: 1, kind: "tron-gateway-payload", channel: "stable", version: "active", gatewayVersion: "1", nodeVersion: "22", sourceRevision: "source", runtimeEpoch: "epoch", payloadFingerprint: fingerprint };
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
        } else await mkdir(join(options.cwd, "node_modules"), { recursive: true });
      },
    });
    assert.equal(result.manifest.version, "candidate");
    assert.equal(commands[0].tool, process.execPath);
    assert.equal(commands[0].args.includes("run"), false);
    assert.equal(await readFile(join(gatewayRoot, "dist", "index.js")).catch(() => undefined), undefined);
    for (const [path, content] of before) assert.deepEqual(await readFile(join(gatewayRoot, path)), content);
    assert.equal(await readFile(join(result.root, "app", "scripts", "gateway-payload-deploy.mjs"), "utf8"), "// trusted updater\n");
    assert.equal(await readFile(join(result.root, "app", "scripts", "ensure-node-pty-helper.mjs"), "utf8"), "// trusted helper\n");
    for (const directory of [
      join(store.versionsRoot, "candidate"), join(store.versionsRoot, "candidate", "app"),
      join(store.versionsRoot, "candidate", "app", "dist"), join(store.versionsRoot, "candidate", "app", "scripts"),
      join(store.versionsRoot, "candidate", "app", "node_modules"), join(store.versionsRoot, "candidate", "runtime"),
    ]) await chmod(directory, 0o755);
  } finally { await rm(root, { recursive: true, force: true }); }
});

async function makePreflightFixture(root) {
  const payload = join(root, "payload");
  await mkdir(join(payload, "app", "dist"), { recursive: true });
  await mkdir(join(payload, "app", "scripts"), { recursive: true });
  await mkdir(join(payload, "app", "node_modules"), { recursive: true });
  await mkdir(join(payload, "runtime"), { recursive: true });
  await writeFile(join(payload, "app", "dist", "index.js"), "x".repeat(1_024));
  await writeFile(join(payload, "app", "dist", "version.js"), "export const PROTOCOL_VERSION = 3; export const MIN_PROTOCOL_VERSION = 3;\n");
  await writeFile(join(payload, "app", "package.json"), "{}\n");
  await writeFile(join(payload, "app", "package-lock.json"), "{}\n");
  await writeFile(join(payload, "app", "scripts", "ensure-node-pty-helper.mjs"), "// helper\n");
  await writeFile(join(payload, "app", "scripts", "gateway-payload-deploy.mjs"), "// updater\n");
  await writeFile(join(payload, "runtime", "node-arm64"), "n".repeat(1_048_576));
  await writeFile(join(payload, "runtime", "node-x64"), "n".repeat(1_048_576));
  await chmod(join(payload, "runtime", "node-arm64"), 0o755);
  await chmod(join(payload, "runtime", "node-x64"), 0o755);
  const fingerprint = await payloadFingerprint(payload);
  await writeFile(join(payload, "manifest.json"), JSON.stringify({
    schema: 1, kind: "tron-gateway-payload", channel: "stable", version: "preflight",
    gatewayVersion: "1", nodeVersion: "22", sourceRevision: "source", runtimeEpoch: "epoch",
    payloadFingerprint: fingerprint,
  }));
  return payload;
}

test("preflight imports candidate protocol values and rejects incompatible ranges", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-preflight-protocol-"));
  try {
    const payload = await makePreflightFixture(root);
    const run = async (_tool, args) => args[0] === "-e"
      ? { code: 0, output: JSON.stringify({ protocolVersion: 3, minProtocolVersion: 3 }) }
      : { code: 0, output: "" };
    await preflightPayload(payload, run);
    await assert.rejects(
      preflightPayload(payload, async (_tool, args) => args[0] === "-e"
        ? { code: 0, output: JSON.stringify({ protocolVersion: 4, minProtocolVersion: 4 }) }
        : { code: 0, output: "" }),
      /protocol range is incompatible/
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
      gatewayVersion: "1.2.3", sourceRevision: "tested-revision", runtimeEpoch: "candidate-epoch",
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
