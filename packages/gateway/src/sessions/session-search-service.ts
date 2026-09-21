import { createHash, randomUUID } from "node:crypto";
import type { FileEntry } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import { JevEvaluationError, type JevDecisionClient } from "../knowledge/jev-client.js";
import { NaturalLanguageEmbeddingClient } from "./session-search-embedding.js";
import type { RuntimeRegistry } from "./runtime-registry.js";
import {
  boundedQuery,
  boundedResults,
  digest,
  type SessionSearchAnchorRequest,
  type SessionSearchAnchorResponse,
  type SessionSearchPolicy,
  type SessionSearchRequest,
  type SessionSearchResponse,
  normalizeForSearch,
  stableSearchResultOrder,
  type SessionSearchResult,
} from "./session-search-contract.js";
import { SessionSearchAllowanceLedger } from "./session-search-allowance.js";
import { SessionSearchIndex, type SearchIndexDocument } from "./session-search-index.js";
import { excerpt, extractSearchText, validateSearchBranch, type SearchTextEntry } from "./session-search-text.js";

const SEARCH_CANDIDATE_LIMIT = 500;
const MAX_SEMANTIC_VECTORS = 100_000;
const MAX_SEMANTIC_BYTES = 128 * 1_024 * 1_024;
const MAX_SEMANTIC_WORK = 20_000;
const MAX_DIRTY_SESSIONS = 256;
const DEFAULT_POLICY: SessionSearchPolicy = { enabled: false, perQueryMicroCents: 0, dailyMicroCents: 0, policyRevision: 1 };

async function awaitWithAbort<T>(promise: Promise<T>, signal?: AbortSignal): Promise<T> {
  if (!signal) return promise;
  if (signal.aborted) throw new GatewayError("cancelled", "Search cancelled", true);
  return await new Promise<T>((resolve, reject) => {
    const abort = () => reject(new GatewayError("cancelled", "Search cancelled", true));
    signal.addEventListener("abort", abort, { once: true });
    void promise.then(value => { signal.removeEventListener("abort", abort); resolve(value); }, error => { signal.removeEventListener("abort", abort); reject(error); });
  });
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
}
export interface SessionSearchEmbeddingClient {
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
  private policy: SessionSearchPolicy = DEFAULT_POLICY;
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
  private searchCutGeneration = 0;
  private readonly semanticAbort = new AbortController();
  private semanticBytes = 0;
  private semanticWork = 0;
  private dirtyOverflow = false;

  constructor(
    private readonly sessions: RuntimeRegistry,
    private readonly index: SessionSearchIndex,
    private readonly jev?: JevDecisionClient,
    private readonly allowance?: SessionSearchAllowanceLedger,
    semanticClient?: SessionSearchEmbeddingClient,
  ) {
    this.semanticClient = semanticClient ?? (process.env.TRON_SEARCH_EMBEDDING_HELPER ? new NaturalLanguageEmbeddingClient(process.env.TRON_SEARCH_EMBEDDING_HELPER) : undefined);
    if (this.allowance) this.policy = this.allowance.readPolicy();
    this.sessions.setSearchInvalidator((sessionID, nextSessionID) => {
      this.searchCutGeneration += 1;
      this.semanticGeneration += 1;
      this.index.remove(sessionID);
      for (const key of this.semanticVectors.keys()) if (key.startsWith(`${sessionID}\u0000`)) this.semanticVectors.delete(key);
      this.semanticTotal = this.semanticVectors.size;
      this.semanticBytes = [...this.semanticVectors.values()].reduce((sum, value) => sum + value.vector.length * Float64Array.BYTES_PER_ELEMENT, 0);
      if (nextSessionID) {
        this.index.remove(nextSessionID);
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

  setSemanticClient(client: SessionSearchEmbeddingClient): void {
    if (!this.semanticClient) {
      this.semanticClient = client;
      if (this.initialized) this.startSemanticIndexing();
    }
  }

  setPolicy(policy: SessionSearchPolicy): void {
    if (!Number.isSafeInteger(policy.perQueryMicroCents) || policy.perQueryMicroCents < 0 || !Number.isSafeInteger(policy.dailyMicroCents) || policy.dailyMicroCents < 0) {
      throw new GatewayError("invalid_request", "Invalid session-search Jev allowance");
    }
    const nextRevision = (this.allowance?.readPolicy().policyRevision ?? this.policy.policyRevision) + 1;
    const nextPolicy = { ...policy, policyRevision: nextRevision };
    this.policy = this.allowance ? this.allowance.writePolicy(nextPolicy) : nextPolicy;
  }

  getPolicy(): SessionSearchPolicy { return { ...this.policy }; }

  async warm(): Promise<void> {
    await this.initialize();
    this.startSemanticIndexing();
  }

  async initialize(signal?: AbortSignal): Promise<void> {
    if (this.initialized) return;
    if (!this.initializing) this.initializing = this.rebuild().finally(() => { this.initializing = undefined; this.startSemanticIndexing(); });
    await awaitWithAbort(this.initializing, signal);
    this.initialized = true;
  }

  async search(request: SessionSearchRequest, signal?: AbortSignal): Promise<SessionSearchResponse> {
    const query = boundedQuery(request.query);
    const maxResults = boundedResults(request.maxResults);
    await this.initialize(signal);
    if (signal?.aborted) throw new GatewayError("cancelled", "Search cancelled", true);
    await this.refreshDirty(signal);
    const publicationGeneration = this.searchCutGeneration;
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
        sessionId: candidate.sessionId, title: candidate.title, cwd: candidate.cwd, updatedAt: candidate.updatedAt,
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
          results.push({ sessionId: hit.sessionId, title: document.title, cwd: document.cwd, updatedAt: document.updatedAt, entryId: entry.id, ...(entry.parentId ? { parentEntryId: entry.parentId } : {}), ordinal: entry.ordinal, passageKind: entry.role, snippet: excerpt(entry.text, query), lexicalScore: 0, semanticScore: hit.score, anchorRevision: { indexRevision: this.index.stats().indexRevision, fileIdentity: document.fileIdentity, branchDigest: document.branchDigest, ...(document.leafEntryId ? { leafEntryId: document.leafEntryId } : {}), entryOrdinal: entry.ordinal, ...(document.forkBoundary ? { forkBoundary: document.forkBoundary } : {}) } });
        }
      } catch (error) {
        if (signal?.aborted) throw error;
        semanticHits = [];
        this.semanticCoverage = "partial";
      }
    }
    results.sort(stableSearchResultOrder);
    results.splice(maxResults * 4);
    let rankingState: SessionSearchResponse["ranking"]["state"] = semanticHits.length > 0 ? "localSemantic" : "lexical";
    let jevState: SessionSearchResponse["ranking"]["jev"] = request.remoteRanking ? "consentRequired" : "disabled";
    if (request.remoteRanking && request.remoteConsent && this.jev && this.policy.enabled && results.length > 0) {
      const usageDay = new Date().toISOString().slice(0, 10);
      const reservedMicroCents = 268_800; // 64k tokens * $0.042/M, expressed in 1e-6 cents.
      const requestID = randomUUID();
      let dispatched = false;
      let reservation: { requestID: string; day: string; reservedMicroCents: number } | undefined;
      try {
        const decisionPromise = this.jev.evaluate(
          { state: { query, candidates: results.slice(0, 16).map((result, index) => ({ id: `r${index}`, text: result.snippet })) }, questions: Object.fromEntries(results.slice(0, 16).map((result, index) => [`r${index}`, { type: "score" as const, instructions: `How relevant is this passage to the search query? Query: ${query} Passage: ${result.snippet}`, criteria: ["irrelevant", "relevant", "direct answer"] as [string, string, string] }])) },
          signal ?? new AbortController().signal,
          {
            maxChargeCents: this.policy.perQueryMicroCents / 1_000_000,
            beforeDispatch: async () => {
              if (!this.allowance || this.policy.perQueryMicroCents < reservedMicroCents) throw new Error("Jev allowance is unavailable or below the bounded request reserve");
              reservation = this.allowance.reserve(requestID, usageDay, reservedMicroCents, this.policy.dailyMicroCents, this.policy.policyRevision);
              if (!reservation) throw new Error("Jev daily allowance is exhausted");
            },
            onDispatch: () => {
              const live = this.allowance?.readPolicy();
              if (!live || !live.enabled || live.policyRevision !== this.policy.policyRevision || live.perQueryMicroCents < reservedMicroCents || live.dailyMicroCents !== this.policy.dailyMicroCents) throw new JevEvaluationError("Jev policy changed before dispatch", "notSent");
              dispatched = true;
            },
          },
        );
        const decision = await awaitWithAbort(decisionPromise, signal);
        const ranked = results.slice(0, 16);
        for (const [key, answer] of Object.entries(decision.answers)) {
          const index = Number(key.slice(1));
          const result = ranked[index];
          if (result && answer.type === "score") result.jevScore = answer.score / 2;
        }
        if (reservation) this.allowance?.settle(reservation.requestID, Math.ceil(decision.estimatedCostCents * 1_000_000));
        rankingState = "jev";
        jevState = undefined;
      } catch (error) {
        if (reservation && !dispatched) this.allowance?.settle(reservation.requestID, 0);
        rankingState = error instanceof Error && /allowance|daily limit/iu.test(error.message) ? "budgetLimited" : "jevUnavailable";
        jevState = dispatched || (error instanceof JevEvaluationError && error.certainty === "uncertain")
          ? "uncertain"
          : "consentRequired";
      }
    }
    results.sort((left, right) => (right.jevScore ?? -1) - (left.jevScore ?? -1) || (right.semanticScore ?? -1) - (left.semanticScore ?? -1) || stableSearchResultOrder(left, right));
    results.splice(maxResults);
    if (publicationGeneration !== this.searchCutGeneration) throw new GatewayError("conflict", "Canonical session changed during search; rerun search");
    const stats = this.index.stats();
    return {
      query, queryRevision: digest({ query, maxResults }), corpusRevision: this.corpusRevision, indexRevision: stats.indexRevision,
      coverage: { state: this.coverageOmittedSessions > 0 || stats.state === "partial" ? "partial" : stats.state, sessionsIndexed: stats.sessionsIndexed, sessionsTotal: this.coverageSessionsTotal, passagesIndexed: stats.passagesIndexed, omittedSessions: this.coverageOmittedSessions, ...(this.coverageReason ? { reason: this.coverageReason } : {}) },
      semantic: { state: this.semanticCoverage === "complete" ? "ready" : this.semanticCoverage, ...(this.semanticModel ? { modelRevision: this.semanticModel.modelRevision, language: this.semanticModel.language, dimension: this.semanticModel.dimension } : {}), vectorsIndexed: this.semanticVectors.size, vectorsTotal: this.semanticTotal, ...((this.semanticCoverage === "unavailable" || this.semanticCoverage === "unsupportedLanguage") ? { reason: this.semanticReason ?? "The signed NaturalLanguage helper is unavailable or not qualified" } : {}) },
      ranking: { state: rankingState, ...(jevState ? { jev: jevState } : {}) },
      results,
    };
  }

  async anchor(request: SessionSearchAnchorRequest, signal?: AbortSignal): Promise<SessionSearchAnchorResponse> {
    await this.initialize(signal);
    if (signal?.aborted) throw new GatewayError("cancelled", "Search navigation cancelled", true);
    const cut = await awaitWithAbort(this.sessions.readSearchCut(request.sessionId), signal);
    const validated = validateSearchBranch(cut.entries, cut.forkBoundary, cut.leafEntryId);
    const currentDigest = digest(validated.entries);
    if (request.anchorRevision.fileIdentity && cut.fileIdentity && request.anchorRevision.fileIdentity !== cut.fileIdentity
      || request.anchorRevision.branchDigest && request.anchorRevision.branchDigest !== currentDigest) {
      throw new GatewayError("conflict", "Search result is stale; rerun search");
    }
    const entryIndex = validated.entries.findIndex(entry => entry.id === request.entryId);
    if (entryIndex < 0) throw new GatewayError("not_found", "Search entry is no longer on the active branch");
    if (request.expectedLeafEntryId && request.expectedLeafEntryId !== validated.leafEntryId) throw new GatewayError("conflict", "Session leaf changed; rerun search");
    const requestedEnd = request.windowEnd === undefined ? undefined : request.windowEnd;
    const page = await awaitWithAbort(this.sessions.readSearchTranscriptPageAtEntry(request.sessionId, request.entryId, request.expectedRuntimeGeneration, request.expectedLeafEntryId, requestedEnd), signal);
    if (!page.items.some(item => item.id === request.entryId)) throw new GatewayError("not_found", "Search entry is not projectable on the active transcript");
    return {
      sessionId: request.sessionId, entryId: request.entryId, start: page.start, end: page.end, total: page.total,
      items: page.items as unknown as SessionSearchAnchorResponse["items"], targetOrdinal: page.items.findIndex(item => item.id === request.entryId) + page.start,
      hasEarlier: page.start > 0, hasLater: page.end < page.total,
      ...(page.runtimeGeneration ? { runtimeGeneration: page.runtimeGeneration } : {}), ...(page.leafEntryId ? { leafEntryId: page.leafEntryId } : {})
    };
  }

  async close(): Promise<void> {
    this.sessions.setSearchInvalidator(() => {});
    this.semanticAbort.abort();
    if (this.semanticTask) await this.semanticTask.catch(() => {});
    if (this.dirtyRefresh) await this.dirtyRefresh.catch(() => {});
    await this.semanticTail.catch(() => {});
    this.index.close();
    this.allowance?.close();
  }

  private async rebuild(): Promise<void> {
    this.index.clear();
    this.semanticVectors.clear();
    this.semanticTotal = 0;
    this.semanticBytes = 0;
    this.semanticWork = 0;
    this.semanticQualified = false;
    this.semanticModel = undefined;
    this.semanticReason = undefined;
    this.semanticCoverage = this.semanticClient ? "indexing" : "unavailable";
    const catalog = await this.sessions.catalog("user");
    this.coverageSessionsTotal = catalog.sessions.length;
    this.coverageOmittedSessions = 0;
    this.coverageReason = undefined;
    const corpusFacts: string[] = [];
    for (const session of catalog.sessions) {
      const document = await this.loadDocument(session.id);
      if (!document) { this.coverageOmittedSessions += 1; this.coverageReason = "One or more canonical sessions could not be admitted for search"; continue; }
      corpusFacts.push(`${document.sessionId}:${document.branchDigest}`);
      try { this.index.replace(document); }
      catch { this.coverageOmittedSessions += 1; this.coverageReason = "One or more sessions exceeded bounded search index capacity"; }
    }
    this.corpusRevision = digest(corpusFacts);
  }

  private startSemanticIndexing(): void {
    if (!this.semanticClient || this.semanticTask || this.semanticAbort.signal.aborted) return;
    this.semanticTask = this.enqueueSemantic(() => this.indexSemanticCorpus()).catch(error => {
      if (!this.semanticAbort.signal.aborted) { this.semanticCoverage = "partial"; this.semanticReason = error instanceof Error ? error.message : "Semantic indexing failed"; }
    }).finally(() => { this.semanticTask = undefined; });
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
    const catalog = await this.sessions.catalog("user");
    for (const session of catalog.sessions) {
      if (this.semanticAbort.signal.aborted || this.semanticWork >= MAX_SEMANTIC_WORK || this.semanticVectors.size >= MAX_SEMANTIC_VECTORS || this.semanticBytes >= MAX_SEMANTIC_BYTES) { this.semanticCoverage = "partial"; break; }
      const document = await this.loadDocument(session.id);
      if (!document) continue;
      for (const entry of document.entries) {
        if (this.semanticAbort.signal.aborted) return;
        if (this.semanticWork >= MAX_SEMANTIC_WORK || this.semanticVectors.size >= MAX_SEMANTIC_VECTORS) { this.semanticCoverage = "partial"; return; }
        this.semanticWork += 1;
        try {
          const vector = await this.semanticClient.embed(entry.text, this.semanticModel?.language, this.semanticAbort.signal);
          if (generation !== this.semanticGeneration || !this.semanticModel || !this.isEmbedding(vector) || !sameSemanticGeneration(vector, this.semanticModel)) return;
          const bytes = vector.vector.length * Float64Array.BYTES_PER_ELEMENT;
          if (this.semanticBytes + bytes > MAX_SEMANTIC_BYTES) { this.semanticCoverage = "partial"; return; }
          this.semanticBytes += bytes;
          this.semanticVectors.set(`${document.sessionId}\u0000${entry.id}`, { vector: vector.vector, textDigest: digest(entry.text), branchDigest: document.branchDigest, fileIdentity: document.fileIdentity, generation: this.semanticModel });
          this.semanticTotal = this.semanticVectors.size;
        } catch (error) { if (this.semanticAbort.signal.aborted) return; this.semanticCoverage = "partial"; }
      }
    }
    this.semanticTotal = this.semanticVectors.size;
    if (this.semanticCoverage === "indexing") this.semanticCoverage = "complete";
  }

  private semanticHitsState(hits: readonly unknown[]): "lexical" | "localSemantic" { return hits.length > 0 ? "localSemantic" : "lexical"; }

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
            if (document) this.index.replace(document);
            else this.index.remove(id);
            refreshed.push({ id, generation: processedGeneration, ...(document ? { document } : {}) });
          } catch {
            this.index.remove(id);
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
          if (generation !== this.semanticGeneration || !this.semanticModel || !this.isEmbedding(vector) || !sameSemanticGeneration(vector, this.semanticModel)) return;
          const bytes = vector.vector.length * Float64Array.BYTES_PER_ELEMENT;
          if (this.semanticBytes + bytes > MAX_SEMANTIC_BYTES) { this.semanticCoverage = "partial"; return; }
          this.semanticBytes += bytes;
          this.semanticVectors.set(`${item.id}\u0000${entry.id}`, { vector: vector.vector, textDigest: digest(entry.text), branchDigest: document.branchDigest, fileIdentity: document.fileIdentity, generation: this.semanticModel });
          this.semanticTotal = this.semanticVectors.size;
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
      const branchDigest = digest(branch.entries);
      const fileIdentity = cut.fileIdentity ?? createHash("sha256").update(branchDigest).digest("hex");
      return {
        sessionId, title: typeof cut.summary.name === "string" && cut.summary.name.trim() ? cut.summary.name.trim() : cut.summary.firstMessage.slice(0, 80), cwd: cut.summary.cwd,
        updatedAt: cut.summary.modified instanceof Date ? cut.summary.modified.toISOString() : String(cut.summary.modified), fileIdentity, branchDigest, ...(branch.leafEntryId ? { leafEntryId: branch.leafEntryId } : {}), ...(boundary ? { forkBoundary: boundary } : {}), entries, texts,
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
