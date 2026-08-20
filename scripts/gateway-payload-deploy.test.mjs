import { strict as assert } from "node:assert";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
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

test("deployment transitions reject skipping identity proof", () => {
  assert.equal(deploymentTransition("prepared", "published"), "published");
  assert.equal(deploymentTransition("published", "restartRequested"), "restart-requested");
  assert.equal(deploymentTransition("restart-requested", "ready"), "ready");
  assert.throws(() => deploymentTransition("published", "ready"), /invalid deployment transition/);
});
