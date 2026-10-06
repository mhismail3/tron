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
  /** Wait before retrying a transiently failed node (gist `RETRY`). */
  retryMs: number;
  /** Transient retries per compactor call before the node blocks. The recipe
   * retries forever because its next turn waits on the summary; here a blocked
   * memory is visible state and `resume()` restarts it, so the retries are
   * bounded. */
  maxRetries: number;
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
  retryMs: 10_000,
  maxRetries: 3,
  maxSourceLineBytes: 16 * 1_024 * 1_024,
  maxStoreLineBytes: 1_024 * 1_024,
};

/** Version of every persisted episodic document. */
export const EPISODIC_STORE_VERSION = 1 as const;

/** What a level-0 node whose message is not a message any more shows. */
export const EPISODIC_OMITTED_TEXT = "[omitted]";
/** How the view renders a part whose node is not built (gist §6). */
export const EPISODIC_PLACEHOLDER = "(not summarized yet: zoom it)";

export type EpisodicBlockedReason =
  | "permanent-failure"
  | "retries-exhausted"
  | "budget-exhausted"
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
  | "invalid-request";

/** One error type for every refusal this module makes, so a caller can tell a
 * visible refusal (invalid store, unsafe directory) from a blocked memory. */
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
  /** Why content was left out: `thinking`, `attachment`, `capped`, `redacted`,
   * `context-edit`, `off-branch`. */
  omissions: string[];
  /** The entry contributes no text of its own (a null context edit, or a
   * navigation that left the branch). Never sent to the model. */
  omitted: boolean;
}

/** One node of the binary tree (gist §3), or the revocation of one. */
export interface EpisodicNodeRecord {
  revision: number;
  level: number;
  index: number;
  kind: "free" | "summary";
  text: string;
  /** Revisions of the two children a merge was built from. */
  childRevisions?: readonly [number, number];
  /** Addresses of the view lines this node's compactor call was given. Empty
   * for a free node, which made no call. */
  contextDependencies: readonly string[];
  textDigest: string;
  /** sha256 of the child texts (merge) or the source message text (leaf). */
  sourceDigest: string;
}

/** Append-only revocation of a whole invalidation, written as one durable line
 * so a crash can never leave a revoked child under a live parent. */
export interface EpisodicInvalidationRecord {
  revision: number;
  generation: number;
  addresses: readonly string[];
}

export type EpisodicNodeLogRecord = EpisodicNodeRecord | EpisodicInvalidationRecord;

export function isInvalidationRecord(record: EpisodicNodeLogRecord): record is EpisodicInvalidationRecord {
  return (record as EpisodicInvalidationRecord).addresses !== undefined;
}

export interface EpisodicStoreState {
  version: typeof EPISODIC_STORE_VERSION;
  generation: number;
  cursor: { completeBytes: number; leafEntryId: string | null } | null;
  blocked: EpisodicBlocked | null;
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
  tokens: { limit: number; reserved: number; used: number };
}

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
}

/** Runs one compactor conversation on the injected model. The default
 * implementation uses `ModelRuntime.completeSimple`. */
export type EpisodicSummarizer = (request: EpisodicCompactorRequest) => Promise<AssistantMessage>;

/** The injected token budget (departure 5). A reservation that does not fit
 * blocks the memory with `budget-exhausted`. */
export interface EpisodicTokenBudget {
  reserve(tokens: number): boolean;
  settle(reserved: number, used: number): void;
  snapshot(): { limit: number; reserved: number; used: number };
}

export function createEpisodicTokenBudget(limitTokens: number): EpisodicTokenBudget {
  if (!Number.isSafeInteger(limitTokens) || limitTokens < 0) throw new EpisodicMemoryError("invalid-request", "Token budget must be a non-negative integer");
  let reserved = 0;
  let used = 0;
  return {
    reserve(tokens) {
      if (tokens < 0 || used + reserved + tokens > limitTokens) return false;
      reserved += tokens;
      return true;
    },
    settle(estimate, actual) {
      reserved = Math.max(0, reserved - estimate);
      used += actual;
    },
    snapshot: () => ({ limit: limitTokens, reserved, used }),
  };
}

export interface EpisodicDiagnostic {
  event: "episodic.source-invalidated" | "episodic.node-blocked" | "episodic.store-refused" | "episodic.store-recovered";
  level: "info" | "warning" | "error";
  message: string;
  counts?: Record<string, number>;
  reason?: string;
}

/** Either the caller injects its own compactor, or it names the model and
 * runtime the default compactor runs on. There is no default model and no
 * default budget: both are the caller's. */
export type EpisodicCompactorDependency =
  | { summarizer: EpisodicSummarizer; modelRuntime?: never; model?: never }
  | { summarizer?: undefined; modelRuntime: ModelRuntime; model: Model<Api> };

export type EpisodicMemoryDependencies = {
  workspace: import("../workspace/tron-workspace.js").TronWorkspace;
  /** The canonical session this memory is over; also its store namespace. */
  sessionId: string;
  /** The canonical session JSONL path. Read only, never repaired. */
  sessionFile: string;
  budget: EpisodicTokenBudget;
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
  for (const name of ["nodeBytes", "viewBytes", "jobs", "tries", "maxSourceLineBytes", "maxStoreLineBytes"] as const) {
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
