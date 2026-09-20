import { describe, expect, it } from "vitest";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { prepareConnectionMigration, publishConnectionMigration, readLegacyConnectorState, recoverConnectionMigration, verifyMigrationPlan } from "./connection-migration.js";

const source = () => ({
  schemaVersion: 1 as const,
  stateRevision: 17,
  config: { schemaVersion: 1, revision: 3, eligibility: { sessionIds: [], projectIds: [], excludedSessionIds: [], excludedProjectIds: [] } },
  connectors: {
    raindrop: { connector: "raindrop" as const, enabled: true, accountId: "100", scope: "0", credentialRef: "connector:raindrop:one", allowWrites: true, paidAccessApproved: true, paidBudgetCents: 25, recurringApproved: false, checkpoints: { "0": "cursor-7" }, pending: [{ id: "9", title: "pending", url: "https://example.test/pending" }], capturedIds: ["1"], pendingRemote: { operationId: "move-1", itemId: "9", action: "move", basisRecordId: "r", basisRevisionId: "v", provider: "raindrop", accountId: "100", originalCollectionId: "0", destination: "1", createdAt: "2026-01-01T00:00:00.000Z" }, assessmentPilot: { id: "pilot", maxItems: 1, budgetCents: 1, usedItems: 0, reservedCents: 1, accountId: "100", sourceCollection: "0", profileVersion: "p", itemIds: ["9"] }, assessmentAttempts: { "pilot:9": { itemId: "9", cohortId: "pilot", status: "dispatched", chargeCents: 1 } } },
  },
  receipts: { "knowledge.connector.state\u0000page-1": { operation: "discover", requestHash: "abc", result: { value: true }, recordIds: [] } },
});

describe("connection migration", () => {
  it("reads the real pre-catalog Knowledge state shape", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-connection-source-"));
    try {
      const path = join(home, "state.json");
      await writeFile(path, JSON.stringify({ ...source(), records: {}, coverage: {}, suppressions: {}, scopeExclusions: {}, cleanup: [], config: { schemaVersion: 1, revision: 0 } }));
      const read = await readLegacyConnectorState(path);
      expect(read.stateRevision).toBe(17);
      expect(read.connectors.raindrop.pendingRemote).toBeDefined();
      expect(read.receipts["knowledge.connector.state\u0000page-1"]).toBeDefined();
    } finally { await rm(home, { recursive: true, force: true }); }
  });

  it("splits generic envelope while preserving provider progress and global receipts", () => {
    const plan = prepareConnectionMigration(source(), "state.json");
    expect(Object.values(plan.ownerState.instances)).toHaveLength(1);
    const first = plan.providerStates[0]!;
    expect(first.state.accountId).toBeUndefined();
    expect(first.state.checkpoints).toEqual({ "0": "cursor-7" });
    expect(first.state.pendingRemote).toBeDefined();
    expect(first.state.assessmentPilot).toBeDefined();
    expect(first.state.assessmentAttempts).toBeDefined();
    expect(plan.knowledgeReceipts).toEqual(source().receipts);
    expect(plan.planHash).toMatch(/^[a-f0-9]{64}$/);
    expect(() => verifyMigrationPlan(plan, plan.planHash)).not.toThrow();
    const tampered = structuredClone(plan); (tampered.providerStates[0]!.state.pendingRemote as Record<string, unknown>).destination = "99";
    expect(() => verifyMigrationPlan(tampered, plan.planHash)).toThrow("contents");
  });

  it("publishes owner and provider authorities with resumable publication metadata", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-connection-migration-"));
    try {
      const plan = prepareConnectionMigration(source());
      const target = { ownerPath: join(home, "state/integrations/connections.json"), providerPath: join(home, "state/knowledge-connectors.json"), publicationPath: join(home, "state/publication.json") };
      await expect(publishConnectionMigration(plan, target, plan.planHash, false)).rejects.toThrow("approval");
      const publication = await publishConnectionMigration(plan, target, plan.planHash, true);
      expect(publication.phase).toBe("published");
      expect(JSON.parse(await readFile(target.ownerPath, "utf8")).instances).toBeDefined();
      const provider = JSON.parse(await readFile(target.providerPath, "utf8"));
      expect(provider.connectors[Object.keys(provider.connectors)[0]].pendingRemote).toBeDefined();
      expect(provider.receipts).toEqual(source().receipts);
      expect((await recoverConnectionMigration(target.publicationPath)).phase).toBe("published");
      await expect(publishConnectionMigration(plan, target, plan.planHash, true)).rejects.toThrow("already exists");
    } finally { await rm(home, { recursive: true, force: true }); }
  });

  it("rejects newer, incomplete, malformed and conflicting production state", () => {
    expect(() => prepareConnectionMigration({ schemaVersion: 2, stateRevision: 1, config: {}, connectors: {}, receipts: {} })).toThrow("schema");
    expect(() => prepareConnectionMigration({ schemaVersion: 1, stateRevision: 1, config: {}, connectors: { raindrop: { ...source().connectors.raindrop, accountId: "" } }, receipts: {} })).toThrow("account/ref");
    const duplicate = source(); duplicate.connectors.second = { ...duplicate.connectors.raindrop };
    expect(() => prepareConnectionMigration(duplicate)).toThrow("conflicting duplicate");
  });
});
