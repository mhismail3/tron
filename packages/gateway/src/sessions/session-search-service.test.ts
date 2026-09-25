import { mkdtemp, rm } from "node:fs/promises";
import { DatabaseSync } from "node:sqlite";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { GatewayError } from "../errors.js";
import { InMemoryConnectorCredentialStore } from "../../test-support/connector-credentials.js";
import { JevDecisionClient, JevEvaluationError } from "../knowledge/jev-client.js";
import { SessionSearchService, type SessionSearchEmbeddingClient } from "./session-search-service.js";
import { SessionSearchIndex } from "./session-search-index.js";
import { SessionSearchAllowanceLedger } from "./session-search-allowance.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

const entries = [
  { type: "session", id: "s", cwd: "/tmp", timestamp: "2026-01-01T00:00:00Z" },
  { type: "message", id: "lexical", parentId: null, timestamp: "2026-01-01T00:00:01Z", message: { role: "user", content: "needle lexical passage" } },
  { type: "message", id: "semantic", parentId: "lexical", timestamp: "2026-01-01T00:00:02Z", message: { role: "user", content: "paraphrased target passage" } },
] as any[];

function sessionsFor(entriesValue = entries, forkBoundary?: { kind: "sessionFork"; inheritedEntryId: string; gapOrdinal: number }): any {
  return {
    setSearchInvalidator: () => {},
    catalog: async () => ({ sessions: [{ id: "s" }] }),
    readSearchCut: async () => ({ summary: { id: "s", name: "Fixture", firstMessage: "Fixture", cwd: "/tmp", modified: new Date("2026-01-01T00:00:00Z") }, entries: entriesValue, fileIdentity: "file-1", ...(forkBoundary ? { forkBoundary } : {}), leafEntryId: "semantic" }),
  };
}

class FixtureEmbedding implements SessionSearchEmbeddingClient {
  calls = 0;
  async qualify(): Promise<{ dimension: number; language: string; modelRevision: string }> { return { dimension: 512, language: "en", modelRevision: "fixture-v1" }; }
  async embed(text: string): Promise<{ vector: number[]; dimension: number; language: string; modelRevision: string }> {
    this.calls += 1;
    const vector = Array.from({ length: 512 }, () => 0);
    vector[text.includes("lexical") ? 1 : 0] = 1;
    return { vector, dimension: 512, language: "en", modelRevision: "fixture-v1" };
  }
}

async function realService(embedding?: SessionSearchEmbeddingClient, sessions = sessionsFor()) {
  const root = await mkdtemp(join(tmpdir(), "tron-search-service-")); roots.push(root);
  const index = await SessionSearchIndex.open(join(root, "index.sqlite"));
  return { index, service: new SessionSearchService(sessions, index, undefined, undefined, embedding) };
}

describe("SessionSearchService backend seams", () => {
  it("stops a rebuilding warm-up after the in-flight session when closed", async () => {
    let readCount = 0;
    let firstReadStarted!: () => void;
    let releaseFirstRead!: () => void;
    const started = new Promise<void>(resolve => { firstReadStarted = resolve; });
    const blocked = new Promise<void>(resolve => { releaseFirstRead = resolve; });
    const sessions = {
      setSearchInvalidator: () => {},
      catalog: async () => ({ sessions: [{ id: "one" }, { id: "two" }, { id: "three" }] }),
      readSearchCut: async () => {
        readCount += 1;
        if (readCount === 1) { firstReadStarted(); await blocked; }
        return { summary: { id: "one", name: "Fixture", firstMessage: "Fixture", cwd: "/tmp", modified: new Date("2026-01-01T00:00:00Z") }, entries, fileIdentity: "file-1", leafEntryId: "semantic" };
      },
    } as any;
    const root = await mkdtemp(join(tmpdir(), "tron-search-close-warmup-")); roots.push(root);
    const index = await SessionSearchIndex.open(join(root, "index.sqlite"));
    const service = new SessionSearchService(sessions, index);
    const warming = service.warm().catch(() => {});
    await started;
    const closing = service.close();
    releaseFirstRead();
    await Promise.all([warming, closing]);
    expect(readCount).toBe(1);

    // Negative control: without cancellation, the same catalog requires all reads.
    let controlReads = 0;
    const controlSessions = {
      setSearchInvalidator: () => {},
      catalog: async () => ({ sessions: [{ id: "one" }, { id: "two" }, { id: "three" }] }),
      readSearchCut: async () => {
        controlReads += 1;
        return { summary: { id: "one", name: "Fixture", firstMessage: "Fixture", cwd: "/tmp", modified: new Date("2026-01-01T00:00:00Z") }, entries, fileIdentity: `file-${controlReads}`, leafEntryId: "semantic" };
      },
    } as any;
    const controlIndex = await SessionSearchIndex.open(join(root, "control.sqlite"));
    const control = new SessionSearchService(controlSessions, controlIndex);
    await control.warm();
    expect(controlReads).toBe(3);
    await control.close();
  });

  it("fuses semantic candidates before the final result cap", async () => {
    const embedding = new FixtureEmbedding();
    const { index, service } = await realService(embedding);
    await service.warm();
    for (let attempt = 0; attempt < 100 && embedding.calls < 3; attempt += 1) await new Promise(resolve => setTimeout(resolve, 2));
    const response = await service.search({ query: "needle", maxResults: 1 });
    expect(response.results).toHaveLength(1);
    expect(response.results[0]?.entryId).toBe("semantic");
    await service.close();
  });

  it("retains a second invalidation that arrives during dirty refresh", async () => {
    let currentEntries = entries;
    let invalidate: ((sessionID: string, nextSessionID?: string) => void) | undefined;
    let reads = 0;
    let release!: () => void;
    let refreshStarted!: () => void;
    const started = new Promise<void>(resolve => { refreshStarted = resolve; });
    const blocked = new Promise<void>(resolve => { release = resolve; });
    const sessions = {
      setSearchInvalidator(callback: typeof invalidate) { invalidate = callback; },
      catalog: async () => ({ sessions: [{ id: "s" }] }),
      readSearchCut: async () => {
        reads += 1;
        const cut = currentEntries;
        if (reads === 2) { refreshStarted(); await blocked; }
        return { summary: { id: "s", name: "Fixture", firstMessage: "Fixture", cwd: "/tmp", modified: new Date("2026-01-01T00:00:00Z") }, entries: cut, fileIdentity: cut === entries ? "file-1" : "file-2", leafEntryId: cut.at(-1)?.id };
      },
    } as any;
    const root = await mkdtemp(join(tmpdir(), "tron-search-refresh-")); roots.push(root);
    const index = await SessionSearchIndex.open(join(root, "index.sqlite"));
    const service = new SessionSearchService(sessions, index);
    await service.warm();
    invalidate!("s");
    const firstSearch = service.search({ query: "new", maxResults: 5 });
    await started;
    currentEntries = [entries[0], entries[1], { ...entries[2], id: "new-entry", parentId: "lexical", message: { role: "user", content: "new canonical passage" } }];
    invalidate!("s");
    release();
    expect((await firstSearch).results).toEqual([]);
    const second = await service.search({ query: "new", maxResults: 5 });
    expect(index.candidates("new", 10).map(candidate => candidate.entryId)).toContain("new-entry");
    expect(second.results.map(result => result.entryId)).toEqual(["new-entry"]);
    await service.close();
  });

  it("fails closed when query metadata changes dimension", async () => {
    class MismatchEmbedding extends FixtureEmbedding {
      override async embed(text: string): Promise<{ vector: number[]; dimension: number; language: string; modelRevision: string }> {
        const result = await super.embed(text);
        if (text === "mismatch") return { ...result, vector: [...result.vector, 1], dimension: 513 };
        return result;
      }
    }
    const { service } = await realService(new MismatchEmbedding());
    await service.warm();
    await service.search({ query: "warmup", maxResults: 1 });
    const response = await service.search({ query: "mismatch", maxResults: 5 });
    expect(response.semantic.state).not.toBe("ready");
    expect(response.ranking.state).not.toBe("localSemantic");
    expect(response.results.every(result => result.semanticScore !== -1)).toBe(true);
    await service.close();
  });

  it("serializes semantic initialization ahead of dirty refresh publication", async () => {
    let invalidate: ((sessionID: string, nextSessionID?: string) => void) | undefined;
    let currentEntries = entries;
    let release!: () => void;
    let started!: () => void;
    const blocked = new Promise<void>(resolve => { release = resolve; });
    const semanticStarted = new Promise<void>(resolve => { started = resolve; });
    const sessions = {
      setSearchInvalidator(callback: typeof invalidate) { invalidate = callback; },
      catalog: async () => ({ sessions: [{ id: "s" }] }),
      readSearchCut: async () => ({ summary: { id: "s", name: "Fixture", firstMessage: "Fixture", cwd: "/tmp", modified: new Date("2026-01-01T00:00:00Z") }, entries: currentEntries, fileIdentity: currentEntries === entries ? "file-1" : "file-2", leafEntryId: currentEntries.at(-1)?.id }),
    } as any;
    class DeferredEmbedding implements SessionSearchEmbeddingClient {
      private calls = 0;
      async qualify() { return { dimension: 512, language: "en", modelRevision: "fixture-v1" }; }
      async embed(text: string) {
        this.calls += 1;
        if (this.calls === 1) { started(); await blocked; }
        return { vector: Array.from({ length: 512 }, (_, index) => index === (text.includes("new") ? 1 : 0) ? 1 : 0), dimension: 512, language: "en", modelRevision: "fixture-v1" };
      }
    }
    const root = await mkdtemp(join(tmpdir(), "tron-search-semantic-refresh-")); roots.push(root);
    const index = await SessionSearchIndex.open(join(root, "index.sqlite"));
    const service = new SessionSearchService(sessions, index, undefined, undefined, new DeferredEmbedding());
    await service.initialize();
    await semanticStarted;
    currentEntries = [entries[0], entries[1], { ...entries[2], id: "new-entry", parentId: "lexical", message: { role: "user", content: "new canonical passage" } }];
    invalidate!("s");
    const search = service.search({ query: "new", maxResults: 5 });
    const response = await Promise.race([
      search,
      new Promise<never>((_, reject) => setTimeout(() => reject(new Error("lexical refresh waited behind semantic work")), 200)),
    ]);
    expect(response.results.map(result => result.entryId)).toContain("new-entry");
    release();
    await search;
    const settled = await service.search({ query: "new", maxResults: 5 });
    expect(settled.semantic.state).toBe("ready");
    await service.close();
  });

  it("charges a real Jev HTTP success through the service", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-search-jev-http-")); roots.push(root);
    const allowance = await SessionSearchAllowanceLedger.open(join(root, "allowance.sqlite"));
    const http = async () => ({ status: 200, body: JSON.stringify({ model: "jev-1.13.0", answers: { r0: { type: "score", score: 2, legend: { "0": "irrelevant", "1": "relevant", "2": "direct answer" }, probabilities: { "0": 0, "1": 0, "2": 1 }, confidence: 1 } }, usage: { input_tokens: 100, output_tokens: 1 } }) });
    const jev = new JevDecisionClient(new InMemoryConnectorCredentialStore(new Map([["connector:jev:personal", "synthetic-token"]])), http);
    const index = await SessionSearchIndex.open(join(root, "index.sqlite"));
    const service = new SessionSearchService(sessionsFor(), index, jev, allowance);
    service.setPolicy({ enabled: true, perQueryMicroCents: 300_000, dailyMicroCents: 300_000, policyRevision: 1 });
    const response = await service.search({ query: "needle", maxResults: 5, remoteRanking: true, remoteConsent: true });
    expect(response.ranking.state).toBe("jev");
    const database = new DatabaseSync(join(root, "allowance.sqlite"));
    expect((database.prepare("SELECT state, actual_micro_cents FROM jev_reservations").get() as { state: string; actual_micro_cents: number }).state).toBe("settled");
    expect((database.prepare("SELECT committed_micro_cents AS n FROM jev_usage").get() as { n: number }).n).toBe(420);
    database.close(); await service.close();
  });

  it("keeps a real HTTP malformed-response hold pending after dispatch", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-search-jev-malformed-")); roots.push(root);
    const allowance = await SessionSearchAllowanceLedger.open(join(root, "allowance.sqlite"));
    const jev = new JevDecisionClient(new InMemoryConnectorCredentialStore(new Map([["connector:jev:personal", "synthetic-token"]])), async () => ({ status: 200, body: "not-json" }));
    const index = await SessionSearchIndex.open(join(root, "index.sqlite"));
    const service = new SessionSearchService(sessionsFor(), index, jev, allowance);
    service.setPolicy({ enabled: true, perQueryMicroCents: 300_000, dailyMicroCents: 300_000, policyRevision: 1 });
    const response = await service.search({ query: "needle", maxResults: 5, remoteRanking: true, remoteConsent: true });
    expect(response.ranking.jev).toBe("uncertain");
    const database = new DatabaseSync(join(root, "allowance.sqlite"));
    expect((database.prepare("SELECT count(*) AS n FROM jev_reservations WHERE state = 'pending'").get() as { n: number }).n).toBe(1);
    database.close(); await service.close();
  });

  it("does not reserve or spend when Jev capability is unavailable before dispatch", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-search-jev-no-token-")); roots.push(root);
    const allowance = await SessionSearchAllowanceLedger.open(join(root, "allowance.sqlite"));
    const jev = new JevDecisionClient(new InMemoryConnectorCredentialStore(new Map()), async () => { throw new Error("must not dispatch"); });
    const index = await SessionSearchIndex.open(join(root, "index.sqlite"));
    const service = new SessionSearchService(sessionsFor(), index, jev, allowance);
    service.setPolicy({ enabled: true, perQueryMicroCents: 300_000, dailyMicroCents: 300_000, policyRevision: 1 });
    const response = await service.search({ query: "needle", maxResults: 5, remoteRanking: true, remoteConsent: true });
    expect(response.ranking.jev).toBe("consentRequired");
    const database = new DatabaseSync(join(root, "allowance.sqlite"));
    expect((database.prepare("SELECT count(*) AS n FROM jev_reservations").get() as { n: number }).n).toBe(0);
    database.close(); await service.close();
  });

  it("retains an uncertain post-dispatch hold across ledger restart", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-search-jev-")); roots.push(root);
    const allowance = await SessionSearchAllowanceLedger.open(join(root, "allowance.sqlite"));
    let dispatched!: () => void;
    const sent = new Promise<void>(resolve => { dispatched = resolve; });
    const jev = {
      evaluate: async (_request: unknown, _signal: AbortSignal, context: { beforeDispatch?: () => Promise<void>; onDispatch?: () => void }) => {
        await context.beforeDispatch?.(); context.onDispatch?.(); dispatched();
        await new Promise<never>(() => {});
        throw new JevEvaluationError("unreachable", "uncertain");
      },
    } as any;
    const rootIndex = await SessionSearchIndex.open(join(root, "index.sqlite"));
    const service = new SessionSearchService(sessionsFor(), rootIndex, jev, allowance);
    service.setPolicy({ enabled: true, perQueryMicroCents: 300_000, dailyMicroCents: 300_000, policyRevision: 1 });
    const controller = new AbortController();
    const search = service.search({ query: "needle", maxResults: 5, remoteRanking: true, remoteConsent: true }, controller.signal);
    await sent;
    controller.abort();
    const response = await search;
    expect(response.ranking.jev).toBe("uncertain");
    await service.close();
    const reopened = await SessionSearchAllowanceLedger.open(join(root, "allowance.sqlite"));
    const database = new DatabaseSync(join(root, "allowance.sqlite"));
    expect((database.prepare("SELECT count(*) AS n FROM jev_reservations WHERE state = 'pending'").get() as { n: number }).n).toBe(1);
    database.close(); reopened.close();
  });

  it("retains exact fork gap metadata in search anchors", async () => {
    const { service } = await realService(undefined, sessionsFor(entries, { kind: "sessionFork", inheritedEntryId: "lexical", gapOrdinal: 3 }));
    const response = await service.search({ query: "paraphrased", maxResults: 5 });
    expect(response.results[0]?.anchorRevision.forkBoundary?.gapOrdinal).toBe(3);
    await service.close();
  });

  it("reports lexical partial coverage instead of failing when an index replacement overflows", async () => {
    // A real index whose storage bound is one byte rejects the fixture session
    // at its own bound, so the service's recovery path is what this observes.
    const root = await mkdtemp(join(tmpdir(), "tron-search-overflow-")); roots.push(root);
    const index = await SessionSearchIndex.open(join(root, "index.sqlite"), { maxStorageBytes: 1 });
    const service = new SessionSearchService(sessionsFor(), index);
    const response = await service.search({ query: "needle", maxResults: 5 });
    expect(response.coverage.state).toBe("partial");
    expect(response.coverage.omittedSessions).toBe(1);
    await service.close();
  });

  it("propagates a cancelled request instead of returning lexical success", async () => {
    const { index, service } = await realService();
    const controller = new AbortController(); controller.abort();
    await expect(service.search({ query: "needle" }, controller.signal)).rejects.toBeInstanceOf(GatewayError);
    await service.close();
  });
});
