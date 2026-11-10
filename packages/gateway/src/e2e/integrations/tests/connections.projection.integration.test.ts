import { chmod, mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it, vi } from "vitest";
import { startLockGateway } from "../../../../test-support/gateway-lock-harness.js";
import { ConnectionOwner } from "../../../integrations/connection-owner.js";

const beforePublish = vi.hoisted(() => ({ hook: undefined as undefined | (() => Promise<void>), directorySync: undefined as undefined | string }));
vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return { ...actual, open: async (...args: Parameters<typeof actual.open>) => {
    const hook = beforePublish.hook;
    if (hook && String(args[0]).includes("connections.json.migration-")) { beforePublish.hook = undefined; await hook(); }
    if (beforePublish.directorySync === String(args[0])) { beforePublish.directorySync = undefined; throw new Error("directory sync failed"); }
    return actual.open(...args);
  } };
});
import { applyConnectionsResidue, planConnectionsResidue, restoreConnectionsResidue } from "../../../integrations/connections-residue-migration.js";
import { createTronCoreExtension } from "../../../workspace/tron-core-extension.js";

it("projects retained connection state read-only and redacts credential references through the agent tool", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-connections-projection-"));
  try {
    const home = join(root, "tron");
    await mkdir(home, { mode: 0o700 });
    const empty = new ConnectionOwner(home);
    expect(await empty.snapshot()).toEqual({ definitions: [], instances: [], setupOperations: [], capabilities: [], stateRevision: 0 });
    await expect(stat(join(home, "gateway", "integrations"))).rejects.toMatchObject({ code: "ENOENT" });

    const credentialRef = "connector:raindrop:preserved-only-reference";
    const at = "2026-01-01T00:00:00.000Z";
    const policy = { enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false };
    const state = {
      schemaVersion: 1, stateRevision: 2,
      instances: { "retired-source": { id: "retired-source", definitionId: "knowledge.raindrop", implementation: "knowledge-connector", providerAccountId: "fixture-account", credentialRef, policy, health: "setup-required", createdAt: at, updatedAt: at, setupRevision: 1, credentialAvailability: "unknown", providerIdentity: "unknown" } },
      setupOperations: { "retired-operation": { operationId: "retired-operation", instanceId: "retired-source", definitionId: "knowledge.raindrop", method: "token", status: "completed", createdAt: at, updatedAt: at } },
      receipts: { "retired-complete": { operation: "setup.complete", requestHash: "fixture", createdAt: at, result: { id: "retired-source" } } },
    };
    const directory = join(home, "gateway", "integrations");
    await mkdir(directory, { recursive: true, mode: 0o700 });
    await chmod(directory, 0o700);
    const path = join(directory, "connections.json");
    await writeFile(path, JSON.stringify(state), { mode: 0o600 });
    const before = await readFile(path, "utf8");

    let tool: { execute: () => Promise<{ content: Array<{ text: string }>; details: unknown }> } | undefined;
    createTronCoreExtension({ describe: async () => ({ root, available: true }) } as never, undefined, new ConnectionOwner(home))({
      registerTool: (definition: typeof tool) => { tool = definition; },
      on: () => {},
    } as never);
    const result = await tool!.execute();
    const { credentialRef: _credentialRef, ...projected } = state.instances["retired-source"];
    expect(result.details).toEqual({
      definitions: [], capabilities: [], stateRevision: 2,
      instances: [{ ...projected, credentialConfigured: true }],
      setupOperations: [state.setupOperations["retired-operation"]],
    });
    expect(result.content[0]!.text).toBe(JSON.stringify(result.details));
    expect(result.content[0]!.text).not.toContain(credentialRef);
    expect(await readFile(path, "utf8")).toBe(before);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

it("removes retired setup operations, receipts and Raindrop mappings once, behind a restorable backup", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-connections-residue-"));
  try {
    const home = join(root, "tron"), directory = join(home, "gateway", "integrations"), path = join(directory, "connections.json");
    expect(await planConnectionsResidue(home)).toEqual({ path, setupOperations: 0, receipts: 0, collectionMappings: 0 });
    const at = "2026-01-01T00:00:00.000Z";
    const instance = { id: "raindrop", definitionId: "knowledge.raindrop", implementation: "knowledge-connector", providerAccountId: "1", credentialRef: "connector:raindrop:kept",
      policy: { enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false }, health: "ready", createdAt: at, updatedAt: at, setupRevision: 2,
      raindropCollections: [{ collectionId: "-1", role: "triage" }, { collectionId: "42", role: "research" }] };
    const state = {
      schemaVersion: 1, stateRevision: 7, instances: { raindrop: instance },
      setupOperations: { jev: { operationId: "jev", instanceId: "jev", definitionId: "knowledge.jev", method: "token", status: "completed", createdAt: at, updatedAt: at } },
      receipts: { one: { operation: "setup.complete", requestHash: "h", createdAt: at, result: null } },
    };
    await mkdir(directory, { recursive: true, mode: 0o700 });
    await writeFile(path, JSON.stringify(state), { mode: 0o600 });
    const original = await readFile(path);

    const plan = await planConnectionsResidue(home);
    expect(plan).toMatchObject({ setupOperations: 1, receipts: 1, collectionMappings: 1 });
    expect(await readFile(path)).toEqual(original);
    await mkdir(join(root, "used"));
    await writeFile(join(root, "used", "x"), "");
    await expect(applyConnectionsResidue(plan, join(root, "used"))).rejects.toThrow(/not empty/);
    await writeFile(path, JSON.stringify({ ...state, stateRevision: 8 }), { mode: 0o600 });
    await expect(applyConnectionsResidue(plan, join(root, "raced"))).rejects.toThrow(/changed while it was backed up/);
    await writeFile(path, original, { mode: 0o600 });
    const concurrent = JSON.stringify({ ...state, stateRevision: 9 });
    beforePublish.hook = () => writeFile(path, concurrent, { mode: 0o600 });
    await expect(applyConnectionsResidue(await planConnectionsResidue(home), join(root, "late"))).rejects.toThrow(/changed since it was read/);
    expect(await readFile(path, "utf8")).toBe(concurrent);
    await expect(restoreConnectionsResidue(join(root, "late"))).rejects.toThrow(/ENOENT.*manifest\.json/);
    await writeFile(path, original, { mode: 0o600 });
    beforePublish.directorySync = directory;
    await expect(applyConnectionsResidue(await planConnectionsResidue(home), join(root, "unsynced"))).rejects.toThrow(/directory sync failed/);
    expect(await planConnectionsResidue(home)).toEqual({ path, setupOperations: 0, receipts: 0, collectionMappings: 0 });
    expect(await restoreConnectionsResidue(join(root, "unsynced"))).toBe(true);
    expect(await readFile(path)).toEqual(original);
    await writeFile(path, original, { mode: 0o600 });
    await writeFile(path, JSON.stringify({ ...state, setupOperations: { jev: { ...state.setupOperations.jev, status: "unknown" } } }), { mode: 0o600 });
    await expect(planConnectionsResidue(home)).rejects.toThrow(/Setup operation is invalid/);
    await writeFile(path, original, { mode: 0o600 });

    const backup = join(root, "backup");
    expect(await applyConnectionsResidue(await planConnectionsResidue(home), backup)).toBe(true);
    const { raindropCollections: _mappings, ...kept } = instance;
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual({ schemaVersion: 1, stateRevision: 8, instances: { raindrop: kept }, setupOperations: {}, receipts: {} });
    const { credentialRef: _credentialRef, ...projected } = kept;
    expect(await new ConnectionOwner(home).snapshot()).toEqual({ definitions: [], capabilities: [], stateRevision: 8, setupOperations: [],
      instances: [{ ...projected, credentialConfigured: true, credentialAvailability: "unknown", providerIdentity: "unknown" }] });
    expect(await planConnectionsResidue(home)).toEqual({ path, setupOperations: 0, receipts: 0, collectionMappings: 0 });

    const migrated = await readFile(path);
    await writeFile(path, JSON.stringify({ ...JSON.parse(migrated.toString("utf8")), stateRevision: 9 }), { mode: 0o600 });
    await expect(restoreConnectionsResidue(backup)).rejects.toThrow(/changed after the migration/);
    await writeFile(path, migrated, { mode: 0o600 });
    await writeFile(join(backup, "connections.json"), "{}");
    await expect(restoreConnectionsResidue(backup)).rejects.toThrow(/does not match its manifest/);
    expect(await readFile(path)).toEqual(migrated);
    await writeFile(join(backup, "connections.json"), original);
    expect(await restoreConnectionsResidue(backup)).toBe(true);
    expect(await readFile(path)).toEqual(original);
    expect(await restoreConnectionsResidue(backup)).toBe(false);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

it("refuses the retired connection, extension-history, timeline and model-validation RPCs on the real socket", async () => {
  const gateway = await startLockGateway("connections-retired-rpcs", { automations: true });
  try {
    const phone = await gateway.connect("phone");
    for (const method of [
      "connections.list", "connections.setup.begin", "connections.setup.complete", "connections.setup.cancel", "connections.policy.update", "connections.disconnect",
      "session.extensionActivity.list", "session.extensionActivity.get", "automation.timeline.list", "models.custom.validate",
      "knowledge.x.oauth.begin", "knowledge.x.oauth.complete", "knowledge.x.credits",
    ]) {
      expect(await phone.request(method, {}), method).toMatchObject({ ok: false, error: { code: "not_found", message: `Unknown gateway method: ${method}` } });
    }
  } finally {
    await gateway.dispose();
  }
}, 60_000);
