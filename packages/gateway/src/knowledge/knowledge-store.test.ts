import { afterEach, describe, expect, it } from "vitest";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { DEFAULT_KNOWLEDGE_CONFIG, type KnowledgeRecordDraft } from "./knowledge-contract.js";
import { KnowledgeStore } from "./knowledge-store.js";

const roots: string[] = [];
const workspaces: TronWorkspace[] = [];
afterEach(async () => {
  await Promise.all(workspaces.splice(0).map(workspace => workspace.dispose()));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

async function fixture(): Promise<{ store: KnowledgeStore; home: string; workspace: TronWorkspace }> {
  const root = await mkdtemp(join(tmpdir(), "tron-knowledge-"));
  roots.push(root);
  const home = join(root, "home");
  const workspace = new TronWorkspace(home);
  workspaces.push(workspace);
  return { store: new KnowledgeStore(workspace), home, workspace };
}

const source = (title: string): KnowledgeRecordDraft & { kind: "source" } => ({
  kind: "source", scope: "research", provenance: { actor: "user", evidence: [] }, relations: [],
  content: { title, text: `${title} retained evidence`, captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z", origin: "manual" },
});
const observation = (sessionId: string, fromEntryId: string): KnowledgeRecordDraft & { kind: "observation" } => ({
  kind: "observation", scope: "personal", provenance: { actor: "agent", sessionId, evidence: [] }, relations: [],
  content: { range: { sessionId, fromEntryId, toEntryId: fromEntryId }, items: [{ text: "The user corrected the plan", attribution: "user", observedAt: "2026-01-01T00:00:00Z", certainty: "certain" }] },
});

function command(suffix: string): string { return `knowledge-test-${suffix}`; }

describe("KnowledgeStore", () => {
  it("is lazy, durable across reopen, and returns lexical canonical results", async () => {
    const { store, home, workspace } = await fixture();
    expect((await store.status()).state).toBe("uninitialized");
    const result = await store.captureSource({ commandId: command("capture"), record: source("Durable source") });
    expect((await store.status()).state).toBe("ready");
    expect((await store.search({ query: "durable" })).hits[0]?.record.revisionId).toBe(result.record.revisionId);
    expect((await store.captureSource({ commandId: command("capture"), record: source("Durable source") })).record.revisionId).toBe(result.record.revisionId);

    await workspace.dispose();
    const reopenedWorkspace = new TronWorkspace(home);
    workspaces.push(reopenedWorkspace);
    const reopened = new KnowledgeStore(reopenedWorkspace);
    expect((await reopened.read(result.record.id))?.revisionId).toBe(result.record.revisionId);
    expect((await reopened.list()).records).toHaveLength(1);
  });

  it("rejects stale writers and keeps immutable record revisions", async () => {
    const { store } = await fixture();
    const created = await store.createNote({ commandId: command("note-create"), record: {
      kind: "note", scope: "personal", provenance: { actor: "user", evidence: [] }, relations: [],
      content: { title: "Preference", body: "old", role: "preference", confirmed: true },
    }});
    const updated = await store.updateNote({ commandId: command("note-update"), recordId: created.record.id, expectedRevision: created.record.revisionId, record: {
      kind: "note", scope: "personal", provenance: { actor: "user", evidence: [] }, relations: [],
      content: { title: "Preference", body: "new", role: "preference", confirmed: true },
    }});
    await expect(store.updateNote({ commandId: command("note-stale"), recordId: created.record.id, expectedRevision: created.record.revisionId, record: {
      kind: "note", scope: "personal", provenance: { actor: "user", evidence: [] }, relations: [],
      content: { title: "Preference", body: "bad", role: "preference", confirmed: true },
    }})).rejects.toThrow("stale");
    expect((await store.read(created.record.id, created.record.revisionId))?.content).toMatchObject({ body: "old" });
    expect((await store.read(created.record.id))?.revisionId).toBe(updated.record.revisionId);
  });

  it("publishes observation coverage with its group and recovers failed coverage", async () => {
    const { store } = await fixture();
    const failed = await store.setCoverage({ commandId: command("coverage-failed"), coverage: {
      id: "coverage-1", range: { sessionId: "session-1", fromEntryId: "entry-1", toEntryId: "entry-1" }, disposition: "failed", groupRevisionIds: [],
    }});
    expect((await store.coverage("coverage-1"))?.disposition).toBe("failed");
    const published = await store.publishObservationGroup({ commandId: command("coverage-recover"), expectedCoverageRevision: failed.coverage.revisionId, coverage: {
      id: "coverage-1", range: failed.coverage.range, disposition: "observed",
    }, records: [observation("session-1", "entry-1")] });
    expect(published.coverage.groupRevisionIds).toEqual([published.records[0]!.revisionId]);
    expect((await store.coverage("coverage-1"))?.disposition).toBe("observed");
    expect((await store.recall({ sessionId: "session-1", entryId: "entry-1" })).records).toHaveLength(1);
  });

  it("durably suppresses and forgets, then cleans referenced objects", async () => {
    const { store } = await fixture();
    const object = await store.putObject(new TextEncoder().encode("private evidence"), "text/plain");
    const created = await store.captureSource({ commandId: command("object-source"), record: { ...source("Object source"), content: { ...source("Object source").content, text: undefined, object } } });
    await store.setExclusion(command("exclude"), created.record.id, true, created.record.revisionId, "not for recall");
    expect((await store.list()).records).toHaveLength(0);
    expect((await store.list({ includeSuppressed: true })).records).toHaveLength(1);
    await store.forget(command("forget"), created.record.id, "user requested deletion", created.record.revisionId);
    expect(await store.read(created.record.id)).toBeNull();
    await expect(store.captureSource({ commandId: command("resurrection"), record: { ...source("resurrection"), id: created.record.id } })).rejects.toThrow("forgotten");
    expect((await store.status()).pendingCleanupCount).toBe(1);
    expect((await store.reconcile()).removedObjects).toEqual([object.hash]);
    expect((await store.status()).pendingCleanupCount).toBe(0);
  });

  it("preserves unsafe and newer state instead of resetting it", async () => {
    const { store, home } = await fixture();
    await store.captureSource({ commandId: command("unsafe-seed"), record: source("Seed") });
    const statePath = join(home, "workspace/state/knowledge/state.json");
    await writeFile(statePath, "{\"schemaVersion\":2}");
    await chmod(statePath, 0o600);
    expect((await store.status()).state).toBe("newer");
    await expect(store.createNote({ commandId: command("blocked"), record: {
      kind: "note", scope: "personal", provenance: { actor: "user", evidence: [] }, relations: [], content: { title: "blocked", role: "fact", confirmed: false },
    }})).rejects.toThrow();
    expect(JSON.parse(await readFile(statePath, "utf8"))).toEqual({ schemaVersion: 2 });
  });

  it("keeps observation disabled until an explicit model is configured", async () => {
    const { store } = await fixture();
    expect((await store.status()).config).toEqual(DEFAULT_KNOWLEDGE_CONFIG);
    await store.configure(command("config"), { ...DEFAULT_KNOWLEDGE_CONFIG, observation: { ...DEFAULT_KNOWLEDGE_CONFIG.observation, enabled: true } });
    expect((await store.status()).observationConfigured).toBe(false);
  });
});
