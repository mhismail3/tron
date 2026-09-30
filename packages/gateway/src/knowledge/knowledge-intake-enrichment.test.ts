import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { ConnectionOwner } from "../integrations/connection-owner.js";
import { KnowledgeConnectorExtension, type ConnectorHTTPResponse } from "./connectors.js";
import { KnowledgeObservationService } from "./knowledge-observation.js";
import { KnowledgeService, type KnowledgeGenerationModel } from "./knowledge-service.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { InMemoryConnectorCredentialStore } from "../../test-support/connector-credentials.js";
import type { SourceAssessmentModel } from "./source-capture.js";
import { KnowledgeTaggingBudget } from "./knowledge-tagger.js";

const roots: string[] = [];
const command = (value: string) => `k5-intake-${value}`;
const headers = () => new Headers();
function response(value: unknown): ConnectorHTTPResponse { return { status: 200, headers: headers(), body: JSON.stringify(value) }; }
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(done => { resolve = done; }); return { promise, resolve }; }
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true}))); });

/** Failure modes: a model or tagging failure blocks other items; unapproved
 * tagging drops the summary; intake waits on model latency; a rerun re-charges;
 * summary and tagging race admission; partial captures (every X post) never
 * get a summary. This drives the actual connector and KnowledgeService owners
 * with local model/Jev fakes, never live credentials or paid providers. Its
 * outcome JSON is kept at packages/gateway/test-results/knowledge-intake-outcome.json
 * inside the worktree that ran it, so concurrent runs in two worktrees keep two
 * artifacts instead of overwriting one shared temp file. */
describe("K5 Raindrop intake enrichment", () => {
  it("keeps a summary when Jev is unapproved, reports the skip, and lets another item survive model failure", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-k5-failure-e2e-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const initial = await store.config();
    await store.configure("k5-failure-model", { ...initial, knowledgeModel: { model: "fixture/deepseek", maxInputChars: 48_000, maxOutputChars: 8_000 }, observation: { ...initial.observation, model: "fixture/observer" } });
    const noCalls: string[] = [];
    const fakeModel: KnowledgeGenerationModel = {
      async reflect() { return "reflect"; }, async synthesize() { return "synthesis"; },
      async summarizeSource(input) { if (input.sourceText.includes("FAIL_MODEL")) throw new Error("fixture model failure"); noCalls.push(input.sessionId); return { text: "Source summary" }; },
      async assess() { return { summary: "assessment", evidenceQuality: "high", freshness: "current" }; },
    };
    const tagCalls: string[] = [];
    const unapprovedTagging = {
      engine: { async decide(record: { id: string }) { tagCalls.push(record.id); throw new Error("must not call Jev when approval is false"); } },
      budget: { async gate() { return { ok: false, code: "unavailable", reason: "TypeSafe provider credential is not configured" }; } },

    };
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {}, () => fakeModel, undefined, undefined, undefined, unapprovedTagging as never);
    const failing = await store.captureSource({ commandId: "k5-failed-item", record: { kind: "source", scope: "research", provenance: { actor: "user", evidence: [] }, relations: [], content: { title: "Failure item", text: "FAIL_MODEL readable text", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z" } } });
    const succeeding = await store.captureSource({ commandId: "k5-good-item", record: { kind: "source", scope: "research", provenance: { actor: "user", evidence: [] }, relations: [], content: { title: "Good item", text: "Readable evidence that can be summarized.", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z" } } });
    const personalWithoutText = await store.captureSource({ commandId: "k5-personal-empty", record: { kind: "source", scope: "personal", provenance: { actor: "user", evidence: [] }, relations: [], content: { title: "Metadata only", captureDisposition: "metadata-only", capturedAt: "2026-01-01T00:00:00Z" } } });
    service.queueIntakeSummary(failing.record as never);
    service.queueIntakeSummary(succeeding.record as never);
    service.queueIntakeSummary(personalWithoutText.record as never);
    for (let attempt = 0; attempt < 1_000; attempt += 1) {
      const jobs = await service.invoke({ operation: "knowledge.curation.jobs", request: { limit: 64 } }) as { jobs: Array<{ operation: string; status: string }> };
      if (jobs.jobs.some(job => job.operation === "tags" && job.status === "failed") && jobs.jobs.filter(job => job.operation === "summary").every(job => job.status !== "running")) break;
      await new Promise(resolve => setTimeout(resolve, 5));
    }
    const result = await service.invoke({ operation: "knowledge.curation.jobs", request: { limit: 64 } }) as { jobs: Array<{ sourceId: string; operation: string; status: string; reason?: string }> };
    expect(result.jobs.find(job => job.operation === "summary" && job.sourceId === failing.record.id)?.status).toBe("failed");
    expect(result.jobs.find(job => job.operation === "summary" && job.sourceId === succeeding.record.id)?.status).toBe("done");
    expect(result.jobs.find(job => job.operation === "tags" && job.sourceId === succeeding.record.id)).toMatchObject({ status: "failed", reason: expect.stringContaining("Tagging skipped") });
    expect((await store.read(succeeding.record.id, undefined, false, true, true))?.content).toMatchObject({ summary: { text: "Source summary" } });
    expect((await store.read(succeeding.record.id, undefined, false, true, true))?.content.admission).toBeUndefined();
    expect((await store.read(failing.record.id, undefined, false, true, true))?.content.summary).toBeUndefined();
    expect((await store.read(failing.record.id, undefined, false, true, true))?.content.admission).toBeUndefined();
    expect(tagCalls).toEqual([]);
    expect(noCalls).toHaveLength(1);
    expect(result.jobs.some(job => job.sourceId === personalWithoutText.record.id)).toBe(false);
  });

  it("runs ten captures through observable summary then tagging without waiting for the models", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-k5-intake-e2e-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const initial = await store.config();
    await store.configure("k5-intake-enrichment-config", { ...initial, knowledgeModel: { model: "fixture/deepseek", maxInputChars: 48_000, maxOutputChars: 8_000 } });
    const configured = await store.config();
    await store.configureTags({ commandId: "k5-intake-vocabulary", expectedConfigRevision: configured.revision, edit: { kind: "add", tag: { id: "workflow", label: "Workflows", definition: "Reusable workflows.", category: "practice", decayClass: "stable", state: "active" } } });
    const sequence: string[] = [];
    const modelGate = deferred<void>();
    let summariesSettled = 0;
    const fakeModel: KnowledgeGenerationModel = {
      async reflect() { return "reflect"; }, async synthesize() { return "synthesis"; },
      async summarizeSource(input) { sequence.push(`summary:${input.sessionId}`); await modelGate.promise; summariesSettled += 1; return { text: `Summary of ${input.sessionId}` }; },
      async assess() { return { summary: "assessment", evidenceQuality: "high", freshness: "current" }; },
    };
    const tagging = {
      engine: { async decide(record: { id: string }, vocabulary: { revision: number }) { sequence.push(`tags:${record.id}`); return { tagIds: ["workflow"], model: "fixture/jev", vocabularyRevision: vocabulary.revision, inputsDigest: "a".repeat(64), estimatedCostCents: 0, callCount: 1 }; } },
      budget: { async gate() { return { ok: true }; } },

    };
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {}, () => fakeModel, undefined, undefined, undefined, tagging as never);
    let userLookup = false;
    const items = Array.from({ length: 10 }, (_, index) => ({ _id: index + 1, title: `Saved source ${index + 1}`, link: `https://example.test/item-${index + 1}`, created: "2026-09-28T00:00:00Z", collection: { $id: 111 } }));
    const assessment: SourceAssessmentModel = { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); await context?.onDispatch?.(); return { summary: "Jev admission assessment", evidenceQuality: "high", freshness: "current", model: "jev-1.13.0", recommendation: "retained", confidence: 0.95, profileVersion: "fixture-profile", rubricVersion: "fixture-rubric", usage: { inputTokens: 100, outputTokens: 3, estimatedCostCents: 0.00042, pricing: "fixture" } }; } };
    const owner = new ConnectionOwner(root);
    const credentials = new InMemoryConnectorCredentialStore(new Map([["connector:raindrop:fixture", "local-token"]]));
    const jevBudget = new KnowledgeTaggingBudget(store, () => true);
    const extension = new KnowledgeConnectorExtension(store, {
      credentials,
      jevBudget,
      resolveHost: async () => ["93.184.216.34"],
      sourceFetch: async url => new Response(`Readable evidence for ${url}. `.repeat(12), { headers: { "content-type": "text/plain" } }),
      http: async url => {
        if (url.endsWith("/user")) { userLookup = true; return response({ user: { _id: 42 } }); }
        if (url.includes("/raindrops/111")) return response({ items });
        throw new Error(`Unexpected fake provider endpoint ${url}`);
      },
      assessment,
      queueSummary: source => service.queueIntakeSummary(source),
      sleep: async () => {}, now: () => "2026-09-29T00:00:00.000Z",
    });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("connector-config"), connector: "raindrop", enabled: true, accountId: "42", scope: "111", credentialRef: "connector:raindrop:fixture" } });
    const intake = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("run"), sourceCollection: "111", dryRun: false, limit: 10, pilot: { id: "fixture-pilot", maxItems: 10, budgetCents: 10 } } }) as { captured: number; retained: number; outcomes: Array<{ sourceId?: string; itemId: string }> };
    expect(userLookup).toBe(true);
    expect(intake).toMatchObject({ captured: 10, retained: 10 }, JSON.stringify(intake));
    for (let attempt = 0; attempt < 2_000; attempt += 1) { if (sequence.filter(value => value.startsWith("summary:")).length === 10) break; await new Promise(resolve => setTimeout(resolve, 5)); }
    expect(sequence.filter(value => value.startsWith("summary:"))).toHaveLength(10);
    expect(summariesSettled).toBe(0, "Intake must return without waiting for model latency");
    modelGate.resolve();
    for (let attempt = 0; attempt < 2_000; attempt += 1) {
      const jobs = await service.invoke({ operation: "knowledge.curation.jobs", request: { limit: 64 } }) as { jobs: Array<{ operation: string; status: string }> };
      const summaries = jobs.jobs.filter(job => job.operation === "summary");
      const tags = jobs.jobs.filter(job => job.operation === "tags");
      if (summaries.length === 10 && tags.length === 10 && [...summaries, ...tags].every(job => job.status !== "running")) break;
      await new Promise(resolve => setTimeout(resolve, 5));
    }
    const finalJobs = await service.invoke({ operation: "knowledge.curation.jobs", request: { limit: 64 } }) as { jobs: Array<{ sourceId: string; operation: string; status: string; code?: string; reason?: string }> };
    expect(finalJobs.jobs.filter(job => job.operation === "summary" && job.status === "done")).toHaveLength(10);
    expect(finalJobs.jobs.filter(job => job.operation === "tags" && job.status === "done")).toHaveLength(10);
    const providerCallsBeforeReplay = sequence.length;
    const replay = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("replay"), sourceCollection: "111", dryRun: false, limit: 10, pilot: { id: "fixture-pilot", maxItems: 10, budgetCents: 10 } } }) as { captured: number };
    expect(replay.captured).toBe(0);
    await new Promise(resolve => setTimeout(resolve, 30));
    expect(sequence).toHaveLength(providerCallsBeforeReplay);
    for (const outcome of intake.outcomes) {
      const summaryAt = sequence.indexOf(`summary:${outcome.sourceId}`);
      const tagsAt = sequence.indexOf(`tags:${outcome.sourceId}`);
      expect(summaryAt).toBeGreaterThanOrEqual(0);
      expect(tagsAt).toBeGreaterThan(summaryAt);
    }
    const latestSources = await Promise.all(intake.outcomes.map(item => store.read(item.sourceId!)));
    const report = {
      commandId: command("run"), items: latestSources.map((record, index) => ({ itemId: intake.outcomes[index]!.itemId, sourceId: record?.id, revisionId: record?.revisionId, summary: record?.content.summary?.text, tagIds: record?.content.tags?.tagIds, jobs: finalJobs.jobs.filter(job => job.sourceId === record?.id).map(({ operation, status }) => ({ operation, status })) })),
      sequence,
    };
    const artifact = join(process.cwd(), "test-results", "knowledge-intake-outcome.json");
    await mkdir(dirname(artifact), { recursive: true });
    await writeFile(artifact, `${JSON.stringify(report, null, 2)}\n`);
    console.info(`K5 intake outcome artifact: ${artifact}`);
    const persisted = JSON.parse(await readFile(artifact, "utf8")) as typeof report;
    expect(persisted.items).toHaveLength(10);
    expect(persisted.items.every(item => item.summary && item.tagIds?.includes("workflow"))).toBe(true);
  });

  it("summarizes a partial research capture once its intake settles", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-k5-partial-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const initial = await store.config();
    await store.configure("k5-partial-config", { ...initial, knowledgeModel: { model: "fixture/deepseek", maxInputChars: 48_000, maxOutputChars: 8_000 } });
    const summarized: string[] = [];
    const fakeModel: KnowledgeGenerationModel = {
      async reflect() { return "reflect"; }, async synthesize() { return "synthesis"; },
      async summarizeSource(input) { summarized.push(input.sessionId); return { text: "Partial summary" }; },
      async assess() { return { summary: "assessment", evidenceQuality: "high", freshness: "current" }; },
    };
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {}, () => fakeModel);
    const items = [{ _id: 7, title: "A repository", link: "https://github.com/example/repository", created: "2026-09-28T00:00:00Z", collection: { $id: 111 } }];
    const extension = new KnowledgeConnectorExtension(store, {
      credentials: new InMemoryConnectorCredentialStore(new Map([["connector:raindrop:fixture", "local-token"]])),
      resolveHost: async () => ["93.184.216.34"],
      // GitHub UI captures are always partial, like every X post: readable
      // text survives, but repository completeness is not certified.
      sourceFetch: async () => new Response("A repository README describing how the project works. ".repeat(8), { headers: { "content-type": "text/plain" } }),
      http: async url => {
        if (url.endsWith("/user")) return response({ user: { _id: 42 } });
        if (url.includes("/raindrops/111")) return response({ items });
        throw new Error(`Unexpected fake provider endpoint ${url}`);
      },
      queueSummary: source => service.queueIntakeSummary(source),
      sleep: async () => {}, now: () => "2026-09-29T00:00:00.000Z",
    });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("partial-config"), connector: "raindrop", enabled: true, accountId: "42", scope: "111", credentialRef: "connector:raindrop:fixture" } });
    const intake = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("partial-run"), sourceCollection: "111", dryRun: false, limit: 1, pilot: { id: "partial-pilot", maxItems: 1, budgetCents: 10 } } }) as { outcomes: Array<{ sourceId?: string }> };
    const sourceId = intake.outcomes[0]?.sourceId;
    const captured = await store.read(sourceId!, undefined, false, true, true);
    expect(captured?.kind === "source" && captured.content.captureDisposition).not.toBe("complete");
    expect(captured?.kind === "source" && captured.content.text).toBeTruthy();
    for (let attempt = 0; attempt < 400 && summarized.length === 0; attempt += 1) await new Promise(resolve => setTimeout(resolve, 5));
    expect(summarized).toEqual([sourceId]);
  });
});

