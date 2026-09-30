import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { KnowledgeService } from "./knowledge-service.js";
import { KnowledgeObservationService } from "./knowledge-observation.js";

const roots: string[] = [];
afterEach(async () => { vi.useRealTimers(); await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });
async function fixture(decayClass: "ages" | "stable" = "ages") {
  const root = await mkdtemp(join(tmpdir(), "knowledge-take-freshness-")); roots.push(root);
  const store = new KnowledgeStore(new TronWorkspace(root));
  const config = await store.config();
  await store.configureTags({ commandId: "k6-install-canonical-tag", expectedConfigRevision: config.revision, edit: { kind: "add", tag: { id: "tool", label: "Tool", definition: "A tool.", category: "work", decayClass, state: "active" } } });
  const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined));
  const record = await store.captureSource({ commandId: "capture-source-for-k6-test", record: { kind: "source", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [], content: {
    title: "A useful tool", uri: "https://example.test/tool", text: "Tool evidence", captureDisposition: "complete", capturedAt: "2024-01-01T00:00:00.000Z", sourceSavedAt: "2024-01-01T00:00:00.000Z", admission: { status: "retained", decidedAt: "2024-01-01T00:00:00.000Z" },
  } } });
  return { store, service, record: record.record as Extract<typeof record.record, {kind:"source"}> };
}

/** Failure modes written before integration changes:
 * - a persisted freshness value must not remain fresh after crossing six months without writes;
 * - SQL retrieval order and returned row freshness must use the same current clock;
 * - changing vocabulary decay metadata must reach existing heads immediately;
 * - merged/retired selections cannot use stale taxonomy policy, but a completed merge uses its active target;
 * - user takes must enqueue current-edition tags whose input digest is stale.
 */
describe("Your take and freshness-aware source retrieval", () => {
  /** Failure modes for C6, identified before implementation:
   * - agent list without scope leaks personal sources while search/recall do not;
   * - listing with explicit personal scope cannot inspect those same sources;
   * - an archived search hit is returned but its row-only metadata disappears because a second filtered query omits it.
   */
  it("hides personal sources from agent list by default and exposes them for explicit personal scope", async () => {
    const { store, service, record } = await fixture();
    const personal = await store.curateSource({ commandId: "k6-list-personal-place", operation: "placement", producer: { actor: "user" }, item: { recordId: record.id, expectedRevision: record.revisionId, placement: { scope: "personal" } } });
    const hidden = await service.tool({ action: "list", kind: "source" });
    expect((hidden.details as {records: Array<{id: string}>}).records.map(item => item.id)).not.toContain(personal.record.id);
    const explicit = await service.tool({ action: "list", kind: "source", scope: "personal" });
    expect((explicit.details as {records: Array<{id: string}>}).records.map(item => item.id)).toContain(personal.record.id);
  });

  it("projects search metadata from an archived result record", async () => {
    const { store, service, record } = await fixture();
    const tagged = await store.curateSource({ commandId: "k6-search-archive-tag", operation: "tags", producer: { actor: "agent" }, item: { recordId: record.id, expectedRevision: record.revisionId, tagIds: ["tool"] } });
    const taken = await store.setSourceTake({ commandId: "k6-search-archive-take", recordId: record.id, expectedRevision: tagged.record.revisionId, text: "Useful take for archived evidence." });
    const archived = await store.setSourceAdmission({ commandId: "k6-search-archive", recordId: record.id, expectedRevision: taken.record.revisionId, status: "archived" });
    const result = await service.tool({ action: "search", query: "useful tool", kind: "source", includeArchived: true });
    const hit = (result.details as {hits: Array<{id: string; sourceSavedAt?: string; ageBasis?: string; ageDays?: number; freshness?: string; verdict?: string | null; take?: string | null}>}).hits.find(item => item.id === archived.record.id);
    expect(hit).toMatchObject({ sourceSavedAt: "2024-01-01T00:00:00.000Z", ageBasis: "sourceSavedAt", freshness: "stale", verdict: null, take: "Useful take for archived evidence." });
    expect(hit?.ageDays).toBeGreaterThan(0);
  });

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
    const { store, service, record: oldSource } = await fixture();
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
    const archived = await store.setSourceAdmission({ commandId: "k6-archive-verdict", recordId: fresh.record.id, expectedRevision: freshTagged.record.revisionId, status: "archived" });
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

  it("recomputes age and retrieval rank at read time when a source crosses 180 days without a write", async () => {
    vi.useFakeTimers();
    const anchor = new Date("2026-01-01T12:00:00.000Z");
    vi.setSystemTime(anchor);
    const { store } = await fixture("ages");
    const ageAnchor = new Date(anchor.getTime() - 179 * 86_400_000).toISOString();
    const aged = await store.captureSource({ commandId: "k6-crossing-source", record: { kind: "source", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [], content: {
      title: "Common reference", uri: "https://example.test/crossing", text: "same query body", captureDisposition: "complete", capturedAt: ageAnchor, sourceSavedAt: ageAnchor,
    } } });
    await store.curateSource({ commandId: "k6-crossing-tag", operation: "tags", producer: { actor: "agent" }, item: { recordId: aged.record.id, expectedRevision: aged.record.revisionId, tagIds: ["tool"] } });
    const permanentConfig = await store.config();
    await store.configureTags({ commandId: "k6-add-permanent", expectedConfigRevision: permanentConfig.revision, edit: { kind: "add", tag: { id: "principle", label: "Principle", definition: "Does not age.", category: "idea", decayClass: "stable", state: "active" } } });
    const permanent = await store.captureSource({ commandId: "k6-permanent-source", record: { kind: "source", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [], content: {
      title: "Common reference", uri: "https://example.test/permanent", text: "same query body", captureDisposition: "complete", capturedAt: anchor.toISOString(), sourceSavedAt: anchor.toISOString(),
    } } });
    await store.curateSource({ commandId: "k6-permanent-tag", operation: "tags", producer: { actor: "agent" }, item: { recordId: permanent.record.id, expectedRevision: permanent.record.revisionId, tagIds: ["principle"] } });
    const unknown = await store.captureSource({ commandId: "k6-unknown-source", record: { kind: "source", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [], content: {
      title: "Common reference", uri: "https://example.test/unknown", text: "same query body", captureDisposition: "complete", capturedAt: anchor.toISOString(), sourceSavedAt: anchor.toISOString(),
    } } });
    const before = await store.search({ query: "common reference", kind: "source" });
    expect(before.hits[0]?.record.id).toBe(permanent.record.id);
    expect(before.hits.findIndex(hit => hit.record.id === aged.record.id)).toBeLessThan(before.hits.findIndex(hit => hit.record.id === unknown.record.id));
    expect((await store.listSourceRows({ kind: "source", ids: [aged.record.id] })).rows[0]).toMatchObject({ ageDays: 179, freshness: "aging" });
    vi.setSystemTime(new Date(anchor.getTime() + 86_400_000));
    const after = await store.search({ query: "common reference", kind: "source" });
    expect(after.hits[0]?.record.id).toBe(permanent.record.id);
    expect(after.hits.findIndex(hit => hit.record.id === unknown.record.id)).toBeLessThan(after.hits.findIndex(hit => hit.record.id === aged.record.id));
    expect((await store.listSourceRows({ kind: "source", ids: [aged.record.id] })).rows[0]).toMatchObject({ ageDays: 180, freshness: "stale" });
    vi.useRealTimers();
  });

  it("reprojects decay changes and treats merged or retired tag selections as unknown", async () => {
    const { store, record } = await fixture("ages");
    const tagged = await store.curateSource({ commandId: "k6-class-tag", operation: "tags", producer: { actor: "agent" }, item: { recordId: record.id, expectedRevision: record.revisionId, tagIds: ["tool"] } });
    let config = await store.config();
    config = await store.configureTags({ commandId: "k6-class-change", expectedConfigRevision: config.revision, edit: { kind: "recategorize", id: "tool", category: "ideas", decayClass: "stable" } });
    expect((await store.listSourceRows({ kind: "source", ids: [record.id] })).rows[0]).toMatchObject({ tags: [{ decayClass: "stable" }], freshness: "fresh" });
    expect((await store.read(record.id))?.revisionId).toBe(tagged.record.revisionId);
    config = await store.configureTags({ commandId: "k6-add-merge-target", expectedConfigRevision: config.revision, edit: { kind: "add", tag: { id: "principle", label: "Principle", definition: "Does not age.", category: "ideas", decayClass: "stable", state: "active" } } });
    config = await store.configureTags({ commandId: "k6-add-retirement-target", expectedConfigRevision: config.revision, edit: { kind: "add", tag: { id: "temporary", label: "Temporary", definition: "A temporary tag.", category: "work", decayClass: "ages", state: "active" } } });
    const retiredRecord = (await store.captureSource({ commandId: "k6-retired-source", record: { kind: "source", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [], content: { title: "Temporary source", uri: "https://example.test/temporary", text: "Temporary", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z" } } })).record;
    const retiredTagged = await store.curateSource({ commandId: "k6-temporary-tag", operation: "tags", producer: { actor: "agent" }, item: { recordId: retiredRecord.id, expectedRevision: retiredRecord.revisionId, tagIds: ["temporary"] } });
    config = await store.configureTags({ commandId: "k6-retire-class-tag", expectedConfigRevision: config.revision, edit: { kind: "retire", id: "temporary" } });
    expect((await store.listSourceRows({ kind: "source", ids: [retiredRecord.id] })).rows[0]).toMatchObject({ tags: [{ state: "retired" }], freshness: "unknown" });
    expect((await store.tagsNeedingRetag({ vocabularyRevision: config.tagVocabulary.revision })).items.map(item => item.id)).toContain(retiredRecord.id);
    config = await store.configureTags({ commandId: "k6-merge-class-tag", expectedConfigRevision: config.revision, edit: { kind: "merge", id: "tool", mergedInto: "principle" } });
    expect((await store.listSourceRows({ kind: "source", ids: [record.id] })).rows[0]).toMatchObject({ tags: [{ state: "merged" }], freshness: "unknown" });
    await store.reconcileTagMerges({ commandId: "k6-reconcile-class-merge", expectedConfigRevision: config.revision });
    expect((await store.listSourceRows({ kind: "source", ids: [record.id] })).rows[0]).toMatchObject({ tags: [{ decayClass: "stable" }], freshness: "fresh" });
    expect((await store.read(retiredRecord.id))?.revisionId).toBe(retiredTagged.record.revisionId);
  });

  it("includes take-invalidated current-edition tags in the catalog retag queue", async () => {
    const { store, record } = await fixture();
    const tagged = await store.curateSource({ commandId: "k6-queue-tag", operation: "tags", producer: { actor: "agent" }, item: { recordId: record.id, expectedRevision: record.revisionId, tagIds: ["tool"] } });
    const taken = await store.setSourceTake({ commandId: "k6-queue-take", recordId: record.id, expectedRevision: tagged.record.revisionId, text: "The key rule is keep it small." });
    const config = await store.config();
    const needed = await store.tagsNeedingRetag({ vocabularyRevision: config.tagVocabulary.revision });
    expect(needed.items).toContainEqual({ id: record.id, revisionId: taken.record.revisionId, reason: "stale-inputs" });
  });

});
