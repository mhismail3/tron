import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
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
  const setup = await owner.execute({ kind: "setup.begin", commandId: "assessment-setup-begin", instanceId: "jev", definitionId: "knowledge.jev", method: "token" }) as { operationId: string };
  await owner.execute({ kind: "setup.complete", commandId: "assessment-setup-done", operationId: setup.operationId, instanceId: "jev", providerAccountId: "personal", credentialRef: "connector:jev:personal", policy: { enabled: true, allowWrites: false, paidAccessApproved, paidBudgetCents: monthlyCap, recurringApproved: false } });
  await owner.recordProviderObservation("jev", 1, { credentialAvailability: "available", providerIdentity: "admitted" });
  const store = new KnowledgeStore(new TronWorkspace(root), undefined, async id => owner.resolveInstance(id).catch(() => undefined));
  const credentials = { async read(reference: string) { return reference === "connector:jev:personal" ? "synthetic" : undefined; } };
  const budget = new KnowledgeTaggingBudget(store, owner, credentials);
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
    const budget = await f.budget.status("jev");
    expect(budget.spentCents).toBeCloseTo(0.00042);
    expect(budget.reservedCents).toBe(0);
  });

  it("refuses Jev dispatch before assessment when the monthly ledger is exhausted", async () => {
    const f = await fixture(1);
    for (let index = 0; index < 3; index += 1) {
      const occupied = await f.budget.reserveAssessment("jev", `existing-monthly-attempt-${index}`);
      await f.budget.markDispatch("jev", occupied);
      await f.budget.settle("jev", occupied, { inputTokens: 64_000, outputTokens: 0, estimatedCostCents: KNOWLEDGE_TAG_CALL_RESERVATION_CENTS });
    }
    let dispatched = false;
    const model: SourceAssessmentModel = { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); dispatched = true; await context?.onDispatch?.(); return { summary: "no", evidenceQuality: "unknown", freshness: "unknown" }; } };
    const service = new KnowledgeService(f.store, new KnowledgeObservationService(f.store, undefined), {}, undefined, undefined, undefined, undefined, { budget: f.budget, assessment: model });
    await expect(service.invoke({ operation: "knowledge.source.assess", request: { commandId: "jev-exhausted-assess", sourceId: f.source.id, expectedRevision: f.source.revisionId, assessor: "jev" } })).rejects.toThrow(/budget/i);
    expect(dispatched).toBe(false);
  });

  it("refuses Jev assessment when paid access is off before provider dispatch", async () => {
    const f = await fixture(500, false);
    let dispatched = false;
    const model: SourceAssessmentModel = { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); dispatched = true; return { summary: "no", evidenceQuality: "unknown", freshness: "unknown" }; } };
    const service = new KnowledgeService(f.store, new KnowledgeObservationService(f.store, undefined), {}, undefined, undefined, undefined, undefined, { budget: f.budget, assessment: model });
    await expect(service.invoke({ operation: "knowledge.source.assess", request: { commandId: "jev-paid-off", sourceId: f.source.id, expectedRevision: f.source.revisionId, assessor: "jev" } })).rejects.toThrow(/paid.access|approved|disabled/i);
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
