import { strict as assert } from "node:assert";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { test } from "node:test";
import {
  deploymentTransition,
  publishSelection,
  rollbackSelection,
  resolveDeploymentHost,
  protocolHandshakeCompatible,
  validateLocalCredentialDocument,
  loadRollbackTarget,
  validateApplyRequest,
  applyPayload,
  sourceBuildCommands,
  validateUpdateConfigDocument,
  payloadFingerprint,
  buildSourcePayload,
} from "./gateway-payload-deploy.mjs";

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
    lock: join(channelRoot, ".update.lock"),
  };
}

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
        if (tool === process.execPath) {
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
    for (const directory of [
      join(store.versionsRoot, "candidate"), join(store.versionsRoot, "candidate", "app"),
      join(store.versionsRoot, "candidate", "app", "dist"), join(store.versionsRoot, "candidate", "app", "scripts"),
      join(store.versionsRoot, "candidate", "app", "node_modules"), join(store.versionsRoot, "candidate", "runtime"),
    ]) await chmod(directory, 0o755);
  } finally { await rm(root, { recursive: true, force: true }); }
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

test("apply accepts only bounded update controls and fails closed for source mode", async () => {
  assert.deepEqual(validateApplyRequest({ channel: "dev", mode: "artifact", candidateVersion: "v1", commandId: "command-1" }), {
    channel: "dev", mode: "artifact", candidateVersion: "v1", commandId: "command-1",
  });
  assert.throws(() => validateApplyRequest({ channel: "stable", mode: "artifact", commandId: "command-1", source: "/tmp" }), /unsupported field/);
  assert.throws(() => validateApplyRequest({ channel: "stable", mode: "source", commandId: "short" }), /command ID/);
  await assert.rejects(applyPayload({ channel: "stable", mode: "source", commandId: "command-1" }), /trusted Gateway update config/);
});

test("deployment transitions reject skipping identity proof", () => {
  assert.equal(deploymentTransition("prepared", "published"), "published");
  assert.equal(deploymentTransition("published", "restartRequested"), "restart-requested");
  assert.equal(deploymentTransition("restart-requested", "ready"), "ready");
  assert.throws(() => deploymentTransition("published", "ready"), /invalid deployment transition/);
});
