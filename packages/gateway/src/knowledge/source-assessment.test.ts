import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ConnectionOwner } from "../integrations/connection-owner.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeObservationService } from "./knowledge-observation.js";
import { KnowledgeService } from "./knowledge-service.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { KnowledgeTaggingBudget, KNOWLEDGE_TAG_CALL_RESERVATION_CENTS } from "./knowledge-tagger.js";
import type { SourceAssessmentModel } from "./source-capture.js";
import type { KnowledgeRecord } from "./knowledge-contract.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

async function fixture(monthlyCap = 500, paidAccessApproved = true) {
  const root = await mkdtemp(join(tmpdir(), "tron-source-assessment-")); roots.push(root);
  const owner = new ConnectionOwner(root);
  const store = new KnowledgeStore(new TronWorkspace(root), undefined, async id => owner.resolveInstance(id).catch(() => undefined));
  // A configured TypeSafe key is the paid-work consent (user decision 2026-09-30).
  const budget = new KnowledgeTaggingBudget(store, () => paidAccessApproved, monthlyCap);
  const source = (await store.captureSource({ commandId: "assessment-source", record: { kind: "source", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [], content: { title: "Assessment source", uri: "https://example.test/source", text: "Useful evidence to assess.", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z", admission: { status: "pending", decidedAt: "2026-01-01T00:00:00Z", producer: { actor: "connector" } } } } })).record as KnowledgeRecord & { kind: "source" };
  return { root, owner, store, budget, source };
}

const assessment: SourceAssessmentModel = { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); await context?.onDispatch?.(); return { summary: "useful", evidenceQuality: "high", freshness: "current", recommendation: "retained", confidence: 0.91, classification: "research", model: "jev-1.13.0", usage: { inputTokens: 100, outputTokens: 2, estimatedCostCents: 0.00042, pricing: "typesafe-jev-1.13.0-input-0.042-usd-per-million-output-free" } }; } };

/* Failure modes: Jev assessment can overspend or bypass the one monthly ledger;
 * a paid call must be refused before POST when authority/capacity is absent;
 * assessment is a derivative and must never decide admission; model assessments
 * require the configured Knowledge model and produce the same decision fields. */
describe("source assessment primitive", () => {
  it("assesses one source with Jev from the shared monthly ledger without changing admission", async () => {
    const f = await fixture();
    const service = new KnowledgeService(f.store, new KnowledgeObservationService(f.store, undefined), {}, undefined, undefined, undefined, undefined, { budget: f.budget, assessment });
    const result = await service.invoke({ operation: "knowledge.source.assess", request: { commandId: "single-jev-assess", sourceId: f.source.id, expectedRevision: f.source.revisionId, assessor: "jev" } }) as { assessment: { recommendation: string; confidence: number; classification: string }; source: KnowledgeRecord & { kind: "source" } };
    expect(result.assessment).toMatchObject({ recommendation: "retained", confidence: 0.91, classification: "research" });
    expect(result.source.content.admission).toMatchObject({ status: "pending" });
    expect(result.source.content.assessment).toMatchObject({ recommendation: "retained", confidence: 0.91 });
    const budget = await f.budget.status("typesafe");
    expect(budget.spentCents).toBeCloseTo(0.00042);
    expect(budget.reservedCents).toBe(0);
  });

  // Failure mode: the personal check read the caller's (older) revision, so a
  // source moved to personal after that revision still had its text sent to Jev.
  it("refuses Jev for an older research revision of a source since moved to personal", async () => {
    const f = await fixture();
    await f.store.curateSource({ commandId: "assessment-move-personal", operation: "placement", producer: { actor: "user" }, item: { recordId: f.source.id, expectedRevision: f.source.revisionId, placement: { scope: "personal" } } });
    let sent = false;
    const model: SourceAssessmentModel = { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); sent = true; await context?.onDispatch?.(); return { summary: "must not assess", evidenceQuality: "unknown", freshness: "unknown" }; } };
    const service = new KnowledgeService(f.store, new KnowledgeObservationService(f.store, undefined), {}, undefined, undefined, undefined, undefined, { budget: f.budget, assessment: model });
    const before = await f.budget.status("typesafe");
    await expect(service.invoke({ operation: "knowledge.source.assess", request: { commandId: "jev-stale-personal", sourceId: f.source.id, expectedRevision: f.source.revisionId, assessor: "jev" } })).rejects.toMatchObject({ code: "unsupported" });
    expect(sent).toBe(false);
    expect(await f.budget.status("typesafe")).toEqual(before);
  });

  // Failure mode: every reservation conflict was reported as "paid and settled",
  // including an unrelated open dispatch that cost this command nothing.
  it("names an open unrelated dispatch instead of claiming this attempt was paid", async () => {
    const f = await fixture();
    const connectionId = (await f.budget.connectionId())!;
    const open = await f.budget.reserve(connectionId, "tagging-job", 0);
    await f.budget.markDispatch(connectionId, open);
    const service = new KnowledgeService(f.store, new KnowledgeObservationService(f.store, undefined), {}, undefined, undefined, undefined, undefined, { budget: f.budget, assessment });
    const refusal = service.invoke({ operation: "knowledge.source.assess", request: { commandId: "jev-open-unrelated", sourceId: f.source.id, expectedRevision: f.source.revisionId, assessor: "jev" } });
    await expect(refusal).rejects.toMatchObject({ code: "conflict" });
    await expect(refusal).rejects.not.toThrow(/paid and settled/);
  });

  it("refuses Jev assessment of a personal source before reserving the monthly ledger", async () => {
    const f = await fixture();
    const personal = (await f.store.captureSource({ commandId: "assessment-personal-source", record: { ...f.source, id: undefined, revisionId: undefined, updatedAt: undefined, scope: "personal" } })).record as KnowledgeRecord & { kind: "source" };
    let dispatched = false;
    const model: SourceAssessmentModel = { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); dispatched = true; await context?.onDispatch?.(); return { summary: "must not assess", evidenceQuality: "unknown", freshness: "unknown" }; } };
    const service = new KnowledgeService(f.store, new KnowledgeObservationService(f.store, undefined), {}, undefined, undefined, undefined, undefined, { budget: f.budget, assessment: model });
    const before = await f.budget.status("typesafe");
    await expect(service.invoke({ operation: "knowledge.source.assess", request: { commandId: "jev-personal-refusal", sourceId: personal.id, expectedRevision: personal.revisionId, assessor: "jev" } })).rejects.toMatchObject({ code: "unsupported" });
    expect(dispatched).toBe(false);
    expect(await f.budget.status("typesafe")).toEqual(before);
  });

  it("replays a committed assessment receipt before touching the paid ledger", async () => {
    const f = await fixture();
    let calls = 0;
    const model: SourceAssessmentModel = { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); calls += 1; await context?.onDispatch?.(); return { summary: "useful", evidenceQuality: "high", freshness: "current", recommendation: "retained", confidence: 0.91, classification: "research", model: "jev-1.13.0", usage: { inputTokens: 100, outputTokens: 2, estimatedCostCents: 0.00042, pricing: "typesafe-jev-1.13.0-input-0.042-usd-per-million-output-free" } }; } };
    const service = new KnowledgeService(f.store, new KnowledgeObservationService(f.store, undefined), {}, undefined, undefined, undefined, undefined, { budget: f.budget, assessment: model });
    const capture = f.store.captureSource.bind(f.store);
    vi.spyOn(f.store, "captureSource").mockImplementationOnce(async value => { await capture(value); throw new Error("response lost after durable commit"); });
    const request = { operation: "knowledge.source.assess" as const, request: { commandId: "replay-committed-assessment", sourceId: f.source.id, expectedRevision: f.source.revisionId, assessor: "jev" as const } };
    await expect(service.invoke(request)).rejects.toThrow("response lost after durable commit");
    const replay = await service.invoke(request);
    expect((replay as { source: KnowledgeRecord }).source).toEqual(await f.store.read(f.source.id, undefined, false, true, true));
    expect(calls).toBe(1);
    expect(await f.budget.status("typesafe")).toMatchObject({ spentCents: 0.00042, reservedCents: 0 });
  });

  it("settles a received Jev result when record persistence fails and requires a new command", async () => {
    const f = await fixture();
    let calls = 0;
    const model: SourceAssessmentModel = { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); calls += 1; await context?.onDispatch?.(); return { summary: "useful", evidenceQuality: "high", freshness: "current", recommendation: "retained", confidence: 0.91, classification: "research", model: "jev-1.13.0", usage: { inputTokens: 100, outputTokens: 2, estimatedCostCents: 0.00042, pricing: "typesafe-jev-1.13.0-input-0.042-usd-per-million-output-free" } }; } };
    const service = new KnowledgeService(f.store, new KnowledgeObservationService(f.store, undefined), {}, undefined, undefined, undefined, undefined, { budget: f.budget, assessment: model });
    const write = vi.spyOn(f.store, "captureSource").mockRejectedValueOnce(new Error("injected record persistence failure"));
    const request = { operation: "knowledge.source.assess" as const, request: { commandId: "settled-write-failure-assessment", sourceId: f.source.id, expectedRevision: f.source.revisionId, assessor: "jev" as const } };
    await expect(service.invoke(request)).rejects.toThrow("injected record persistence failure");
    const budget = await f.budget.status("typesafe");
    expect(budget).toMatchObject({ spentCents: 0.00042, reservedCents: 0 });
    await expect(service.invoke(request)).rejects.toMatchObject({ code: "conflict", message: expect.stringContaining("retry with a new commandId") });
    expect(calls).toBe(1);
    write.mockRestore();
  });

  it("refuses Jev dispatch before assessment when the monthly ledger is exhausted", async () => {
    const f = await fixture(1);
    for (let index = 0; index < 3; index += 1) {
      const occupied = await f.budget.reserveAssessment("typesafe", `existing-monthly-attempt-${index}`);
      await f.budget.markDispatch("typesafe", occupied);
      await f.budget.settle("typesafe", occupied, { inputTokens: 64_000, outputTokens: 0, estimatedCostCents: KNOWLEDGE_TAG_CALL_RESERVATION_CENTS });
    }
    let dispatched = false;
    const model: SourceAssessmentModel = { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); dispatched = true; await context?.onDispatch?.(); return { summary: "no", evidenceQuality: "unknown", freshness: "unknown" }; } };
    const service = new KnowledgeService(f.store, new KnowledgeObservationService(f.store, undefined), {}, undefined, undefined, undefined, undefined, { budget: f.budget, assessment: model });
    await expect(service.invoke({ operation: "knowledge.source.assess", request: { commandId: "jev-exhausted-assess", sourceId: f.source.id, expectedRevision: f.source.revisionId, assessor: "jev" } })).rejects.toThrow(/budget/i);
    expect(dispatched).toBe(false);
  });

  it("refuses Jev assessment without a configured TypeSafe key before provider dispatch", async () => {
    const f = await fixture(500, false);
    let dispatched = false;
    const model: SourceAssessmentModel = { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); dispatched = true; return { summary: "no", evidenceQuality: "unknown", freshness: "unknown" }; } };
    const service = new KnowledgeService(f.store, new KnowledgeObservationService(f.store, undefined), {}, undefined, undefined, undefined, undefined, { budget: f.budget, assessment: model });
    await expect(service.invoke({ operation: "knowledge.source.assess", request: { commandId: "jev-paid-off", sourceId: f.source.id, expectedRevision: f.source.revisionId, assessor: "jev" } })).rejects.toThrow(/TypeSafe provider credential/i);
    expect(dispatched).toBe(false);
  });

  it("uses the configured Knowledge model and refuses when it is unset", async () => {
    const f = await fixture();
    const model: SourceAssessmentModel = { async assess() { return { summary: "model result", evidenceQuality: "medium", freshness: "current", recommendation: "retained", confidence: 0.7, classification: "workflow", model: "fixture/model" }; } };
    const configured = new KnowledgeService(f.store, new KnowledgeObservationService(f.store, undefined), {}, () => model);
    const tool = await configured.tool({ action: "assessSource", commandId: "model-assess", sourceId: f.source.id, revisionId: f.source.revisionId, assessor: "model" });
    const result = tool.details as { assessment: { recommendation: string; confidence: number; classification: string }; source: KnowledgeRecord & { kind: "source" } };
    expect(result.assessment).toMatchObject({ recommendation: "retained", confidence: 0.7, classification: "workflow" });
    expect(result.source.content.admission).toMatchObject({ status: "pending" });
    const unset = new KnowledgeService(f.store, new KnowledgeObservationService(f.store, undefined));
    const latest = result.source;
    await expect(unset.invoke({ operation: "knowledge.source.assess", request: { commandId: "model-unset", sourceId: latest.id, expectedRevision: latest.revisionId, assessor: "model" } })).rejects.toThrow(/configured Knowledge model/i);
  });
});
