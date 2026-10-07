import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { KnowledgeObservationService } from "./knowledge-observation.js";
import { KnowledgeCurationJobs, type KnowledgeCurationJob } from "./knowledge-curation.js";
import { KnowledgeService } from "./knowledge-service.js";
import { KnowledgeTaggingBudget, KnowledgeTaggingEngine, KNOWLEDGE_TAG_CALL_RESERVATION_CENTS } from "./knowledge-tagger.js";
import type { JevDecisionClient, JevDecisionRequest } from "./jev-client.js";

const roots: string[] = [];
const workspaces: TronWorkspace[] = [];
afterEach(async () => {
  for (const workspace of workspaces.splice(0)) await workspace.dispose();
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});
describe("Knowledge Jev tagging scale", () => {
  it("processes 440 sources in bounded queue batches with fake Jev", async () => {
    const home = await mkdtemp(join(tmpdir(), "tron-tagging-scale-")); roots.push(home);
    const workspace = new TronWorkspace(home); workspaces.push(workspace);
    const store = new KnowledgeStore(workspace);
    let config = await store.config();
    config = await store.configureTags({ commandId: "tag-scale-vocabulary", expectedConfigRevision: config.revision, edit: { kind: "add", tag: { id: "useful", label: "Useful", definition: "Useful for future work.", category: "work", decayClass: "ages", state: "active" } } });
    for (let index = 0; index < 440; index += 1) await store.captureSource({ commandId: `tag-scale-source-${index}`, record: { kind: "source", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [], content: { title: `Scale source ${index}`, uri: `https://scale.example/${index}`, text: "A bounded synthetic source useful for future work.", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z", admission: { status: "retained", decidedAt: "2026-01-01T00:00:00Z" } } } });
    let dispatched = 0;
    const fakeJev: Pick<JevDecisionClient, "evaluate"> = { async evaluate(request: JevDecisionRequest, _signal, context) {
      await context.beforeDispatch?.(); await context.onDispatch?.("sent"); dispatched += 1;
      return { requestedModel: "jev-latest", actualModel: "jev-latest", answers: Object.fromEntries(Object.keys(request.questions).map(key => [key, { type: "noul" as const, noul: 0.9 }])), usage: { input_tokens: 120, output_tokens: 1 }, estimatedCostCents: 120 * 42 / 10_000_000, maxEstimatedChargeCents: KNOWLEDGE_TAG_CALL_RESERVATION_CENTS };
    } };
    const budget = new KnowledgeTaggingBudget(store);
    const terminalWaiters = new Map<string, (job: KnowledgeCurationJob) => void>();
    const jobs = new KnowledgeCurationJobs(64, 120_000, job => {
      terminalWaiters.get(job.commandId)?.(job);
      terminalWaiters.delete(job.commandId);
    });
    const waitJob = (commandId: string): Promise<KnowledgeCurationJob> =>
      new Promise(resolve => terminalWaiters.set(commandId, resolve));
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {}, undefined, undefined, undefined, jobs, { engine: new KnowledgeTaggingEngine(fakeJev, budget), budget });
    const started = performance.now();
    let processed = 0;
    for (let batch = 0; batch < 18; batch += 1) {
      const commandId = `tag-scale-queue-${batch}`;
      const settledJob = waitJob(commandId);
      const startedJob = await service.invoke({ operation: "knowledge.tags.run", request: { commandId, connectionId: "typesafe", limit: 25 } }) as { job: { commandId: string } };
      expect(startedJob.job.commandId).toBe(commandId);
      const job = await settledJob;
      expect(job.status).toBe("done");
      const configNow = await store.config();
      const stale = await store.tagsNeedingRetag({ vocabularyRevision: configNow.tagVocabulary.revision, limit: 25 });
      processed += Math.min(25, 440 - processed);
      if (processed < 440) expect(stale.items.length).toBeGreaterThan(0);
    }
    const elapsedMs = performance.now() - started;
    expect(dispatched).toBe(440);
    expect(processed).toBe(440);
    const budgetStatus = await budget.status("typesafe");
    const expectedSpendCents = 440 * (120 * 42 / 10_000_000);
    expect(budgetStatus.spentCents).toBeCloseTo(expectedSpendCents);
    expect(budgetStatus.spentCents).toBeLessThanOrEqual(budgetStatus.capCents);
    expect(budgetStatus.reservedCents).toBe(0);
    expect(elapsedMs).toBeLessThan(120_000);
    console.log(JSON.stringify({ sources: 440, batches: 18, jevDispatches: dispatched, elapsedMs: +elapsedMs.toFixed(1), throughputSourcesPerSecond: +(440 / (elapsedMs / 1_000)).toFixed(1) }));
  }, 180_000);
});
