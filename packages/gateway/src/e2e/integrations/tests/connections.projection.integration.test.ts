import { chmod, mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { startLockGateway } from "../../../../test-support/gateway-lock-harness.js";
import { ConnectionOwner } from "../../../integrations/connection-owner.js";
import { createTronCoreExtension } from "../../../workspace/tron-core-extension.js";

// The agent `connections` tool is the owner's only consumer. Historical state on
// disk is projected as-is: credential references never leave the owner, nothing
// is initialized, migrated or rewritten, and production advertises no definitions.
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

    // A supported definition never advertises an available capability for a
    // disconnected or unadmitted instance.
    await writeFile(path, JSON.stringify({ ...state, instances: { "retired-source": { ...state.instances["retired-source"], health: "disconnected", policy: { ...policy, enabled: false } } } }), { mode: 0o600 });
    const defined = await new ConnectionOwner(home, [{
      schemaVersion: 1, id: "knowledge.raindrop", implementation: "knowledge-connector", displayName: "Raindrop", setupMethods: ["token"],
      capabilities: [{ id: "read", displayName: "Read bookmarks", effects: ["read"], supported: true }],
    }]).snapshot();
    expect(defined.capabilities).toEqual([{
      id: "read", availability: "unavailable", effects: ["read"], definitionId: "knowledge.raindrop", connectionId: "retired-source",
      provenance: { owner: "connection", definitionId: "knowledge.raindrop", connectionId: "retired-source" }, detail: "Connection is disconnected",
    }]);
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
