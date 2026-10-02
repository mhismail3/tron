import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { KnowledgeCurationJobs } from "./knowledge-curation.js";
import { chooseKnowledgeTags, decideKnowledgeTags, KNOWLEDGE_TAG_CALL_RESERVATION_CENTS, KNOWLEDGE_TAG_CONFIDENCE_THRESHOLD, KnowledgeTaggingBudget, KnowledgeTaggingEngine } from "./knowledge-tagger.js";
import type { JevDecisionClient, JevDecisionRequest, JevDecisionResponse } from "./jev-client.js";
import { KnowledgeObservationService } from "./knowledge-observation.js";
import { KnowledgeService } from "./knowledge-service.js";
import type { KnowledgeCurationJob, KnowledgeRecord } from "./knowledge-contract.js";
const roots: string[] = [];
const sleep = (ms = 0) => new Promise(resolve => setTimeout(resolve, ms));
async function taggingFixture(options: { count?: number; monthlyCap?: number; client?: Pick<JevDecisionClient, "evaluate"> } = {}) {
  const base = await budgetFixture(options.monthlyCap);
  let config = await base.store.config();
  for (let i = 0; i < 2; i += 1) {
    config = await base.store.configureTags({ commandId: `tag-fixture-vocab-${i}`, expectedConfigRevision: config.revision, edit: { kind: "add", tag: { id: i ? "ideas" : "tools", label: i ? "Ideas" : "Tools", definition: i ? "A durable principle or concept." : "A product, service, or tool." , category: i ? "ideas" : "tools", decayClass: i ? "stable" : "ages", state: "active" } } });
  }
  const records = [];
  for (let i = 0; i < (options.count ?? 1); i += 1) {
    const saved = await base.store.captureSource({ commandId: `tag-fixture-source-${i}`, record: { kind: "source", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [], content: { title: `Source ${i}`, uri: `https://example.test/${i}`, text: "A tool and principle saved for future work.", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z", admission: { status: "retained", decidedAt: "2026-01-01T00:00:00Z" } } } });
    records.push(saved.record);
  }
  let calls = 0;
  const client = options.client ?? { async evaluate(request: JevDecisionRequest, _signal, context): Promise<JevDecisionResponse> {
    calls += 1; await context.beforeDispatch?.(); await context.onDispatch?.("sent");
    const categoryKeys = Object.keys(request.questions).filter(key => key.startsWith("category_"));
    const answers = categoryKeys.length ? Object.fromEntries(categoryKeys.map(key => {
      const criteria = request.questions[key]!.criteria as Record<string, unknown>;
      const choice = Object.keys(criteria).find(option => option !== "none") ?? "none";
      return [key, { type: "choice" as const, choice, probabilities: Object.fromEntries(Object.keys(criteria).map(option => [option, option === choice ? 1 : 0])), confidence: 1 }];
    })) : Object.fromEntries(Object.keys(request.questions).map(key => [key, { type: "noul" as const, noul: 0.91 }]));
    return { requestedModel: "jev-latest", actualModel: "jev-latest", answers, usage: { input_tokens: 100, output_tokens: 1 }, estimatedCostCents: 0.00042, maxEstimatedChargeCents: KNOWLEDGE_TAG_CALL_RESERVATION_CENTS };
  } };
  const engine = new KnowledgeTaggingEngine(client, base.budget);
  const waiters = new Map<string, Array<(job: KnowledgeCurationJob) => void>>();
  const settled = new Map<string, KnowledgeCurationJob>();
  const jobs = new KnowledgeCurationJobs(64, 120_000, job => {
    settled.set(job.commandId, job);
    for (const resolve of waiters.get(job.commandId) ?? []) resolve(job);
    waiters.delete(job.commandId);
  });
  const waitJob = (commandId: string): Promise<KnowledgeCurationJob> => {
    const current = jobs.find(commandId) ?? settled.get(commandId);
    if (current && current.status !== "running") return Promise.resolve(current);
    return new Promise(resolve => {
      const pending = waiters.get(commandId) ?? [];
      pending.push(resolve);
      waiters.set(commandId, pending);
    });
  };
  const service = new KnowledgeService(base.store, new KnowledgeObservationService(base.store, undefined), {}, undefined, undefined, undefined, jobs, { engine, budget: base.budget });
  return { ...base, service, records, waitJob, get calls() { return calls; } };
}
afterEach(async () => { vi.useRealTimers(); await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });
async function budgetFixture(monthlyCap = 500) {
  const root = await mkdtemp(join(tmpdir(), "tron-knowledge-tag-budget-")); roots.push(root);
  const store = new KnowledgeStore(new TronWorkspace(root));
  return { root, store, budget: new KnowledgeTaggingBudget(store, () => true, monthlyCap) };
}

/* Failure modes protected by the K4 cases below:
 * - model uncertainty at the threshold or ties must never guess extra tags;
 * - vocabularies wider than Jev's 16-question ceiling must be narrowed first;
 * - disabled/unapproved/exhausted paid access must stop before provider dispatch;
 * - reservation must exist before dispatch, survive restart, and reconcile only
 *   known settlement; uncertain provider outcomes must not be retried blindly;
 * - UTC month rollover must not carry old spend or erase unresolved reservations;
 * - a take/vocabulary/summary change while Jev is in flight must lose the stale
 *   revision fence, preserve the competing edit, and stay in the retag queue;
 * - duplicate owned queue starts must share a run/charge, and cancellation must
 *   preserve completed source writes;
 * - queue pages must be bounded and stop cleanly at paid budget exhaustion.
 */
describe("Knowledge Jev tagging", () => {
  it("blocks paid tagging when the TypeSafe provider credential is absent while free writes continue", async () => {
    const fixture = await taggingFixture();
    const source = fixture.records[0]!;
    const service = new KnowledgeService(fixture.store, new KnowledgeObservationService(fixture.store, undefined), {}, undefined, undefined, async operation => operation === "tags" ? new KnowledgeTaggingBudget(fixture.store, () => false).gate("typesafe") : { ok: true });
    const tags = await service.invoke({ operation: "knowledge.source.curate", request: { commandId: "tag-gate-denied", operation: "tags", producer: { actor: "agent" }, items: [{ recordId: source.id, expectedRevision: source.revisionId, tagIds: ["tools"] }] } }) as { outcomes: Array<{ status: string; code?: string }> };
    expect(tags.outcomes[0]).toMatchObject({ status: "skipped", code: "unavailable" });
    const verdict = await service.invoke({ operation: "knowledge.source.curate", request: { commandId: "free-verdict-after-budget", operation: "verdict", producer: { actor: "user" }, items: [{ recordId: source.id, expectedRevision: source.revisionId, verdict: { verdict: "evergreen" } }] } }) as { outcomes: Array<{ status: string }> };
    expect(verdict.outcomes[0]?.status).toBe("applied");
  });
  it("tags Knowledge through the TypeSafe provider budget without a Jev connection instance", async () => {
    const fixture = await taggingFixture();
    const source = fixture.records[0]!;
    const started = await fixture.service.invoke({ operation: "knowledge.source.tag", request: { commandId: "tag-typesafe-provider", sourceId: source.id, expectedRevision: source.revisionId } }) as { job: { status: string } };
    expect(started.job.status).toBe("running");
    expect((await fixture.waitJob("tag-typesafe-provider")).status).toBe("done");
    expect(await fixture.budget.status("typesafe")).toMatchObject({ enabled: true, paidAccessApproved: true });
  });
  it("uses a strict confidence threshold and omits boundary ties", () => {
    expect(KNOWLEDGE_TAG_CONFIDENCE_THRESHOLD).toBe(0.65);
    expect(chooseKnowledgeTags({ tag_alpha: { type: "noul", noul: 0.9 }, tag_beta: { type: "noul", noul: 0.65 }, tag_gamma: { type: "noul", noul: 0.64 } }, ["alpha", "beta", "gamma"])).toEqual(["alpha"]);
  });
  it("narrows more than sixteen active tags with one category-choice pass and batches noul questions", async () => {
    const tags = Array.from({ length: 20 }, (_, index) => ({ id: `tag-${index}`, label: `Tag ${index}`, definition: `Definition ${index}`, category: index === 0 ? "one" : "other", decayClass: "stable" as const, state: "active" as const }));
    const vocabulary = { revision: 7, tags, guidelines: "Apply definitions, not keyword matches." };
    const record: KnowledgeRecord & { kind: "source" } = { schemaVersion: 1, kind: "source", id: "source", revisionId: "revision-00000001", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [], content: { title: "source", text: "evidence", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z" } };
    const calls: JevDecisionRequest[] = [];
    const client: Pick<JevDecisionClient, "evaluate"> = { async evaluate(request: JevDecisionRequest, _signal, context): Promise<JevDecisionResponse> {
      await context.beforeDispatch?.(); await context.onDispatch?.("sent");
      calls.push(request);
      const categoryKeys = Object.keys(request.questions).filter(key => key.startsWith("category_"));
      const answers = categoryKeys.length ? Object.fromEntries(categoryKeys.map(key => [key, { type: "choice" as const, choice: "one", probabilities: Object.fromEntries(Object.keys(request.questions[key]!.criteria as Record<string, unknown>).map(option => [option, option === "one" ? 1 : 0])), confidence: 1 }])) : Object.fromEntries(Object.keys(request.questions).map(key => [key, { type: "noul" as const, noul: 0.9 }]));
      return { requestedModel: "jev-latest", actualModel: "jev-latest", answers, usage: { input_tokens: 100, output_tokens: 0 }, estimatedCostCents: 0.00042, maxEstimatedChargeCents: KNOWLEDGE_TAG_CALL_RESERVATION_CENTS };
    } };
    const callsReserved: number[] = [];
    const decision = await decideKnowledgeTags(client, record, vocabulary, new AbortController().signal, { async beforeDispatch(index) { callsReserved.push(index); }, async onDispatch() {}, async settle() {}, async uncertain() {} });
    expect(calls.map(call => Object.keys(call.questions))).toEqual([["category_0"], ["tag_tag-0"]]);
    expect(decision).toMatchObject({ tagIds: ["tag-0"], vocabularyRevision: 7, callCount: 2 });
    expect(callsReserved).toEqual([0, 1]);
  });
  it("splits the 256-category taxonomy into bounded category-choice questions", async () => {
    const tags = Array.from({ length: 256 }, (_, index) => ({ id: `tag-${String(index).padStart(3, "0")}`, label: `Tag ${index}`, definition: `Definition ${index}`, category: `category-${String(index).padStart(3, "0")}`, decayClass: "stable" as const, state: "active" as const }));
    const record = { schemaVersion: 1 as const, kind: "source" as const, id: "category-source", revisionId: "revision-00000002", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", scope: "research" as const, provenance: { actor: "connector" as const, evidence: [] }, relations: [], content: { title: "Category source", text: "evidence", captureDisposition: "complete" as const, capturedAt: "2026-01-01T00:00:00Z" } };
    const calls: JevDecisionRequest[] = [];
    const client: Pick<JevDecisionClient, "evaluate"> = { async evaluate(request, _signal, context) {
      await context.beforeDispatch?.(); await context.onDispatch?.("sent"); calls.push(request);
      const categoryKeys = Object.keys(request.questions).filter(key => key.startsWith("category_"));
      const answers = categoryKeys.length ? Object.fromEntries(categoryKeys.map(key => {
        const criteria = request.questions[key]!.criteria as Record<string, unknown>;
        const choice = Object.keys(criteria).find(option => option !== "none")!;
        return [key, { type: "choice" as const, choice, probabilities: Object.fromEntries(Object.keys(criteria).map(option => [option, option === choice ? 1 : 0])), confidence: 1 }];
      })) : Object.fromEntries(Object.keys(request.questions).map(key => [key, { type: "noul" as const, noul: 0.9 }]));
      return { requestedModel: "jev-latest", actualModel: "jev-latest", answers, usage: { input_tokens: 100, output_tokens: 0 }, estimatedCostCents: 0.00042, maxEstimatedChargeCents: KNOWLEDGE_TAG_CALL_RESERVATION_CENTS };
    } };
    const decision = await decideKnowledgeTags(client, record, { revision: 1, tags, guidelines: "Use definitions." }, new AbortController().signal, { async beforeDispatch() {}, async onDispatch() {}, async settle() {}, async uncertain() {} });
    expect(calls[0]?.questions).toHaveProperty("category_0"); expect(calls[0]?.questions).toHaveProperty("category_1");
    expect(Object.keys(calls[0]!.questions)).toHaveLength(2);
    expect(calls[1]!.questions).toHaveProperty("tag_tag-000");
    expect(decision.callCount).toBe(2); expect(decision.tagIds).toEqual(["tag-000", "tag-128"]);
  });
  it("settles provider-budget usage durably and leaves dispatched uncertainty fenced", async () => {
    const { budget, store, root } = await budgetFixture();
    const attempt = await budget.reserve("typesafe", "dispatch-run-0001", 0);
    await budget.markDispatch("typesafe", attempt);
    await budget.settle("typesafe", attempt, { estimatedCostCents: 0.00042, inputTokens: 100, outputTokens: 2 });
    expect(await budget.status("typesafe")).toMatchObject({ spentCents: 0.00042, reservedCents: 0, uncertain: [] });
    const heldWorkspace = (store as unknown as { workspace: TronWorkspace }).workspace as unknown as { release?: () => Promise<void> };
    await heldWorkspace.release?.();
    const restartedStore = new KnowledgeStore(new TronWorkspace(root));
    const restartedBudget = new KnowledgeTaggingBudget(restartedStore);
    expect(await restartedBudget.status("typesafe")).toMatchObject({ spentCents: 0.00042 });
    const uncertain = await restartedBudget.reserve("typesafe", "uncertain-run-0001", 0);
    await restartedBudget.markDispatch("typesafe", uncertain);
    const restartedWorkspace = (restartedStore as unknown as { workspace: TronWorkspace }).workspace as unknown as { release?: () => Promise<void> };
    await restartedWorkspace.release?.();
    const crashRecoveryStore = new KnowledgeStore(new TronWorkspace(root));
    const crashRecoveryBudget = new KnowledgeTaggingBudget(crashRecoveryStore);
    expect(await crashRecoveryBudget.status("typesafe")).toMatchObject({ reservedCents: KNOWLEDGE_TAG_CALL_RESERVATION_CENTS, uncertain: [{ attemptId: uncertain }] });
    await expect(crashRecoveryBudget.reserve("typesafe", "uncertain-run-0001", 0)).rejects.toMatchObject({ code: "conflict" });
    const crashWorkspace = (crashRecoveryStore as unknown as { workspace: TronWorkspace }).workspace as unknown as { release?: () => Promise<void> };
    await crashWorkspace.release?.();
  });
  it("rolls settled spend by UTC month but preserves unresolved dispatches", async () => {
    vi.useFakeTimers(); vi.setSystemTime(new Date("2026-01-31T23:59:00Z"));
    const { budget } = await budgetFixture();
    const attempt = await budget.reserve("typesafe", "rollover-run-0001", 0);
    await budget.markDispatch("typesafe", attempt);
    vi.setSystemTime(new Date("2026-02-01T00:01:00Z"));
    expect(await budget.status("typesafe")).toMatchObject({ month: "2026-02", spentCents: 0, reservedCents: 0, uncertain: [{ attemptId: attempt, month: "2026-01" }] });
  });
  it("reconciles an uncertain attempt by settling the full reserved ceiling instead of retrying blindly", async () => {
    const { budget } = await budgetFixture();
    const attemptId = await budget.reserve("typesafe", "reconcile-run-0001", 0);
    await budget.markDispatch("typesafe", attemptId);
    await expect(budget.reserve("typesafe", "another-run-0001", 0)).rejects.toMatchObject({ code: "conflict" });
    await expect(budget.reconcileUncertain("typesafe", attemptId)).resolves.toEqual({ attemptId, reconciledCostCents: KNOWLEDGE_TAG_CALL_RESERVATION_CENTS });
    expect(await budget.status("typesafe")).toMatchObject({ spentCents: KNOWLEDGE_TAG_CALL_RESERVATION_CENTS, reservedCents: 0, uncertain: [] });
  });
  it("preserves a take revision written during Jev inference and leaves it queued", async () => {
    let release!: () => void; let started!: () => void;
    const wait = new Promise<void>(resolve => { release = resolve; }); const dispatched = new Promise<void>(resolve => { started = resolve; });
    const client: Pick<JevDecisionClient, "evaluate"> = { async evaluate(request, _signal, context) {
      await context.beforeDispatch?.(); await context.onDispatch?.("sent"); started(); await wait;
      const answers = Object.fromEntries(Object.keys(request.questions).map(key => [key, { type: "noul" as const, noul: 0.9 }]));
      return { requestedModel: "jev-latest", actualModel: "jev-latest", answers, usage: { input_tokens: 100, output_tokens: 0 }, estimatedCostCents: 0.00042, maxEstimatedChargeCents: KNOWLEDGE_TAG_CALL_RESERVATION_CENTS };
    } };
    const fixture = await taggingFixture({ client }); const source = fixture.records[0]!;
    const start = await fixture.service.invoke({ operation: "knowledge.source.tag", request: { commandId: "tag-concurrency-command", sourceId: source.id, expectedRevision: source.revisionId, connectionId: "typesafe" } }) as { job: { status: string } };
    expect(start.job.status).toBe("running"); await dispatched;
    const edited = await fixture.store.setSourceTake({ commandId: "user-take-during-tag", recordId: source.id, expectedRevision: source.revisionId, text: "Keep the design simple." });
    release();
    expect(await fixture.waitJob("tag-concurrency-command")).toMatchObject({ status: "failed", code: "stale-revision" });
    expect((await fixture.store.read(source.id))?.revisionId).toBe(edited.record.revisionId);
    const config = await fixture.store.config();
    expect((await fixture.store.tagsNeedingRetag({ vocabularyRevision: config.tagVocabulary.revision })).items.map(item => item.id)).toContain(source.id);
  });
  it("automatically starts a shared background retag after the take is saved", async () => {
    const fixture = await taggingFixture(); const source = fixture.records[0]!;
    const tagged = await fixture.store.curateSource({ commandId: "tag-before-take", operation: "tags", producer: { actor: "agent" }, item: { recordId: source.id, expectedRevision: source.revisionId, tagIds: ["tools"] } });
    const take = await fixture.service.invoke({ operation: "knowledge.source.take", request: { commandId: "take-auto-retag", recordId: source.id, expectedRevision: tagged.record.revisionId, text: "The product is worth keeping." } }) as { record: KnowledgeRecord };
    expect(take.record.revisionId).not.toBe(tagged.record.revisionId);
    for (let i = 0; i < 200; i += 1) {
      const current = await fixture.store.read(source.id);
      if (current?.kind === "source" && current.content.tags?.inputsDigest && current.content.tags.inputsDigest === (await import("./knowledge-store.js")).curationInputsDigest(current.content)) break;
      await sleep(1);
    }
    expect(fixture.calls).toBeGreaterThan(0);
    const current = await fixture.store.read(source.id);
    expect(current?.kind === "source" ? current.content.tags?.tagIds : undefined).toEqual(["tools", "ideas"]);
  });
  it("automatically re-tags when a summary changes because the digest includes the summary text", async () => {
    const fixture = await taggingFixture(); const source = fixture.records[0]!;
    const first = await fixture.store.curateSource({ commandId: "tag-before-summary", operation: "tags", producer: { actor: "agent" }, item: { recordId: source.id, expectedRevision: source.revisionId, tagIds: ["tools"] } });
    const response = await fixture.service.invoke({ operation: "knowledge.source.curate", request: { commandId: "summary-auto-retag", operation: "summary", producer: { actor: "user" }, items: [{ recordId: source.id, expectedRevision: first.record.revisionId, summary: { text: "A useful tool and durable principle.", coverage: "full" } }] } }) as { outcomes: Array<{ status: string }> };
    expect(response.outcomes[0]?.status).toBe("applied");
    for (let i = 0; i < 200; i += 1) {
      const current = await fixture.store.read(source.id);
      if (current?.kind === "source" && current.content.tags?.inputsDigest === (await import("./knowledge-store.js")).curationInputsDigest(current.content)) break;
      await sleep(1);
    }
    expect(fixture.calls).toBeGreaterThan(0);
    expect((await fixture.store.read(source.id))?.revisionId).not.toBe(first.record.revisionId);
  });
  it("exposes explicit tagging through the agent knowledge tool", async () => {
    const fixture = await taggingFixture(); const source = fixture.records[0]!;
    const result = await fixture.service.tool({ action: "tagSource", commandId: "agent-tag-tool", sourceId: source.id, expectedRevision: source.revisionId, connectionId: "typesafe" });
    expect(result.text).toContain("Knowledge tag job");
    const details = result.details as { job: { commandId: string } };
    expect(await fixture.waitJob(details.job.commandId)).toMatchObject({ status: "done", operation: "tags" });
    const tagged = await fixture.store.read(source.id);
    expect(tagged?.kind === "source" ? tagged.content.tags?.producer : undefined).toMatchObject({ actor: "agent", model: "jev-latest" });
  });
  it("automatically queues stale selections after a vocabulary edition change", async () => {
    const fixture = await taggingFixture(); const source = fixture.records[0]!;
    const initial = await fixture.store.curateSource({ commandId: "tag-vocab-before", operation: "tags", producer: { actor: "agent" }, item: { recordId: source.id, expectedRevision: source.revisionId, tagIds: ["tools"] } });
    const config = await fixture.store.config();
    await fixture.service.invoke({ operation: "knowledge.tags.configure", request: { commandId: "tag-vocab-auto", expectedConfigRevision: config.revision, edit: { kind: "guidelines", guidelines: "The updated user policy." } } });
    for (let i = 0; i < 200; i += 1) {
      const current = await fixture.store.read(source.id);
      if (current?.kind === "source" && current.content.tags?.vocabularyRevision === config.tagVocabulary.revision + 1) break;
      await sleep(1);
    }
    expect(fixture.calls).toBeGreaterThan(0);
    expect((await fixture.store.read(source.id))?.revisionId).not.toBe(initial.record.revisionId);
  });
  it("rejects a Jev result after a vocabulary edition changes while the call is in flight", async () => {
    let release!: () => void; let started!: () => void;
    const wait = new Promise<void>(resolve => { release = resolve; }); const dispatched = new Promise<void>(resolve => { started = resolve; });
    const client: Pick<JevDecisionClient, "evaluate"> = { async evaluate(request, _signal, context) {
      await context.beforeDispatch?.(); await context.onDispatch?.("sent"); started(); await wait;
      const answers = Object.fromEntries(Object.keys(request.questions).map(key => [key, { type: "noul" as const, noul: 0.9 }]));
      return { requestedModel: "jev-latest", actualModel: "jev-latest", answers, usage: { input_tokens: 100, output_tokens: 0 }, estimatedCostCents: 0.00042, maxEstimatedChargeCents: KNOWLEDGE_TAG_CALL_RESERVATION_CENTS };
    } };
    const fixture = await taggingFixture({ client }); const source = fixture.records[0]!;
    await fixture.service.invoke({ operation: "knowledge.source.tag", request: { commandId: "tag-vocab-race", sourceId: source.id, expectedRevision: source.revisionId, connectionId: "typesafe" } }); await dispatched;
    const config = await fixture.store.config();
    await fixture.store.configureTags({ commandId: "vocabulary-edition-during-tag", expectedConfigRevision: config.revision, edit: { kind: "guidelines", guidelines: "Apply the new user rule." } });
    release();
    expect(await fixture.waitJob("tag-vocab-race")).toMatchObject({ status: "failed", code: "stale-vocabulary" });
    const after = await fixture.store.read(source.id); expect(after?.revisionId).toBe(source.revisionId);
    expect((await fixture.store.tagsNeedingRetag({ vocabularyRevision: (await fixture.store.config()).tagVocabulary.revision })).items.map(item => item.id)).toContain(source.id);
  });
  it("stops a queue at the monthly cap after keeping earlier entry commits", async () => {
    let jevCalls = 0;
    const client: Pick<JevDecisionClient, "evaluate"> = { async evaluate(request, _signal, context) { await context.beforeDispatch?.(); await context.onDispatch?.("sent"); jevCalls += 1; return { requestedModel: "jev-latest", actualModel: "jev-latest", answers: Object.fromEntries(Object.keys(request.questions).map(key => [key, { type: "noul" as const, noul: 0.9 }])), usage: { input_tokens: 64_000, output_tokens: 0 }, estimatedCostCents: KNOWLEDGE_TAG_CALL_RESERVATION_CENTS, maxEstimatedChargeCents: KNOWLEDGE_TAG_CALL_RESERVATION_CENTS }; } };
    const fixture = await taggingFixture({ count: 4, monthlyCap: 1, client });
    const result = await fixture.service.invoke({ operation: "knowledge.tags.run", request: { commandId: "retag-under-budget", connectionId: "typesafe", limit: 4 } }) as { job: { commandId: string } };
    const queueJob = await fixture.waitJob(result.job.commandId);
    expect(queueJob).toMatchObject({ status: "failed", code: "budget-exhausted" });
    expect(jevCalls).toBe(3);
    const config = await fixture.store.config();
    expect((await fixture.store.tagsNeedingRetag({ vocabularyRevision: config.tagVocabulary.revision })).items).toHaveLength(1);
    expect(await fixture.budget.status("typesafe")).toMatchObject({ capCents: 1, availableCents: 1 - 3 * KNOWLEDGE_TAG_CALL_RESERVATION_CENTS });
  });
  it("shares duplicate in-flight starts so a retry does not make a second call", async () => {
    let calls = 0; let release!: () => void; let started!: () => void;
    const wait = new Promise<void>(resolve => { release = resolve; }); const dispatched = new Promise<void>(resolve => { started = resolve; });
    const client: Pick<JevDecisionClient, "evaluate"> = { async evaluate(request, _signal, context) {
      calls += 1; await context.beforeDispatch?.(); await context.onDispatch?.("sent"); started(); await wait;
      return { requestedModel: "jev-latest", actualModel: "jev-latest", answers: Object.fromEntries(Object.keys(request.questions).map(key => [key, { type: "noul" as const, noul: 0.9 }])), usage: { input_tokens: 100, output_tokens: 0 }, estimatedCostCents: 0.00042, maxEstimatedChargeCents: KNOWLEDGE_TAG_CALL_RESERVATION_CENTS };
    } };
    const fixture = await taggingFixture({ client }); const source = fixture.records[0]!;
    const request = { operation: "knowledge.source.tag" as const, request: { commandId: "duplicate-tag-start", sourceId: source.id, expectedRevision: source.revisionId, connectionId: "typesafe" } };
    const first = await fixture.service.invoke(request); await dispatched;
    const second = await fixture.service.invoke(request);
    expect((second as { job: { status: string } }).job.status).toBe("running"); expect(calls).toBe(1);
    release(); await fixture.waitJob("duplicate-tag-start");
    expect(await fixture.budget.status("typesafe")).toMatchObject({ spentCents: 0.00042, reservedCents: 0 });
    expect(first).toEqual(second);
  });
  it("estimates the bounded queue reservation without calling Jev", async () => {
    const fixture = await taggingFixture({ count: 4 });
    const estimate = await fixture.service.invoke({ operation: "knowledge.tags.estimate", request: { connectionId: "typesafe", limit: 4 } }) as { queuedSources: number; callsAtMost: number; reservationCentsAtMost: number; affordableByCurrentBudget: boolean };
    expect(estimate).toMatchObject({ queuedSources: 4, callsAtMost: 4, affordableByCurrentBudget: true });
    expect(estimate.reservationCentsAtMost).toBeCloseTo(4 * KNOWLEDGE_TAG_CALL_RESERVATION_CENTS);
    let config = await fixture.store.config();
    for (let index = 0; index < 15; index += 1) config = await fixture.store.configureTags({ commandId: `estimate-tag-${index}`, expectedConfigRevision: config.revision, edit: { kind: "add", tag: { id: `extra-${index}`, label: `Extra ${index}`, definition: "A bounded synthetic category candidate.", category: "tools", decayClass: "ages", state: "active" } } });
    const wider = await fixture.service.estimateTaggingCost({ connectionId: "typesafe", limit: 4 });
    expect(wider).toMatchObject({ queuedSources: 4, callsAtMost: 12 });
    expect(fixture.calls).toBe(0);
  });
  it("cancels a queue without rolling back previously committed tags", async () => {
    let count = 0; let secondStarted!: () => void; const waiting = new Promise<void>(resolve => { secondStarted = resolve; });
    const client: Pick<JevDecisionClient, "evaluate"> = { async evaluate(request, signal, context) {
      count += 1; await context.beforeDispatch?.(); await context.onDispatch?.("sent");
      if (count === 2) { secondStarted(); await new Promise<never>((_resolve, reject) => signal.addEventListener("abort", () => reject(new Error("cancelled")), { once: true })); }
      return { requestedModel: "jev-latest", actualModel: "jev-latest", answers: Object.fromEntries(Object.keys(request.questions).map(key => [key, { type: "noul" as const, noul: 0.9 }])), usage: { input_tokens: 100, output_tokens: 0 }, estimatedCostCents: 0.00042, maxEstimatedChargeCents: KNOWLEDGE_TAG_CALL_RESERVATION_CENTS };
    } };
    const fixture = await taggingFixture({ count: 2, client });
    const start = await fixture.service.invoke({ operation: "knowledge.tags.run", request: { commandId: "cancel-tag-queue", connectionId: "typesafe", limit: 2 } }) as { job: { commandId: string } };
    await waiting; fixture.service.dispose();
    expect(await fixture.waitJob(start.job.commandId)).toMatchObject({ status: "failed", code: "cancelled" });
    const tagged = await Promise.all(fixture.records.map(async source => {
      const current = await fixture.store.read(source.id);
      return current?.kind === "source" && Boolean(current.content.tags);
    }));
    expect(tagged.filter(Boolean)).toHaveLength(1);
    expect(count).toBe(2);
  });
});
