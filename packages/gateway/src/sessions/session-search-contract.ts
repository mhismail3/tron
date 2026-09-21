import { createHash } from "node:crypto";
import type { SessionSummary, JsonValue } from "../protocol/types.js";

export const SESSION_SEARCH_CAPABILITY = "session-search.v1" as const;
export const SESSION_SEARCH_MAX_QUERY_BYTES = 2_048;
export const SESSION_SEARCH_MAX_RESULTS = 50;
export const SESSION_SEARCH_MAX_PASSAGES_PER_SESSION = 5;
export const SESSION_SEARCH_MAX_SNIPPET_BYTES = 1_024;
export const SESSION_SEARCH_MAX_ENTRY_BYTES = 128 * 1_024;
export const SESSION_SEARCH_MAX_INDEX_BYTES = 512 * 1_024 * 1_024;
export const SESSION_SEARCH_MAX_INDEX_SESSIONS = 25_000;
export const SESSION_SEARCH_MAX_INDEX_PASSAGES = 1_000_000;

export type SessionSearchScope = "user";
export type SessionSearchCoverageState = "complete" | "indexing" | "partial" | "unavailable";
export type SessionSearchSemanticState = "ready" | "partial" | "indexing" | "unavailable" | "unsupportedLanguage" | "disabled";
export type SessionSearchRankingState = "lexical" | "localSemantic" | "jev" | "jevUnavailable" | "budgetLimited";

export interface SessionSearchAnchorRevision {
  indexRevision: string;
  fileIdentity: string;
  branchDigest: string;
  leafEntryId?: string;
  entryOrdinal: number;
  forkBoundary?: SessionSearchForkBoundary;
}

export interface SessionSearchForkBoundary {
  kind: "sessionFork" | "subagentFork";
  inheritedEntryId: string;
  gapOrdinal: number;
}

export interface SessionSearchResult {
  sessionId: string;
  gatewayProfileID?: string;
  title: string;
  cwd: string;
  updatedAt: string;
  entryId: string;
  parentEntryId?: string;
  ordinal: number;
  passageKind: "user" | "assistant";
  snippet: string;
  lexicalScore: number;
  semanticScore?: number;
  jevScore?: number;
  anchorRevision: SessionSearchAnchorRevision;
}

export interface SessionSearchCoverage {
  state: SessionSearchCoverageState;
  sessionsIndexed: number;
  sessionsTotal: number;
  passagesIndexed: number;
  omittedSessions: number;
  reason?: string;
}

export interface SessionSearchSemanticStatus {
  state: SessionSearchSemanticState;
  modelRevision?: string;
  language?: string;
  dimension?: number;
  vectorsIndexed: number;
  vectorsTotal: number;
  reason?: string;
}

export interface SessionSearchResponse {
  query: string;
  queryRevision: string;
  corpusRevision: string;
  indexRevision: string;
  coverage: SessionSearchCoverage;
  semantic: SessionSearchSemanticStatus;
  ranking: { state: SessionSearchRankingState; jev?: "disabled" | "notConfigured" | "consentRequired" | "uncertain" };
  results: SessionSearchResult[];
}

export interface SessionSearchRequest {
  query: string;
  scope?: SessionSearchScope;
  maxResults?: number;
  remoteRanking?: boolean;
  remoteConsent?: boolean;
}

export interface SessionSearchAnchorRequest {
  sessionId: string;
  entryId: string;
  anchorRevision: SessionSearchAnchorRevision;
  before?: number;
  expectedRuntimeGeneration?: string;
  expectedLeafEntryId?: string;
  windowStart?: number;
  windowEnd?: number;
}

export interface SessionSearchAnchorResponse {
  sessionId: string;
  entryId: string;
  start: number;
  end: number;
  total: number;
  items: JsonValue[];
  runtimeGeneration?: string;
  leafEntryId?: string;
  targetOrdinal?: number;
  hasEarlier?: boolean;
  hasLater?: boolean;
}

export interface SessionSearchPolicy {
  enabled: boolean;
  perQueryMicroCents: number;
  dailyMicroCents: number;
  policyRevision: number;
}

export function boundedQuery(raw: unknown): string {
  if (typeof raw !== "string") throw new Error("Search query must be a string");
  const query = raw.trim();
  if (!query || Buffer.byteLength(query, "utf8") > SESSION_SEARCH_MAX_QUERY_BYTES || /[\u0000-\u001f\u007f]/u.test(query)) {
    throw new Error("Search query is empty or exceeds its bound");
  }
  return query;
}

export function boundedResults(raw: unknown): number {
  if (raw === undefined) return 25;
  if (typeof raw !== "number" || !Number.isSafeInteger(raw) || raw < 1 || raw > SESSION_SEARCH_MAX_RESULTS) {
    throw new Error("Search result limit exceeds its bound");
  }
  return raw;
}

export function digest(value: unknown): string {
  return createHash("sha256").update(JSON.stringify(value)).digest("base64url");
}

export function normalizeForSearch(value: string): string {
  return value.normalize("NFKC").toLocaleLowerCase("und");
}

export function stableSearchResultOrder(left: SessionSearchResult, right: SessionSearchResult): number {
  const leftScore = left.jevScore ?? left.semanticScore ?? left.lexicalScore;
  const rightScore = right.jevScore ?? right.semanticScore ?? right.lexicalScore;
  const score = rightScore - leftScore;
  if (score !== 0) return score;
  const semantic = (right.semanticScore ?? -1) - (left.semanticScore ?? -1);
  if (semantic !== 0) return semantic;
  if (right.lexicalScore !== left.lexicalScore) return right.lexicalScore - left.lexicalScore;
  const updated = right.updatedAt.localeCompare(left.updatedAt);
  return updated || left.sessionId.localeCompare(right.sessionId) || left.entryId.localeCompare(right.entryId);
}

export function titleForSummary(summary: Pick<SessionSummary, "name" | "firstMessage">): string {
  const named = summary.name?.trim();
  if (named) return named;
  const first = summary.firstMessage.trim();
  return first ? first.slice(0, 80) : "New session";
}
