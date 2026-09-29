import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { drainDurableWriteStats } from "../util/durable-json.js";
import { ConnectionOwner } from "./connection-owner.js";

describe("ConnectionOwner", () => {
  it("exposes paid Jev tagging only through the generic connection approval policy", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-jev-tag-connection-"));
    try {
    const owner = new ConnectionOwner(home);
    const setup = await owner.execute({ kind: "setup.begin", commandId: "jev-tag-begin-0001", instanceId: "tagger", definitionId: "knowledge.jev", method: "token" }) as { operationId: string };
    await owner.execute({ kind: "setup.complete", commandId: "jev-tag-complete-0001", operationId: setup.operationId, instanceId: "tagger", providerAccountId: "personal", credentialRef: "connector:jev:personal", policy: { enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 500, recurringApproved: false } });
    await owner.recordProviderObservation("tagger", 1, { credentialAvailability: "available", providerIdentity: "unknown" });
    expect((await owner.snapshot()).capabilities).toContainEqual(expect.objectContaining({ id: "tag", connectionId: "tagger", availability: "unavailable", detail: "Paid access approval is required for this capability" }));
    await owner.execute({ kind: "policy.update", commandId: "jev-tag-approve-0001", instanceId: "tagger", expectedSetupRevision: 1, policy: { enabled: true, allowWrites: false, paidAccessApproved: true, paidBudgetCents: 500, recurringApproved: false } });
    await owner.recordProviderObservation("tagger", 2, { credentialAvailability: "available", providerIdentity: "unknown" });
    expect((await owner.snapshot()).capabilities).toContainEqual(expect.objectContaining({ id: "tag", connectionId: "tagger", availability: "available" }));
    } finally { await rm(home, { recursive: true, force: true }); }
  });
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
      expect(snapshot.instances.every(item => item.credentialAvailability === "unknown" && item.providerIdentity === "unknown")).toBe(true);
      await expect(owner.recordProviderObservation("account-one", 0, { credentialAvailability: "available", providerIdentity: "admitted" })).rejects.toThrow("no longer admitted");
      await owner.recordProviderObservation("account-one", 1, { credentialAvailability: "available", providerIdentity: "admitted", providerDisplayName: "one@example.test" });
      await owner.recordProviderObservation("account-two", 1, { credentialAvailability: "available", providerIdentity: "admitted" });
      const admitted = await owner.snapshot();
      expect(admitted.instances.find(item => item.id === "account-one")).toMatchObject({ credentialConfigured: true, credentialAvailability: "available", providerIdentity: "admitted", providerDisplayName: "one@example.test", health: "ready" });
      await expect(owner.recordProviderObservation("account-one", 0, { credentialAvailability: "available", providerIdentity: "admitted", providerDisplayName: "stale@example.test" })).rejects.toThrow("no longer admitted");
      await owner.recordProviderObservation("account-one", 1, { credentialAvailability: "available", providerIdentity: "mismatch", providerDisplayName: "ignored@example.test" });
      expect((await owner.snapshot()).instances.find(item => item.id === "account-one")?.providerDisplayName).toBeUndefined();
      await owner.recordProviderObservation("account-one", 1, { credentialAvailability: "available", providerIdentity: "admitted" });
      expect(admitted.capabilities.find(item => item.id === "move" && item.connectionId === "account-one")).toMatchObject({ availability: "unavailable", detail: "Write approval is required for this capability" });
      expect(admitted.capabilities.find(item => item.id === "assess" && item.connectionId === "account-one")).toMatchObject({ availability: "unavailable", detail: "Paid access approval is required for this capability" });
      expect(admitted.capabilities.find(item => item.id === "move" && item.connectionId === "account-two")?.availability).toBe("available");
      await expect(owner.admitRuntimeBinding({ schemaVersion: 1, integrationId: "knowledge.raindrop", connectionId: "account-one", capabilityId: "move", sessionId: "session-one", runtimeGeneration: 1, provider: { owner: "connection", definitionId: "knowledge.raindrop", connectionId: "account-one" } })).rejects.toThrow("Write approval is required");
      await owner.execute({ kind: "policy.update", commandId: "policy-approve-one-0001", instanceId: "account-one", expectedSetupRevision: 1, policy: { enabled: true, allowWrites: true, paidAccessApproved: true, paidBudgetCents: 25, recurringApproved: false } });
      const latestPolicy = (await owner.resolveInstance("account-one")).policy;
      // A distinct stale command cannot revoke or restore fields from the old
      // sheet; replay of the accepted command still returns its original receipt.
      await expect(owner.execute({ kind: "policy.update", commandId: "stale-policy-one-0001", instanceId: "account-one", expectedSetupRevision: 1, policy: { ...latestPolicy, allowWrites: false } })).rejects.toThrow("Connection changed");
      expect((await owner.resolveInstance("account-one")).policy).toEqual(latestPolicy);
      await expect(owner.execute({ kind: "policy.update", commandId: "policy-approve-one-0001", instanceId: "account-one", expectedSetupRevision: 1, policy: latestPolicy })).resolves.toMatchObject({ setupRevision: 2 });
      await owner.recordProviderObservation("account-one", 2, { credentialAvailability: "available", providerIdentity: "admitted", providerDisplayName: "one@example.test" });
      const approved = await owner.snapshot();
      expect(approved.capabilities.find(item => item.id === "move" && item.connectionId === "account-one")?.availability).toBe("available");
      expect(approved.capabilities.find(item => item.id === "assess" && item.connectionId === "account-one")?.availability).toBe("available");
      await expect(owner.execute({ kind: "setup.complete", commandId: "late-complete-0001", operationId: first.operationId, instanceId: "account-two", providerAccountId: "999", credentialRef: "connector:raindrop:wrong", policy: { enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false } })).rejects.toThrow("another instance");
      await owner.execute({ kind: "disconnect", commandId: "disconnect-one-0001", instanceId: "account-one" });
      const after = await owner.snapshot();
      expect(after.instances.find(item => item.id === "account-one")?.health).toBe("disconnected");
      expect(after.instances.find(item => item.id === "account-two")?.health).toBe("ready");
    } finally { await rm(home, { recursive: true, force: true }); }
  });

  it("skips an unchanged provider observation and persists every changed one", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-connections-observation-"));
    try {
      const owner = new ConnectionOwner(home);
      const setup = await owner.execute({ kind: "setup.begin", commandId: "observe-begin-0001", instanceId: "observed", definitionId: "knowledge.raindrop", method: "token" }) as { operationId: string };
      await owner.execute({ kind: "setup.complete", commandId: "observe-complete-0001", operationId: setup.operationId, instanceId: "observed", providerAccountId: "42", scope: "0", credentialRef: "connector:raindrop:observed", policy: { enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false } });
      const path = join(home, "state/integrations/connections.json");
      const admission = { credentialAvailability: "available", providerIdentity: "admitted", providerDisplayName: "owner@example.test" } as const;
      await owner.recordProviderObservation("observed", 1, admission);
      const unchanged = await readFile(path, "utf8");
      const unchangedMtimeMs = (await stat(path)).mtimeMs;
      const unchangedRevision = (JSON.parse(unchanged) as { stateRevision: number }).stateRevision;
      drainDurableWriteStats();
      // An identical observation is already the projection: the read-triggered
      // call must not rewrite the document, bump its revision, or fsync.
      await owner.recordProviderObservation("observed", 1, admission);
      expect(drainDurableWriteStats().count).toBe(0);
      expect((await stat(path)).mtimeMs).toBe(unchangedMtimeMs);
      expect(await readFile(path, "utf8")).toBe(unchanged);
      expect((await owner.snapshot()).stateRevision).toBe(unchangedRevision);
      // A renamed provider account changes only the display label; the
      // projection must not keep the old name.
      drainDurableWriteStats();
      await owner.recordProviderObservation("observed", 1, { credentialAvailability: "available", providerIdentity: "admitted", providerDisplayName: "renamed@example.test" });
      expect(drainDurableWriteStats().count).toBe(2);
      const renamed = JSON.parse(await readFile(path, "utf8")) as { stateRevision: number; instances: Record<string, Record<string, unknown>> };
      expect(renamed.stateRevision).toBe(unchangedRevision + 1);
      expect(renamed.instances.observed).toMatchObject({ credentialAvailability: "available", providerIdentity: "admitted", providerDisplayName: "renamed@example.test", health: "ready" });
      // A changed availability/identity is a state transition: it must land,
      // with the derived health and without a stale display label.
      drainDurableWriteStats();
      await owner.recordProviderObservation("observed", 1, { credentialAvailability: "available", providerIdentity: "mismatch", providerDisplayName: "ignored@example.test" });
      expect(drainDurableWriteStats().count).toBe(2);
      const mismatched = JSON.parse(await readFile(path, "utf8")) as { stateRevision: number; instances: Record<string, Record<string, unknown>> };
      expect(mismatched.stateRevision).toBe(unchangedRevision + 2);
      expect(mismatched.instances.observed).toMatchObject({ credentialAvailability: "available", providerIdentity: "mismatch", health: "auth-error" });
      expect(mismatched.instances.observed.providerDisplayName).toBeUndefined();
      await owner.recordProviderObservation("observed", 1, { credentialAvailability: "unavailable", providerIdentity: "unknown" });
      const unavailable = (await owner.snapshot()).instances.find(item => item.id === "observed");
      expect(unavailable).toMatchObject({ credentialAvailability: "unavailable", providerIdentity: "unknown", health: "auth-error" });
      expect(unavailable?.providerDisplayName).toBeUndefined();
      // An identity change that keeps the derived health and availability the
      // same is still a different admission state, not an unchanged one.
      await owner.recordProviderObservation("observed", 1, { credentialAvailability: "unavailable", providerIdentity: "mismatch" });
      expect((await owner.snapshot()).instances.find(item => item.id === "observed")).toMatchObject({ credentialAvailability: "unavailable", providerIdentity: "mismatch", health: "auth-error" });
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
