import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeObservationService } from "./knowledge-observation.js";
import { KnowledgeService, type KnowledgeGenerationModel } from "./knowledge-service.js";
import { KnowledgeStore } from "./knowledge-store.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

function model(): KnowledgeGenerationModel {
  return {
    async reflect() { return "generated handoff"; },
    async synthesize() { return "generated synthesis"; },
    async assess() { return { summary: "Useful source", evidenceQuality: "high", freshness: "current" }; },
  };
}

function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(r => { resolve = r; }); return { promise, resolve }; }

describe("KnowledgeService integration", () => {
  it("routes source triage through the persisted source and model seam", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-knowledge-service-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const source = await store.captureSource({ commandId: "service-source", record: {
      kind: "source", scope: "research", provenance: { actor: "user", evidence: [] }, relations: [],
      content: { title: "Retained source", text: "bounded source evidence", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z", origin: "manual" },
    }});
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {}, () => model());
    const result = await service.invoke({ operation: "knowledge.source.triage", request: { commandId: "service-triage", sourceId: source.record.id, expectedRevision: source.record.revisionId } });
    expect(result).toMatchObject({ assessment: { summary: "Useful source", evidenceQuality: "high" } });
    expect((await store.read(source.record.id))?.content).toMatchObject({ assessment: { summary: "Useful source" } });
  });

  it("rejects reflection queued behind a configuration change", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-knowledge-service-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const initial = await store.config();
    const configured = await store.configure("service-reflect-queue-config", { ...initial, observation: { ...initial.observation, model: "fixture/model" }, eligibility: { ...initial.eligibility, sessionIds: ["queued-session"] } });
    const range = { sessionId: "queued-session", branchId: "queued-branch", fromEntryId: "queued-entry", toEntryId: "queued-entry", entryIds: ["queued-entry"], entryDigest: "a".repeat(64) };
    const source = await store.publishObservationGroup({ commandId: "service-reflect-queue-source", expectedConfigRevision: configured.revision, coverage: { id: "service-reflect-queue-coverage", range, disposition: "observed" }, records: [{ kind: "observation", scope: "personal", provenance: { actor: "agent", sessionId: range.sessionId, branchId: range.branchId, evidence: [] }, relations: [], content: { range, items: [{ text: "queued", attribution: "user", observedAt: "2026-01-01T00:00:00Z", certainty: "qualified" }] } }] });
    const release = deferred<void>();
    const blocker = (store as unknown as { mutex: { run<T>(operation: () => Promise<T>): Promise<T> } }).mutex.run(() => release.promise);
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {}, () => model());
    const reflection = service.invoke({ operation: "knowledge.reflect", request: { commandId: "service-reflect-queued", sessionId: range.sessionId, sourceRevisionIds: [source.records[0]!.revisionId] } }).then(() => false, () => true);
    const changed = store.configure("service-reflect-queued-change", { ...configured, currentInterests: ["changed"] });
    try { await vi.waitFor(() => expect((store as unknown as { mutex: { waiting: Set<unknown> } }).mutex.waiting.size).toBe(2)); }
    finally { release.resolve(); }
    await blocker; await changed;
    expect(await reflection).toBe(true);
    expect((await store.list({ kind: "note" })).records).toHaveLength(0);
  });

  it("rejects reflection cancellation while queued for serialized publication", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-knowledge-service-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const initial = await store.config();
    const configured = await store.configure("service-reflect-cancel-config", { ...initial, observation: { ...initial.observation, model: "fixture/model" }, eligibility: { ...initial.eligibility, sessionIds: ["cancel-session"] } });
    const range = { sessionId: "cancel-session", branchId: "cancel-branch", fromEntryId: "cancel-entry", toEntryId: "cancel-entry", entryIds: ["cancel-entry"], entryDigest: "b".repeat(64) };
    const source = await store.publishObservationGroup({ commandId: "service-reflect-cancel-source", expectedConfigRevision: configured.revision, coverage: { id: "service-reflect-cancel-coverage", range, disposition: "observed" }, records: [{ kind: "observation", scope: "personal", provenance: { actor: "agent", sessionId: range.sessionId, branchId: range.branchId, evidence: [] }, relations: [], content: { range, items: [{ text: "cancel", attribution: "user", observedAt: "2026-01-01T00:00:00Z", certainty: "qualified" }] } }] });
    const release = deferred<void>();
    const blocker = (store as unknown as { mutex: { run<T>(operation: () => Promise<T>): Promise<T> } }).mutex.run(() => release.promise);
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {}, () => model());
    const cancellation = new AbortController();
    const reflection = service.invoke({ operation: "knowledge.reflect", request: { commandId: "service-reflect-cancelled", sessionId: range.sessionId, sourceRevisionIds: [source.records[0]!.revisionId] } }, cancellation.signal).then(() => false, () => true);
    try { await vi.waitFor(() => expect((store as unknown as { mutex: { waiting: Set<unknown> } }).mutex.waiting.size).toBe(1)); cancellation.abort(); }
    finally { release.resolve(); }
    await blocker;
    expect(await reflection).toBe(true);
    expect((await store.list({ kind: "note" })).records).toHaveLength(0);
  });

  it("preserves source actor while recording trusted confirmation and supports agent note reads/updates", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-knowledge-service-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined));
    const created = await service.invoke({ operation: "knowledge.note.create", request: {
      commandId: "service-agent-note", confirmedByUser: true,
      record: { kind: "note", scope: "personal", provenance: { actor: "agent", source: "automation", evidence: [] }, relations: [], content: { title: "Agent note", body: "initial", role: "fact", confirmed: true },
    }}});
    expect(created).toMatchObject({ record: { provenance: { actor: "agent" }, content: { confirmed: true } } });
    const record = (created as { record: { id: string; revisionId: string } }).record;
    const updated = await service.tool({ action: "updateNote", commandId: "service-agent-note-update", id: record.id, revisionId: record.revisionId, title: "Agent note", noteBody: "updated" });
    expect(updated.details).toMatchObject({ record: { provenance: { actor: "agent" }, content: { body: "updated", confirmed: false } } });
    const read = await service.tool({ action: "read", id: record.id, revisionId: (updated.details as { record: { revisionId: string } }).record.revisionId });
    expect(read.details).toMatchObject({ record: { provenance: { actor: "agent" }, content: { body: "updated" } } });
  });

  it("synthesizes exact source and note revisions through the registered knowledge tool", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-knowledge-service-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const configured = await store.configure("service-synthesis-config", { ...(await store.config()), observation: { ...(await store.config()).observation, enabled: true, model: "fixture/model" } });
    const source = await store.captureSource({ commandId: "service-synthesis-source", record: {
      kind: "source", scope: "research", provenance: { actor: "connector", source: "fixture:account:item", evidence: [] }, relations: [],
      content: { title: "Partial source", text: "source evidence", captureDisposition: "partial", capturedAt: "2026-01-01T00:00:00Z" },
    }});
    const note = await store.createNote({ commandId: "service-synthesis-note", record: {
      kind: "note", scope: "research", provenance: { actor: "user", evidence: [] }, relations: [],
      content: { title: "Qualification", body: "candidate claim", role: "preference", confirmed: false, freshness: "aging", contraryEvidence: [{ recordId: source.record.id, revisionId: source.record.revisionId }] },
    }});
    let input = "";
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {}, () => ({ ...model(), async synthesize(request) { input = request.sourceText; return "bounded synthesis retaining uncertainty"; } }));
    const result = await service.tool({ action: "synthesis", commandId: "service-synthesis", sessionId: "synthetic-session", sourceRevisionIds: [source.record.revisionId, note.record.revisionId] });
    const generated = (result.details as { record: import("./knowledge-contract.js").KnowledgeRecord }).record;
    expect(generated).toMatchObject({ kind: "note", scope: "research", content: { role: "synthesis", confirmed: false, body: "bounded synthesis retaining uncertainty" } });
    expect(generated.provenance.evidence).toEqual([{ recordId: source.record.id, revisionId: source.record.revisionId }, { recordId: note.record.id, revisionId: note.record.revisionId }]);
    expect(input).toContain("disposition=partial");
    expect(input).toContain("confirmed=false");
    expect(input).toContain("contraryEvidence");
    expect(configured.revision).toBe(1);
  });

  it("does not publish a late synthesis when the model ignores cancellation", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-knowledge-service-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    await store.configure("service-late-config", { ...(await store.config()), observation: { ...(await store.config()).observation, enabled: true, model: "fixture/model" } });
    const source = await store.captureSource({ commandId: "service-late-source", record: { kind: "source", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [], content: { title: "Source", text: "evidence", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z" } } });
    const controller = new AbortController();
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {}, () => ({ ...model(), async synthesize() { return "late result"; } }));
    controller.abort(new Error("cancelled"));
    await expect(service.tool({ action: "synthesis", commandId: "service-late-synthesis", sessionId: "synthetic-session", sourceRevisionIds: [source.record.revisionId] }, controller.signal)).rejects.toMatchObject({ code: "busy" });
    expect((await store.list({ kind: "note" })).records).toHaveLength(0);
  });

  it("rejects excluded observation revisions before invoking the Reflector", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-knowledge-service-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const config = await store.configure("service-reflect-config", { ...(await store.config()), observation: { ...(await store.config()).observation, model: "fixture/model" }, eligibility: { ...(await store.config()).eligibility, sessionIds: ["service-session"] } });
    const range = { sessionId: "service-session", fromEntryId: "service-entry", toEntryId: "service-entry", entryIds: ["service-entry"], entryDigest: "a".repeat(64) };
    const published = await store.publishObservationGroup({ commandId: "service-reflect-source", expectedConfigRevision: config.revision, coverage: { id: "service-reflect-coverage", range, disposition: "observed" }, records: [{ kind: "observation", scope: "personal", provenance: { actor: "agent", sessionId: range.sessionId, evidence: [] }, relations: [], content: { range, items: [{ text: "withheld", attribution: "user", observedAt: "2026-01-01T00:00:00Z", certainty: "qualified" }] } }] });
    await store.setScopeExclusion("service-reflect-exclude", { sessionId: range.sessionId }, true, "privacy");
    let calls = 0;
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {}, () => ({ ...model(), async reflect() { calls += 1; return "must not run"; } }));
    await expect(service.invoke({ operation: "knowledge.reflect", request: { commandId: "service-reflect", sessionId: range.sessionId, sourceRevisionIds: [published.records[0]!.revisionId] } })).rejects.toThrow();
    expect(calls).toBe(0);
    expect(await store.read(published.records[0]!.id)).toBeNull();
  });

  it("exposes typed connector sweeps to existing Automation tool callers", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-knowledge-service-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {
      connector: async action => ({ operation: action.operation, accepted: true }),
    });
    const result = await service.tool({ action: "connectorSweep", commandId: "service-sweep", connector: "raindrop", dryRun: true, limit: 1 });
    expect(result.text).toContain("connector sweep completed");
    expect(result.details).toEqual({ operation: "knowledge.connector.run", accepted: true });
  });

  it("rejects connector and importer calls without an installed extension", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-knowledge-service-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined));
    await expect(service.invoke({ operation: "knowledge.connector.status", request: { connector: "raindrop" } })).rejects.toMatchObject({ code: "unsupported" });
    await expect(service.invoke({ operation: "knowledge.import.dry-run", request: { commandId: "service-import", source: "synthetic", limit: 1 } })).rejects.toMatchObject({ code: "unsupported" });
  });
});
