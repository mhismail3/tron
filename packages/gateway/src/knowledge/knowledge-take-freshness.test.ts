import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore, type KnowledgeTagVocabulary } from "./knowledge-store.js";
import { KnowledgeService } from "./knowledge-service.js";
import { KnowledgeObservationService } from "./knowledge-observation.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });
const vocabulary: KnowledgeTagVocabulary = { revision: 1, isActiveTag: id => id === "tool" };
async function fixture(vocab = vocabulary) {
  const root = await mkdtemp(join(tmpdir(), "knowledge-take-freshness-")); roots.push(root);
  const store = new KnowledgeStore(new TronWorkspace(root), undefined, undefined, vocab);
  const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined));
  const record = await store.captureSource({ commandId: "capture-source-for-k6-test", record: { kind: "source", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [], content: {
    title: "A useful tool", uri: "https://example.test/tool", text: "Tool evidence", captureDisposition: "complete", capturedAt: "2024-01-01T00:00:00.000Z", sourceSavedAt: "2024-01-01T00:00:00.000Z", admission: { status: "retained", decidedAt: "2024-01-01T00:00:00.000Z" },
  } } });
  return { store, service, record: record.record as Extract<typeof record.record, {kind:"source"}> };
}

describe("Your take and freshness-aware source retrieval", () => {
  it("returns the current take in a typed stale-revision conflict so the caller can retain its draft", async () => {
    const { store, service, record } = await fixture();
    const request = { commandId: "k6-take-first", recordId: record.id, expectedRevision: record.revisionId, text: "Keep APIs boring." };
    const saved = await service.invoke({ operation: "knowledge.source.take", request }) as Awaited<ReturnType<KnowledgeStore["setSourceTake"]>>;
    expect(saved.record.content.take).toMatchObject({ text: "Keep APIs boring.", confirmed: true, producer: { actor: "user" } });
    await expect(service.invoke({ operation: "knowledge.source.take", request: { ...request, commandId: "k6-take-stale-draft", text: "My unsaved draft" } }))
      .rejects.toMatchObject({ code: "conflict", details: { currentRevision: saved.record.revisionId, currentTake: "Keep APIs boring." } });
    expect((await store.read(record.id))?.content).toMatchObject({ take: { text: "Keep APIs boring.", confirmed: true } });
  });

  it("replays one take command without another revision, and explicit empty text clears it", async () => {
    const { store, record } = await fixture();
    const request = { commandId: "k6-take-replay-command", recordId: record.id, expectedRevision: record.revisionId, text: "One take-k6-command" };
    const first = await store.setSourceTake(request);
    const replay = await store.setSourceTake(request);
    expect(replay.record.revisionId).toBe(first.record.revisionId);
    const cleared = await store.setSourceTake({ commandId: "k6-take-clear-command", recordId: record.id, expectedRevision: first.record.revisionId, text: "" });
    expect(cleared.record.content.take).toBeUndefined();
    expect(cleared.record.revisionId).not.toBe(first.record.revisionId);
  });

  it("changing the take invalidates the existing tags through K1's curation input digest", async () => {
    const { store, record } = await fixture();
    const tagged = await store.curateSource({ commandId: "tag-k6-command", operation: "tags", producer: { actor: "agent" }, item: { recordId: record.id, expectedRevision: record.revisionId, tagIds: ["tool"] } });
    const taken = await store.setSourceTake({ commandId: "take-k6-command", recordId: record.id, expectedRevision: tagged.record.revisionId, text: "This is useful only for internal tools." });
    expect(taken.record.content.tags?.inputsDigest).toBe((await store.read(taken.record.id, tagged.record.revisionId))?.content.tags?.inputsDigest);
    expect((await store.listSourceRows({ kind: "source", ids: [record.id] })).rows[0]).toMatchObject({ hasTake: true, tagsStale: true });
  });

  it("filters personal sources from default agent search and recall but preserves observations and notes", async () => {
    const { store, service, record } = await fixture();
    const placed = await store.curateSource({ commandId: "personalize-k6-command", operation: "placement", producer: { actor: "user" }, item: { recordId: record.id, expectedRevision: record.revisionId, placement: { scope: "personal" } } });
    await store.setSourceTake({ commandId: "k6-personal-source-take", recordId: record.id, expectedRevision: placed.record.revisionId, text: "Keep APIs boring." });
    const personal = await service.tool({ action: "search", query: "useful tool" });
    expect((personal.details as {hits: unknown[]}).hits).toHaveLength(0);
    const explicit = await service.tool({ action: "search", query: "useful tool", scope: "personal" });
    expect((explicit.details as {hits: unknown[]}).hits).toHaveLength(1);
    const note = await store.createNote({ commandId: "k6-personal-note-write", record: { kind: "note", scope: "personal", provenance: { actor: "user", evidence: [] }, relations: [], content: { title: "Shared context note", body: "useful tool reference", role: "fact", confirmed: true } } });
    const initialConfig = await store.config();
    const config = await store.configure("k6-configure-recall-session", { ...initialConfig, eligibility: { ...initialConfig.eligibility, sessionIds: ["k6-recall-session"] } });
    const range = { sessionId: "k6-recall-session", fromEntryId: "k6-entry", toEntryId: "k6-entry", entryIds: ["k6-entry"], entryDigest: "a".repeat(64) };
    await store.publishObservationGroup({ commandId: "k6-observation-write", expectedConfigRevision: config.revision, coverage: { id: "k6-observation-cut", range, disposition: "observed" }, records: [{ kind: "observation", scope: "personal", provenance: { actor: "user", sessionId: range.sessionId, evidence: [] }, relations: [], content: { range, items: [{ text: "useful tool reference", attribution: "user", certainty: "certain", observedAt: "2026-09-28T00:00:00Z" }] } }] });
    expect((await service.tool({ action: "recall", query: "useful tool" })).details).toMatchObject({ records: expect.arrayContaining([expect.objectContaining({ id: note.record.id }), expect.objectContaining({ kind: "observation" })]) });
    const explicitRecall = await service.tool({ action: "recall", query: "useful tool", scope: "personal" });
    expect((explicitRecall.details as {records: Array<{take?: string}>}).records.some(record => record.take === "Keep APIs boring.")).toBe(true);
  });

  it("ranks freshness only after relevance, exposes supersession and age basis, and avoids body reads for rows", async () => {
    const { store, service, record: oldSource } = await fixture({ revision: 2, isActiveTag: id => id === "tool", decayClassForTag: id => id === "tool" ? "ages" : undefined });
    const oldTagged = await store.curateSource({ commandId: "k6-old-tag", operation: "tags", producer: { actor: "agent" }, item: { recordId: oldSource.id, expectedRevision: oldSource.revisionId, tagIds: ["tool"] } });
    const fresh = await store.captureSource({ commandId: "k6-fresh-source", record: { kind: "source", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [], content: { title: "A useful tool", uri: "https://example.test/fresh", text: "Tool evidence", captureDisposition: "complete", capturedAt: new Date().toISOString(), sourceSavedAt: new Date().toISOString(), admission: { status: "retained", decidedAt: new Date().toISOString() } } } });
    const freshTagged = await store.curateSource({ commandId: "k6-fresh-tag", operation: "tags", producer: { actor: "agent" }, item: { recordId: fresh.record.id, expectedRevision: fresh.record.revisionId, tagIds: ["tool"] } });
    const search = await store.search({ query: "useful", kind: "source" });
    expect(search.hits[0]?.record.id).toBe(fresh.record.id);
    expect(search.hits[0]?.score).toBe(search.hits.find(hit => hit.record.id === oldSource.id)?.score);
    expect((await store.recall({ query: "useful", limit: 2 })).records[0]?.id).toBe(fresh.record.id);
    const superseded = await store.curateSource({ commandId: "k6-supersede", operation: "verdict", producer: { actor: "user" }, item: { recordId: oldSource.id, expectedRevision: oldTagged.record.revisionId, verdict: { verdict: "superseded", supersededBy: fresh.record.id } } });
    const result = await service.tool({ action: "search", query: "useful", kind: "source" });
    expect(result.text).toContain(`supersededBy=${fresh.record.id}`);
    expect(result.text).toContain("prefer");
    expect((result.details as {hits: Array<{supersededBy?: string; ageBasis?: string; freshness?: string}>}).hits.find(hit => hit.supersededBy)?.supersededBy).toBe(fresh.record.id);
    expect((result.details as {hits: Array<{ageBasis?: string; freshness?: string}>}).hits.every(hit => hit.ageBasis === "sourceSavedAt" && hit.freshness)).toBe(true);
    expect(freshTagged.record.revisionId).not.toBe(superseded.record.revisionId);
    const rows = await store.listSourceRows({ kind: "source", ids: [oldSource.id] });
    expect(rows.rows[0]).toMatchObject({ ageBasis: "sourceSavedAt", freshness: "stale", verdict: "superseded", supersededBy: fresh.record.id });
    const archived = await store.curateSource({ commandId: "k6-archive-verdict", operation: "verdict", producer: { actor: "user" }, item: { recordId: fresh.record.id, expectedRevision: freshTagged.record.revisionId, verdict: { verdict: "archive" } } });
    const hiddenArchive = await store.search({ query: "useful", kind: "source" });
    expect(hiddenArchive.hits.some(hit => hit.record.id === archived.record.id)).toBe(false);
    const includedArchive = await store.search({ query: "useful", kind: "source", includeArchived: true });
    expect(includedArchive.hits.some(hit => hit.record.id === archived.record.id)).toBe(true);
    const unknown = await store.captureSource({ commandId: "k6-age-basis-fallback", record: { kind: "source", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [], content: { title: "Saved without provider time", uri: "https://example.test/no-save-date", text: "No save time supplied", captureDisposition: "complete", capturedAt: "2024-02-03T00:00:00.000Z", admission: { status: "retained", decidedAt: "2024-02-03T00:00:00.000Z" } } } });
    const reads = vi.spyOn(store as unknown as { readRecord: (...args: unknown[]) => Promise<unknown> }, "readRecord");
    const fallback = await store.listSourceRows({ kind: "source", ids: [unknown.record.id] });
    expect(fallback.rows[0]).toMatchObject({ ageBasis: "capturedAt", freshness: "unknown", ageDays: expect.any(Number) });
    expect(reads).not.toHaveBeenCalled();
  });
});
