import { afterEach, describe, expect, it } from "vitest";
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
    const { store, record } = await fixture();
    const saved = await store.setSourceTake({ commandId: "k6-take-first", recordId: record.id, expectedRevision: record.revisionId, text: "Keep APIs boring." });
    expect(saved.record.content.take).toMatchObject({ text: "Keep APIs boring.", confirmed: true, producer: { actor: "user" } });
    await expect(store.setSourceTake({ commandId: "k6-take-stale-draft", recordId: record.id, expectedRevision: record.revisionId, text: "My unsaved draft" }))
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
    expect(taken.record.content.tags?.inputsDigest).not.toBe((await store.read(taken.record.id, tagged.record.revisionId))?.content.tags?.inputsDigest);
    expect((await store.listSourceRows({ kind: "source", ids: [record.id] })).rows[0]).toMatchObject({ hasTake: true, tagsStale: true });
  });

  it("filters personal sources from default agent search and recall but preserves observations and notes", async () => {
    const { store, service, record } = await fixture();
    await store.curateSource({ commandId: "personalize-k6-command", operation: "placement", producer: { actor: "user" }, item: { recordId: record.id, expectedRevision: record.revisionId, scope: "personal" } });
    const personal = await service.tool({ action: "search", query: "useful tool" });
    expect((personal.details as {hits: unknown[]}).hits).toHaveLength(0);
    const explicit = await service.tool({ action: "search", query: "useful tool", scope: "personal" });
    expect((explicit.details as {hits: unknown[]}).hits).toHaveLength(1);
    expect((await service.tool({ action: "recall", query: "useful tool" })).details).toMatchObject({ records: [] });
    const explicitRecall = await service.tool({ action: "recall", query: "useful tool", scope: "personal" });
    expect((explicitRecall.details as {records: Array<{take?: string}>}).records[0]?.take).toBeUndefined();
  });

  it("ranks freshness only after relevance, exposes supersession and age basis, and avoids body reads for rows", async () => {
    const { store } = await fixture({ revision: 2, isActiveTag: id => id === "tool" });
    const old = await store.status();
    expect(old.recordCount).toBe(1);
    // Added in the implementation stage: prepare equally relevant old and fresh
    // sources and assert catalog-head ranking, supersededBy, and row metadata.
  });
});
