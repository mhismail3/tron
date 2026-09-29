import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeObservationService } from "./knowledge-observation.js";
import { KnowledgeService, type KnowledgeGenerationModel } from "./knowledge-service.js";
import { KnowledgeStore } from "./knowledge-store.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(r => { resolve = r; }); return { promise, resolve }; }
async function until(condition: () => boolean) {
  for (let attempt = 0; attempt < 200; attempt += 1) { if (condition()) return; await new Promise(resolve => setTimeout(resolve, 5)); }
  throw new Error("Condition was not reached");
}

/** Failure modes under test: a long model call holds the store lock so every
 * read waits for it, and one command charges the configured model more than
 * once (replay or a duplicate concurrent call). */
describe("Knowledge source summary scheduling", () => {
  async function fixture(gate: Promise<void>, counter: { generations: number }) {
    const root = await mkdtemp(join(tmpdir(), "tron-summary-scheduling-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const source = await store.captureSource({ commandId: "summary-scheduling-capture", record: { kind: "source", scope: "research",
      provenance: { actor: "user", evidence: [] }, relations: [],
      content: { title: "Thread", text: "A post and its saved replies", captureDisposition: "partial", capturedAt: "2026-01-01T00:00:00Z" } } });
    const model: KnowledgeGenerationModel = {
      async reflect() { return "handoff"; }, async synthesize() { return "synthesis"; },
      async assess() { return { summary: "Useful", evidenceQuality: "high", freshness: "current" }; },
      async summarizeSource() { counter.generations += 1; await gate; return { text: "A post with saved replies.", tags: [] }; },
    };
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {}, () => model);
    const action = { operation: "knowledge.source.summarize" as const, request: { commandId: "summary-scheduling-command", sourceId: source.record.id, expectedRevision: source.record.revisionId } };
    return { store, service, action, source };
  }

  it("completes reads while a summary generation is still pending", async () => {
    const gate = deferred<void>(); const counter = { generations: 0 };
    const { store, service, action, source } = await fixture(gate.promise, counter);
    const pending = service.invoke(action);
    await until(() => counter.generations === 1);
    // The generation is in flight: every read must still answer.
    expect((await store.status()).available).toBe(true);
    expect((await store.list({ kind: "source" })).records.map(record => record.id)).toEqual([source.record.id]);
    expect((await store.read(source.record.id))?.revisionId).toBe(source.record.revisionId);
    expect((await store.listSourceRows({ kind: "source", projection: "sourceRow" })).rows).toHaveLength(1);
    expect((await store.search({ query: "saved replies" })).hits).toHaveLength(1);
    gate.resolve();
    await expect(pending).resolves.toMatchObject({ record: { content: { summary: { text: "A post with saved replies." } } } });
    expect(counter.generations).toBe(1);
  });

  it("charges the model once for a replayed command and once for concurrent duplicates", async () => {
    const immediate = Promise.resolve(); const counter = { generations: 0 };
    const { service, action } = await fixture(immediate, counter);
    const first = await service.invoke(action);
    const replay = await service.invoke(action);
    expect(counter.generations).toBe(1);
    expect(replay).toEqual(first);

    const gate = deferred<void>(); const concurrent = { generations: 0 };
    const second = await fixture(gate.promise, concurrent);
    const shared = { ...second.action, request: { ...second.action.request, commandId: "summary-scheduling-duplicate" } };
    const left = second.service.invoke(shared);
    const right = second.service.invoke(shared);
    await until(() => concurrent.generations === 1);
    gate.resolve();
    expect(await left).toEqual(await right);
    expect(concurrent.generations).toBe(1);
  });

  it("refuses a different request that reuses a command ID", async () => {
    const counter = { generations: 0 };
    const { service, action } = await fixture(Promise.resolve(), counter);
    await service.invoke(action);
    await expect(service.invoke({ ...action, request: { ...action.request, expectedRevision: "00000000-0000-4000-8000-000000000000" } })).rejects.toThrow(/already used/);
    expect(counter.generations).toBe(1);
  });
});
