import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeObservationService } from "./knowledge-observation.js";
import { KnowledgeService, type KnowledgeGenerationModel } from "./knowledge-service.js";
import { KnowledgeCurationJobs } from "./knowledge-curation.js";
import { KnowledgeStore } from "./knowledge-store.js";
import type { KnowledgeCurationResponse } from "./knowledge-contract.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

/** Failure modes under test:
 *  1. a curation write onto a stale revision silently overwrites another
 *     writer's revision (a lost update);
 *  2. a reused command ID with a changed payload is accepted as if it were new;
 *  3. a replayed batch writes or charges twice, or reports a conflict for an
 *     item it already applied;
 *  4. a curation write lands on an excluded or forgotten entry;
 *  5. an unknown vocabulary tag is stored anyway;
 *  6. a superseded verdict names no replacement, or one that does not exist;
 *  7. one bad item aborts the batch and discards the items after it;
 *  8. a batch keeps dispatching after the paid gate has refused;
 *  9. summary generation holds the caller open, or loses its outcome when the
 *     caller goes away;
 * 10. the agent tool cannot see the outcome of the work it started;
 * 11. curation mutates captured evidence instead of interpretation.
 * 12. a stale Your take save discards the draft instead of returning the latest take;
 *     take writes are not user-confirmed, receipted, or fast.
 * 13. changing Your take leaves an otherwise current tag selection looking fresh.
 * 14. default agent retrieval exposes personal sources or explicit personal
 *     requests accidentally hide Chronicle observations and notes.
 * 15. relevance ordering overwhelms freshness, or a superseded result loses its replacement.
 * 16. missing save dates silently use capture time without identifying the age basis.
 * 17. row freshness requires body reads, making Library projection scale with source text.
 * 18. the K1 constructor vocabulary seam can disagree with Knowledge config about active tag IDs.
 */


const summarizer: KnowledgeGenerationModel = {
  async reflect() { return "handoff"; },
  async synthesize() { return "synthesis"; },
  async summarizeSource() { return { text: "A bounded saved-source summary." }; },
  async assess() { return { summary: "Useful", evidenceQuality: "high", freshness: "current" }; },
};
const other = (arguments_: string) => `knowledge-curation-${arguments_}`;

async function installVocabulary(store: KnowledgeStore) {
  let config = await store.config();
  for (const [id, label] of [["agent-harness", "Agent harness"], ["memory", "Memory"], ["evaluation", "Evaluation"]]) {
    config = await store.configureTags({ commandId: other(`install-${id}`), expectedConfigRevision: config.revision, edit: { kind: "add", tag: { id, label, definition: `${label} resources.`, category: "work", decayClass: "ages", state: "active" } } });
  }
  return config;
}
async function fixture(options: { emptyVocabulary?: boolean } = {}) {
  const root = await mkdtemp(join(tmpdir(), "tron-curation-")); roots.push(root);
  const store = new KnowledgeStore(new TronWorkspace(root));
  if (!options.emptyVocabulary) await installVocabulary(store);
  const config = await store.config();
  await store.configure(other("knowledge-model"), { ...config, knowledgeModel: { model: "fixture/enrichment", maxInputChars: 48_000, maxOutputChars: 8_000 } });
  const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {}, () => summarizer);
  return { root, store, service };
}

/** A batch through the real agent tool, which is the surface an agent uses. */
async function curate(service: KnowledgeService, operation: string, commandId: string, items: Array<Record<string, unknown>>, producerModel = "fixture/model") {
  const result = await service.tool({ action: "curate", curation: operation as never, commandId, producerModel, items: items as never });
  return result.details as KnowledgeCurationResponse;
}

async function capture(store: KnowledgeStore, index: number) {
  const result = await store.captureSource({
    commandId: other(`capture-${index}`),
    record: {
      kind: "source", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [],
      content: {
        title: `Saved source ${index}`, uri: `https://example.test/${index}`, text: `Body of saved source ${index}`, mediaType: "text/plain",
        captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z",
        admission: { status: "retained", reason: "Fixture admission", decidedAt: "2026-01-01T00:00:00Z" },
      },
    },
  });
  return result.record;
}
const statuses = (response: KnowledgeCurationResponse) => response.outcomes.map(outcome => outcome.status);
const byStatus = (response: KnowledgeCurationResponse, status: string) => response.outcomes.filter(outcome => outcome.status === status);

describe("Knowledge curation", () => {
  /** Failure modes: terminal state is never published, failure is mistaken for
   * success, or event delivery can alter the durable job result. */
  it("publishes terminal events for successful and failed owned jobs", async () => {
    const events: unknown[] = [];
    const jobs = new KnowledgeCurationJobs(64, 30_000, job => events.push(job));
    jobs.start({ commandId: "job-success", operation: "summary", sourceId: "source-1", run: async () => ({ revisionId: "revision-2" }) });
    jobs.start({ commandId: "job-failure", operation: "tags", sourceId: "source-2", run: async () => { throw new Error("provider failed"); } });
    for (let attempt = 0; attempt < 200 && events.length < 2; attempt += 1) await new Promise(resolve => setTimeout(resolve, 5));
    expect(events).toEqual(expect.arrayContaining([
      expect.objectContaining({ commandId: "job-success", operation: "summary", sourceId: "source-1", status: "done", revisionId: "revision-2" }),
      expect.objectContaining({ commandId: "job-failure", operation: "tags", sourceId: "source-2", status: "failed", code: expect.any(String), reason: expect.any(String) }),
    ]));
  });
  it("applies a batch through the agent tool and reads back what it wrote", async () => {
    const { store, service } = await fixture();
    const records = [await capture(store, 1), await capture(store, 2)];
    const response = await curate(service, "tags", other("batch-apply"), records.map(record => ({ id: record.id, revisionId: record.revisionId, tagIds: ["agent-harness", "memory"] })));
    expect(statuses(response)).toEqual(["applied", "applied"]);
    expect(response.applied).toBe(2);
    for (const [index, outcome] of response.outcomes.entries()) {
      expect(outcome.revisionId).not.toBe(records[index]!.revisionId);
      expect(outcome.stored).toEqual({ tagIds: ["agent-harness", "memory"], vocabularyRevision: 3 });
      const committed = await store.read(outcome.recordId!, outcome.revisionId!);
      expect(committed?.content).toMatchObject({ tags: { tagIds: ["agent-harness", "memory"], vocabularyRevision: 3, inputsDigest: expect.stringMatching(/^[a-f0-9]{64}$/), producer: { actor: "agent", model: "fixture/model" } } });
    }
    // Interpretation only: the captured evidence is untouched.
    const read = await store.read(records[0]!.id);
    expect(read?.content.title).toBe("Saved source 1");
    expect(read?.content.text).toBe("Body of saved source 1");
    expect(read?.content.uri).toBe("https://example.test/1");
  });

  it("reports a stale item as a conflict carrying the current revision and still applies the rest", async () => {
    const { store, service } = await fixture();
    const stale = await capture(store, 3);
    const fresh = await capture(store, 4);
    // Another writer commits first: the batch's expected revision is now stale.
    await store.curateSource({ commandId: other("other-writer"), operation: "summary", producer: { actor: "user" }, item: { recordId: stale.id, expectedRevision: stale.revisionId, summary: { text: "Another writer's summary", coverage: "full" } } });
    const currentRevision = (await store.read(stale.id))!.revisionId;

    const response = await curate(service, "tags", other("batch-stale"), [
      { id: stale.id, revisionId: stale.revisionId, tagIds: ["memory"] },
      { id: fresh.id, revisionId: fresh.revisionId, tagIds: ["evaluation"] },
    ]);
    expect(statuses(response)).toEqual(["conflict", "applied"]);
    expect(response.outcomes[0]).toMatchObject({ status: "conflict", code: "stale-revision", currentRevision });
    // One failing item never rolls back or blocks another.
    expect((await store.read(fresh.id))?.content.tags?.tagIds).toEqual(["evaluation"]);
    expect((await store.read(stale.id))?.content.summary?.text).toBe("Another writer's summary");
    expect((await store.read(stale.id))?.content.tags).toBeUndefined();
  });

  it("is idempotent per item: a replayed batch writes no second revision", async () => {
    const { store, service } = await fixture();
    const record = await capture(store, 5);
    const first = await curate(service, "tags", other("batch-replay"), [{ id: record.id, revisionId: record.revisionId, tagIds: ["memory"] }]);
    const second = await curate(service, "tags", other("batch-replay"), [{ id: record.id, revisionId: record.revisionId, tagIds: ["memory"] }]);
    expect(second.outcomes[0]?.revisionId).toBe(first.outcomes[0]?.revisionId);
    expect(second.outcomes[0]?.status).toBe("applied");
    expect((await store.read(record.id, undefined, true, true, true))?.revisionId).toBe(first.outcomes[0]?.revisionId);
  });

  it("refuses a changed payload under a reused command ID", async () => {
    const { store, service } = await fixture();
    const record = await capture(store, 6);
    await curate(service, "tags", other("batch-reuse"), [{ id: record.id, revisionId: record.revisionId, tagIds: ["memory"] }]);
    const changed = await curate(service, "tags", other("batch-reuse"), [{ id: record.id, revisionId: record.revisionId, tagIds: ["evaluation"] }]);
    expect(changed.outcomes[0]).toMatchObject({ status: "failed", code: "command-id-reuse" });
    expect((await store.read(record.id))?.content.tags?.tagIds).toEqual(["memory"]);
  });

  it("fails closed on an excluded or forgotten entry", async () => {
    const { store, service } = await fixture();
    const excluded = await capture(store, 7);
    const forgotten = await capture(store, 8);
    await store.setExclusion(other("exclude"), excluded.id, true, undefined, "fixture exclusion");
    await store.forget(other("forget"), forgotten.id, "fixture forget");
    const response = await curate(service, "verdict", other("batch-closed"), [
      { id: excluded.id, revisionId: excluded.revisionId, verdict: "evergreen" },
      { id: forgotten.id, revisionId: forgotten.revisionId, verdict: "evergreen" },
    ]);
    expect(statuses(response)).toEqual(["failed", "failed"]);
    expect(response.outcomes.map(outcome => outcome.code)).toEqual(["excluded", "forgotten"]);
    expect(await store.read(excluded.id, undefined, true, true, true)).toBeTruthy();
    expect((await store.read(excluded.id, undefined, true, true, true))?.content.verdict).toBeUndefined();
  });

  it("produces one winner and one clean conflict when two writers race on one entry", async () => {
    const { store, service } = await fixture();
    const record = await capture(store, 20);
    // Distinct batch command IDs: two independent writers, not a duplicate.
    const racing = (name: string, tag: string) => curate(service, "tags", other(name), [{ id: record.id, revisionId: record.revisionId, tagIds: [tag] }]);
    const [left, right] = await Promise.all([racing("batch-race-left", "memory"), racing("batch-race-right", "evaluation")]);
    const outcomes = [...left.outcomes, ...right.outcomes];
    expect(outcomes.filter(outcome => outcome.status === "applied")).toHaveLength(1);
    expect(outcomes.filter(outcome => outcome.status === "conflict" && outcome.code === "stale-revision")).toHaveLength(1);
    // Neither writer lost the other's revision: exactly one curation landed.
    const committed = await store.read(record.id);
    expect(committed?.content.tags?.tagIds).toHaveLength(1);
    const revisions = (await store.read(record.id, undefined, true, true, true))!;
    expect(revisions.revisionId).toBe(outcomes.find(outcome => outcome.status === "applied")?.revisionId);
  });

  it("refuses an unknown tag and reports the empty-vocabulary seam honestly", async () => {
    const { store, service } = await fixture();
    const record = await capture(store, 9);
    const unknown = await curate(service, "tags", other("batch-unknown-tag"), [{ id: record.id, revisionId: record.revisionId, tagIds: ["not-a-tag"] }]);
    expect(unknown.outcomes[0]).toMatchObject({ status: "failed", code: "unknown-tag" });
    expect((await store.read(record.id))?.content.tags).toBeUndefined();

    const empty = await fixture({ emptyVocabulary: true });
    const emptyRecord = await capture(empty.store, 10);
    const refused = await curate(empty.service, "tags", other("batch-empty-vocabulary"), [{ id: emptyRecord.id, revisionId: emptyRecord.revisionId, tagIds: ["memory"] }]);
    expect(refused.outcomes[0]).toMatchObject({ status: "failed", code: "unknown-tag" });
    expect(refused.outcomes[0]?.reason).toContain("no tag vocabulary is installed");
  });

  it("requires a superseded verdict to name an available replacement", async () => {
    const { store, service } = await fixture();
    const older = await capture(store, 11);
    const newer = await capture(store, 12);
    const missing = await curate(service, "verdict", other("batch-verdict-missing"), [{ id: older.id, revisionId: older.revisionId, verdict: "superseded" }]);
    expect(missing.outcomes[0]).toMatchObject({ status: "failed", code: "invalid-input" });
    const unknown = await curate(service, "verdict", other("batch-verdict-unknown"), [{ id: older.id, revisionId: older.revisionId, verdict: "superseded", supersededBy: "00000000-0000-4000-8000-000000000000" }]);
    expect(unknown.outcomes[0]).toMatchObject({ status: "failed", code: "invalid-input" });
    const applied = await curate(service, "verdict", other("batch-verdict-ok"), [{ id: older.id, revisionId: older.revisionId, verdict: "superseded", supersededBy: newer.id, reason: "Replaced by the newer harness write-up" }]);
    expect(applied.outcomes[0]?.status).toBe("applied");
    expect(applied.outcomes[0]?.stored).toEqual({ verdict: "superseded", supersededBy: newer.id });
  });

  it("applies relations, placement and a summary without touching either other kind", async () => {
    const { store, service } = await fixture();
    const left = await capture(store, 13);
    const right = await capture(store, 14);
    const related = await curate(service, "relation", other("batch-relation"), [{ id: left.id, revisionId: left.revisionId, relationType: "related", relationId: right.id, relationAction: "add" }]);
    expect(related.outcomes[0]?.stored?.relations).toEqual([`related:${right.id}`]);
    const revision = (await store.read(left.id))!.revisionId;
    const removed = await curate(service, "relation", other("batch-relation-remove"), [{ id: left.id, revisionId: revision, relationType: "related", relationId: right.id, relationAction: "remove" }]);
    expect(removed.outcomes[0]?.status).toBe("applied");
    expect(removed.outcomes[0]?.stored?.relations).toEqual([]);
    const absent = await curate(service, "relation", other("batch-relation-absent"), [{ id: left.id, revisionId: removed.outcomes[0]!.revisionId!, relationType: "related", relationId: right.id, relationAction: "remove" }]);
    expect(absent.outcomes[0]?.status).toBe("unchanged");

    const placed = await curate(service, "placement", other("batch-placement"), [{ id: left.id, revisionId: absent.outcomes[0]!.revisionId!, scope: "personal", admission: "archived", reason: "Moved to Moose's Corner" }]);
    expect(placed.outcomes[0]?.stored).toEqual({ scope: "personal", admission: "archived" });
    const placedRecord = await store.read(left.id, undefined, true, true, true);
    expect(placedRecord?.scope).toBe("personal");
    expect(placedRecord?.content.admission?.status).toBe("archived");
    // The summary written by another operation is preserved by placement.
    const summarized = await curate(service, "summary", other("batch-summary"), [{ id: right.id, revisionId: right.revisionId, summary: "A bounded summary of the saved evidence.", coverage: "full" }]);
    expect(summarized.outcomes[0]?.stored?.summary).toMatchObject({ text: "A bounded summary of the saved evidence.", coverage: "full" });
    const finalRecord = await store.read(right.id);
    expect(finalRecord?.content.summary?.evidenceDigest).toMatch(/^[a-f0-9]{64}$/);
    expect(finalRecord?.content.summary?.sourceRevisionId).toBe(right.revisionId);
    expect(finalRecord?.content.text).toBe("Body of saved source 14");
  });

  it("stops the batch when the paid gate refuses and reports the rest as skipped", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-curation-gate-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    await installVocabulary(store);
    const budget = { remaining: 2 };
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {}, () => summarizer, undefined,
      operation => operation !== "tags" ? { ok: true } as const : budget.remaining > 0 ? (budget.remaining -= 1, { ok: true } as const) : ({ ok: false, code: "budget-exhausted" as const, reason: "Monthly tagging budget is spent" }));
    const records = await Promise.all([1, 2, 3, 4, 5].map(index => capture(store, index)));
    const response = await curate(service, "tags", other("batch-budget"), records.map(record => ({ id: record.id, revisionId: record.revisionId, tagIds: ["memory"] })));
    expect(statuses(response)).toEqual(["applied", "applied", "skipped", "skipped", "skipped"]);
    expect(response.outcomes[2]).toMatchObject({ code: "budget-exhausted" });
    expect((await store.read(records[0]!.id))?.content.tags?.tagIds).toEqual(["memory"]);
    // A skipped item is never dispatched, so it stays untouched.
    expect((await store.read(records[2]!.id))?.content.tags).toBeUndefined();
    expect(budget.remaining).toBe(0);
    // A spent tagging budget never blocks a free edit.
    const current = await Promise.all(records.map(async record => (await store.read(record.id))!.revisionId));
    const verdicts = await curate(service, "verdict", other("batch-budget-verdicts"), records.map((record, index) => ({ id: record.id, revisionId: current[index]!, verdict: "evergreen" })));
    expect(verdicts.applied).toBe(5);
  });

  it("reports an unusable item without discarding the rest of the batch", async () => {
    const { store, service } = await fixture();
    const record = await capture(store, 15);
    const untouched = await capture(store, 19);
    const response = await curate(service, "tags", other("batch-partial-payload"), [
      { id: untouched.id, revisionId: untouched.revisionId },
      { id: record.id, revisionId: record.revisionId, tagIds: ["memory"] },
    ]);
    expect(response.outcomes[0]).toMatchObject({ status: "failed", code: "invalid-input" });
    // The usable item after the unusable one still lands.
    expect(response.outcomes[1]?.status).toBe("applied");
    expect((await store.read(record.id))?.content.tags?.tagIds).toEqual(["memory"]);
    expect((await store.read(untouched.id, undefined, true, true, true))?.content.tags).toBeUndefined();
  });

  it("accepts a summary as background work and reports its outcome through the job query", async () => {
    const { store, service } = await fixture();
    const record = await capture(store, 16);
    const started = await service.tool({ action: "summarize", commandId: other("job-start"), sourceId: record.id, revisionId: record.revisionId });
    expect((started.details as { job: { status: string } }).job.status).toBe("running");
    const job = await waitForJob(service, other("job-start"));
    expect(job.status).toBe("done");
    expect(job.revisionId).toBeTruthy();
    expect((await store.read(record.id))?.content.summary?.text).toBe("A bounded saved-source summary.");
    // A duplicate call observes the finished job instead of generating again.
    const duplicate = await service.tool({ action: "summarize", commandId: other("job-start"), sourceId: record.id, revisionId: record.revisionId });
    expect((duplicate.details as { job: { status: string } }).job.status).toBe("done");
    const listed = await service.tool({ action: "curationJob", sourceId: record.id });
    expect((listed.details as { jobs: unknown[] }).jobs).toHaveLength(1);
  });

  it("marks a failed generation as failed and leaves an existing summary in place", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-curation-job-failure-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    await installVocabulary(store);
    const config = await store.config();
    await store.configure(other("failure-knowledge-model"), { ...config, knowledgeModel: { model: "fixture/enrichment", maxInputChars: 48_000, maxOutputChars: 8_000 } });
    const failing: KnowledgeGenerationModel = { ...summarizer, async summarizeSource() { throw new Error("model unavailable"); } };
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {}, () => failing);
    const record = await capture(store, 17);
    await curate(service, "summary", other("job-existing-summary"), [{ id: record.id, revisionId: record.revisionId, summary: "Kept summary", coverage: "sampled" }]);
    const revision = (await store.read(record.id))!.revisionId;
    await service.tool({ action: "summarize", commandId: other("job-failure"), sourceId: record.id, revisionId: revision });
    const job = await waitForJob(service, other("job-failure"));
    expect(job.status).toBe("failed");
    expect(job.code).toBe("unavailable");
    expect((await store.read(record.id))?.content.summary?.text).toBe("Kept summary");
  });

  it("refuses a summary start on a stale revision before any model work", async () => {
    const { store, service } = await fixture();
    const record = await capture(store, 18);
    await curate(service, "verdict", other("job-stale-writer"), [{ id: record.id, revisionId: record.revisionId, verdict: "evergreen" }]);
    await expect(service.tool({ action: "summarize", commandId: other("job-stale"), sourceId: record.id, revisionId: record.revisionId })).rejects.toThrow(/revision changed/);
  });

  // Acceptance case from epic #214 / K1: one batch exercises the real agent tool
  // through an injected conflict, replay, budget stop, and restart, leaving an
  // inspectable JSON report.
  it("survives a conflict, a replay, a budget stop and a restart in one batch", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-curation-acceptance-")); roots.push(root);
    const workspace = new TronWorkspace(root);
    const budget = { remaining: 10_000 };
    // A restarted process is a new owner instance over the same durable
    // workspace: receipts, revisions and the catalog all come back from disk.
    const open = () => { const store = new KnowledgeStore(workspace); return { store, service: new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {}, () => summarizer, undefined, operation => operation !== "tags" ? { ok: true } as const : budget.remaining > 0 ? (budget.remaining -= 1, { ok: true } as const) : ({ ok: false, code: "budget-exhausted" as const, reason: "Monthly tagging budget is spent" }), new KnowledgeCurationJobs(64, 30_000)) }; };
    const first = open();
    await installVocabulary(first.store);
    const records = await Promise.all(Array.from({ length: 25 }, (_, index) => capture(first.store, 100 + index)));
    const batch = other("acceptance-batch");
    const expected = records.map(record => ({ id: record.id, revisionId: record.revisionId, tagIds: ["agent-harness"] }));
    const phases: Array<Record<string, unknown>> = [];

    // Phase 1: a partial batch commits ten items, then the process is lost.
    const partial = await curate(first.service, "tags", batch, expected.slice(0, 10));
    phases.push({ name: "partial-batch", ...counts(partial) });

    // Another writer moves one entry forward, so its batch revision is stale.
    const conflicted = records[10]!;
    await first.store.curateSource({ commandId: other("acceptance-other-writer"), operation: "summary", producer: { actor: "user" }, item: { recordId: conflicted.id, expectedRevision: conflicted.revisionId, summary: { text: "A user note written first", coverage: "full" } } });
    const conflictedRevision = (await first.store.read(conflicted.id))!.revisionId;

    // Phase 2: a new store and service on the same workspace resume the batch
    // from its per-item receipts.
    const second = open();
    const resumed = await curate(second.service, "tags", batch, expected);
    phases.push({ name: "resumed-after-restart", ...counts(resumed) });
    const appliedAfterResume = resumed.outcomes.filter(outcome => outcome.status === "applied").map(outcome => `${outcome.recordId}@${outcome.revisionId}`);
    expect(resumed.applied).toBe(24);
    expect(resumed.outcomes[10]).toMatchObject({ status: "conflict", code: "stale-revision", currentRevision: conflictedRevision });

    // Phase 3: an exact replay writes no second revision for any item.
    const replay = await curate(second.service, "tags", batch, expected);
    phases.push({ name: "replay", ...counts(replay) });
    expect(replay.outcomes.filter(outcome => outcome.status === "applied").map(outcome => `${outcome.recordId}@${outcome.revisionId}`)).toEqual(appliedAfterResume);

    // Phase 4: a spent tagging budget stops a re-tag batch instead of
    // dispatching the rest, while free verdict edits still apply.
    const revisions = await Promise.all(records.map(async record => (await second.store.read(record.id, undefined, true, true, true))!.revisionId));
    budget.remaining = 5;
    const stopped = await curate(second.service, "tags", other("acceptance-budget-stop"), records.map((record, index) => ({ id: record.id, revisionId: revisions[index]!, tagIds: ["evaluation"] })));
    const afterRetag = await Promise.all(records.map(async record => (await second.store.read(record.id, undefined, true, true, true))!.revisionId));
    const verdicts = await curate(second.service, "verdict", other("acceptance-verdicts"), records.map((record, index) => ({ id: record.id, revisionId: afterRetag[index]!, verdict: "evergreen" })));
    phases.push({ name: "budget-stop", ...counts(stopped) });
    expect(stopped.applied).toBe(5);
    expect(stopped.outcomes.filter(outcome => outcome.status === "skipped")).toHaveLength(20);

    // The other writer's summary survived, and only the pre-stop items changed.
    const conflictedAfter = await second.store.read(conflicted.id, undefined, true, true, true);
    expect(conflictedAfter?.content.summary?.text).toBe("A user note written first");
    const final = await Promise.all(records.map(record => second.store.read(record.id, undefined, true, true, true)));
    const tagged = final.filter(record => record?.content.tags?.tagIds.length === 1).length;
    const retagged = final.filter(record => record?.content.tags?.tagIds[0] === "evaluation").length;
    const evergreen = final.filter(record => record?.content.verdict?.verdict === "evergreen").length;
    expect(tagged).toBe(24);
    expect(conflictedAfter?.content.tags).toBeUndefined();
    expect(retagged).toBe(5);
    expect(evergreen).toBe(25);
    expect(verdicts.applied).toBe(25);

    const report = {
      plan: "epic #214 / K1",
      batchCommandId: batch,
      items: records.length,
      phases,
      taggedRecords: tagged,
      retaggedBeforeBudgetStop: retagged,
      conflictedRecordPreservedUserSummary: conflictedAfter?.content.summary?.text === "A user note written first",
      verdictsAppliedWhileBudgetSpent: evergreen,
      stateRevision: stopped.stateRevision,
    };
    const path = join(root, "knowledge-curation-outcome.json");
    await (await import("node:fs/promises")).writeFile(path, `${JSON.stringify(report, null, 2)}\n`);
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual(report);
    expect(phases).toEqual([
      { name: "partial-batch", applied: 10, unchanged: 0, conflict: 0, failed: 0, skipped: 0 },
      { name: "resumed-after-restart", applied: 24, unchanged: 0, conflict: 1, failed: 0, skipped: 0 },
      { name: "replay", applied: 24, unchanged: 0, conflict: 1, failed: 0, skipped: 0 },
      { name: "budget-stop", applied: 5, unchanged: 0, conflict: 0, failed: 0, skipped: 20 },
    ]);
  });
});

function counts(response: KnowledgeCurationResponse) {
  return {
    applied: byStatus(response, "applied").length,
    unchanged: byStatus(response, "unchanged").length,
    conflict: byStatus(response, "conflict").length,
    failed: byStatus(response, "failed").length,
    skipped: byStatus(response, "skipped").length,
  };
}

async function waitForJob(service: KnowledgeService, commandId: string) {
  for (let attempt = 0; attempt < 400; attempt += 1) {
    const listed = await service.tool({ action: "curationJob", commandId });
    const job = (listed.details as { jobs: Array<{ status: string; revisionId?: string; code?: string }> }).jobs[0];
    if (job && job.status !== "running") return job;
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  throw new Error("Summary job did not settle");
}
