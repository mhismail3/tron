import { describe, expect, it } from "vitest";
import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { KnowledgeCatalog } from "../knowledge/knowledge-catalog.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "../knowledge/knowledge-store.js";
import { ConnectionOwner, connectionStatePath } from "./connection-owner.js";
import { prepareConnectionMigration, publishConnectionMigration, readLegacyConnectorState, recoverConnectionMigration, resolveConnectionMigrationPaths, stageConnectionMigration, type KnowledgeConnectorSource } from "./connection-migration.js";

const source = () => ({
  schemaVersion: 1 as const,
  storageVersion: 2 as const,
  catalogID: "11111111-1111-4111-8111-111111111111",
  stateRevision: 17,
  config: { schemaVersion: 1, revision: 3, eligibility: { sessionIds: [], projectIds: [], excludedSessionIds: [], excludedProjectIds: [] } },
  connectors: {
    raindrop: { connector: "raindrop" as const, enabled: true, accountId: "100", scope: "0", credentialRef: "connector:raindrop:one", allowWrites: true, paidAccessApproved: true, paidBudgetCents: 25, recurringApproved: false, health: "ready", remaining: 1, pending: [{ id: "9", title: "pending", url: "https://example.test/pending" }], capturedIds: ["1"], checkpoints: { "0": "cursor-7" }, pendingRemote: { operationId: "move-1", itemId: "9", action: "move", basisRecordId: "r", basisRevisionId: "v", provider: "raindrop", accountId: "100", originalCollectionId: "0", destination: "1", createdAt: "2026-01-01T00:00:00.000Z" }, assessmentPilot: { id: "pilot", maxItems: 1, budgetCents: 1, usedItems: 0, reservedCents: 1, accountId: "100", sourceCollection: "0", profileVersion: "p", itemIds: ["9"] }, assessmentAttempts: { "pilot:9": { itemId: "9", cohortId: "pilot", status: "dispatched", chargeCents: 1 } } },
  },
  receipts: { "knowledge.connector.state\u0000page-1": { operation: "discover", requestHash: "abc", result: { value: true }, recordIds: [] } },
});

describe("connection migration", () => {
  it("inspects an existing workspace without taking ownership or creating missing state", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-read-only-migration-"));
    const workspace = new TronWorkspace(home);
    try {
      const absent = await TronWorkspace.describeExisting(join(home, "missing"));
      expect(absent.available).toBe(false);
      expect(await readdir(home)).toEqual([]);
      await workspace.initialize();
      const before = await readdir(join(home, "gateway", "workspace-state"));
      expect((await TronWorkspace.describeExisting(home)).available).toBe(true);
      expect(await readdir(join(home, "gateway", "workspace-state"))).toEqual(before);
      expect((await workspace.describe()).available).toBe(true);
    } finally { await workspace.dispose(); await rm(home, { recursive: true, force: true }); }
  });

  it("rejects a pre-catalog connector-only snapshot instead of inventing an authority", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-connection-source-"));
    try {
      const path = join(home, "state.json");
      await writeFile(path, JSON.stringify({ ...source(), storageVersion: undefined, catalogID: undefined, records: {}, coverage: {}, suppressions: {}, scopeExclusions: {}, cleanup: [] }));
      await expect(readLegacyConnectorState(path)).rejects.toThrow("catalog-v2");
    } finally { await rm(home, { recursive: true, force: true }); }
  });

  it("reads the production catalog v2 control and receipt tables with the owner envelope", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-connection-catalog-"));
    try {
      const plan = prepareConnectionMigration(source());
      const catalogID = "11111111-1111-4111-8111-111111111111";
      const knowledgeRoot = join(home, "state/knowledge");
      await mkdir(knowledgeRoot, { recursive: true, mode: 0o700 });
      const catalogPath = join(knowledgeRoot, `catalog-${catalogID}.sqlite`);
      const catalog = new KnowledgeCatalog(catalogPath, false, true);
      const providerState = structuredClone(source().connectors.raindrop) as Record<string, unknown>;
      for (const key of ["enabled", "accountId", "scope", "credentialRef", "allowWrites", "paidAccessApproved", "paidBudgetCents", "recurringApproved"]) delete providerState[key];
      providerState.connectionId = Object.keys(plan.ownerState.instances)[0];
      catalog.setControl({ schemaVersion: 1, stateRevision: 17, catalogID, config: source().config, connectors: { [providerState.connectionId as string]: providerState } });
      catalog.table("receipts").set("knowledge.connector.state\\u0000page-1", { operation: "discover", requestHash: "abc", result: { kind: "value", value: true }, recordIds: [] });
      catalog.close();
      await writeFile(join(knowledgeRoot, "state.json"), JSON.stringify({ schemaVersion: 1, storageVersion: 2, catalogID }), { mode: 0o600 });
      await mkdir(join(home, "state/integrations"), { recursive: true, mode: 0o700 });
      await writeFile(join(home, "state/integrations/connections.json"), JSON.stringify(plan.ownerState), { mode: 0o600 });
      const read = await readLegacyConnectorState(join(knowledgeRoot, "state.json"), join(home, "state/integrations/connections.json"));
      expect(read.storageVersion).toBe(2);
      expect(read.connectors[providerState.connectionId as string]!.credentialRef).toBe("connector:raindrop:one");
      expect(read.receipts["knowledge.connector.state\\u0000page-1"]).toBeDefined();
      expect(prepareConnectionMigration(read).providerStates[0]?.state.pendingRemote).toBeDefined();
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
    expect(plan.authoritySelection).toEqual({ canonicalOwner: "connection-owner", providerStateOwner: "knowledge" });
  });

  it("migrates the real workspace catalog through KnowledgeStore and ConnectionOwner", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-connection-production-layout-"));
    const home = join(root, "home");
    const workspace = new TronWorkspace(home);
    try {
      const store = new KnowledgeStore(workspace);
      await store.captureSource({ commandId: "knowledge-migration-record", record: {
        kind: "source", scope: "research", provenance: { actor: "user", evidence: [] }, relations: [],
        content: { title: "retained catalog record", text: "immutable evidence", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z", origin: "manual" },
      } });
      const initialConfig = await store.config();
      await store.configure("knowledge-migration-config", { ...initialConfig, revision: initialConfig.revision });
      await store.updateConnectorState("knowledge-migration-source", "raindrop", () => ({
        connector: "raindrop", enabled: true, allowWrites: true,
        paidAccessApproved: true, paidBudgetCents: 25, recurringApproved: false,
        accountId: "100", scope: "0", credentialRef: "connector:raindrop:one",
        health: "ready", remaining: 1, pending: [{ id: "9", title: "pending", url: "https://example.test/pending" }],
        capturedIds: ["1"], checkpoints: { "0": "cursor-7" },
      }));
      const paths = await resolveConnectionMigrationPaths(workspace, home);
      await expect(readFile(paths.ownerPath, "utf8")).rejects.toMatchObject({ code: "ENOENT" });
      expect(paths.statePath).toBe(join(paths.knowledgeRoot, "state.json"));
      expect(paths.ownerPath).toBe(connectionStatePath(home));
      const plan = await prepareConnectionMigration(paths);
      const staging = join(root, "private-staging/connection");
      await stageConnectionMigration(plan, staging);
      await publishConnectionMigration(staging, true);
      await workspace.dispose();

      const owner = new ConnectionOwner(home);
      const snapshot = await owner.snapshot();
      const instance = snapshot.instances[0];
      expect(instance?.providerAccountId).toBe("100");
      expect(instance?.id).toBeDefined();
      const reopenedWorkspace = new TronWorkspace(home);
      const reopened = new KnowledgeStore(reopenedWorkspace, undefined, async connectionId => owner.resolveInstance(connectionId));
      const migrated = await reopened.connectorState("raindrop", instance!.id);
      expect(migrated).toMatchObject({ connectionId: instance!.id, connector: "raindrop", health: "ready", pending: [{ id: "9" }] });
      expect((await reopened.list({ kind: "source" })).records).toHaveLength(1);
      expect((await reopened.config()).revision).toBe(initialConfig.revision + 1);
      await reopened.withConnectorContext(instance!.id, async () => {
        await reopened.updateConnectorState("knowledge-migration-receipt", "raindrop", current => ({ ...current!, lastRunAt: "2026-01-01T00:00:00.000Z" }), { operation: "test" });
        await reopened.updateConnectorState("knowledge-migration-receipt", "raindrop", () => { throw new Error("receipt replay must not execute update"); }, { operation: "test" });
      });
      expect((await reopened.connectorState("raindrop", instance!.id))?.lastRunAt).toBe("2026-01-01T00:00:00.000Z");
      const setup = await owner.execute({ kind: "setup.begin", commandId: "migration-second-begin", instanceId: "connection:raindrop:second", definitionId: "knowledge.raindrop", method: "token" }) as { operationId: string };
      const second = await owner.execute({ kind: "setup.complete", commandId: "migration-second-complete", operationId: setup.operationId, instanceId: "connection:raindrop:second", providerAccountId: "200", credentialRef: "connector:raindrop:two", policy: { enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false } }) as { id: string };
      for (const connectionId of [instance!.id, second.id]) {
        await reopened.withConnectorContext(connectionId, async () => {
          const commandId = `same-provider-${connectionId}`;
          await reopened.updateConnectorState(commandId, "raindrop", current => ({ ...(current ?? { connector: "raindrop", enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false, health: "ready", remaining: 1, pending: [], capturedIds: [] }), lastRunAt: "2026-01-02T00:00:00.000Z" }));
          await reopened.updateConnectorState(commandId, "raindrop", () => { throw new Error("separated receipt replay must not execute update"); });
        });
      }
      await reopenedWorkspace.dispose();
    } finally { await workspace.dispose(); await rm(root, { recursive: true, force: true }); }
  });

  it("fails closed on staged tampering and source revision drift", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-connection-tamper-"));
    const home = join(root, "home");
    const workspace = new TronWorkspace(home);
    try {
      const store = new KnowledgeStore(workspace);
      await store.updateConnectorState("migration-tamper-source", "raindrop", () => ({ connector: "raindrop", enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false, accountId: "100", credentialRef: "connector:raindrop:one", health: "ready", remaining: 1, pending: [], capturedIds: [] }));
      const paths = await resolveConnectionMigrationPaths(workspace, home);
      const plan = await prepareConnectionMigration(paths);
      const staging = join(root, "staging");
      await stageConnectionMigration(plan, staging);
      await expect(publishConnectionMigration(staging, false)).rejects.toThrow("approval");
      const stagedPlan = JSON.parse(await readFile(join(staging, "plan.json"), "utf8")) as { providerStates: Array<{ state: Record<string, unknown> }> };
      stagedPlan.providerStates[0]!.state.tampered = true;
      await writeFile(join(staging, "plan.json"), JSON.stringify(stagedPlan), { mode: 0o600 });
      await expect(publishConnectionMigration(staging, true)).rejects.toThrow("plan contents");
      await expect(readFile(paths.ownerPath, "utf8")).rejects.toMatchObject({ code: "ENOENT" });
    } finally { await workspace.dispose(); await rm(root, { recursive: true, force: true }); }

    const driftRoot = await mkdtemp(join(tmpdir(), "tron-connection-drift-"));
    const driftHome = join(driftRoot, "home");
    const driftWorkspace = new TronWorkspace(driftHome);
    try {
      const store = new KnowledgeStore(driftWorkspace);
      await store.updateConnectorState("migration-drift-source", "raindrop", () => ({ connector: "raindrop", enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false, accountId: "100", credentialRef: "connector:raindrop:one", health: "ready", remaining: 1, pending: [], capturedIds: [] }));
      const paths = await resolveConnectionMigrationPaths(driftWorkspace, driftHome);
      const plan = await prepareConnectionMigration(paths);
      const staging = join(driftRoot, "staging");
      await stageConnectionMigration(plan, staging);
      await writeFile(paths.statePath, `${JSON.stringify(JSON.parse(await readFile(paths.statePath, "utf8")))}\\n`, { mode: 0o600 });
      await expect(publishConnectionMigration(staging, true)).rejects.toThrow("source changed");
      await expect(readFile(paths.ownerPath, "utf8")).rejects.toMatchObject({ code: "ENOENT" });
    } finally { await driftWorkspace.dispose(); await rm(driftRoot, { recursive: true, force: true }); }
  });

  it.each(["prepared", "owner-published", "knowledge-published"] as const)("recovers the %s publication crash window", async phase => {
    const root = await mkdtemp(join(tmpdir(), `tron-connection-recovery-${phase}-`));
    const home = join(root, "home");
    const workspace = new TronWorkspace(home);
    try {
      const store = new KnowledgeStore(workspace);
      await store.updateConnectorState(`migration-recovery-${phase}`, "raindrop", () => ({ connector: "raindrop", enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false, accountId: "100", credentialRef: "connector:raindrop:one", health: "ready", remaining: 1, pending: [], capturedIds: [] }));
      const paths = await resolveConnectionMigrationPaths(workspace, home);
      const plan = await prepareConnectionMigration(paths);
      const staging = join(root, "staging");
      await stageConnectionMigration(plan, staging);
      if (phase === "owner-published") { await mkdir(join(home, "state/integrations"), { recursive: true, mode: 0o700 }); await writeFile(paths.ownerPath, JSON.stringify(plan.ownerState), { mode: 0o600 }); }
      if (phase === "knowledge-published") await publishConnectionMigration(staging, true);
      const journal = JSON.parse(await readFile(join(staging, "journal.json"), "utf8")) as Record<string, unknown>;
      journal.phase = phase;
      await writeFile(join(staging, "journal.json"), JSON.stringify(journal), { mode: 0o600 });
      await expect((await recoverConnectionMigration(staging)).phase).toBe("published");
    } finally { await workspace.dispose(); await rm(root, { recursive: true, force: true }); }
  });

  it("rejects newer, incomplete, malformed and conflicting production state", () => {
    expect(() => prepareConnectionMigration({ ...source(), schemaVersion: 2 })).toThrow("schema");
    expect(() => prepareConnectionMigration({ ...source(), connectors: { raindrop: { ...source().connectors.raindrop, accountId: "" } } })).toThrow("account/ref");
    const duplicate = source() as KnowledgeConnectorSource;
    duplicate.connectors.second = { ...duplicate.connectors.raindrop!, connector: "raindrop" };
    expect(() => prepareConnectionMigration(duplicate)).toThrow("conflicting duplicate");
  });
});
