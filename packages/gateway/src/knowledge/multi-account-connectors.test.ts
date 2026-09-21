import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it } from "vitest";
import { ConnectionOwner } from "../integrations/connection-owner.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { KnowledgeConnectorExtension, type ConnectorHTTPResponse } from "./connectors.js";
import { InMemoryConnectorCredentialStore } from "./connector-credentials.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });
const response = (value: unknown): ConnectorHTTPResponse => ({ status: 200, headers: new Headers(), body: JSON.stringify(value) });

it("runs same-provider accounts against separate refs, identity fences, checkpoints, and receipts", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-multi-account-")); roots.push(root);
  const owner = new ConnectionOwner(root);
  const first = await owner.execute({ kind: "setup.begin", commandId: "begin-first-0001", instanceId: "first", definitionId: "knowledge.raindrop", method: "token" }) as { operationId: string };
  const second = await owner.execute({ kind: "setup.begin", commandId: "begin-second-0001", instanceId: "second", definitionId: "knowledge.raindrop", method: "token" }) as { operationId: string };
  await owner.execute({ kind: "setup.complete", commandId: "complete-first-0001", operationId: first.operationId, instanceId: "first", providerAccountId: "101", scope: "0", credentialRef: "connector:raindrop:first", policy: { enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false } });
  await owner.execute({ kind: "setup.complete", commandId: "complete-second-0001", operationId: second.operationId, instanceId: "second", providerAccountId: "202", scope: "0", credentialRef: "connector:raindrop:second", policy: { enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false } });
  const store = new KnowledgeStore(new TronWorkspace(root));
  const calls: string[] = [];
  let mismatchFirstIdentity = false;
  const extension = new KnowledgeConnectorExtension(store, {
    connections: owner,
    credentials: new InMemoryConnectorCredentialStore(new Map([["connector:raindrop:first", "token-first"], ["connector:raindrop:second", "token-second"]])),
    http: async (url, init) => {
      calls.push(`${init.headers.authorization}:${url}`);
      if (url.endsWith("/user")) return response({ user: { _id: init.headers.authorization === "Bearer token-first" ? (mismatchFirstIdentity ? 202 : 101) : 202 } });
      const firstAccount = init.headers.authorization === "Bearer token-first";
      const items = Array.from({ length: 50 }, (_, index) => firstAccount
        ? { _id: 11 + index, title: "first", link: `https://first.example/${index}` }
        : { _id: 22 + index, title: "second", link: `https://second.example/${index}` });
      return response({ items, meta: { page: 0, has_more: true } });
    },
    sleep: async () => {},
    sourceFetch: async (_url, _excerpt) => new Response("captured", { headers: { "content-type": "text/plain" } }),
  });
  await expect(extension.invoke({ operation: "knowledge.connector.run", request: { commandId: "pre-migration-0001", connector: "raindrop", dryRun: true, limit: 1 } })).rejects.toThrow("connectionId");
  for (const [id, commandId] of [["first", "configure-first-0001"], ["second", "configure-second-0001"]] as const) {
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId, connector: "raindrop", connectionId: id, enabled: true } });
  }
  const beforeAdmission = await extension.invoke({ operation: "knowledge.connector.status", request: { connector: "raindrop", connectionId: "first" } }) as { health: string; credentialAvailability: string; providerIdentity: string };
  expect(beforeAdmission).toMatchObject({ health: "setup-required", credentialAvailability: "unknown", providerIdentity: "unknown" });
  mismatchFirstIdentity = true;
  await expect(extension.invoke({ operation: "knowledge.connector.run", request: { commandId: "run-first-fenced-0001", connector: "raindrop", connectionId: "first", dryRun: false, limit: 1 } })).rejects.toThrow("authenticated account");
  const mismatched = await extension.invoke({ operation: "knowledge.connector.status", request: { connector: "raindrop", connectionId: "first" } }) as { providerIdentity: string };
  expect(mismatched.providerIdentity).toBe("mismatch");
  mismatchFirstIdentity = false;
  await extension.invoke({ operation: "knowledge.connector.run", request: { commandId: "run-first-0001", connector: "raindrop", connectionId: "first", dryRun: false, limit: 1 } });
  await extension.invoke({ operation: "knowledge.connector.run", request: { commandId: "run-second-0001", connector: "raindrop", connectionId: "second", dryRun: false, limit: 1 } });
  const afterAdmission = await extension.invoke({ operation: "knowledge.connector.status", request: { connector: "raindrop", connectionId: "first" } }) as { health: string; credentialAvailability: string; providerIdentity: string; connectionId?: string };
  expect(afterAdmission).toMatchObject({ connectionId: "first", credentialAvailability: "available", providerIdentity: "admitted" });
  expect(["ready", "partial"]).toContain(afterAdmission.health);
  // The same command ID is valid across accounts only because the receipt
  // operation includes the admitted connection identity.
  await store.updateConnectorState("checkpoint-shared-0001", "raindrop", state => ({ ...(state ?? {} as any), checkpoints: { page: "1" } }), { checkpoint: "first" }, "first");
  await store.updateConnectorState("checkpoint-shared-0001", "raindrop", state => ({ ...(state ?? {} as any), checkpoints: { page: "2" } }), { checkpoint: "second" }, "second");
  const firstState = await store.connectorState("raindrop", "first");
  const secondState = await store.connectorState("raindrop", "second");
  expect(firstState?.connectionId).toBe("first"); expect(secondState?.connectionId).toBe("second");
  expect(firstState?.pending.map(item => item.id)).toEqual(["11"]); expect(secondState?.pending.map(item => item.id)).toEqual(["22"]);
  expect(firstState?.checkpoints).toEqual({ page: "1" }); expect(secondState?.checkpoints).toEqual({ page: "2" });
  expect(calls.filter(call => call.includes("Bearer token-first")).length).toBeGreaterThan(0);
  expect(calls.filter(call => call.includes("Bearer token-second")).length).toBeGreaterThan(0);
  await expect(extension.invoke({ operation: "knowledge.connector.run", request: { commandId: "run-cross-account-0001", connector: "raindrop", connectionId: "first", dryRun: false, limit: 1 } })).resolves.toBeDefined();
  expect((await store.connectorState("raindrop", "second"))?.pending.map(item => item.id)).toEqual(["22"]);
});
