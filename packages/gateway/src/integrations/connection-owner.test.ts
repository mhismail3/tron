import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ConnectionOwner } from "./connection-owner.js";

describe("ConnectionOwner", () => {
  it("keeps two same-provider accounts isolated and requires exact setup operations", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-connections-"));
    try {
      const owner = new ConnectionOwner(home);
      const first = await owner.execute({ kind: "setup.begin", commandId: "begin-one-0001", instanceId: "account-one", definitionId: "knowledge.raindrop", method: "token" }) as { operationId: string };
      const second = await owner.execute({ kind: "setup.begin", commandId: "begin-two-0001", instanceId: "account-two", definitionId: "knowledge.raindrop", method: "token" }) as { operationId: string };
      expect(first.operationId).not.toBe(second.operationId);
      await owner.execute({ kind: "setup.complete", commandId: "complete-one-0001", operationId: first.operationId, instanceId: "account-one", providerAccountId: "100", scope: "0", credentialRef: "connector:raindrop:one", policy: { enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false } });
      await owner.execute({ kind: "setup.complete", commandId: "complete-two-0001", operationId: second.operationId, instanceId: "account-two", providerAccountId: "200", scope: "0", credentialRef: "connector:raindrop:two", policy: { enabled: true, allowWrites: true, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false } });
      const snapshot = await owner.snapshot();
      expect(snapshot.instances.map(item => item.providerAccountId).sort()).toEqual(["100", "200"]);
      expect("credentialRef" in snapshot.instances[0]!).toBe(false);
      expect(snapshot.capabilities.filter(item => item.id === "read" && item.connectionId).map(item => item.connectionId).sort()).toEqual(["account-one", "account-two"]);
      await expect(owner.execute({ kind: "setup.complete", commandId: "late-complete-0001", operationId: first.operationId, instanceId: "account-two", providerAccountId: "999", credentialRef: "connector:raindrop:wrong", policy: { enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false } })).rejects.toThrow("another instance");
      await owner.execute({ kind: "disconnect", commandId: "disconnect-one-0001", instanceId: "account-one" });
      const after = await owner.snapshot();
      expect(after.instances.find(item => item.id === "account-one")?.health).toBe("disconnected");
      expect(after.instances.find(item => item.id === "account-two")?.health).toBe("ready");
    } finally { await rm(home, { recursive: true, force: true }); }
  });

  it("replays an identical command receipt without a second publication", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-connections-"));
    try {
      const owner = new ConnectionOwner(home);
      const command = { kind: "setup.begin" as const, commandId: "begin-replay-0001", instanceId: "replay", definitionId: "knowledge.x", method: "token" as const };
      const first = await owner.execute(command);
      const stateBefore = JSON.parse(await readFile(join(home, "state/integrations/connections.json"), "utf8"));
      const second = await owner.execute(command);
      const stateAfter = JSON.parse(await readFile(join(home, "state/integrations/connections.json"), "utf8"));
      expect(second).toEqual(first);
      expect(stateAfter.stateRevision).toBe(stateBefore.stateRevision);
    } finally { await rm(home, { recursive: true, force: true }); }
  });

  it("rejects malformed persisted state and does not repair it", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-connections-"));
    try {
      const path = join(home, "state/integrations/connections.json");
      await (await import("node:fs/promises")).mkdir(join(home, "state/integrations"), { recursive: true, mode: 0o700 });
      await (await import("node:fs/promises")).writeFile(path, JSON.stringify({ schemaVersion: 99 }), { mode: 0o600 });
      await expect(new ConnectionOwner(home).snapshot()).rejects.toThrow("unavailable");
      expect(JSON.parse(await readFile(path, "utf8")).schemaVersion).toBe(99);
    } finally { await rm(home, { recursive: true, force: true }); }
  });
});
