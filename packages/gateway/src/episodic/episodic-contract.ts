import type { Api, AssistantMessage, Model } from "@earendil-works/pi-ai";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
/*
 * The episodic memory is the projected-summary tree of the OptChat recipe: a
 * binary tree of one-line summaries over one source session, a soft-budgeted
 * view of the tree, and a background pump that builds nodes. The recipe's
 * sections are cited as "gist §N" throughout this module. This file owns the
 * values and shapes shared by its parts. The recipe's constants are the
 * production defaults; every one of them is injectable because the tests need a
 * small tree and a fast retry.
 */

/** The kinds Tron projects into the memory. They are the compactor prompt's
 * vocabulary and the prefix of a level-0 free node (gist §2, §3). */
export type EpisodicMessageKind = "user" | "talk" | "echo" | "event";

export interface EpisodicLimits {
  /** Target size of one summary line (gist `NODE`). */
  nodeBytes: number;
  /** Byte budget of the view (gist `VIEW`); soft, see `fitView`. */
  viewBytes: number;
  /** Compactor calls in flight at once (gist `JOBS`). */
  jobs: number;
  /** Attempts per node to get its line under `nodeBytes` (gist `TRIES`). */
  tries: number;
  /** Max characters of one projected tool result (gist `CAP`). */
  capChars: number;
  /** Characters of the tail kept when a text is capped; the head keeps the rest. */
  capTailChars: number;
  /** Max characters of one projected user, assistant or event text. The recipe
   * sends those whole; a memory record must still fit its store's line, so this
   * is the store bound, not a model-input bound (a JSON string can expand to
   * six bytes per character, and the record carries the digests around it). */
  recordCapChars: number;
  /** Wait before retrying a transiently failed node (gist `RETRY`). */
  retryMs: number;
  /** Transient retries per compactor call before the node blocks. The recipe
   * retries forever because its next turn waits on the summary; here a blocked
   * memory is visible state and `resume()` restarts it, so the retries are
   * bounded. */
  maxRetries: number;
  /** Bound on one compactor call before it is abandoned as transient. A call
   * that never returns would hold its build slot forever: the pump would neither
   * block nor retry, and every turn waiting on that node would wait for the life
   * of the process. 0 disables the bound (tests that drive the pump by hand). */
  compactorTimeoutMs: number;
  /** One canonical JSONL line larger than this refuses the read. */
  maxSourceLineBytes: number;
  /** One stored JSONL record larger than this refuses the store. */
  maxStoreLineBytes: number;
}

/** Production defaults equal the recipe's table (gist §1). */
export const EPISODIC_DEFAULTS: Readonly<EpisodicLimits> = {
  nodeBytes: 512,
  viewBytes: 128_000,
  jobs: 8,
  tries: 5,
  capChars: 30_000,
  capTailChars: 4_000,
  // 128 Ki characters: six bytes per character of JSON escaping plus the record
  // around it stays under the one-megabyte store line bound.
  recordCapChars: 128 * 1_024,
  retryMs: 10_000,
  maxRetries: 3,
  // The recipe has no such bound: its compactor retries forever because its next
  // turn waits on the summary and it never gives up. Here a blocked memory is
  // visible state with an operator resume, so a call that is simply gone has to
  // become a block instead of an unbounded wait.
  compactorTimeoutMs: 120_000,
  maxSourceLineBytes: 16 * 1_024 * 1_024,
  maxStoreLineBytes: 1_024 * 1_024,
};

/** Version of every persisted episodic document. */
export const EPISODIC_STORE_VERSION = 2 as const;

/** How many revoked nodes one invalidation record carries. The record is
 * written once per chunk in ancestor-first order, so any prefix of a batch
 * leaves a consistent store. */
export const EPISODIC_INVALIDATION_CHUNK = 2_048;

/** What a level-0 node whose message is not a message any more shows. */
export const EPISODIC_OMITTED_TEXT = "[omitted]";
/** How the view renders a part whose node is not built (gist §6). */
export const EPISODIC_PLACEHOLDER = "(not summarized yet: zoom it)";

/* The memory's own search (Tron's addition to the recipe, docs/episodic-memory.md):
 * one case-insensitive substring pass over the projected catalog. */

/** Longest accepted search query, in characters. */
export const EPISODIC_SEARCH_QUERY_CHARS = 200;
/** Most hits one search returns; the match count still covers the whole range. */
export const EPISODIC_SEARCH_HITS = 20;
/** Bound on one hit's snippet, in characters, including its truncation marks. */
export const EPISODIC_SEARCH_SNIPPET_CHARS = 300;

export type EpisodicBlockedReason =
  | "permanent-failure"
  | "retries-exhausted"
  | "source-unavailable";

export interface EpisodicBlocked {
  reason: EpisodicBlockedReason;
  detail?: string;
}

export type EpisodicErrorKind =
  | "blocked"
  | "closed"
  | "invalid-store"
  | "unsafe-store"
  | "source"
  | "invalid-request"
  | "already-open";

/** One error type for every refusal this module makes, so a caller can tell a
 * visible refusal (invalid store, unsafe directory, a second opener) from a
 * blocked memory. */
export class EpisodicMemoryError extends Error {
  constructor(readonly kind: EpisodicErrorKind, message: string) {
    super(message);
    this.name = "EpisodicMemoryError";
  }
}

/**
 * One canonical session entry, projected (departure 1 of the brief): the
 * memory never holds canonical text, only this bounded projection.
 */
export interface EpisodicMessageRecord {
  /** Store-wide monotonic sequence; the latest record for an index wins. */
  revision: number;
  /** Permanent index in this memory; never renumbered. */
  index: number;
  sessionId: string;
  entryId: string;
  kind: EpisodicMessageKind;
  /** Projected text without the kind prefix. `[omitted]` when omitted. */
  text: string;
  /** sha256 of the canonical entry's JSON line as it was read. */
  sourceDigest: string;
  /** sha256 of `text`. */
  projectedDigest: string;
  /** Why content was left out: `thinking`, `attachment`, `capped`,
   * `record-cap`, `credentials`, `context-edit`, `off-branch`, `empty`,
   * `unsupported-part`. */
  omissions: string[];
  /** The entry contributes no text of its own (a null context edit, or a
   * navigation that left the branch). Never sent to the model. */
  omitted: boolean;
  /** The canonical entry's instant. Absent on a record written before this
   * field existed: `entryTimestamp` reads the source for it instead. */
  timestamp?: string;
}

/**
 * One run of the view lines a node's compactor call was given: `[level, count]`
 * in view order. The view tiles from message 0, so the run list reconstructs
 * every address exactly and stays bounded by the number of level changes
 * instead of growing with the view.
 */
export type EpisodicContextRun = readonly [level: number, count: number];

/** One node of the binary tree (gist §3). */
export interface EpisodicNodeRecord {
  revision: number;
  level: number;
  index: number;
  kind: "free" | "summary";
  text: string;
  /** Revisions of the two children a merge was built from. */
  childRevisions?: readonly [number, number];
  /** The context runs of this node's compactor call. Empty for a free node,
   * which made no call. */
  contextRuns: readonly EpisodicContextRun[];
  textDigest: string;
  /** sha256 of the child texts (merge) or the source message text (leaf). */
  sourceDigest: string;
}

/**
 * Append-only revocation, one record per chunk of one invalidation. Addresses
 * are encoded as space-separated base-36 codes (see `encodeNodeCode`), and the
 * chunks are written ancestor-first, so a crash between chunks leaves a
 * consistent store: every live parent still has live children.
 */
export interface EpisodicInvalidationRecord {
  revision: number;
  generation: number;
  /** Zero-based chunk number and the chunk count of this invalidation. */
  part: number;
  parts: number;
  nodes: string;
}

export type EpisodicNodeLogRecord = EpisodicNodeRecord | EpisodicInvalidationRecord;

export function isInvalidationRecord(record: EpisodicNodeLogRecord): record is EpisodicInvalidationRecord {
  return (record as EpisodicInvalidationRecord).nodes !== undefined;
}

/** Where the canonical reader stopped, and the identity of the file it read, so
 * the next read can continue at the offset when the file only grew. */
export interface EpisodicChapterSourceCursor {
  sessionId: string;
  dev: number;
  ino: number;
  size: number;
  completeBytes: number;
  leafEntryId: string | null;
  leafLineDigest: string | null;
  completePrefixDigest?: string | null;
}

export interface EpisodicSourceCursor {
  dev: number;
  ino: number;
  size: number;
  completeBytes: number;
  leafEntryId: string | null;
  /** Ordered canonical chapter cursors for a stable Home namespace. */
  home?: { ledgerRevision: number; chapters: EpisodicChapterSourceCursor[] };
  /** sha256 chain over every complete source line through this cursor. */
  completePrefixDigest?: string | null;
  /** sha256 of the last complete line's JSON text, so an in-place rewrite of
   * the prefix is detected by the window read before the offset. */
  leafLineDigest: string | null;
}

export interface EpisodicStoreState {
  version: typeof EPISODIC_STORE_VERSION;
  generation: number;
  cursor: EpisodicSourceCursor | null;
  blocked: EpisodicBlocked | null;
  /** Tokens this memory's compactor calls have spent, over the whole life of the
   * store. Reported, never a ceiling (#493); a restart must not reset it. */
  spend: number;
}

export interface EpisodicViewPartStatus {
  address: string;
  start: number;
  messages: number;
  bytes: number;
  built: boolean;
}

/** The bounded status query (departure 6). `view.parts` is capped and reports
 * how many it left out, so the object cannot grow with the history. */
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
  /** Spend, reported and never a ceiling (#493). */
  tokens: {
    used: number;
    /** What the provider reported since this memory opened, so caching can be
     * checked from its own usage fields (gist §8); not persisted. */
    sinceOpen: EpisodicUsage;
  };
}

export interface EpisodicUsage { input: number; output: number; cacheRead: number; cacheWrite: number }

/** The bounded view-part list status returns; more parts than this are counted
 * but not listed. A production view holds ~250 parts, so this is headroom. */
export const EPISODIC_STATUS_PARTS = 1_024;

/** One compactor conversation (gist §4.2, §4.3). The step is the last turn. */
export interface EpisodicCompactorRequest {
  /** The COMPACT prompt (gist §4.4), constant for every call. */
  system: string;
  /** Alternating turns: the step, the reply, the size feedback, the reply. */
  turns: Array<{ role: "user" | "assistant"; text: string }>;
  signal: AbortSignal;
  /** The start of the first turn that consecutive calls share: the context
   * block (gist §8, "the compactor calls share their <chat> prefix"). */
  cachePrefix: string;
  /** Stable for one memory, so a provider routes its calls to one cache. */
  cacheKey: string;
}

/** Runs one compactor conversation on the injected model. The default
 * implementation uses `ModelRuntime.completeSimple`. */
export type EpisodicSummarizer = (request: EpisodicCompactorRequest) => Promise<AssistantMessage>;

export interface EpisodicDiagnostic {
  event: "episodic.source-invalidated" | "episodic.source-read-retried" | "episodic.node-blocked" | "episodic.store-refused" | "episodic.store-recovered";
  level: "info" | "warning" | "error";
  message: string;
  counts?: Record<string, number>;
  reason?: string;
}

/** Either the caller injects its own compactor, or it names the model and
 * runtime the default compactor runs on. There is no default model. */
export type EpisodicCompactorDependency =
  | { summarizer: EpisodicSummarizer; modelRuntime?: never; model?: never }
  | { summarizer?: undefined; modelRuntime: ModelRuntime; model: Model<Api> };

export type EpisodicMemoryDependencies = {
  workspace: import("../workspace/tron-workspace.js").TronWorkspace;
  /** The canonical session this memory is over; also its store namespace. */
  sessionId: string;
  /** The canonical session JSONL path. Read only, never repaired. */
  sessionFile: string;
  /** Ordered canonical source for a multi-chapter Home namespace. */
  sessionSource?: (cursor: EpisodicSourceCursor | null) => Promise<import("./episodic-source.js").EpisodicCanonicalCut>;
  limits?: Partial<EpisodicLimits>;
  /** Where this module raises its bounded records; the caller (gateway-main)
   * decides whether to persist them. */
  diagnostic?: (record: EpisodicDiagnostic) => void;
  /** Injectable wait, so tests do not sleep through the retry delay. */
  sleep?: (ms: number, signal: AbortSignal) => Promise<void>;
} & EpisodicCompactorDependency;

export function resolveLimits(overrides?: Partial<EpisodicLimits>): EpisodicLimits {
  const limits = { ...EPISODIC_DEFAULTS, ...overrides };
  for (const [name, value] of Object.entries(limits)) {
    if (!Number.isSafeInteger(value) || value < 0) throw new EpisodicMemoryError("invalid-request", `Episodic limit ${name} must be a non-negative integer`);
  }
  for (const name of ["nodeBytes", "viewBytes", "jobs", "tries", "recordCapChars", "maxSourceLineBytes", "maxStoreLineBytes"] as const) {
    if (limits[name] === 0) throw new EpisodicMemoryError("invalid-request", `Episodic limit ${name} must be positive`);
  }
  return limits;
}

/** The one wait used by the retry loop; the injected one is for tests. */
export function defaultSleep(ms: number, signal: AbortSignal): Promise<void> {
  if (signal.aborted) return Promise.reject(new EpisodicMemoryError("closed", "Episodic memory is closing"));
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      signal.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    const onAbort = () => {
      clearTimeout(timer);
      reject(new EpisodicMemoryError("closed", "Episodic memory is closing"));
    };
    signal.addEventListener("abort", onAbort, { once: true });
  });
}
