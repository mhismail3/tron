import { createHash } from "node:crypto";
import type { FileEntry } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import { NaturalLanguageEmbeddingClient } from "./session-search-embedding.js";
import type { RuntimeRegistry } from "./runtime-registry.js";
import {
  boundedQuery,
  boundedResults,
  digest,
  type SessionSearchRequest,
  type SessionSearchResponse,
  normalizeForSearch,
  stableSearchResultOrder,
  type SessionSearchResult,
} from "./session-search-contract.js";
import { SessionSearchIndex, type SearchIndexStamp, type SearchIndexSessionFacts, type SearchIndexDocument } from "./session-search-index.js";
import type { SessionCatalogIdentity } from "./session-catalog.js";
import { excerpt, extractSearchText, validateSearchBranch, type SearchTextEntry } from "./session-search-text.js";
import { yieldToEventLoop } from "../util/event-loop-yield.js";

const SEARCH_CANDIDATE_LIMIT = 500;
const MAX_SEMANTIC_VECTORS = 100_000;
const MAX_SEMANTIC_BYTES = 128 * 1_024 * 1_024;
const MAX_SEMANTIC_WORK = 20_000;
const MAX_DIRTY_SESSIONS = 256;
/** Longest stretch of warm-up or reindex work between event-loop yields, so an
 * owned background pass cannot delay an in-flight request. */
const SEARCH_SLICE_MS = 20;
/** How long a start waits for the catalog owner's first verified cut before it
 * parses whatever it cannot prove unchanged. The warm-up is a background task,
 * so this never delays listener readiness. */
const SEARCH_WARMUP_CATALOG_WAIT_MS = 30_000;
/** A start's optional semantic pass stops here and reports partial coverage: it
 * re-reads and re-embeds the corpus, which must not run without a time bound. */
const SEARCH_SEMANTIC_WARMUP_BUDGET_MS = 120_000;

async function awaitWithAbort<T>(promise: Promise<T>, signal?: AbortSignal): Promise<T> {
  if (!signal) return promise;
  if (signal.aborted) throw new GatewayError("cancelled", "Search cancelled", true);
  return await new Promise<T>((resolve, reject) => {
    const abort = () => reject(new GatewayError("cancelled", "Search cancelled", true));
    signal.addEventListener("abort", abort, { once: true });
    void promise.then(value => { signal.removeEventListener("abort", abort); resolve(value); }, error => { signal.removeEventListener("abort", abort); reject(error); });
  });
}

function sameFileIdentity(reuse: SearchIndexStamp, current: SessionCatalogIdentity): boolean {
  return reuse.fileIdentity === current.fileIdentity && reuse.size === current.size && reuse.mtimeMs === current.mtimeMs;
}

function sameSemanticGeneration(left: Pick<SemanticGeneration, "dimension" | "language" | "modelRevision">, right: SemanticGeneration): boolean {
  return left.dimension === right.dimension && left.language === right.language && left.modelRevision === right.modelRevision;
}

function cosine(left: readonly number[], right: readonly number[]): number {
  if (left.length !== right.length || left.length === 0) return -1;
  let dot = 0; let leftMagnitude = 0; let rightMagnitude = 0;
  for (let index = 0; index < left.length; index += 1) { dot += left[index]! * right[index]!; leftMagnitude += left[index]! ** 2; rightMagnitude += right[index]! ** 2; }
  return leftMagnitude > 0 && rightMagnitude > 0 ? dot / Math.sqrt(leftMagnitude * rightMagnitude) : -1;
}

interface SearchDocument extends SearchIndexDocument {
  texts: Map<string, SearchTextEntry>;
  /** Set when the document was read from an open session's in-memory branch
   * rather than from the canonical file, so the catalog's file facts do not
   * describe it (`RuntimeRegistry.readSearchCut`). */
  runtimeGeneration?: string;
}
interface SessionSearchEmbeddingClient {
  qualify(signal?: AbortSignal): Promise<{ dimension: number; language: string; modelRevision: string }>;
  embed(text: string, language?: string, signal?: AbortSignal): Promise<{ vector: number[]; dimension: number; language: string; modelRevision: string }>;
}

interface SemanticGeneration {
  dimension: number;
  language: string;
  modelRevision: string;
}

interface SemanticVector {
  vector: number[];
  textDigest: string;
  branchDigest: string;
  fileIdentity: string;
  generation: SemanticGeneration;
}

/** Gateway-owned coordinator. It holds no canonical transcript mirror: every
 * result is validated against a fresh registry-owned cut before publication. */
export class SessionSearchService {
  private initialized = false;
  private initializing: Promise<void> | undefined;
  private readonly warmupAbort = new AbortController();
  private semanticClient: SessionSearchEmbeddingClient | undefined;
  private readonly semanticVectors = new Map<string, SemanticVector>();
  private semanticTotal = 0;
  private semanticCoverage: "complete" | "indexing" | "partial" | "unavailable" | "unsupportedLanguage" = "unavailable";
  private semanticQualified = false;
  private semanticReason: string | undefined;
  private corpusRevision = "empty";
  private coverageSessionsTotal = 0;
  private coverageOmittedSessions = 0;
  private coverageReason: string | undefined;
  private readonly dirtySessions = new Map<string, number>();
  private dirtyGeneration = 0;
  private dirtyRefresh: Promise<void> | undefined;
  private semanticTask: Promise<void> | undefined;
  // Optional semantic work has its own serialized owner. Lexical rebuilds
  // never wait behind helper I/O, so canonical refreshes remain searchable.
  private semanticTail: Promise<void> = Promise.resolve();
  private semanticGeneration = 0;
  private semanticModel: SemanticGeneration | undefined;
  private readonly semanticAbort = new AbortController();
  private semanticBytes = 0;
  private semanticWork = 0;
  private dirtyOverflow = false;
  private indexReused = 0;
  private indexParsed = 0;
  private sliceStartedAt = 0;

  constructor(
    private readonly sessions: RuntimeRegistry,
    private readonly index: SessionSearchIndex,
    semanticClient?: SessionSearchEmbeddingClient,
  ) {
    this.semanticClient = semanticClient ?? (process.env.TRON_SEARCH_EMBEDDING_HELPER ? new NaturalLanguageEmbeddingClient(process.env.TRON_SEARCH_EMBEDDING_HELPER) : undefined);
    this.sessions.setSearchInvalidator((sessionID, nextSessionID) => {
      this.semanticGeneration += 1;
      // This runs inside another owner's summary publication, so it stays
      // cheap: no SQLite work and no scan of the whole vector map. The dirty
      // lane replaces the session's rows in a bounded slice, and the old rows
      // answer nothing meanwhile because every candidate is validated against
      // a fresh canonical cut before publication.
      for (const [key, value] of this.semanticVectors) {
        if (!key.startsWith(`${sessionID}\u0000`)) continue;
        this.semanticVectors.delete(key);
        this.semanticBytes -= value.vector.length * Float64Array.BYTES_PER_ELEMENT;
      }
      this.semanticTotal = this.semanticVectors.size;
      if (nextSessionID) {
        this.initialized = false;
        this.dirtySessions.clear();
        this.semanticModel = undefined;
        this.semanticQualified = false;
        this.semanticVectors.clear();
        this.semanticTotal = 0;
        this.semanticBytes = 0;
      } else {
        if (this.dirtySessions.size >= MAX_DIRTY_SESSIONS && !this.dirtySessions.has(sessionID)) { this.dirtyOverflow = true; this.coverageReason = "Search refresh queue is full; coverage is partial"; return; }
        this.dirtyGeneration += 1;
        this.dirtySessions.set(sessionID, this.dirtyGeneration);
        if (this.semanticClient) this.semanticCoverage = "partial";
      }
    });
  }

  /** What the last index pass reused and parsed, for the warm-up record. */
  indexPassStats(): { reusedSessions: number; parsedSessions: number } {
    return { reusedSessions: this.indexReused, parsedSessions: this.indexParsed };
  }

  setSemanticClient(client: SessionSearchEmbeddingClient): void {
    if (!this.semanticClient) {
      this.semanticClient = client;
      if (this.initialized) this.startSemanticIndexing();
    }
  }

  async warm(): Promise<void> {
    await this.initialize(this.warmupAbort.signal);
    if (!this.warmupAbort.signal.aborted) this.startSemanticIndexing();
  }

  async initialize(signal?: AbortSignal): Promise<void> {
    if (this.initialized) return;
    if (!this.initializing) this.initializing = this.rebuild().finally(() => { this.initializing = undefined; if (!this.warmupAbort.signal.aborted) this.startSemanticIndexing(); });
    await awaitWithAbort(this.initializing, signal);
    if (!this.warmupAbort.signal.aborted) this.initialized = true;
  }

  cancelWarmup(): void { this.warmupAbort.abort(); }

  async search(request: SessionSearchRequest, signal?: AbortSignal): Promise<SessionSearchResponse> {
    const query = boundedQuery(request.query);
    const maxResults = boundedResults(request.maxResults);
    await this.initialize(signal);
    if (signal?.aborted) throw new GatewayError("cancelled", "Search cancelled", true);
    await this.refreshDirty(signal);
    const candidates = this.index.candidates(query, Math.min(SEARCH_CANDIDATE_LIMIT, maxResults * 10));
    const docs = new Map<string, SearchDocument>();
    const results: SessionSearchResult[] = [];
    for (const candidate of candidates) {
      if (signal?.aborted) throw new GatewayError("cancelled", "Search cancelled", true);
      let document = docs.get(candidate.sessionId);
      if (!document) {
        document = await awaitWithAbort(this.loadDocument(candidate.sessionId), signal);
        if (!document) continue;
        docs.set(candidate.sessionId, document);
      }
      if (candidate.anchorRevision.branchDigest !== document.branchDigest || candidate.anchorRevision.fileIdentity !== document.fileIdentity) continue;
      const entry = document.texts.get(candidate.entryId);
      if (!entry || !this.matches(entry.text, query)) continue;
      const currentAnchor = document.entries.find(item => item.id === candidate.entryId);
      if (!currentAnchor || currentAnchor.ordinal !== candidate.ordinal) continue;
      results.push({
        // Archive state is the owning store's display projection read at
        // publication, never part of the index, so this needs no reindex.
        sessionId: candidate.sessionId, archived: this.sessions.isArchived(candidate.sessionId),
        title: candidate.title, cwd: candidate.cwd, updatedAt: candidate.updatedAt,
        entryId: candidate.entryId, ...(candidate.parentEntryId ? { parentEntryId: candidate.parentEntryId } : {}), ordinal: candidate.ordinal,
        passageKind: candidate.role, snippet: excerpt(entry.text, query), lexicalScore: candidate.lexicalScore,
        anchorRevision: candidate.anchorRevision,
      });
      if (results.length >= SEARCH_CANDIDATE_LIMIT) break;
    }
    let semanticHits: Array<{ sessionId: string; entryId: string; vector: SemanticVector; score: number }> = [];
    if (this.semanticClient && this.semanticQualified && this.semanticModel && this.semanticVectors.size > 0) {
      try {
        const queryEmbedding = await awaitWithAbort(this.semanticClient.embed(query, this.semanticModel.language, signal), signal);
        if (!this.semanticModel || !sameSemanticGeneration(queryEmbedding, this.semanticModel)) throw new Error("Embedding query metadata changed");
        const queryVector = queryEmbedding.vector;
        semanticHits = [...this.semanticVectors.entries()].map(([key, vector]) => {
          const [sessionId, entryId] = key.split("\u0000");
          return sessionId && entryId ? { sessionId, entryId, vector, score: cosine(queryVector, vector.vector) } : undefined;
        }).filter((hit): hit is { sessionId: string; entryId: string; vector: SemanticVector; score: number } => hit !== undefined)
          .sort((left, right) => right.score - left.score).slice(0, maxResults * 4);
        const existing = new Set(results.map(result => `${result.sessionId}\u0000${result.entryId}`));
        for (const hit of semanticHits) {
          const key = `${hit.sessionId}\u0000${hit.entryId}`;
          if (existing.has(key)) continue;
          const document = await awaitWithAbort(this.loadDocument(hit.sessionId), signal);
          const entry = document?.texts.get(hit.entryId);
          const stored = this.semanticVectors.get(key);
          if (!document || !entry || !stored || !this.semanticModel || !sameSemanticGeneration(stored.generation, this.semanticModel) || stored.branchDigest !== document.branchDigest || stored.textDigest !== digest(entry.text)) continue;
          existing.add(key);
          results.push({ sessionId: hit.sessionId, archived: this.sessions.isArchived(hit.sessionId), title: document.title, cwd: document.cwd, updatedAt: document.updatedAt, entryId: entry.id, ...(entry.parentId ? { parentEntryId: entry.parentId } : {}), ordinal: entry.ordinal, passageKind: entry.role, snippet: excerpt(entry.text, query), lexicalScore: 0, semanticScore: hit.score, anchorRevision: { indexRevision: this.index.stats().indexRevision, fileIdentity: document.fileIdentity, branchDigest: document.branchDigest, ...(document.leafEntryId ? { leafEntryId: document.leafEntryId } : {}), entryOrdinal: entry.ordinal, ...(document.forkBoundary ? { forkBoundary: document.forkBoundary } : {}) } });
        }
      } catch (error) {
        if (signal?.aborted) throw error;
        semanticHits = [];
        this.semanticCoverage = "partial";
      }
    }
    results.sort(stableSearchResultOrder);
    results.splice(maxResults * 4);
    const rankingState: SessionSearchResponse["ranking"]["state"] = semanticHits.length > 0 ? "localSemantic" : "lexical";
    results.sort((left, right) => (right.semanticScore ?? -1) - (left.semanticScore ?? -1) || stableSearchResultOrder(left, right));
    results.splice(maxResults);
    // Semantic ranking awaits the embedding helper while any session continues
    // to move. Re-cut only result-bearing sessions and publish lexical hits only when the
    // exact passage still matches; unrelated publications cannot invalidate the
    // response, and stale semantic scores are discarded rather than reused.
    const currentDocuments = new Map<string, SearchDocument | undefined>();
    const publishable: SessionSearchResult[] = [];
    for (const result of results) {
      let current = currentDocuments.get(result.sessionId);
      if (!currentDocuments.has(result.sessionId)) {
        current = await awaitWithAbort(this.loadDocument(result.sessionId), signal);
        currentDocuments.set(result.sessionId, current);
      }
      const entry = current?.texts.get(result.entryId);
      if (!current || !entry || entry.ordinal !== result.ordinal) continue;
      if (result.semanticScore !== undefined) {
        if (current.branchDigest !== result.anchorRevision.branchDigest
          || current.fileIdentity !== result.anchorRevision.fileIdentity) continue;
      } else if (!this.matches(entry.text, query)) continue;
      result.archived = this.sessions.isArchived(result.sessionId);
      result.title = current.title;
      result.cwd = current.cwd;
      result.updatedAt = current.updatedAt;
      result.snippet = excerpt(entry.text, query);
      result.anchorRevision = {
        indexRevision: this.index.stats().indexRevision,
        fileIdentity: current.fileIdentity,
        branchDigest: current.branchDigest,
        ...(current.leafEntryId ? { leafEntryId: current.leafEntryId } : {}),
        entryOrdinal: entry.ordinal,
        ...(current.forkBoundary ? { forkBoundary: current.forkBoundary } : {}),
      };
      publishable.push(result);
    }
    results.splice(0, results.length, ...publishable);
    const stats = this.index.stats();
    return {
      query, queryRevision: digest({ query, maxResults }), corpusRevision: this.corpusRevision, indexRevision: stats.indexRevision,
      coverage: { state: this.coverageOmittedSessions > 0 || stats.state === "partial" ? "partial" : stats.state, sessionsIndexed: stats.sessionsIndexed, sessionsTotal: this.coverageSessionsTotal, passagesIndexed: stats.passagesIndexed, omittedSessions: this.coverageOmittedSessions, ...(this.coverageReason ? { reason: this.coverageReason } : {}) },
      semantic: { state: this.semanticCoverage === "complete" ? "ready" : this.semanticCoverage, ...(this.semanticModel ? { modelRevision: this.semanticModel.modelRevision, language: this.semanticModel.language, dimension: this.semanticModel.dimension } : {}), vectorsIndexed: this.semanticVectors.size, vectorsTotal: this.semanticTotal, ...((this.semanticCoverage === "unavailable" || this.semanticCoverage === "unsupportedLanguage") ? { reason: this.semanticReason ?? "The signed NaturalLanguage helper is unavailable or not qualified" } : {}) },
      ranking: { state: rankingState },
      results,
    };
  }

  async close(): Promise<void> {
    this.sessions.setSearchInvalidator(() => {});
    this.cancelWarmup();
    this.semanticAbort.abort();
    await this.initializing?.catch(() => {});
    if (this.semanticTask) await this.semanticTask.catch(() => {});
    if (this.dirtyRefresh) await this.dirtyRefresh.catch(() => {});
    await this.semanticTail.catch(() => {});
    this.index.close();
  }

  private async rebuild(): Promise<void> {
    this.semanticVectors.clear();
    this.semanticTotal = 0;
    this.semanticBytes = 0;
    this.semanticWork = 0;
    this.semanticQualified = false;
    this.semanticModel = undefined;
    this.semanticReason = undefined;
    this.semanticCoverage = this.semanticClient ? "indexing" : "unavailable";
    this.indexReused = 0;
    this.indexParsed = 0;
    this.sliceStartedAt = performance.now();
    const catalog = await this.sessions.catalog("user");
    this.coverageSessionsTotal = catalog.sessions.length;
    this.coverageOmittedSessions = 0;
    this.coverageReason = undefined;
    // One persisted row is reused while the catalog owner still reports the
    // exact file facts the row was indexed from: an unchanged corpus is warmed
    // without reading a transcript, and only what changed is parsed again.
    const identities = await this.catalogIdentities();
    const stored = new Map(this.index.sessionFacts().map(facts => [facts.sessionId, facts]));
    const published = new Set(catalog.sessions.map(session => session.id));
    for (const sessionId of stored.keys()) {
      if (published.has(sessionId)) continue;
      await this.index.remove(sessionId);
      await this.yieldSlice();
    }
    const corpusFacts: string[] = [];
    for (const session of catalog.sessions) {
      if (this.warmupAbort.signal.aborted) return;
      const candidate = identities?.get(session.id);
      const previous = stored.get(session.id);
      if (previous?.reuse && candidate && sameFileIdentity(previous.reuse, candidate)) {
        this.indexReused += 1;
        corpusFacts.push(`${session.id}:${previous.branchDigest}`);
        await this.yieldSlice();
        continue;
      }
      const document = await this.loadDocument(session.id);
      if (this.warmupAbort.signal.aborted) return;
      if (!document) { this.coverageOmittedSessions += 1; this.coverageReason = "One or more canonical sessions could not be admitted for search"; continue; }
      corpusFacts.push(`${document.sessionId}:${document.branchDigest}`);
      try {
        // Only a cut read from the file may carry the catalog's file facts: an
        // open session's in-memory branch can move (a tree navigation writes
        // nothing), and a row stamped with facts it was not derived from would
        // be reused across a restart and then dropped by its own digest.
        await this.index.replace(document, document.runtimeGeneration ? undefined : candidate);
        this.indexParsed += 1;
      } catch { this.coverageOmittedSessions += 1; this.coverageReason = "One or more sessions exceeded bounded search index capacity"; }
      await this.yieldSlice();
    }
    this.corpusRevision = digest(corpusFacts);
  }

  /** The catalog owner's verified file facts, or undefined when no complete cut
   * arrives within this start's bounded wait: the pass then parses whatever it
   * cannot prove unchanged instead of trusting an unverified durable row. */
  private async catalogIdentities(): Promise<ReadonlyMap<string, SessionCatalogIdentity> | undefined> {
    let timer: NodeJS.Timeout | undefined;
    const expired = new Promise<undefined>(resolve => { timer = setTimeout(() => resolve(undefined), SEARCH_WARMUP_CATALOG_WAIT_MS); });
    const identities = await Promise.race([
      this.readCatalogIdentities(),
      expired,
    ]);
    if (timer) clearTimeout(timer);
    return identities;
  }

  /** A catalog seam that fails or is unavailable leaves every row unproven, so
   * the pass parses instead of reusing what it cannot check. */
  private async readCatalogIdentities(): Promise<ReadonlyMap<string, SessionCatalogIdentity> | undefined> {
    try { return await this.sessions.searchCatalogIdentities(); } catch { return undefined; }
  }

  /** Hand the loop back between slices: the warm-up is one long background
   * task, and a transcript read must not hold an in-flight request. */
  private async yieldSlice(): Promise<void> {
    if (performance.now() - this.sliceStartedAt < SEARCH_SLICE_MS) return;
    this.sliceStartedAt = performance.now();
    await yieldToEventLoop();
  }

  private startSemanticIndexing(): void {
    if (!this.semanticClient || this.semanticTask || this.semanticAbort.signal.aborted) return;
    this.semanticTask = this.enqueueSemantic(() => this.indexSemanticCorpus()).catch(error => {
      if (!this.semanticAbort.signal.aborted) { this.semanticCoverage = "partial"; this.semanticReason = error instanceof Error ? error.message : "Semantic indexing failed"; }
    }).finally(() => { this.semanticTask = undefined; });
  }

  /** Admits one embedded entry under the semantic byte bound. Returns false
   * when the scan must stop: the vector no longer matches the current
   * generation, or the exact byte budget is full (coverage becomes partial). */
  private admitSemanticVector(
    sessionId: string,
    document: SearchDocument,
    entry: SearchTextEntry,
    vector: { vector: number[]; dimension: number; language: string; modelRevision: string },
  ): boolean {
    if (!this.semanticModel || !this.isEmbedding(vector) || !sameSemanticGeneration(vector, this.semanticModel)) return false;
    const bytes = vector.vector.length * Float64Array.BYTES_PER_ELEMENT;
    if (this.semanticBytes + bytes > MAX_SEMANTIC_BYTES) { this.semanticCoverage = "partial"; return false; }
    this.semanticBytes += bytes;
    this.semanticVectors.set(`${sessionId}\u0000${entry.id}`, {
      vector: vector.vector,
      textDigest: digest(entry.text),
      branchDigest: document.branchDigest,
      fileIdentity: document.fileIdentity,
      generation: this.semanticModel,
    });
    this.semanticTotal = this.semanticVectors.size;
    return true;
  }

  private async indexSemanticCorpus(): Promise<void> {
    if (!this.semanticClient) return;
    const generation = this.semanticGeneration;
    try {
      const qualified = await this.semanticClient.qualify(this.semanticAbort.signal);
      if (!this.isMetadata(qualified) || generation !== this.semanticGeneration) return;
      this.semanticModel = { dimension: qualified.dimension, language: qualified.language, modelRevision: qualified.modelRevision };
      this.semanticQualified = true;
    } catch (error) {
      if (this.semanticAbort.signal.aborted || generation !== this.semanticGeneration) return;
      this.semanticCoverage = error instanceof Error && /unsupported|language/iu.test(error.message) ? "unsupportedLanguage" : "unavailable";
      this.semanticReason = error instanceof Error ? error.message : "The signed local embedding helper failed qualification";
      return;
    }
    this.semanticCoverage = "indexing";
    const deadline = performance.now() + SEARCH_SEMANTIC_WARMUP_BUDGET_MS;
    const catalog = await this.sessions.catalog("user");
    for (const session of catalog.sessions) {
      if (this.semanticAbort.signal.aborted || this.semanticOutOfBudget(deadline) || this.semanticWork >= MAX_SEMANTIC_WORK || this.semanticVectors.size >= MAX_SEMANTIC_VECTORS || this.semanticBytes >= MAX_SEMANTIC_BYTES) { this.semanticCoverage = "partial"; break; }
      const document = await this.loadDocument(session.id);
      if (!document) continue;
      for (const entry of document.entries) {
        if (this.semanticAbort.signal.aborted) return;
        if (this.semanticOutOfBudget(deadline) || this.semanticWork >= MAX_SEMANTIC_WORK || this.semanticVectors.size >= MAX_SEMANTIC_VECTORS) { this.semanticCoverage = "partial"; return; }
        this.semanticWork += 1;
        try {
          const vector = await this.semanticClient.embed(entry.text, this.semanticModel?.language, this.semanticAbort.signal);
          if (generation !== this.semanticGeneration) return;
          if (!this.admitSemanticVector(document.sessionId, document, entry, vector)) return;
        } catch (error) { if (this.semanticAbort.signal.aborted) return; this.semanticCoverage = "partial"; }
      }
      await this.yieldSlice();
    }
    this.semanticTotal = this.semanticVectors.size;
    if (this.semanticCoverage === "indexing") this.semanticCoverage = "complete";
  }

  /** The optional semantic pass stops at its per-start budget with explicit
   * partial coverage instead of re-embedding the corpus without a time bound. */
  private semanticOutOfBudget(deadline: number): boolean {
    return performance.now() >= deadline;
  }

  private enqueueSemantic(operation: () => Promise<void>): Promise<void> {
    const run = this.semanticTail.then(operation, operation);
    this.semanticTail = run.then(() => undefined, () => undefined);
    return run;
  }

  private async refreshDirty(signal?: AbortSignal): Promise<void> {
    if (!this.dirtySessions.size) return;
    if (!this.dirtyRefresh) {
      const entries = [...this.dirtySessions.entries()];
      this.dirtyRefresh = (async () => {
        const refreshed: Array<{ id: string; generation: number; document?: SearchDocument }> = [];
        for (const [id, processedGeneration] of entries) {
          try {
            const document = await this.loadDocument(id);
            if (document) await this.index.replace(document);
            else await this.index.remove(id);
            refreshed.push({ id, generation: processedGeneration, ...(document ? { document } : {}) });
          } catch {
            await this.index.remove(id);
            this.coverageReason = "A changed session could not be indexed and will be retried on a later search";
          }
          if (this.dirtySessions.get(id) === processedGeneration) this.dirtySessions.delete(id);
        }
        // Vector replacement remains serialized, but is deliberately detached
        // from this lexical owner. A blocked helper must not delay search.
        if (refreshed.length > 0) {
          void this.enqueueSemantic(() => this.refreshSemanticDocuments(refreshed)).catch(error => {
            if (!this.semanticAbort.signal.aborted) this.semanticReason = error instanceof Error ? error.message : "Semantic refresh failed";
          });
        }
      })().finally(() => { this.dirtyRefresh = undefined; });
    }
    await awaitWithAbort(this.dirtyRefresh, signal);
    try {
      const catalog = await awaitWithAbort(this.sessions.catalog("user"), signal);
      this.coverageSessionsTotal = catalog.sessions.length;
      const stats = this.index.stats();
      this.coverageOmittedSessions = Math.max(0, catalog.sessions.length - stats.sessionsIndexed);
      this.semanticTotal = this.semanticVectors.size;
    } catch (error) { if (signal?.aborted) throw error; this.coverageReason = "Coverage could not be refreshed from the current catalog"; }
    if (this.dirtyOverflow) { this.semanticCoverage = "partial"; }
  }

  private async refreshSemanticDocuments(refreshed: Array<{ id: string; generation: number; document?: SearchDocument }>): Promise<void> {
    const generation = this.semanticGeneration;
    for (const item of refreshed) {
      if (generation !== this.semanticGeneration || this.semanticAbort.signal.aborted) return;
      for (const key of this.semanticVectors.keys()) if (key.startsWith(`${item.id}\u0000`)) this.semanticVectors.delete(key);
      this.semanticTotal = this.semanticVectors.size;
      this.semanticBytes = [...this.semanticVectors.values()].reduce((sum, value) => sum + value.vector.length * Float64Array.BYTES_PER_ELEMENT, 0);
      const document = item.document;
      if (!document || !this.semanticClient || !this.semanticQualified || !this.semanticModel) continue;
      if (this.semanticCoverage !== "unavailable") this.semanticCoverage = "indexing";
      for (const entry of document.entries.slice(0, 2_000)) {
        if (generation !== this.semanticGeneration || this.semanticAbort.signal.aborted) return;
        if (this.semanticWork >= MAX_SEMANTIC_WORK || this.semanticVectors.size >= MAX_SEMANTIC_VECTORS) { this.semanticCoverage = "partial"; return; }
        this.semanticWork += 1;
        try {
          const vector = await this.semanticClient.embed(entry.text, this.semanticModel.language, this.semanticAbort.signal);
          if (generation !== this.semanticGeneration) return;
          if (!this.admitSemanticVector(item.id, document, entry, vector)) return;
        } catch {
          if (this.semanticAbort.signal.aborted) return;
          this.semanticCoverage = "partial";
          return;
        }
      }
    }
    if (this.semanticCoverage === "indexing") this.semanticCoverage = "complete";
  }

  private async loadDocument(sessionId: string): Promise<SearchDocument | undefined> {
    try {
      const cut = await this.sessions.readSearchCut(sessionId);
      const boundary = cut.forkBoundary;
      const branch = validateSearchBranch(cut.entries, boundary, cut.leafEntryId);
      const texts = new Map<string, SearchTextEntry>();
      const entries = branch.entries.flatMap((entry, ordinal) => {
        const text = extractSearchText(entry, ordinal);
        if (text) texts.set(text.id, text);
        return text ? [text] : [];
      });
      // The branch digest is derived state too: changing what it covers (the
      // entries, their order, or their projection) requires bumping
      // SESSION_SEARCH_INDEX_DERIVATION_VERSION in session-search-index.ts.
      const branchDigest = digest(branch.entries);
      const fileIdentity = cut.fileIdentity ?? createHash("sha256").update(branchDigest).digest("hex");
      return {
        sessionId, title: typeof cut.summary.name === "string" && cut.summary.name.trim() ? cut.summary.name.trim() : cut.summary.firstMessage.slice(0, 80), cwd: cut.summary.cwd,
        updatedAt: cut.summary.modified instanceof Date ? cut.summary.modified.toISOString() : String(cut.summary.modified), fileIdentity, branchDigest, ...(branch.leafEntryId ? { leafEntryId: branch.leafEntryId } : {}), ...(boundary ? { forkBoundary: boundary } : {}), ...(cut.runtimeGeneration ? { runtimeGeneration: cut.runtimeGeneration } : {}), entries, texts,
      };
    } catch {
      return undefined;
    }
  }

  private isMetadata(value: { dimension: number; language: string; modelRevision: string }): boolean {
    return Number.isSafeInteger(value.dimension) && value.dimension > 0 && value.language.length > 0 && value.modelRevision.length > 0;
  }

  private isEmbedding(value: { vector: number[]; dimension: number; language: string; modelRevision: string }): boolean {
    return this.isMetadata(value) && value.vector.length === value.dimension && value.vector.every(Number.isFinite);
  }

  private matches(text: string, query: string): boolean {
    const normalizedText = normalizeForSearch(text);
    const normalizedQuery = normalizeForSearch(query);
    if (normalizedText.includes(normalizedQuery)) return true;
    return normalizedQuery.split(/\s+/u).every((term: string) => normalizedText.includes(term));
  }
}
