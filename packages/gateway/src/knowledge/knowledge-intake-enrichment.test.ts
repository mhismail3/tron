import { mkdir, mkdtemp, open, readFile, realpath, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeConnectorExtension, type ConnectorHTTPResponse } from "./connectors.js";
import { KnowledgeObservationService } from "./knowledge-observation.js";
import { KnowledgeCurationJobs } from "./knowledge-curation.js";
import { KnowledgeService, type KnowledgeGenerationModel } from "./knowledge-service.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { InMemoryConnectorCredentialStore } from "../../test-support/connector-credentials.js";
import type { SourceAssessmentModel } from "./source-capture.js";
import { KnowledgeTaggingBudget } from "./knowledge-tagger.js";
import * as durableJson from "../util/durable-json.js";

interface IntakeFixture { root: string; cleanup?: () => Promise<void>; retire?: () => void; retained?: boolean }
const fixtures: IntakeFixture[] = [];
const command = (value: string) => `k5-intake-${value}`;
const headers = () => new Headers();
function response(value: unknown): ConnectorHTTPResponse { return { status: 200, headers: headers(), body: JSON.stringify(value) }; }
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(done => { resolve = done; }); return { promise, resolve }; }
function registerFixture(root: string, cleanup?: () => Promise<void>, retire?: () => void): IntakeFixture {
  const fixture = { root, cleanup, retire };
  fixtures.push(fixture);
  return fixture;
}
function retireFixture(fixture: IntakeFixture): void {
  const retire = fixture.retire;
  fixture.retire = undefined;
  retire?.();
}
async function joinFixture(fixture: IntakeFixture): Promise<void> {
  // Global interception retires synchronously; already-dispatched writes keep
  // their own closure. Instance admission tracking lives until the body drains.
  retireFixture(fixture);
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([fixture.cleanup?.(), new Promise<never>((_, reject) => {
      // One budget for the entire cleanup/report, below Vitest's 10s hook.
      timer = setTimeout(() => reject(new Error(`Fixture join deadline; retained ${fixture.root}`)), 5_000);
    })]);
  } catch (error) {
    fixture.retained = true;
    throw error;
  } finally { clearTimeout(timer); }
}
async function cleanupFixtures(): Promise<void> {
  // A framework timeout does not cancel this hook. Detach every owned resource
  // before yielding; a late continuation must never consume the next fixture.
  const owned = fixtures.splice(0);
  for (const fixture of owned) retireFixture(fixture);
  await Promise.all(owned.map(async fixture => {
    await joinFixture(fixture);
    if (!fixture.retained) await rm(fixture.root, { recursive: true, force: true });
  }));
}
afterEach(cleanupFixtures);

/** Failure modes: a model or tagging failure blocks other items; unapproved
 * tagging drops the summary; intake waits on model latency; a rerun re-charges;
 * summary and tagging race admission; partial captures (every X post) never
 * get a summary; assertion/timeout teardown removes files while intake or
 * enrichment still owns writes. This drives the actual connector and KnowledgeService owners
 * with local model/Jev fakes, never live credentials or paid providers. Its
 * outcome JSON is kept at packages/gateway/test-results/knowledge-intake-outcome.json
 * inside the worktree that ran it, so concurrent runs in two worktrees keep two
 * artifacts instead of overwriting one shared temp file. */
describe("K5 Raindrop intake enrichment", () => {
  it("keeps a summary when Jev is unapproved, reports the skip, and lets another item survive model failure", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-k5-failure-e2e-")); registerFixture(root);
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

  // Failure modes missed by the successful intake oracle: a rejected join
  // leaks the publication spy into the next fixture; a late hook consumes the
  // next fixture's root or restores its active publication interception.
  it("isolates a failed join from the subsequent durable-write fixture", async () => {
    const oldRoot = await mkdtemp(join(tmpdir(), "tron-k5-failed-join-"));
    const nextRoot = await mkdtemp(join(tmpdir(), "tron-k5-next-"));
    const originalWrite = durableJson.durableAtomicWriteJson;
    const oldSpy = vi.spyOn(durableJson, "durableAtomicWriteJson").mockImplementation(originalWrite);
    const joinFailed = deferred<void>();
    registerFixture(oldRoot, async () => { await joinFailed.promise; throw new Error("fixture join failed"); }, () => oldSpy.mockRestore());
    let nextSpy: ReturnType<typeof vi.spyOn> | undefined;
    try {
      const finishing = cleanupFixtures();
      joinFailed.resolve();
      await expect(finishing).rejects.toThrow("fixture join failed");
      // This is the next real fixture's forwarding pattern. A leaked Vitest
      // spy becomes its own implementation and recurses rather than writing.
      const nextWrite = durableJson.durableAtomicWriteJson;
      nextSpy = vi.spyOn(durableJson, "durableAtomicWriteJson").mockImplementation(nextWrite);
      await durableJson.durableAtomicWriteJson(join(nextRoot, "proof.json"), { next: true });
      expect(JSON.parse(await readFile(join(nextRoot, "proof.json"), "utf8"))).toEqual({ next: true });
      await writeFile(join(oldRoot, "retained.txt"), "retained after failed join");
      const artifact = join(process.cwd(), "test-results", "knowledge-intake-failed-join.json");
      await mkdir(dirname(artifact), { recursive: true });
      await writeFile(artifact, JSON.stringify({ failedJoin: "retained", subsequentDurableWrite: "read back" }));
    } finally {
      nextSpy?.mockRestore(); oldSpy.mockRestore();
      await rm(oldRoot, { recursive: true, force: true });
      await rm(nextRoot, { recursive: true, force: true });
    }
  });

  it("isolates delayed old cleanup from the next fixture's root and publication spy", async () => {
    const oldRoot = await mkdtemp(join(tmpdir(), "tron-k5-old-cleanup-"));
    const nextRoot = await mkdtemp(join(tmpdir(), "tron-k5-live-next-"));
    const release = deferred<void>();
    registerFixture(oldRoot, () => release.promise);
    const finishing = cleanupFixtures();
    const originalWrite = durableJson.durableAtomicWriteJson;
    const nextSpy = vi.spyOn(durableJson, "durableAtomicWriteJson").mockImplementation(originalWrite);
    registerFixture(nextRoot, undefined, () => nextSpy.mockRestore());
    try {
      await writeFile(join(nextRoot, "live.txt"), "next fixture still owns this");
      release.resolve();
      await finishing;
      expect(await readFile(join(nextRoot, "live.txt"), "utf8")).toBe("next fixture still owns this");
      // The later fixture must still control its own publication boundary.
      nextSpy.mockImplementation(async () => { throw new Error("next publication gate"); });
      await expect(durableJson.durableAtomicWriteJson(join(nextRoot, "proof.json"), {})).rejects.toThrow("next publication gate");
      const artifact = join(process.cwd(), "test-results", "knowledge-intake-delayed-cleanup.json");
      await mkdir(dirname(artifact), { recursive: true });
      await writeFile(artifact, JSON.stringify({ oldCleanup: "joined", nextRoot: "preserved", nextPublicationGate: "active" }));
    } finally {
      release.resolve(); await finishing.catch(() => {});
      nextSpy.mockRestore();
      await rm(oldRoot, { recursive: true, force: true });
      await rm(nextRoot, { recursive: true, force: true });
    }
  });

  async function tenCaptures(failAt?: "model" | "publication") {
    const root = await realpath(await mkdtemp(join(tmpdir(), "tron-k5-intake-e2e-"))); const fixture = registerFixture(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const sequence: string[] = [];
    const phases: Array<{ phase: string; ms: number }> = [];
    const started = performance.now();
    const phase = (name: string) => phases.push({ phase: name, ms: Math.round(performance.now() - started) });
    const dispatched = deferred<void>();
    const publicationStarted = deferred<void>();
    const teardownStarted = deferred<void>();
    const releasePublication = deferred<void>();
    const terminal = new Map<string, ReturnType<typeof deferred<void>>>();
    const jobs = new KnowledgeCurationJobs(64, 120_000, job => {
      phase(`${job.operation}:${job.status}`);
      terminal.get(job.commandId)?.resolve();
    });
    const waitForTerminal = async () => {
      await Promise.all(jobs.observe({ limit: 64 }).jobs.map(job => {
        if (job.status !== "running") return;
        let done = terminal.get(job.commandId);
        if (!done) { done = deferred<void>(); terminal.set(job.commandId, done); }
        return done.promise;
      }));
    };
    const bounded = async <T,>(name: string, promise: Promise<T>): Promise<T> => {
      let timer: ReturnType<typeof setTimeout> | undefined;
      try {
        return await Promise.race([promise, new Promise<never>((_, reject) => {
          timer = setTimeout(() => reject(new Error(`${name}: ${JSON.stringify({ sequence, jobs: jobs.observe({ limit: 64 }), phases })}`)), 10_000);
        })]);
      } finally { clearTimeout(timer); }
    };
    const modelGate = deferred<void>();
    let summariesSettled = 0;
    const fakeModel: KnowledgeGenerationModel = {
      async reflect() { return "reflect"; }, async synthesize() { return "synthesis"; },
      async summarizeSource(input) { sequence.push(`summary:${input.sessionId}`); phase("summary dispatch"); if (sequence.length === 10) dispatched.resolve(); await modelGate.promise; summariesSettled += 1; return { text: `Summary of ${input.sessionId}` }; },
      async assess() { return { summary: "assessment", evidenceQuality: "high", freshness: "current" }; },
    };
    const tagging = {
      engine: { async decide(record: { id: string }, vocabulary: { revision: number }) { sequence.push(`tags:${record.id}`); return { tagIds: ["workflow"], model: "fixture/jev", vocabularyRevision: vocabulary.revision, inputsDigest: "a".repeat(64), estimatedCostCents: 0, callCount: 1 }; } },
      budget: { async gate() { return { ok: true }; } },

    };
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {}, () => fakeModel, undefined, undefined, jobs, tagging as never);
    // Admission is async before jobs.start; a snapshot of running jobs alone
    // can miss both the last summary and the summary-to-tag handoff.
    const admissions: Promise<unknown>[] = [];
    const summarize = service.summarize.bind(service);
    const summarizeSpy = vi.spyOn(service, "summarize").mockImplementation(request => {
      const admitted = summarize(request); admissions.push(admitted.catch(() => {})); return admitted;
    });
    const autoRetag = service.autoRetag.bind(service);
    const autoRetagSpy = vi.spyOn(service, "autoRetag").mockImplementation((...args) => {
      const admitted = autoRetag(...args); admissions.push(admitted.catch(() => {})); return admitted;
    });
    const drain = async () => {
      modelGate.resolve(); releasePublication.resolve();
      // Summary settlement can enqueue tags. Join admissions and terminals to
      // a fixed point, not an empty running snapshot between those two owners.
      let joined = 0;
      do {
        joined = admissions.length;
        await Promise.all(admissions);
        await waitForTerminal();
      } while (joined !== admissions.length);
    };
    let publicationBlocked = false;
    const originalWrite = durableJson.durableAtomicWriteJson;
    const writeSpy = vi.spyOn(durableJson, "durableAtomicWriteJson").mockImplementation((path, value, mode) => originalWrite(path, value, mode, {
      mkdir, open, rm,
      rename: async (from, to) => {
        if (!publicationBlocked && to.startsWith(`${root}/`) && to.includes("/records/") && (value as { content?: { summary?: unknown } }).content?.summary) {
          publicationBlocked = true; phase("publication blocked"); publicationStarted.resolve();
          await releasePublication.promise;
        }
        await rename(from, to);
      },
    }));
    fixture.retire = () => writeSpy.mockRestore();
    let userLookup = false;
    let assessmentCalls = 0;
    let failure: string | undefined;
    const items = Array.from({ length: 10 }, (_, index) => ({ _id: index + 1, title: `Saved source ${index + 1}`, link: `https://example.test/item-${index + 1}`, created: "2026-09-28T00:00:00Z", collection: { $id: 111 } }));
    const assessment: SourceAssessmentModel = { async assess(_input, _signal, context) { assessmentCalls += 1; await context?.beforeDispatch?.(); await context?.onDispatch?.(); return { summary: "Jev admission assessment", evidenceQuality: "high", freshness: "current", model: "jev-1.13.0", recommendation: "retained", confidence: 0.95, profileVersion: "fixture-profile", rubricVersion: "fixture-rubric", usage: { inputTokens: 100, outputTokens: 3, estimatedCostCents: 0.00042, pricing: "fixture" } }; } };
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
    const run = (async () => {
      try {
        phase("configuration");
        const initial = await store.config();
        await store.configure("k5-intake-enrichment-config", { ...initial, knowledgeModel: { model: "fixture/deepseek", maxInputChars: 48_000, maxOutputChars: 8_000 } });
        const configured = await store.config();
        await store.configureTags({ commandId: "k5-intake-vocabulary", expectedConfigRevision: configured.revision, edit: { kind: "add", tag: { id: "workflow", label: "Workflows", definition: "Reusable workflows.", category: "practice", decayClass: "stable", state: "active" } } });
        phase("intake start");
        await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("connector-config"), connector: "raindrop", enabled: true, accountId: "42", scope: "111", credentialRef: "connector:raindrop:fixture" } });
        const intake = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("run"), sourceCollection: "111", dryRun: false, limit: 10, pilot: { id: "fixture-pilot", maxItems: 10, budgetCents: 10 } } }) as { captured: number; retained: number; outcomes: Array<{ sourceId?: string; itemId: string }> };
        phase("intake returned");
        expect(userLookup).toBe(true);
        expect(intake).toMatchObject({ captured: 10, retained: 10 }, JSON.stringify(intake));
        await bounded("ten summary dispatches", dispatched.promise);
        expect(sequence.filter(value => value.startsWith("summary:"))).toHaveLength(10);
        expect(summariesSettled).toBe(0, "Intake must return without waiting for model latency");
        expect(failAt, "fixture failure at model").not.toBe("model");
        modelGate.resolve();
        await bounded("summary publication", publicationStarted.promise);
        expect(jobs.running).toBeGreaterThan(0);
        if (failAt === "publication") {
          await teardownStarted.promise;
          expect(failAt, "fixture failure at publication").not.toBe("publication");
        }
        releasePublication.resolve();
        await bounded("summary and tagging terminal", drain());
        const finalJobs = await service.invoke({ operation: "knowledge.curation.jobs", request: { limit: 64 } }) as { jobs: Array<{ sourceId: string; operation: string; status: string; code?: string; reason?: string }> };
        expect(finalJobs.jobs.filter(job => job.operation === "summary" && job.status === "done")).toHaveLength(10);
        expect(finalJobs.jobs.filter(job => job.operation === "tags" && job.status === "done")).toHaveLength(10);
        const providerCallsBeforeReplay = sequence.length;
        expect(assessmentCalls).toBe(10);
        const replay = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("replay"), sourceCollection: "111", dryRun: false, limit: 10, pilot: { id: "fixture-pilot", maxItems: 10, budgetCents: 10 } } }) as { captured: number };
        expect(replay.captured).toBe(0);
        await bounded("replay admission and terminal", drain());
        expect(sequence).toHaveLength(providerCallsBeforeReplay);
        expect(assessmentCalls).toBe(10);
        for (const outcome of intake.outcomes) {
          const summaryAt = sequence.indexOf(`summary:${outcome.sourceId}`);
          const tagsAt = sequence.indexOf(`tags:${outcome.sourceId}`);
          expect(summaryAt).toBeGreaterThanOrEqual(0);
          expect(tagsAt).toBeGreaterThan(summaryAt);
        }
        const latestSources = await Promise.all(intake.outcomes.map(item => store.read(item.sourceId!)));
        const report = {
          commandId: command("run"), items: latestSources.map((record, index) => ({ itemId: intake.outcomes[index]!.itemId, sourceId: record?.id, revisionId: record?.revisionId, summary: record?.content.summary?.text, tagIds: record?.content.tags?.tagIds, jobs: finalJobs.jobs.filter(job => job.sourceId === record?.id).map(({ operation, status }) => ({ operation, status })) })),
          sequence, phases,
        };
        const artifact = join(process.cwd(), "test-results", "knowledge-intake-outcome.json");
        await mkdir(dirname(artifact), { recursive: true });
        await writeFile(artifact, `${JSON.stringify(report, null, 2)}\n`);
        console.info(`K5 intake outcome artifact: ${artifact}`);
        const persisted = JSON.parse(await readFile(artifact, "utf8")) as typeof report;
        expect(persisted.items).toHaveLength(10);
        expect(persisted.items.every(item => item.summary && item.tagIds?.includes("workflow"))).toBe(true);
      } catch (error) {
        failure = error instanceof Error ? error.message : String(error);
        throw error;
      } finally {
        await bounded("fixture owner drain", drain());
        service.dispose();
        summarizeSpy.mockRestore(); autoRetagSpy.mockRestore();
      }
    })();
    fixture.cleanup = async () => {
      // Vitest timeout does not cancel run. Release its gates and join the
      // whole body before afterEach can remove its filesystem or restore spies.
      modelGate.resolve(); releasePublication.resolve(); teardownStarted.resolve();
      let joined = false;
      try {
        await run.catch(() => {});
        await drain();
        expect(jobs.running).toBe(0);
        joined = true;
      } finally {
        const artifact = join(process.cwd(), "test-results", `knowledge-intake-lifecycle${failAt ? `-${failAt}` : ""}.json`);
        await mkdir(dirname(artifact), { recursive: true });
        await writeFile(artifact, `${JSON.stringify({ failAt, failure, phases, sequence, assessmentCalls, jobs: jobs.observe({ limit: 64 }), cleanup: joined && !fixture.retained ? "joined" : "retained", ...(!joined || fixture.retained ? { root } : {}) }, null, 2)}\n`);
      }
    };
    const cleanup = () => joinFixture(fixture);
    if (failAt) {
      const rejected = expect(run).rejects.toThrow(`fixture failure at ${failAt}`);
      try {
        if (failAt === "publication") {
          await bounded("publication before framework teardown", publicationStarted.promise);
          // Framework teardown may run without unwinding the timed-out body.
          await cleanup();
        }
      } finally { await rejected; }
      await cleanup();
      expect(jobs.running).toBe(0);
      // Exercise the real removal, not only the bookkeeping assertion.
      await rm(root, { recursive: true, force: true });
    } else await run;
  }

  it("runs ten captures through observable summary then tagging without waiting for the models", () => tenCaptures());
  it.each(["model", "publication"] as const)("joins ten-capture writes after failure at %s", failAt => tenCaptures(failAt));

  it("summarizes a partial research capture once its intake settles", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-k5-partial-")); const fixture = registerFixture(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const initial = await store.config();
    await store.configure("k5-partial-config", { ...initial, knowledgeModel: { model: "fixture/deepseek", maxInputChars: 48_000, maxOutputChars: 8_000 } });
    const modelStarted = deferred<void>();
    const fakeModel: KnowledgeGenerationModel = {
      async reflect() { return "reflect"; }, async synthesize() { return "synthesis"; },
      async summarizeSource() { modelStarted.resolve(); return { text: "Partial summary" }; },
      async assess() { return { summary: "assessment", evidenceQuality: "high", freshness: "current" }; },
    };
    const items = [{ _id: 7, title: "A repository", link: "https://github.com/example/repository", created: "2026-09-28T00:00:00Z", collection: { $id: 111 } }];
    const writeStarted = deferred<void>();
    const releaseWrite = deferred<void>();
    let summaryRecordId: string | undefined;
    const terminalSummary = deferred<{ operation: string; status: string; sourceId: string }>();
    const jobs = new KnowledgeCurationJobs(64, 120_000, job => {
      if (job.operation === "summary" && job.sourceId === summaryRecordId) terminalSummary.resolve(job);
    });
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {}, () => fakeModel, undefined, undefined, jobs);
    let blocked = false;
    const originalWrite = durableJson.durableAtomicWriteJson;
    const writeSpy = vi.spyOn(durableJson, "durableAtomicWriteJson").mockImplementation((path, value, mode) => originalWrite(path, value, mode, {
      mkdir, open, rm,
      rename: async (from, to) => {
        if (!blocked && summaryRecordId && to.includes(`/records/${summaryRecordId}/`)) {
          blocked = true;
          writeStarted.resolve();
          await releaseWrite.promise;
        }
        await rename(from, to);
      },
    }));
    fixture.retire = () => writeSpy.mockRestore();
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
      queueSummary: source => { summaryRecordId = source.id; service.queueIntakeSummary(source); },
      sleep: async () => {}, now: () => "2026-09-29T00:00:00.000Z",
    });
    try {
      await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("partial-config"), connector: "raindrop", enabled: true, accountId: "42", scope: "111", credentialRef: "connector:raindrop:fixture" } });
      const intake = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("partial-run"), sourceCollection: "111", dryRun: false, limit: 1, pilot: { id: "partial-pilot", maxItems: 1, budgetCents: 10 } } }) as { outcomes: Array<{ sourceId?: string }> };
      const sourceId = intake.outcomes[0]?.sourceId;
      const captured = await store.read(sourceId!, undefined, false, true, true);
      expect(captured?.kind === "source" && captured.content.captureDisposition).not.toBe("complete");
      expect(captured?.kind === "source" && captured.content.text).toBeTruthy();
      expect(summaryRecordId).toBe(sourceId);
      await modelStarted.promise;
      await writeStarted.promise;
      // This is where the old test returned after observing model dispatch:
      // the summary job is still running and its temp file is in the fixture.
      const inFlight = await service.invoke({ operation: "knowledge.curation.jobs", request: { sourceId } }) as { jobs: Array<{ operation: string; status: string; sourceId: string }> };
      expect(inFlight.jobs).toContainEqual(expect.objectContaining({ operation: "summary", sourceId, status: "running" }));
      releaseWrite.resolve();
      const summaryJob = await terminalSummary.promise;
      expect(summaryJob).toMatchObject({ sourceId, status: "done" });
      expect((await store.read(sourceId!, undefined, false, true, true))?.content.summary?.text).toBe("Partial summary");
    } finally {
      releaseWrite.resolve();
      retireFixture(fixture);
    }
  });
});

