import { EpisodicMemoryError } from "../errors.js";
import { CANONICAL_SOURCE_MAX_LINE_BYTES } from "../kernel/resources/prompt-bounds.js";
import type { AssistantMessage } from "../kernel/pi/ai.js";

export type EpisodicMessageKind = "user" | "talk" | "echo" | "event";

export interface EpisodicLimits {
  nodeBytes: number;
  viewBytes: number;
  jobs: number;
  recordCapChars: number;
  retryMs: number;
  maxRetries: number;
  compactorTimeoutMs: number;
  maxSourceLineBytes: number;
  maxStoreLineBytes: number;
}

export const EPISODIC_DEFAULTS: Readonly<EpisodicLimits> = {
  nodeBytes: 512,
  viewBytes: 128_000,
  jobs: 8,
  recordCapChars: 128 * 1_024,
  retryMs: 10_000,
  maxRetries: 3,
  compactorTimeoutMs: 120_000,
  maxSourceLineBytes: CANONICAL_SOURCE_MAX_LINE_BYTES,
  maxStoreLineBytes: 1_024 * 1_024,
};

export const EPISODIC_TRIES = 5;
export const EPISODIC_CAP_CHARS = 30_000;
export const EPISODIC_CAP_TAIL_CHARS = 4_000;

export const HOME_MAX_CHAPTERS = 100_000;

export const EPISODIC_HOME_CURSOR_MAX_BYTES = 640;
export const EPISODIC_STATE_MAX_BYTES = HOME_MAX_CHAPTERS * EPISODIC_HOME_CURSOR_MAX_BYTES + 64 * 1_024;

export const EPISODIC_STORE_VERSION = 2 as const;

export const EPISODIC_INVALIDATION_CHUNK = 2_048;

export const EPISODIC_OMITTED_TEXT = "[omitted]";
export const EPISODIC_PLACEHOLDER = "(not summarized yet: zoom it)";

export const EPISODIC_SEARCH_QUERY_CHARS = 200;
export const EPISODIC_SEARCH_HITS = 20;
export const EPISODIC_SEARCH_SNIPPET_CHARS = 300;

export type EpisodicBlockedReason =
  | "permanent-failure"
  | "retries-exhausted"
  | "usage-limit"
  | "source-unavailable";

export interface EpisodicBlocked {
  reason: EpisodicBlockedReason;
  detail?: string;
}

export interface EpisodicMessageRecord {
  revision: number;
  index: number;
  sessionId: string;
  entryId: string;
  kind: EpisodicMessageKind;
  text: string;
  sourceDigest: string;
  projectedDigest: string;
  omissions: string[];
  omitted: boolean;
  timestamp: string;
}

export type EpisodicContextRun = readonly [level: number, count: number];

export interface EpisodicNodeRecord {
  revision: number;
  level: number;
  index: number;
  kind: "free" | "summary";
  text: string;
  childRevisions?: readonly [number, number];
  contextRuns: readonly EpisodicContextRun[];
  textDigest: string;
  sourceDigest: string;
}

export interface EpisodicInvalidationRecord {
  revision: number;
  generation: number;
  part: number;
  parts: number;
  nodes: string;
}

export type EpisodicNodeLogRecord = EpisodicNodeRecord | EpisodicInvalidationRecord;

export interface EpisodicChapterSourceCursor {
  sealed: boolean;
  mtimeMs: number;
  ctimeMs: number;
  sessionId: string;
  dev: number;
  ino: number;
  size: number;
  completeBytes: number;
  leafEntryId: string | null;
  leafLineDigest: string | null;
  completePrefixDigest: string;
}

export interface EpisodicSourceCursor {
  completeBytes: number;
  leafEntryId: string | null;
  home: { version: 2; ledgerRevision: number; chapters: EpisodicChapterSourceCursor[] };
  completePrefixDigest: string;
}

export interface EpisodicStoreState {
  version: typeof EPISODIC_STORE_VERSION;
  generation: number;
  cursor: EpisodicSourceCursor | null;
  blocked: EpisodicBlocked | null;
  spend: number;
}

export interface EpisodicViewPartStatus {
  address: string;
  start: number;
  messages: number;
  bytes: number;
  built: boolean;
}

export interface EpisodicMemoryStatus {
  sourceSessionId: string;
  generation: number;
  messages: number;
  nodes: { total: number; free: number; summary: number; byLevel: Array<{ level: number; count: number }> };
  view: {
    parts: EpisodicViewPartStatus[];
    truncatedParts: number;
    bytes: number;
    budgetBytes: number;
    built: number;
    unbuilt: number;
  };
  coverage: { admitted: number; summarized: number };
  pump: { busy: number };
  blocked: EpisodicBlocked | null;
  tokens: {
    used: number;
    sinceOpen: EpisodicUsage;
  };
}

export interface EpisodicUsage { input: number; output: number; cacheRead: number; cacheWrite: number }

export const EPISODIC_STATUS_PARTS = 1_024;

export interface EpisodicCompactorRequest {
  system: string;
  turns: Array<{ role: "user" | "assistant"; text: string }>;
  signal: AbortSignal;
  cacheKey: string;
}

export type EpisodicSummarizer = (request: EpisodicCompactorRequest) => Promise<AssistantMessage>;

export interface EpisodicDiagnostic {
  event: "episodic.source-invalidated" | "episodic.source-read-retried" | "episodic.node-blocked" | "episodic.store-refused" | "episodic.store-recovered";
  level: "info" | "warning" | "error";
  message: string;
  counts?: Record<string, number>;
  reason?: string;
}

export interface EpisodicSessionSource {
  read(cursor: EpisodicSourceCursor | null, limits: EpisodicLimits): AsyncIterable<import("./episodic-projection.js").EpisodicSourceDelta>;
  branchAtCursor(cursor: EpisodicSourceCursor, limits: EpisodicLimits): AsyncIterable<{ id: string; sourceSessionId: string }>;
}

export interface EpisodicMemoryDependencies {
  workspace: import("../workspace/tron-workspace.js").TronWorkspace;
  sessionId: string;
  sessionSource: EpisodicSessionSource;
  summarizer: EpisodicSummarizer;
  isPaused?: () => boolean;
  limits?: Partial<EpisodicLimits>;
  diagnostic?: (record: EpisodicDiagnostic) => void;
}

export function resolveLimits(overrides?: Partial<EpisodicLimits>): EpisodicLimits {
  const limits = { ...EPISODIC_DEFAULTS, ...overrides };
  for (const [name, value] of Object.entries(limits)) {
    if (!Number.isSafeInteger(value) || value < 0) throw new EpisodicMemoryError("invalid-request", `Episodic limit ${name} must be a non-negative integer`);
  }
  for (const name of ["nodeBytes", "viewBytes", "jobs", "recordCapChars", "compactorTimeoutMs", "maxSourceLineBytes", "maxStoreLineBytes"] as const) {
    if (limits[name] === 0) throw new EpisodicMemoryError("invalid-request", `Episodic limit ${name} must be positive`);
  }
  return limits;
}
