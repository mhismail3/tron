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
  it("clears only an exact failed cut through a durable, replayable terminal skip", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-knowledge-clear-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const initial = await store.config();
    const config = await store.configure("clear-cut-config", { ...initial, eligibility: { ...initial.eligibility, sessionIds: ["session-clear"] } });
    const range = { sessionId: "session-clear", fromEntryId: "e1", toEntryId: "e1", entryIds: ["e1"], entryDigest: "a".repeat(64) };
    const failed = await store.setCoverage({ commandId: "clear-cut-failed", expectedConfigRevision: config.revision,
      coverage: { id: "cut-failed", range, disposition: "failed", groupRevisionIds: [], reason: "Observer output must be an object" } });
    const goodRange = { ...range, fromEntryId: "e2", toEntryId: "e2", entryIds: ["e2"], entryDigest: "b".repeat(64) };
    const observed = await store.publishObservationGroup({ commandId: "clear-cut-observed", expectedConfigRevision: config.revision,
      coverage: { id: "cut-observed", range: goodRange, disposition: "observed" },
      records: [{ kind: "observation", scope: "personal", provenance: { actor: "agent", evidence: [] }, relations: [],
        content: { range: goodRange, items: [{ text: "Retained statement", attribution: "user", certainty: "qualified", observedAt: "2026-01-01T00:00:00Z" }] } }] });
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined));
    const request = { commandId: "clear-cut-command", coverageId: failed.coverage.id, expectedRevision: failed.coverage.revisionId };
    const cleared = await service.invoke({ operation: "knowledge.observation.dismiss", request });
    expect(cleared).toMatchObject({ coverage: { id: failed.coverage.id, range, disposition: "excluded", groupRevisionIds: [], reason: "dismissed-by-user: Observer output must be an object" } });
    expect((await store.status()).coverage).toMatchObject({ failedCount: 0, excludedCount: 1, observedCount: 1, remainingCount: 0 });
    expect(await store.read(observed.records[0]!.id)).toEqual(observed.records[0]);
    expect(await store.config()).toEqual(config);
    expect(await store.scopeExcluded(range)).toBe(false);
    expect(await service.invoke({ operation: "knowledge.observation.dismiss", request })).toEqual(cleared);
    await expect(service.invoke({ operation: "knowledge.observation.dismiss", request: { ...request, commandId: "clear-cut-stale" } })).rejects.toThrow("changed");
    await expect(store.setCoverage({ commandId: "clear-cut-late-failure", expectedConfigRevision: config.revision,
      expectedRevision: failed.coverage.revisionId, coverage: { id: failed.coverage.id, range, disposition: "failed", groupRevisionIds: [] } })).rejects.toThrow("stale");
    const pending = await store.setCoverage({ commandId: "clear-cut-pending", expectedConfigRevision: config.revision,
      coverage: { id: "cut-pending", range: { ...range, fromEntryId: "e3", toEntryId: "e3", entryIds: ["e3"] }, disposition: "pending", groupRevisionIds: [] } });
    for (const coverage of [pending.coverage, observed.coverage]) {
      await expect(service.invoke({ operation: "knowledge.observation.dismiss", request: { commandId: `cannot-clear-${coverage.id}`, coverageId: coverage.id, expectedRevision: coverage.revisionId } })).rejects.toThrow("Only failed");
    }
  });

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

  it("reads complete source text and qualifications through bounded continuation pages", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-knowledge-service-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const source = await store.captureSource({ commandId: "service-long-source", record: {
      kind: "source", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [],
      content: { title: "Long source", text: `${"prefix ".repeat(900)}TAIL-EVIDENCE`, captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z", sourcePublishedAt: "2025-12-01T00:00:00Z", retention: { sensitivity: "restricted", evidenceAvailable: true, usageConstraint: "synthetic qualification" }, assessment: { summary: "assessed", evidenceQuality: "medium", freshness: "aging", generatedAt: "2026-01-01T00:00:00Z" } },
    }});
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined));
    let offset = 0; let text = ""; let pages = 0;
    for (;;) {
      const page = await service.tool({ action: "read", id: source.record.id, revisionId: source.record.revisionId, offset });
      text += page.text; pages += 1;
      const nextOffset = (page.details as { nextOffset?: number } | null)?.nextOffset;
      if (nextOffset === undefined) break;
      offset = nextOffset;
    }
    expect(pages).toBeGreaterThan(1);
    expect(text).toContain("TAIL-EVIDENCE");
    expect(text).toContain("synthetic qualification");
    expect(text).toContain("sourcePublishedAt");
  });

  it("returns readable text object evidence while keeping binary bytes explicit", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-knowledge-service-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const textObject = await store.putObject(new TextEncoder().encode("OBJECT_TEXT_MARKER"), "text/plain");
    const source = await store.captureSource({ commandId: "service-object-source", record: { kind: "source", scope: "research", provenance: { actor: "user", evidence: [] }, relations: [], content: { title: "Object source", object: textObject, captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z" } } });
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined));
    const readable = await service.tool({ action: "readObject", id: source.record.id, revisionId: source.record.revisionId, hash: textObject.hash, mediaType: textObject.mediaType, bytes: textObject.bytes });
    expect(readable.text).toContain("OBJECT_TEXT_MARKER");
    expect(readable.text).toContain("offset=0");
    expect(readable.text).not.toContain("base64");
    const jsonObject = await store.putObject(new TextEncoder().encode('{"provider":"synthetic"}'), "application/json");
    const jsonSource = await store.captureSource({ commandId: "service-json-source", record: { kind: "source", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [], content: { title: "JSON source", object: jsonObject, captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z" } } });
    const json = await service.tool({ action: "readObject", id: jsonSource.record.id, revisionId: jsonSource.record.revisionId, hash: jsonObject.hash, mediaType: jsonObject.mediaType, bytes: jsonObject.bytes });
    expect(json.text).toContain('"provider":"synthetic"');
    const binaryObject = await store.putObject(new Uint8Array([0, 255, 1]), "application/octet-stream");
    const binarySource = await store.captureSource({ commandId: "service-binary-source", record: { kind: "source", scope: "research", provenance: { actor: "user", evidence: [] }, relations: [], content: { title: "Binary source", object: binaryObject, captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z" } } });
    const binary = await service.tool({ action: "readObject", id: binarySource.record.id, revisionId: binarySource.record.revisionId, hash: binaryObject.hash, mediaType: binaryObject.mediaType, bytes: binaryObject.bytes });
    expect(binary.text).toContain("Binary or unsupported media type");
    expect(binary.text).not.toContain("OBJECT_TEXT_MARKER");
    const splitObject = await store.putObject(new TextEncoder().encode(`${"HEAD"}${"a".repeat(511_995)}🧭TAIL`), "text/plain");
    const splitSource = await store.captureSource({ commandId: "service-split-source", record: { kind: "source", scope: "research", provenance: { actor: "user", evidence: [] }, relations: [], content: { title: "Split source", object: splitObject, captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z" } } });
    let offset = 0;
    let splitText = "";
    for (;;) {
      const page = await service.tool({ action: "readObject", id: splitSource.record.id, revisionId: splitSource.record.revisionId, hash: splitObject.hash, mediaType: splitObject.mediaType, bytes: splitObject.bytes, offset });
      splitText += page.text;
      const nextOffset = (page.details as { nextOffset?: number } | null)?.nextOffset;
      if (nextOffset === undefined) break;
      expect(nextOffset).toBeGreaterThan(offset);
      offset = nextOffset;
    }
    expect(splitText).toContain("HEAD");
    expect(splitText).toContain("🧭");
    expect(splitText).toContain("TAIL");
  });

  it("returns dated qualified recall evidence and a pinned read continuation", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-knowledge-service-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const configured = await store.configure("service-recall-config", { ...(await store.config()), eligibility: { ...(await store.config()).eligibility, sessionIds: ["recall-session"] } });
    const range = { sessionId: "recall-session", fromEntryId: "recall-entry", toEntryId: "recall-entry", entryIds: ["recall-entry"], entryDigest: "c".repeat(64) };
    const published = await store.publishObservationGroup({ commandId: "service-recall-source", expectedConfigRevision: configured.revision, coverage: { id: "service-recall-coverage", range, disposition: "observed" }, records: [{ kind: "observation", scope: "personal", provenance: { actor: "agent", sessionId: range.sessionId, evidence: [{ sessionEntry: { sessionId: range.sessionId, entryId: range.fromEntryId } }] }, relations: [], content: { range, items: [{ text: `RECALL_EVIDENCE ${"qualified detail ".repeat(400)} RECALL_TAIL`, attribution: "user", observedAt: "2026-01-02T03:04:05Z", certainty: "qualified", evidence: [{ sessionEntry: { sessionId: range.sessionId, entryId: range.fromEntryId } }] }] } }] });
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined));
    const recalled = await service.tool({ action: "recall", sessionId: range.sessionId, entryId: range.fromEntryId, limit: 1 });
    expect(recalled.text).toContain("2026-01-02T03:04:05Z");
    expect(recalled.text).toContain("qualified");
    expect(recalled.text).toContain("user: RECALL_EVIDENCE");
    expect(recalled.text).toContain("entryId");
    expect(recalled.text).toContain("Continue with action=read");
    const continuation = recalled.text.match(/Continue with action=read id=([^ ]+) revisionId=([^ ]+) offset=(\d+)\./);
    expect(continuation).not.toBeNull();
    let offset = Number(continuation![3]!);
    let pages = "";
    for (;;) {
      const page = await service.tool({ action: "read", id: continuation![1]!, revisionId: continuation![2]!, offset });
      pages += page.text;
      const nextOffset = (page.details as { nextOffset?: number } | null)?.nextOffset;
      if (nextOffset === undefined) break;
      offset = nextOffset;
    }
    expect(offset).toBeGreaterThan(0);
    expect(pages).toContain("RECALL_TAIL");
    expect(published.records[0]!.revisionId).toBe(continuation![2]);
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

  it("rejects mixed branched and unbranched reflection cuts before model invocation", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-knowledge-service-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const config = await store.configure("service-reflect-branch-config", { ...(await store.config()), observation: { ...(await store.config()).observation, model: "fixture/model" }, eligibility: { ...(await store.config()).eligibility, sessionIds: ["branch-session"] } });
    const make = async (commandId: string, coverageID: string, branchId: string | undefined, entryID: string) => store.publishObservationGroup({ commandId, expectedConfigRevision: config.revision, coverage: { id: coverageID, range: { sessionId: "branch-session", ...(branchId ? { branchId } : {}), fromEntryId: entryID, toEntryId: entryID, entryIds: [entryID], entryDigest: "a".repeat(64) }, disposition: "observed" }, records: [{ kind: "observation", scope: "personal", provenance: { actor: "agent", sessionId: "branch-session", ...(branchId ? { branchId } : {}), evidence: [] }, relations: [], content: { range: { sessionId: "branch-session", ...(branchId ? { branchId } : {}), fromEntryId: entryID, toEntryId: entryID, entryIds: [entryID], entryDigest: "a".repeat(64) }, items: [{ text: entryID, attribution: "user", observedAt: "2026-01-01T00:00:00Z", certainty: "qualified" }] } }] });
    const unbranched = await make("service-reflect-unbranched", "service-reflect-unbranched-coverage", undefined, "entry-unbranched");
    const branched = await make("service-reflect-branched", "service-reflect-branched-coverage", "branch-a", "entry-branched");
    let calls = 0;
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {}, () => ({ ...model(), async reflect() { calls += 1; return "must not run"; } }));
    await expect(service.invoke({ operation: "knowledge.reflect", request: { commandId: "service-reflect-mixed-branches", sessionId: "branch-session", sourceRevisionIds: [unbranched.records[0]!.revisionId, branched.records[0]!.revisionId] } })).rejects.toMatchObject({ code: "conflict" });
    expect(calls).toBe(0);
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

  it("routes a disposition filter through the coverage request", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-knowledge-service-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const initial = await store.config();
    const config = await store.configure("service-coverage-filter", { ...initial, eligibility: { ...initial.eligibility, sessionIds: ["session-filter"] } });
    const range = (entry: string) => ({ sessionId: "session-filter", fromEntryId: entry, toEntryId: entry, entryIds: [entry], entryDigest: "a".repeat(64) });
    for (const [entry, disposition] of [["e1", "pending"], ["e2", "failed"], ["e3", "unavailable"]] as const) {
      await store.setCoverage({ commandId: `service-filter-${entry}`, expectedConfigRevision: config.revision,
        coverage: { id: `cut-${entry}`, range: range(entry), disposition, groupRevisionIds: [] } });
    }
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined));
    const page = await service.invoke({ operation: "knowledge.observation.coverage", request: { limit: 100, dispositions: ["pending", "failed", "unavailable"] } });
    expect((page as { coverage: Array<{ id: string }> }).coverage.map(cut => cut.id).sort()).toEqual(["cut-e1", "cut-e2", "cut-e3"]);
    const settledOnly = await service.invoke({ operation: "knowledge.observation.coverage", request: { limit: 100, dispositions: ["observed", "empty", "excluded"] } });
    expect((settledOnly as { coverage: unknown[] }).coverage).toEqual([]);
  });

  it("rejects connector and importer calls without an installed extension", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-knowledge-service-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined));
    await expect(service.invoke({ operation: "knowledge.connector.status", request: { connector: "raindrop" } })).rejects.toMatchObject({ code: "unsupported" });
    await expect(service.invoke({ operation: "knowledge.import.dry-run", request: { commandId: "service-import", source: "synthetic", limit: 1 } })).rejects.toMatchObject({ code: "unsupported" });
  });
});
