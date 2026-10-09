import type { ManagedSubagents } from "./managed-subagents.js";
import { createHash, randomUUID } from "node:crypto";
import { getHeapStatistics } from "node:v8";
import { realpathSync } from "node:fs";
import { lstat, open, opendir, readFile, realpath, rename, rm, stat } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { tmpdir } from "node:os";
import { performance } from "node:perf_hooks";
import {
  ModelRuntime,
  parseSessionEntries,
  SessionManager,
  type FileEntry,
  SettingsManager,
} from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import { installKimiK3Policy } from "../providers/kimi-k3-policy.js";
import { OpenAIModelEligibility } from "../providers/openai-model-eligibility.js";
import { applyJevModelPricing } from "../providers/jev-model-pricing.js";
import type {
  AdministrativeDrainBlockerCategory,
  AdministrativeDrainBlockerSummary,
  AdministrativeDrainPhase,
  AdministrativeDrainSnapshot,
  SessionArchiveFilter,
  SessionCreationOrigin,
  SessionSummary,
  SessionSummaryUpdate,
} from "../protocol/types.js";
import { SessionAttentionStore, type SessionAttentionProjection } from "./session-attention-store.js";
import { SessionArchiveStore } from "./session-archive-store.js";
import { RecentModelStore, type RecentModelUsage } from "../providers/recent-models.js";
import {
  SessionPresentationPresenceRegistry,
  type SessionPresentationPresenceProjection,
} from "./session-presentation-presence.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { QueuedWorkGate } from "../util/queued-work-gate.js";
import { abortableRead } from "../util/abortable-read.js";
import { count, currentRequestSpan, stage, wait } from "../transport/request-span.js";
import type { ResourceRecorder, ResourceRuntimeEntry } from "../transport/stall-diagnostics.js";
import type { TrustService } from "../admin/trust-service.js";
import { BlobStore } from "./blob-store.js";
import {
  SESSION_EXPORT_MAX_ITEM_BYTES,
  SESSION_EXPORT_MAX_ITEMS,
  SESSION_EXPORT_MAX_PRODUCTIONS,
  SESSION_EXPORT_MAX_READERS,
  SESSION_EXPORT_MINIMUM_FREE_BYTES,
  SESSION_EXPORT_MAX_TOTAL_BYTES,
} from "./session-export.js";
import { RunMarkerStore, type RunMarkerEvidence } from "./run-markers.js";
import {
  RuntimeSlot,
  observationBranchIdFor,
  completionOwnedByMarker,
  type CanonicalAssistantCompletion,
  type SessionAttentionRebindDisposition,
  type SessionBroadcast,
  type RuntimeSlotDependencies,
} from "./runtime-slot.js";
import { ExtensionActivityRecency } from "./extension-activity-recency.js";
import { ProcessActivityRecency } from "./process-activity-recency.js";
import {
  MAX_EXTENSION_ARTIFACT_BYTES,
  MAX_EXTENSION_LIFECYCLE_HEADER_BYTES,
  admitExtensionLifecycleArtifact,
  hasExtensionLifecycleProjectionProperty,
  inspectExtensionLifecycleProjection,
  lifecycleProjectionArtifact,
  observedPausedProcessTerminalAt,
  parseExtensionLifecycleProjectionHeader,
} from "./extension-run-projection.js";
import type { NotificationService } from "../notifications/notification-service.js";
import { DisplayArtifactStore } from "../display/display-artifact-store.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { GatewayWorkRegistry } from "./gateway-work-registry.js";
import type { ScheduleToolOperations } from "../automations/tron-schedule-extension.js";
import type { BrowserLiveViewRegistry } from "../display/browser-live-view.js";
import { isAutomationId, runIdFromAutomationOperationId } from "../automations/automation-contract.js";
import {
  invocationProjection,
  invocationReceipts,
  type InvocationProjection,
} from "./invocation-receipts.js";
import { projectTranscriptPage, type TranscriptPage } from "./projection.js";
import {
  CatalogMetadataIndex,
  type CatalogMetadataIndexFailure,
  type CatalogMetadataIndexSummary,
} from "./catalog-metadata-index.js";
import { branchFromParsedSession } from "./session-branch.js";
import {
  SessionCatalog,
  SUBAGENT_RUN_DIRECTORY,
  delegatedSessionParentPath,
  type SessionCatalogChange,
  type SessionCatalogIdentity,
  type SessionCatalogReconcileOutcome,
  type SessionCatalogSource,
  type SessionCatalogWatcherReset,
} from "./session-catalog.js";
import { resolveForkBoundaryAnchor, type ForkBoundaryAnchor } from "./fork-boundary.js";
import type { KnowledgeService } from "../knowledge/knowledge-service.js";
import type { JevDecisionClient } from "../knowledge/jev-client.js";
import type { ConnectionOwner } from "../integrations/connection-owner.js";
import type { SessionSearchForkBoundary } from "./session-search-contract.js";
import { validateSearchBranch } from "./session-search-text.js";
import { observationEntriesDigest } from "../knowledge/knowledge-observation.js";
import {
  CatalogDiscovery,
  DEFAULT_CATALOG_DISCOVERY_LIMITS,
  buildCatalogSessionInfo,
  type CatalogDiscoveryOptions,
  type CatalogHeaderIdentity,
  type CatalogSessionInfo,
  type DelegatedSessionTopology,
} from "./catalog-discovery.js";

/** A read-only child observer may page only canonical sessions that fit this
 * explicit parse budget. The parser needs the selected branch graph, so it
 * reads one bounded file rather than maintaining an incremental mirror. */
const MAX_READ_ONLY_SUBAGENT_SESSION_BYTES = 64 * 1_024 * 1_024;
// MaximumLiveRuntimes is 16 and each slot retains at most 64 owned activity
// bindings, so this covers every exact drain owner before ambient work. An
// ambient pass spends the read budget only on artifacts whose status.json
// identity changed, so unchanged directories are still walked and an artifact
// past the budget is read by the next pass.
const MAX_EXTENSION_DISCOVERY_WORK = 1_024;
const MAX_EXTENSION_DISCOVERY_ROOTS = 64;
const MAX_EXTENSION_TEMP_ENTRIES = 1_024;
// Ambient enumeration shares these global pass bounds. Exact-owned artifact
// reconciliation above is intentionally outside this ambient budget.
const MAX_EXTENSION_ROOT_ENTRIES = 4_096;
/** A lasting stop is reported when its episode starts and then at most hourly:
 * the counts move slowly and the pass runs every 750 ms, so an undeduplicated
 * record would repeat 80 times a minute. */
const EXTENSION_DISCOVERY_TRUNCATION_REPORT_MS = 60 * 60 * 1_000;
/** An ambient decision keeps its entry for this many passes after it was last
 * seen. A pass that stops at a budget still ages the entries it did not reach,
 * so a deleted run leaves the cache while the root stays over the cap. */
const AMBIENT_ARTIFACT_FACT_PASSES = 4;

/** What one discovery pass spent before it stopped. `entries` is root entries
 * walked, `statusReads` the artifacts it read because their status.json
 * identity changed, `work` the exact refreshes and routed candidates, and
 * `dropped` the candidates its per-root routing budget cut off. */
export interface ExtensionArtifactDiscoveryCounts {
  entries: number;
  statusReads: number;
  work: number;
  dropped: number;
}
// A Pi append can land inside the summary's read window; the summary is retried
// rather than published with a size its counts do not describe.
const CATALOG_SUMMARY_ATTEMPTS = 3;

/** Estimated heap the live runtimes may hold together. Below the 4,096 MB V8
 * old-space limit the launcher passes, with room for the catalog index, the
 * projections and the transport, so budgeted sessions cannot reach the heap
 * limit the memory exit criterion measures. */
export const LIVE_RUNTIME_BYTE_BUDGET = 1_536 * 1_024 * 1_024;

/** Estimated heap one loaded runtime holds per canonical transcript byte.
 * Measured 2026-09-28 on the live Gateway: a 108 MB session cost about 310 MB of
 * heap (2.9x). The registry fixture measured 1.0x for plain repeated text, which
 * has no projection duplication, so the live figure is the honest one. */
export const LIVE_RUNTIME_HEAP_ESTIMATE_FACTOR = 3;

/** Cold runtime loads admitted at once (`G-12`). A load parses a transcript into
 * a runtime the budget then has to hold, so two at a time share the loop and the
 * libuv pool with interactive reads; a third waits its turn instead of thrashing
 * the same disk and heap. The wait, not the load, is what a leaving client
 * abandons. */
export const MAXIMUM_CONCURRENT_COLD_LOADS = 2;

/** Heap share of the V8 limit above which a cold load first reclaims idle
 * runtimes, largest first (`G-12`): the exit criterion is that the heap never
 * passes 70% of the configured limit, so the load that would cross it is the
 * moment to give memory back rather than after it crossed. */
export const HEAP_EVICTION_SHARE = 0.70;

/** Heap share above which a cold runtime load is refused instead of admitted
 * (`G-12`): past this point the load is what would take the process to its
 * limit, and a retryable refusal is cheaper than the OOM it would cause. The
 * byte budget (eviction pressure) deliberately never refuses. */
export const HEAP_REFUSAL_SHARE = 0.85;

/** What a refused cold load tells the client to wait (`G-12`). Heap pressure is
 * released by eviction and the collector rather than by the next tick, so the
 * hint is longer than the transport's own deadline hint; the phone bounds any
 * hint to 10 s. */
export const HEAP_REFUSAL_RETRY_AFTER_MS = 5_000;

/** Why a runtime was published: the admission that did it, or `oversize` for a
 * transcript whose own estimate exceeds `LIVE_RUNTIME_BYTE_BUDGET`, which is
 * admitted alone because no retirement can make it fit. */
export type RuntimeLoadReason = "open" | "create" | "automation" | "import" | "oversize";

/** What reclaimed a runtime: the idle lifetime, the runtime count, the byte
 * budget's own pass, the heap-pressure pass (`G-12`), or a lifecycle event the
 * user or the process caused.
 * `disposed` is the slot that was already disposed when a later open cleared it
 * from the live set, with no other reason recorded for it. */
export type RuntimeEvictionReason =
  | "idle" | "capacity" | "bytes" | "heap" | "closed" | "disposed" | "deleted" | "shutdown";

export type RuntimeLifecycleReason = RuntimeLoadReason | RuntimeEvictionReason;

/** One runtime load or eviction, with the bytes the byte budget charges it.
 * `transcriptBytes` is the canonical JSONL size the estimate came from — at
 * publication for a load, and from the stat the byte pass itself read for an
 * eviction it made — so a reader can cross-check the record against the
 * sampler's runtime inventory. `overBudget` names a load that leaves the live
 * charge over `LIVE_RUNTIME_BYTE_BUDGET`, which the budget admits instead of
 * refusing (it is eviction pressure, not an admission gate). */
export interface RuntimeLifecycleRecord {
  event: "runtime.loaded" | "runtime.evicted";
  sessionId: string;
  reason: RuntimeLifecycleReason;
  transcriptBytes: number;
  estimatedHeapBytes: number;
  overBudget?: true;
}

/** One published runtime's byte charge, as the budget assesses it. */
interface PublishedRuntimeBytes {
  transcriptBytes: number;
  estimatedHeapBytes: number;
}

/** One admission the heap-pressure gate refused (`G-12`): a cold runtime load
 * any owner asked `acquire` for (`open`, the same reason its `runtime.loaded`
 * record carries), or a JSONL import. `acquire` serves reads, leases and
 * automation alike, so the registry cannot name the RPC that asked for a cold
 * load; it names the admission it refused instead of claiming one caller. */
export type ColdLoadAdmission = "open" | "import";

/** One cold start shared by every requester that joined it (`C-6`), with the
 * waiters still holding it. The start is one shared entry, so the signal that
 * drops a queued load belongs to the last waiter rather than to the requester
 * that happened to arrive first. */
interface PendingColdLoad {
  /** The shared start, set before the record is published in
   * `pendingSlotStarts`, so a joiner never sees a half-built record. */
  operation: Promise<RuntimeSlot>;
  /** Aborted when the last waiter leaves, which is what drops the load still
   * queued behind the concurrency cap. */
  readonly controller: AbortController;
  waiters: number;
}

/** One admission refused because the process heap was already past
 * `HEAP_REFUSAL_SHARE` of its limit (`G-12`). The Gateway logs one
 * `gateway.shed` for it with the same reason and counts the transport's own
 * deadline sheds carry, so a triage run sees every shed admission in one event. */
export interface CapacityShedRecord {
  reason: "heap";
  /** Which admission was refused; see `ColdLoadAdmission`. */
  admission: ColdLoadAdmission;
  heapUsedBytes: number;
  heapLimitBytes: number;
  retryAfterMs: number;
}

export interface HeapSample {
  usedBytes: number;
  limitBytes: number;
}

/** The heap one loaded runtime is estimated to hold. */
function estimateRuntimeHeapBytes(transcriptBytes: number): number {
  return Math.ceil(Math.max(0, transcriptBytes) * LIVE_RUNTIME_HEAP_ESTIMATE_FACTOR);
}

/** Canonical transcript bytes of a live or starting runtime; a session that has
 * not written its file yet holds none. */
async function sessionFileBytes(path: string | undefined): Promise<number> {
  if (path === undefined) return 0;
  return stat(path).then((metadata) => metadata.size).catch(() => 0);
}

function assertProcessSessionRef(value: string): void {
  if (!value || Buffer.byteLength(value) > 256 || /[\\/\0]/u.test(value)) {
    throw new GatewayError("invalid_request", "Invalid subagent session reference");
  }
}

/** Pi stores the spelling of a parent path; macOS may surface the same path
 * through its `/var` and `/private/var` aliases. Normalize lexically so catalog
 * assembly does not add synchronous filesystem work per session. */
function sessionCatalogPathKey(path: string): string {
  const absolute = resolve(path);
  return process.platform === "darwin" && absolute.startsWith("/private/var/")
    ? absolute.slice("/private".length)
    : absolute;
}

interface DashboardOrderableSession {
  id: string;
  phase: SessionSummary["phase"];
  updatedAt: string;
  activeSince?: string;
}

function orderDashboardSessions<T extends DashboardOrderableSession>(sessions: readonly T[]): T[] {
  const active = (phase: SessionSummary["phase"]) => phase === "running" || phase === "compacting" || phase === "retrying";
  const compareTimestamp = (left: string | undefined, right: string | undefined): number => {
    const leftInstant = left === undefined ? Number.NaN : Date.parse(left);
    const rightInstant = right === undefined ? Number.NaN : Date.parse(right);
    const leftValid = Number.isFinite(leftInstant);
    const rightValid = Number.isFinite(rightInstant);
    if (leftValid && rightValid && leftInstant !== rightInstant) return rightInstant - leftInstant;
    if (leftValid !== rightValid) return rightValid ? 1 : -1;
    return 0;
  };
  return [...sessions].sort((left, right) => {
    const leftActive = active(left.phase);
    const rightActive = active(right.phase);
    if (leftActive !== rightActive) return leftActive ? -1 : 1;
    const byTime = compareTimestamp(
      leftActive ? left.activeSince : left.updatedAt,
      rightActive ? right.activeSince : right.updatedAt,
    );
    return byTime !== 0 ? byTime : left.id.localeCompare(right.id);
  });
}

/** The dashboard shows work for a session whose projection is active. Archive
 * admission and archive restoration share this rule: an archived session must
 * be idle, so an active projection both blocks archiving and clears a record
 * that a run reached without Gateway admission. */
function sessionShowsWork(projection: {
  phase?: SessionSummary["phase"] | undefined;
  foregroundPhase?: SessionSummary["phase"] | undefined;
  waitingForUser?: boolean | undefined;
  hasActiveSubagents?: boolean | undefined;
}): boolean {
  const active = (phase: SessionSummary["phase"] | undefined) =>
    phase === "running" || phase === "compacting" || phase === "retrying";
  return active(projection.phase)
    || active(projection.foregroundPhase)
    || projection.waitingForUser === true
    || projection.hasActiveSubagents === true;
}

/** Privacy-safe archive lifecycle signal, never a session ID or path. */
export type ArchiveDiagnostic =
  | { outcome: "failure"; stage: "set" | "remove" | "auto-unarchive" }
  | { outcome: "auto-unarchived"; trigger: "admission" | "backstop" };

/** The archived container is ordered by when each session was archived, newest
 * first. Archive timestamps are unique per session but a tie still needs one
 * deterministic order across pages. */
function orderArchivedSessions<T extends { id: string; archivedAt?: string }>(sessions: readonly T[]): T[] {
  return [...sessions].sort((left, right) => {
    const leftInstant = left.archivedAt === undefined ? Number.NaN : Date.parse(left.archivedAt);
    const rightInstant = right.archivedAt === undefined ? Number.NaN : Date.parse(right.archivedAt);
    if (Number.isFinite(leftInstant) && Number.isFinite(rightInstant) && leftInstant !== rightInstant) {
      return rightInstant - leftInstant;
    }
    return left.id.localeCompare(right.id);
  });
}

async function readOpenedSessionHeader(
  handle: Awaited<ReturnType<typeof open>>,
  byteCount: number,
): Promise<{ sessionId: string; parentSession?: string } | undefined> {
  if (!Number.isSafeInteger(byteCount) || byteCount <= 0) return undefined;
  const length = Math.min(byteCount, DEFAULT_CATALOG_DISCOVERY_LIMITS.maximumHeaderBytesPerFile);
  const bytes = Buffer.alloc(length);
  const { bytesRead } = await handle.read(bytes, 0, length, 0);
  const newline = bytes.subarray(0, bytesRead).indexOf(0x0a);
  if (newline < 0) return undefined;
  try {
    const header = JSON.parse(bytes.subarray(0, newline).toString("utf8")) as Record<string, unknown>;
    if (header.type !== "session" || typeof header.id !== "string" || !header.id) return undefined;
    const parentSession = typeof header.parentSession === "string" && header.parentSession
      ? header.parentSession
      : undefined;
    return { sessionId: header.id, ...(parentSession ? { parentSession } : {}) };
  } catch {
    return undefined;
  }
}

async function readOpenedSessionEntries(
  handle: Awaited<ReturnType<typeof open>>,
  byteCount: number,
  signal?: AbortSignal,
): Promise<import("@earendil-works/pi-coding-agent").FileEntry[] | undefined> {
  if (!Number.isSafeInteger(byteCount) || byteCount < 0) return undefined;
  if (byteCount > MAX_READ_ONLY_SUBAGENT_SESSION_BYTES) {
    throw new GatewayError(
      "invalid_request",
      "Subagent session exceeds the bounded read-only viewer budget",
    );
  }
  const bytes = Buffer.alloc(byteCount);
  let offset = 0;
  while (offset < bytes.length) {
    signal?.throwIfAborted();
    const read = await handle.read(bytes, offset, Math.min(64 * 1024, bytes.length - offset), offset);
    if (read.bytesRead <= 0) return undefined;
    offset += read.bytesRead;
  }
  signal?.throwIfAborted();
  try { return parseSessionEntries(bytes.toString("utf8")); }
  catch { return undefined; }
}

function parseStrictSessionJSONL(bytes: Buffer): FileEntry[] {
  const text = bytes.toString("utf8");
  if (!text || !text.endsWith("\n")) throw new GatewayError("invalid_request", "Session JSONL has an incomplete tail");
  const lines = text.slice(0, -1).split("\n");
  const raw = lines.map((line, index) => {
    if (!line.trim()) throw new GatewayError("invalid_request", `Session JSONL contains an empty line at ${index + 1}`);
    try {
      const value: unknown = JSON.parse(line);
      if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("not an object");
      return value;
    } catch {
      throw new GatewayError("invalid_request", `Session JSONL contains malformed line ${index + 1}`);
    }
  });
  let entries: FileEntry[];
  try { entries = parseSessionEntries(text); }
  catch { throw new GatewayError("invalid_request", "Session JSONL could not be parsed"); }
  if (entries.length !== raw.length) throw new GatewayError("invalid_request", "Session JSONL contains an unsupported record");
  return entries;
}

interface CatalogAcquisitionEntry {
  id: string;
  path: string;
  cwd: string;
  canonicalCwd: string;
  fileIdentity?: string;
  structuralSubagent: boolean;
  parentSessionId?: string;
}

interface CatalogAcquisitionResolution {
  entriesByID: ReadonlyMap<string, CatalogAcquisitionEntry>;
  ambiguousIDs: ReadonlySet<string>;
}

interface ReadOnlySubagentAdmission {
  path: string;
  fileIdentity: string;
}

interface CatalogPageSeed {
  readonly id: string;
  readonly name?: string;
  readonly cwd: string;
  readonly kind: SessionSummary["kind"];
  readonly parentSessionId?: string;
  readonly creationOrigin?: SessionCreationOrigin;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly activeSince?: string;
  readonly messageCount: number;
  readonly firstMessage: string;
  readonly phase: SessionSummary["phase"];
  readonly foregroundPhase?: SessionSummary["foregroundPhase"];
  readonly hasActiveSubagents?: boolean;
  readonly waitingForUser?: boolean;
  readonly summaryRevision: number;
  readonly archivedAt?: string;
  readonly attention: SessionAttentionProjection;
}

interface CatalogPageSource {
  readonly generation: string;
  /** Conditional-read token for this exact projection. It covers the whole
   * projection, not just structural membership: the page-source generation
   * plus this Gateway runtime's epoch. Every row field that can change without
   * moving `listRevision` (a live summary, a cold row's attention projection,
   * archive state) moves the projection generation inside the token, and the
   * epoch fences a restart whose revisions begin again at zero. A client may
   * therefore revalidate a retained token on a replacement connection (G-7). */
  readonly projectionToken: string;
  readonly listRevision: number;
  readonly count: number;
  readonly compactByteEstimate: number;
  readonly page: (offset: number, limit: number) => Promise<SessionSummary[]>;
}

/** One immutable read cut of the catalog index. `allInfos` is the scope's
 * every indexed row; `infos` is that set without the IDs the index reports as
 * ambiguous, which no reader may resolve. */
interface CatalogIndexCut {
  allInfos: CatalogSessionInfo[];
  infos: CatalogSessionInfo[];
  ambiguousIDs: ReadonlySet<string>;
}

interface IdleEviction {
  slot: RuntimeSlot;
  committed: boolean;
  completion?: Promise<boolean>;
}

/**
 * A registry lane that reports its queue wait to the current request span. The
 * mutex hands over inside its own operation, so the exact moment the wait ends
 * is known there; the wait is [request, handover), and the work the lock admits
 * stays attributed to the span that measures it. `AsyncMutex` runs the admitted
 * operation in this caller's async context, so its nested stages stay on this
 * request.
 */
class RequestSpanLane extends AsyncMutex {
  constructor(private readonly spanLabel: string) {
    super();
  }

  override run<T>(operation: () => Promise<T> | T, signal?: AbortSignal): Promise<T> {
    const span = currentRequestSpan();
    if (span === undefined) return super.run(operation, signal);
    return span.wait(
      this.spanLabel,
      (acquired) => super.run(() => {
        acquired();
        return operation();
      }, signal),
    );
  }
}

export class RuntimeRegistry {
  private readonly slots = new Map<string, RuntimeSlot>();
  private readonly openAIModelEligibility: OpenAIModelEligibility;
  /** Live-only generated sessions are bound to the exact Automation operation
   * until Pi persists their first user or assistant message. Weak ownership cannot outlive
   * the RuntimeSlot and is never a second session catalog. */
  private readonly automationSessionOwners = new WeakMap<RuntimeSlot, {
    operationId: string;
    automationId: string;
  }>();
  private readonly mutex = new RequestSpanLane("registry.mutex");
  /** One disposable flight per admission scope. All-scope work may wait for a
   * user cut, but a dashboard never inherits child-only delay or failure. */
  private readonly catalogMaterializations = new Map<"user" | "all", {
    generation: string;
    promise: Promise<Awaited<ReturnType<RuntimeRegistry["materializeCatalogSnapshot"]>>>;
  }>();
  /** Serializes attention membership checks with set/delete/rekey. Archive
   * state shares this lane: both are Gateway-owned display projections of one
   * canonical session and must not outlive it.
   *
   * Lock order is registry mutex -> session lane -> this lane. The archive
   * commit and run admission both run on a session's lane and nest this lane
   * inside it, and the rekey hook already holds a lane while it nests this one.
   * Nothing holds this lane while it waits for a registry mutex or a session
   * lane: delete releases this lane before taking the mutex, and setAttention
   * resolves admission before entering. Keep that direction when adding work
   * here, or runs and archive commits can deadlock. */
  private readonly attentionLane = new RequestSpanLane("registry.attention-lane");
  /** Linearizes display lease admission with canonical session deletion. */
  private readonly displayArtifactLane = new RequestSpanLane("registry.display-lane");
  private readonly blobs: BlobStore;
  private readonly exports: BlobStore;
  private readonly displayArtifacts: DisplayArtifactStore;
  private readonly workspace: TronWorkspace;
  private knowledgeService: KnowledgeService | undefined;
  private searchInvalidator: ((sessionID: string, nextSessionID?: string) => void) | undefined;
  private readonly markers: RunMarkerStore;
  private readonly extensionActivityRecency = new ExtensionActivityRecency();
  private readonly processActivityRecency = new ProcessActivityRecency();
  private readonly attention: SessionAttentionStore;
  private readonly archive: SessionArchiveStore;
  private readonly recentModels: RecentModelStore;
  private readonly presentationPresence = new SessionPresentationPresenceRegistry();
  private readonly catalogMetadataIndex: CatalogMetadataIndex;
  /** The catalog owner: one row per canonical session file (G-1c switches the
   * readers onto it; until then only the owner and its tests read it). */
  private readonly sessionCatalog: SessionCatalog;
  private readonly configuredSessionDir: string | undefined;
  private interrupted = new Set<string>();
  private readonly subscribers = new Map<string, Set<string>>();
  // A reservation is intentionally separate from slot ownership. Acquiring or
  // subscribing cancels it before RuntimeSlot crosses its lane-protected
  // disposal boundary, so an idle scan cannot retire a newly live session.
  private readonly idleEvictions = new Map<string, IdleEviction>();
  private readonly summaryRevisions = new Map<string, number>();
  private readonly latestSummaries = new Map<string, SessionSummaryUpdate>();
  private readonly pendingAttentionRemovals = new Set<string>();
  private readonly pendingArchiveRemovals = new Set<string>();
  /** Archived IDs whose live projection already shows work. The row is visible
   * from the moment the projection is published and the durable record is
   * cleared behind it; a failed write stays visible here instead of leaving a
   * running session hidden. */
  private readonly pendingArchiveRestorations = new Set<string>();
  /** One durable archive-clear attempt per ID, so a repeated active projection
   * cannot queue another store write. */
  private readonly archiveRestorationAttempts = new Map<string, Promise<void>>();
  private readonly deletingSessionIds = new Set<string>();
  private ambiguousSessionIds = new Set<string>();
  private readonly trustReloadProjects = new Set<string>();
  private revision = 0;
  private catalogFingerprint: string | undefined;
  // User and all-scope cuts have different membership contracts. Keeping their
  // fingerprints separate lets a partial user cut advance its own revision
  // without treating omitted delegated rows as a deletion from the full list.
  private catalogUserFingerprint: string | undefined;
  private catalogAcquisitionInvalidationGeneration = 0;
  private catalogStructuralGeneration = 0;
  /** Mutable page overlays are separate from structural listRevision. This
   * generation keys immutable compact page seeds without making them catalog
   * authority. */
  private catalogProjectionGeneration = 0;
  private readonly catalogPageSources = new Map<string, WeakRef<CatalogPageSource>>();
  private readonly pendingSlotStarts = new Map<string, PendingColdLoad>();
  private reservedSlotStarts = 0;
  /** Heap the byte budget has charged to session starts that are not published
   * yet, keyed by the session being opened. The byte pass counts them in the
   * projected total, so two concurrent opens each see the room the other has
   * taken; a session's own reservation is left out of its own projected total,
   * which is the charge it is opening with. */
  private readonly reservedRuntimeBytes = new Map<string, number>();
  /** Heap the byte budget charges each published runtime, written synchronously
   * where the runtime is published, refreshed by the byte pass from the stat it
   * read, and cleared where it leaves `slots`. It is the live charge the load
   * record's `overBudget` compares against the budget, and the size an eviction
   * records. */
  private readonly publishedRuntimeBytes = new Map<string, PublishedRuntimeBytes>();
  private readonly readHeapSample: () => HeapSample;
  private evictionTimer?: NodeJS.Timeout;
  private artifactDiscoveryTimer?: NodeJS.Timeout;
  private artifactDiscoveryInFlight = false;
  private artifactDiscoveryPass = 0;
  /** When the current run of stopped passes began (0 after a pass reached the
   * end of its roots), when the current run of passes that dropped candidates
   * began, and when a stop was last reported. */
  private artifactDiscoveryStoppedSince = 0;
  private artifactDiscoveryDroppedSince = 0;
  private artifactDiscoveryStopReportedAt = 0;
  /** The status.json identity each live slot last dealt with for one run
   * directory: a slot that accepted this exact artifact has its projection, and
   * one that rejected it can only reject the same bytes again. Only those two
   * outcomes are recorded, so an offer that failed temporarily is offered again
   * on the next pass; a run the slot still holds an exact binding for is
   * refreshed by the exact-binding lane every pass. */
  private readonly ambientArtifactRoutes = new Map<string, Map<string, { identity: string; pass: number }>>();
  /** Ambient artifact decisions keyed by run directory. The identity is the stat
   * of the same status.json a read would have opened, so an unchanged artifact
   * costs one stat and no open, read or parse; `pass` lets a complete pass drop
   * the entries whose directories are gone. */
  private readonly ambientArtifactFacts = new Map<string, {
    identity: string;
    active: boolean;
    timestamp: number;
    pass: number;
  }>();
  private slotAdmissionsInFlight = 0;
  private administrativeDrainStarted = false;
  private readonly workRegistry: GatewayWorkRegistry;
  private drainId: string;
  private drainRevision = 0;
  private drainPhase: AdministrativeDrainPhase = "idle";
  private drainFingerprint = "";
  private shutdownState: "active" | "shuttingDown" | "disposed" = "active";
  private disposalPromise: Promise<void> | undefined;
  private blobsDisposed = false;
  private exportsDisposed = false;
  private workspaceDisposed = false;
  private catalogIndexDisposed = false;
  private sessionCatalogDisposed = false;
  private recentModelsDisposed = false;

  constructor(
    private readonly options: {
      agentDir: string;
      tronHome: string;
      /** Exact provider-owned root under the resolved Tron home. */
      delegatedArtifactRoot?: string;
      managedSubagents?: ManagedSubagents;
      mcpAuth?: RuntimeSlotDependencies["mcpAuth"];
      idleRuntimeMs: number;
      maximumLiveRuntimes?: number;
      modelRuntimeFactory?: () => Promise<ModelRuntime>;
      openAIModelEligibility?: OpenAIModelEligibility;
      trust: TrustService;
      broadcast: SessionBroadcast;
      sessionSummaryChanged: (summary: SessionSummaryUpdate) => void;
      sessionListChanged: () => void;
      /** Global broadcast seam for `models.recentChanged`. */
      recentModelsChanged?: () => void;
      sessionRekeyed?: (previousId: string, nextId: string) => void;
      beforeSessionRekey?: (previousId: string, nextId: string) => Promise<void>;
      beforeSessionDelete?: (sessionId: string) => Promise<void>;
      sessionClosed?: (sessionId: string) => void;
      persistenceDiagnostic?: (sessionId: string, code: string) => void;
      /** One runtime load or eviction, for the Gateway log. */
      runtimeLifecycleRecord?: (record: RuntimeLifecycleRecord) => void;
      /** One cold load the heap-pressure gate refused, for the Gateway log. */
      capacityShedRecord?: (record: CapacityShedRecord) => void;
      /** The live heap picture the pressure gate reads. The process's own
       * numbers by default; an injected sample drives the gate in tests without
       * allocating past a limit the host cannot afford. */
      heapSample?: () => HeapSample;
      /** Privacy-safe archive lifecycle outcome, never a session ID. */
      archiveDiagnostic?: (diagnostic: ArchiveDiagnostic) => void;
      /** Read-only automation admission query, so archiving cannot hide a
       * reserved or already-running automation target. */
      sessionAutomationReserved?: (sessionId: string) => boolean;
      compactionDiagnostic?: RuntimeSlotDependencies["compactionDiagnostic"];
      stopSteeringDiagnostic?: RuntimeSlotDependencies["stopSteeringDiagnostic"];
      manualCompactionAdopted?: RuntimeSlotDependencies["manualCompactionAdopted"];
      codemodeDiagnostic?: RuntimeSlotDependencies["codemodeDiagnostic"];
      catalogDiscoveryLimits?: Partial<typeof DEFAULT_CATALOG_DISCOVERY_LIMITS>;
      /** Handled catalog-index write failures. The index write is fire-and-forget
       * outside any request span, so its owner records them. */
      catalogIndexFailure?: CatalogMetadataIndexFailure;
      /** One catalog reconcile, with the files it covered and the rows it
       * changed. An incomplete or failed pass is reported instead of silent. */
      catalogReconciled?: (reconciled: SessionCatalogReconcileOutcome) => void;
      /** One catalog row the folder watcher changed for one file: a change no
       * request or commit explains. */
      catalogChanged?: (change: SessionCatalogChange) => void;
      /** The folder watcher stopped observing the catalog folder, so the index
       * is re-derived from the folder's own cut once a watcher is attached. */
      catalogWatcherReset?: (reset: SessionCatalogWatcherReset) => void;
      /** A runtime whose extension shutdown overran its disposal grace and was
       * forced. Outside any request span. */
      runtimeDisposeTimeout?: (graceMs: number) => void;
      /** The transport's resource sampler; the registry reports the work only it
       * performs (catalog walks, runtime publications) and answers its runtime
       * inventory. */
      resources?: ResourceRecorder;
      machineId?: string;
      notifications?: NotificationService;
      browserLiveViews?: BrowserLiveViewRegistry;
      workRegistry?: GatewayWorkRegistry;
      /** A discovery pass that stopped at one of its budgets instead of the end
       * of its roots, with the counts it spent. A directory past the stop is
       * examined by a later pass; the report keeps the stop visible. */
      artifactDiscoveryTruncated?: (counts: ExtensionArtifactDiscoveryCounts) => void;
      extensionArtifactWarning?: (warning: { reason: import("./extension-run-projection.js").ExtensionArtifactRejectionReason; owner: string }) => void;
      scheduleToolOperations?: ScheduleToolOperations;
      jev?: JevDecisionClient;
      connections?: ConnectionOwner;
    },
  ) {
    this.openAIModelEligibility = options.openAIModelEligibility ?? new OpenAIModelEligibility();
    this.blobs = new BlobStore(undefined, Date.now, join(options.tronHome, "gateway", "blobs"));
    this.displayArtifacts = new DisplayArtifactStore(options.tronHome);
    this.workspace = new TronWorkspace(options.tronHome);
    this.exports = new BlobStore({
      maximumItemBytes: SESSION_EXPORT_MAX_ITEM_BYTES,
      maximumItems: SESSION_EXPORT_MAX_ITEMS,
      maximumTotalBytes: SESSION_EXPORT_MAX_TOTAL_BYTES,
      maximumReaders: SESSION_EXPORT_MAX_READERS,
      maximumFileProductions: SESSION_EXPORT_MAX_PRODUCTIONS,
      minimumFreeBytes: SESSION_EXPORT_MINIMUM_FREE_BYTES,
    }, Date.now, join(options.tronHome, "gateway", "exports"));
    this.markers = new RunMarkerStore(options.tronHome);
    this.attention = new SessionAttentionStore(options.tronHome);
    this.archive = new SessionArchiveStore(options.tronHome);
    this.recentModels = new RecentModelStore(options.tronHome);
    this.catalogMetadataIndex = new CatalogMetadataIndex(join(options.tronHome, "gateway"), options.catalogIndexFailure);
    this.sessionCatalog = new SessionCatalog({
      catalogRoot: () => this.catalogDirectory(),
      index: this.catalogMetadataIndex,
      source: this.sessionCatalogSource(),
      onReconciled: (reconciled) => { this.options.catalogReconciled?.(reconciled); },
      ...(options.catalogChanged ? { onChanged: options.catalogChanged } : {}),
      ...(options.catalogWatcherReset ? { onWatcherReset: options.catalogWatcherReset } : {}),
    });
    this.workRegistry = options.workRegistry ?? new GatewayWorkRegistry();
    this.readHeapSample = options.heapSample ?? (() => ({
      usedBytes: process.memoryUsage().heapUsed,
      limitBytes: getHeapStatistics().heap_size_limit,
    }));
    this.drainId = `idle-${createHash("sha256").update(this.workRegistry.runtimeEpoch).digest("hex").slice(0, 16)}`;
    this.configuredSessionDir = SettingsManager.create(
      process.cwd(),
      options.agentDir,
      { projectTrusted: false },
    ).getSessionDir();
    for (const [name, value] of Object.entries(this.catalogDiscoveryLimits())) {
      if (!Number.isSafeInteger(value) || value < 1) throw new Error(`Invalid session catalog ${name} bound`);
    }
  }

  get listRevision(): number {
    return this.revision;
  }

  /** Shared workspace owner for capability stores; callers must not construct a
   * second workspace authority for the same Tron installation. */
  knowledgeWorkspace(): TronWorkspace { return this.workspace; }

  setSearchInvalidator(invalidator: (sessionID: string, nextSessionID?: string) => void): void {
    this.searchInvalidator = invalidator;
  }

  setKnowledgeService(service: KnowledgeService): void {
    if (this.knowledgeService && this.knowledgeService !== service) throw new Error("Knowledge service is already installed");
    this.knowledgeService = service;
  }

  get administrativeWorkRegistry(): GatewayWorkRegistry { return this.workRegistry; }

  /** Drain admission is owned here; readers derive it from the canonical phase rather than mirroring a stop flag. */
  get isAdministrativeDrainStarted(): boolean { return this.drainPhase !== "idle"; }

  /** Shared model recency for the model picker; newest first and bounded. */
  recentModelUsage(): RecentModelUsage[] { return this.recentModels.entries(); }

  /**
   * Bounded best-effort recency for one admitted user-session run. Subagent
   * sessions never acquire a Gateway runtime, so every reporting slot is a user
   * session. A failed preference write must not disturb the admitted run.
   */
  private async noteModelUsed(sessionId: string, model: { provider: string; id: string }): Promise<void> {
    try {
      if (await this.recentModels.record(model.provider, model.id)) this.options.recentModelsChanged?.();
    } catch {
      this.options.persistenceDiagnostic?.(sessionId, "recent-model-record-failed");
    }
  }

  async initialize(onPhase?: (phase: "catalog-warming" | "attention-recovery") => void): Promise<void> {
    await this.workspace.initialize();
    // Load the durable recovery inputs before capturing catalog membership, as
    // before this optimization. The later evidence cut therefore cannot omit a
    // marker that was already admitted to this reconciliation pass.
    await this.attention.initialize();
    await this.archive.initialize();
    await this.recentModels.initialize();
    // The catalog owner loads its durable rows, reconciles once, and watches
    // the folder for external writers; the periodic pass is the backstop for
    // any event the watcher could not see (G-9 moves both into the scheduler).
    // A reader joins that first cut rather than walking the folder itself.
    this.sessionCatalog.start();
    const markerEvidence = await this.markers.evidence();
    // Recovery can open and parse large session files. Do not hold listener
    // readiness on those full reads; recover them once the Gateway is serving.
    this.pendingAttentionRecovery = markerEvidence;
    this.pendingStartupPhaseObserver = onPhase;
    this.evictionTimer = setInterval(() => void this.evictIdle(), 60_000);
    this.evictionTimer.unref();
    this.artifactDiscoveryTimer = setInterval(() => void this.discoverExtensionArtifacts(), 750);
    this.artifactDiscoveryTimer.unref();
    void this.discoverExtensionArtifacts();
  }

  private pendingAttentionRecovery: ReadonlyMap<string, readonly RunMarkerEvidence[]> | undefined;
  private pendingStartupPhaseObserver: ((phase: "catalog-warming" | "attention-recovery") => void) | undefined;

  async recoverCanonicalAttention(): Promise<void> {
    const markerEvidence = this.pendingAttentionRecovery;
    if (!markerEvidence) return;
    this.pendingAttentionRecovery = undefined;
    this.pendingStartupPhaseObserver?.("catalog-warming");
    // Wait for this process's own reconcile pass to report, whatever it found:
    // pruning attention and archive records for rows a cut omits destroys data,
    // so it waits for a cut that saw the folder now, and keeps every record when
    // the pass could not produce one. Recovery never fails startup.
    await this.sessionCatalog.whenReconciled();
    this.pendingStartupPhaseObserver?.("attention-recovery");
    this.pendingStartupPhaseObserver = undefined;
    await this.reconcileCanonicalAttention(markerEvidence);
    this.interrupted = await this.markers.interruptedSessionIds();
  }

  /** Re-admit only durable pending/failed Knowledge cuts after restart. The
   * canonical slot supplies the exact currently selected branch; recovery does
   * not acquire or pin a foreground runtime, replay a prompt/tool, or invent
   * provenance. Missing/non-active/changed coverage is made explicitly
   * unavailable so it remains visible as a bounded gap. */
  async recoverKnowledgeObservation(): Promise<void> {
    const knowledge = this.knowledgeService;
    if (!knowledge) return;
    const pending = await knowledge.pendingObservationCoverage(100).catch(() => []);
    const config = await knowledge.store.config().catch(() => undefined);
    if (!config) return;
    // Recovery owns its canonical membership read; storage initialization is
    // not a presentation-catalog warmup. The indexed rows cannot turn a durable
    // pending cut into a claim that its session disappeared.
    // The first reconcile pass of this process, not merely a loaded durable
    // document: a mark this recovery writes is permanent, so it may only be
    // made against a cut that saw the folder now.
    if (pending.length > 0) await this.sessionCatalog.whenReconciled();
    for (const coverage of pending) {
      const markUnavailable = async (reason: string): Promise<void> => {
        await knowledge.store.setCoverage({
          commandId: `knowledge-recovery-unavailable-${coverage.id}`,
          expectedConfigRevision: config.revision,
          expectedRevision: coverage.revisionId,
          coverage: { ...coverage, disposition: "unavailable", groupRevisionIds: [], reason },
        }).catch(() => {});
      };
      let branch: FileEntry[];
      let canonicalEntries: FileEntry[];
      let branchId: string;
      const slot = this.slots.get(coverage.range.sessionId);
      if (slot && !slot.isDisposed) {
        canonicalEntries = slot.canonicalSessionEntries();
        branch = canonicalEntries.slice(1);
        branchId = slot.canonicalObservationBranchId();
      } else {
        // Read the admitted canonical file without constructing a live slot.
        // This keeps recovery useful after restart while avoiding foreground
        // ownership, model/session initialization, or a second runtime. The
        // indexed row is the membership, and the row's own file is read and
        // re-proved before it is used. An incomplete cut leaves the coverage
        // pending rather than claiming its session is gone.
        if (!this.sessionCatalog.hasReconciledCut()) continue;
        const candidates = this.sessionCatalog.rows()
          .filter((row) => row.id === coverage.range.sessionId)
          .map((row) => ({ path: row.path, id: row.id, cwd: row.cwd, fileIdentity: row.fileIdentity, size: row.size, mtimeMs: row.mtimeMs }));
        if (candidates.length !== 1) { await markUnavailable(candidates.length === 0 ? "canonical-session-unavailable" : "canonical-session-identity-ambiguous"); continue; }
        const candidate = candidates[0]!;
        let manager: SessionManager;
        try {
          manager = SessionManager.open(candidate.path, this.sessionDirectoryFor(candidate.cwd));
          const current = await lstat(candidate.path);
          if (!current.isFile() || current.isSymbolicLink()
            || `${current.dev}:${current.ino}` !== candidate.fileIdentity
            || current.size !== candidate.size || current.mtimeMs !== candidate.mtimeMs
            || manager.getSessionId() !== candidate.id || manager.getCwd() !== candidate.cwd) continue;
        } catch { await markUnavailable("canonical-session-read-failed"); continue; }
        canonicalEntries = manager.getHeader() ? [manager.getHeader()!, ...manager.getBranch()] : [];
        branch = canonicalEntries.slice(1);
        const anchor = await this.resolveForkBoundary(manager).catch(() => undefined);
        branchId = observationBranchIdFor(canonicalEntries, manager.getEntries(), anchor?.inheritedEntryId);
      }
      if (branchId !== (coverage.range.branchId ?? "root")) { await markUnavailable("coverage-branch-not-active"); continue; }
      const start = branch.findIndex(entry => entry.id === coverage.range.fromEntryId);
      if (start < 0) { await markUnavailable("coverage-start-is-unavailable"); continue; }
      const entries = branch.slice(start, start + coverage.range.entryIds.length);
      if (entries.length !== coverage.range.entryIds.length || entries.some((entry, index) => entry.id !== coverage.range.entryIds[index])) { await markUnavailable("coverage-entry-sequence-changed"); continue; }
      if (observationEntriesDigest(entries) !== coverage.range.entryDigest) { await markUnavailable("coverage-digest-changed"); continue; }
      // Recovery must retain the outcome admitted with this exact cut. A
      // restart is not evidence that a completed canonical invocation became
      // unknown; only a missing or contradictory Gateway terminal receipt is.
      const invocationIds = coverage.range.invocationIds;
      if (!invocationIds || invocationIds.length === 0) { await markUnavailable("invocation-provenance-missing"); continue; }
      let recoveredOutcome: "completed" | "failed" | "interrupted" | "outcomeUnknown";
      try {
        const projections = invocationProjection(invocationReceipts(canonicalEntries as unknown as Parameters<typeof invocationReceipts>[0], coverage.range.sessionId));
        const byInvocation = new Map(projections.map(projection => [projection.invocationId, projection]));
        const outcomes = invocationIds.map(invocationId => byInvocation.get(invocationId)?.lifecycle);
        if (outcomes.some(outcome => outcome === undefined)) { await markUnavailable("invocation-terminal-missing"); continue; }
        if (outcomes.some(outcome => !["completed", "failed", "interrupted", "outcomeUnknown"].includes(outcome as string))) { await markUnavailable("invocation-terminal-missing"); continue; }
        const distinct = new Set(outcomes);
        if (distinct.size !== 1) { await markUnavailable("invocation-terminal-conflict"); continue; }
        recoveredOutcome = outcomes[0] as "completed" | "failed" | "interrupted" | "outcomeUnknown";
      } catch {
        await markUnavailable("invocation-terminal-conflict");
        continue;
      }
      knowledge.observe({
        sessionId: coverage.range.sessionId, entries, outcome: recoveredOutcome,
        ...(coverage.range.branchId ? { branchId: coverage.range.branchId } : {}),
        ...(coverage.range.projectId ? { projectId: coverage.range.projectId } : {}),
        ...(coverage.range.invocationIds?.[0] ? { invocationId: coverage.range.invocationIds[0] } : {}),
        ...(coverage.range.invocationIds ? { invocationIds: coverage.range.invocationIds } : {}),
      });
    }
  }

  async initializeBlobStorage(): Promise<void> {
    // Loading durable storage must not require transcript-wide presentation
    // metadata. Preserve owners here; the maintenance pass prunes orphans only
    // after it obtains a complete catalog. A failed catalog is never absence.
    await Promise.all([
      this.blobs.initialize(),
      this.exports.initialize(),
      this.displayArtifacts.initialize(),
    ]);
    await Promise.all([...this.slots.values()].map((slot) => slot.reconcileDisplayArtifactOwnership()));
  }

  async maintainDisplayArtifacts(): Promise<void> {
    await this.displayArtifacts.maintain(() => this.sessionIDsForStorageMaintenance());
  }

  async removeDisplayArtifacts(sessionID: string): Promise<void> {
    await this.displayArtifactLane.run(() => this.displayArtifacts.removeSession(sessionID));
  }

  private async reconcileCanonicalAttention(
    markerEvidence: ReadonlyMap<string, readonly RunMarkerEvidence[]>,
  ): Promise<void> {
    const scanBoundary = new Date().toISOString();
    // Startup recovery uses the owner's first cut: one indexed row per canonical
    // file, which is the same membership the listeners serve from. An incomplete
    // cut cannot prove either membership or absence, so attention records and
    // the reconciliation cursor are kept for the next startup instead.
    if (!this.sessionCatalog.hasReconciledCut()) return;
    const byID = new Map<string, Array<{ path: string }>>();
    for (const row of this.sessionCatalog.rows()) {
      const candidates = byID.get(row.id) ?? [];
      candidates.push({ path: row.path });
      byID.set(row.id, candidates);
    }
    const retainedSessionIds = new Set(byID.keys());
    // Live ownership is membership too: a session that was opened or created
    // after this cut, or one that has not reached disk yet, must keep its
    // record. Recovery runs after the listener is already serving.
    for (const sessionId of this.slots.keys()) retainedSessionIds.add(sessionId);
    await this.attention.prune(retainedSessionIds);
    // Archive state is a display projection of the same membership, so it
    // recovers from the same complete cut or keeps its records untouched. It
    // serializes with delete and rebind, and each dropped record names its live
    // slot so an open snapshot cannot keep a timestamp the store no longer has.
    await this.attentionLane.run(async () => {
      // Live ownership is re-read inside the lane: a session created and archived
      // while the attention prune above was awaiting must keep its record, and
      // archive commits serialize on this same lane.
      const archiveRetained = new Set(retainedSessionIds);
      for (const sessionId of this.slots.keys()) archiveRetained.add(sessionId);
      const pruned = await this.archive.prune(archiveRetained);
      if (pruned.length > 0) this.archiveChanged(pruned);
    });
    for (const [sessionId, markers] of markerEvidence) {
      const candidates = byID.get(sessionId);
      // Duplicate IDs are intentionally not recoverable: choosing one file
      // would make attention state depend on enumeration order.
      if (!candidates || candidates.length !== 1) continue;
      const path = candidates[0]!.path;
      let manager: SessionManager;
      try { manager = SessionManager.open(path); }
      catch { continue; }
      for (const marker of markers) {
        const completion = completionOwnedByMarker(manager, marker);
        if (!completion) continue;
        await this.attention.complete(sessionId, completion.id);
        // Automation recovery must commit its own terminal record before this
        // exact marker is cleared. Ordinary prompt markers remain attention-owned.
        if (!marker.operationId.startsWith("automation:")) {
          await this.markers.clear(sessionId, marker.operationId);
        }
      }
    }
    await this.attention.advanceReconciliationCursor(scanBoundary);
  }

  private hooks() {
    return {
      broadcast: this.options.broadcast,
      summaryChanged: (summary: SessionSummaryUpdate) => {
        // A run that Pi started on its own (an extension's `triggerTurn`, a
        // scheduled wake) never reached run admission, so this is the only
        // boundary that can notice it. Visibility is restored before the
        // publication so the row is never both working and hidden, and a
        // retained override keeps retrying its durable clear.
        if (this.pendingArchiveRestorations.has(summary.sessionId) || sessionShowsWork(summary)) {
          this.restoreArchivedSession(summary.sessionId);
        }
        this.publishRevisionedSummary({ ...summary, ...this.attention.projection(summary.sessionId) });
        // The slot's summary commit point: every Gateway-owned canonical append
        // reaches the row here, without a reader walking the folder.
        void this.sessionCatalog.refresh(this.slots.get(summary.sessionId)?.persistedSessionFile);
      },
      changed: (sessionId: string) => {
        this.invalidateCatalogAcquisition();
        // A structural commit point (a rename or session-info entry): the row is
        // re-derived from the file. Message appends reach the row through the
        // summary commit point below.
        void this.sessionCatalog.refresh(this.slots.get(sessionId)?.persistedSessionFile);
        this.revision += 1;
        this.options.sessionListChanged();
      },
      settled: (sessionId: string) => { this.interrupted.delete(sessionId); },
      turnSettled: (sessionId: string, entries: readonly import("@earendil-works/pi-coding-agent").FileEntry[], outcome: "completed" | "failed" | "interrupted" | "outcomeUnknown", completionId?: string, branchId?: string, projectId?: string, invocationId?: string) => {
        // Admission is detached from inference, but RuntimeSlot invokes this
        // only after the terminal receipt and canonical attention barrier settle.
        this.knowledgeService?.observe({ sessionId, entries, outcome, ...(completionId ? { completionId } : {}), ...(branchId ? { branchId } : {}), ...(projectId ? { projectId } : {}), ...(invocationId ? { invocationId } : {}) });
      },
      assistantResponseCompleted: async (
        sessionId: string,
        completion: CanonicalAssistantCompletion,
        recovery: boolean,
        observed: boolean,
      ) => this.attentionLane.run(async () => {
        const result = await this.attention.complete(sessionId, completion.id, !recovery && observed);
        if (result.changed) await this.publishAttentionSummary(sessionId, result.projection);
      }),
      closed: (sessionId: string, slot: RuntimeSlot) => {
        const removed = this.slots.get(sessionId) === slot;
        const persistedPath = slot.persistedSessionFile;
        const removedLiveOnlySession = removed && persistedPath === undefined;
        const persistedPathWasIndexed = persistedPath !== undefined
          && this.sessionCatalog.rows().some((row) => row.id === sessionId
            && resolve(row.path) === resolve(persistedPath));
        if (removed) {
          this.slots.delete(sessionId);
          this.recordRuntimeEviction(sessionId, "closed");
        }
        this.cancelIdleEviction(sessionId, slot);
        // The transport owns subscription lifetime: it subscribes a client
        // before it installs that client's synchronization barrier and
        // unsubscribes it on close, revoke, or session close. A slot going away
        // (idle eviction, an extension-requested shutdown) is not an
        // unsubscribe, so a client still watching this session keeps its
        // audience and receives snapshots again once the session is acquired.
        this.presentationPresence.removeSession(sessionId);
        this.interrupted.delete(sessionId);
        if (removedLiveOnlySession) {
          // Empty runtime ownership is permanent only while the slot exists.
          // Retire both halves of its revisioned row projection together.
          this.summaryRevisions.delete(sessionId);
          this.latestSummaries.delete(sessionId);
          this.invalidateCatalogAdmission();
          this.revision += 1;
          this.options.sessionListChanged();
        } else if (removed && persistedPath !== undefined && !persistedPathWasIndexed) {
          // The slot may have created its canonical file after the cached disk
          // generation. Force the next catalog read to discover that file once
          // runtime ownership is no longer available as the row projection, and
          // apply the change to the catalog owner at the same commit point.
          this.invalidateCatalogAcquisition();
          void this.sessionCatalog.refresh(persistedPath);
        }
        // Persisted closure publishes a final idle summary before this hook and
        // retains its revision continuity; membership did not change.
        this.options.sessionClosed?.(sessionId);
      },
      rekey: async (
        previousId: string,
        nextId: string,
        slot: RuntimeSlot,
        disposition: SessionAttentionRebindDisposition,
        commitIdentity: () => void,
      ) => this.attentionLane.run(async () => {
        await this.flushPendingProjectionRemovals();
        if (this.deletingSessionIds.has(previousId) || this.deletingSessionIds.has(nextId)) {
          throw new GatewayError("busy", "Session identity is being deleted", true);
        }
        const existing = this.slots.get(nextId);
        if (existing && existing !== slot) throw new GatewayError("conflict", "Replacement session is already active");
        // Every fallible admission check runs before the first change, so a
        // rejected rebind cannot leave attention and archive state out of step
        // while the slot rolls back its identity. A reset identity (a new session
        // or a fork) starts unarchived, and a discarded identity takes its state
        // away, so both must claim an identity that owns nothing yet. A migrate
        // moves both records onto the replacement identity, which must therefore
        // own nothing either. A preserve rebind (an extension switching to an
        // existing session) is the opposite: the target already owns its records
        // and keeps them, so it takes no admission here.
        if (previousId !== nextId && disposition !== "preserve") {
          await this.attention.assertAbsent(nextId);
          await this.archive.assertAbsent(nextId);
        }
        // A reset identity (a new session or a fork) starts unarchived; a
        // migrated identity carries its archive state; a discarded identity
        // takes it away. Complete these writes while the slot and registry still
        // own previousId, then commit both in one synchronous turn.
        if (disposition === "migrate") {
          await this.attention.rekey(previousId, nextId);
          await this.archive.rekey(previousId, nextId);
          // Inbox rows carry the canonical session identity they belong to, so a
          // migrated identity takes its alerts with it instead of orphaning them.
          await this.options.notifications?.rekeySession(previousId, nextId);
        } else if (disposition === "discard") {
          await this.attention.remove(previousId);
          await this.archive.remove(previousId);
        }
        // A rebind ends any pending visible override: the identity changed, so
        // the previous ID's run is no longer the owner of either record.
        this.pendingArchiveRestorations.delete(previousId);
        this.pendingArchiveRestorations.delete(nextId);
        // The forked branch already owns its exact canonical display references.
        // Publish those owner links before committing the new session identity so
        // a successful fork can never expose a dangling artifact reference.
        for (const artifactID of slot.displayArtifactIDs()) {
          await this.displayArtifacts.grant(artifactID, nextId, previousId);
        }
        await this.options.beforeSessionRekey?.(previousId, nextId);
        // A rebind is the only identity change the Gateway owns: a reset
        // identity (new session or fork) persists beneath a new path, and a
        // migrate moves the row to the replacement's canonical file.
        const previousCatalogPath = slot.persistedSessionFile;
        commitIdentity();
        if (this.slots.get(previousId) === slot) this.slots.delete(previousId);
        this.slots.set(nextId, slot);
        // The charge follows the slot's identity: the runtime is the same live
        // runtime, so this is not an eviction.
        const previousCharge = this.publishedRuntimeBytes.get(previousId);
        if (previousCharge !== undefined) {
          this.publishedRuntimeBytes.delete(previousId);
          this.publishedRuntimeBytes.set(nextId, previousCharge);
        }
        if (disposition === "migrate" || disposition === "discard") {
          const previousSummaryRevision = this.summaryRevisions.get(previousId);
          this.summaryRevisions.delete(previousId);
          const previousSummary = this.latestSummaries.get(previousId);
          this.latestSummaries.delete(previousId);
          const wasInterrupted = this.interrupted.delete(previousId);
          if (disposition === "migrate") {
            if (previousSummaryRevision !== undefined) this.summaryRevisions.set(nextId, previousSummaryRevision);
            if (previousSummary) this.latestSummaries.set(nextId, { ...previousSummary, sessionId: nextId });
            if (wasInterrupted) this.interrupted.add(nextId);
          }
        }
        this.presentationPresence.rekey(previousId, nextId);
        const subscribers = this.subscribers.get(previousId);
        if (subscribers) {
          this.subscribers.delete(previousId);
          const destinationSubscribers = this.subscribers.get(nextId);
          if (destinationSubscribers) {
            for (const clientId of subscribers) destinationSubscribers.add(clientId);
          } else {
            this.subscribers.set(nextId, subscribers);
          }
        }
        // Identity and map ownership are already committed. Observers are
        // notification-only and cannot trigger the slot's pre-commit rollback.
        try { this.searchInvalidator?.(previousId, nextId); } catch {}
        try { this.options.sessionRekeyed?.(previousId, nextId); } catch {}
        this.invalidateCatalogAcquisition();
        void this.sessionCatalog.refresh(previousCatalogPath);
        void this.sessionCatalog.refresh(slot.persistedSessionFile);
        this.revision += 1;
        this.options.sessionListChanged();
      }),
    };
  }

  private publishRevisionedSummary(summary: SessionSummaryUpdate): void {
    this.catalogProjectionGeneration += 1;
    const summaryRevision = (this.summaryRevisions.get(summary.sessionId) ?? 0) + 1;
    this.summaryRevisions.set(summary.sessionId, summaryRevision);
    const revisioned = { ...summary, summaryRevision };
    this.latestSummaries.set(summary.sessionId, revisioned);
    try { this.searchInvalidator?.(summary.sessionId); } catch {}
    this.options.sessionSummaryChanged(revisioned);
  }

  /** Both pending sets are display projections of a deleted canonical session
   * and share one retry owner: the next lane operation, or restart
   * reconciliation for records with no canonical catalog owner. */
  private async flushPendingProjectionRemovals(): Promise<void> {
    for (const sessionId of [...this.pendingAttentionRemovals]) {
      try {
        await this.attention.remove(sessionId);
        this.pendingAttentionRemovals.delete(sessionId);
      } catch {
        // Retain for the next lane operation; restart reconciliation also
        // prunes records with no canonical catalog owner.
      }
    }
    for (const sessionId of [...this.pendingArchiveRemovals]) {
      try {
        if (await this.archive.remove(sessionId)) this.archiveChanged([sessionId]);
        this.pendingArchiveRemovals.delete(sessionId);
        this.pendingArchiveRestorations.delete(sessionId);
      } catch {
        // Retain for the next lane operation; restart reconciliation also
        // prunes records with no canonical catalog owner.
      }
    }
  }

  /** A committed archive change is a dashboard membership change, not a
   * transcript change, so it publishes a list revision instead of a summary.
   * Archive state is also part of a live slot's snapshot, so every named slot
   * republishes in the same call. */
  private archiveChanged(sessionIds: readonly string[] = []): void {
    this.revision += 1;
    this.options.sessionListChanged();
    for (const sessionId of sessionIds) this.slots.get(sessionId)?.refreshArchiveProjection();
  }

  private archivePersistFailed(stage: "set" | "remove" | "auto-unarchive"): void {
    // Privacy: outcome and stage only. A session ID would turn a bounded
    // storage diagnostic into a session-identifying record.
    this.options.archiveDiagnostic?.({ outcome: "failure", stage });
  }

  /** Effective archive projection. A pending record change is already visible:
   * a restoration's record could not be removed yet, and a removal's record
   * outlives a session that no longer exists, so the live outcome wins until
   * the store proves otherwise. */
  private archivedAt(sessionId: string): string | undefined {
    if (this.pendingArchiveRestorations.has(sessionId) || this.pendingArchiveRemovals.has(sessionId)) return undefined;
    return this.archive.archivedAt(sessionId);
  }

  /** Clears retained archive state before the Gateway admits a run. The owning
   * slot calls this inside its lane after every synchronous rejection and
   * immediately before run ownership begins, so no run can start while the
   * session is archived and a store failure rejects the run retryably instead of
   * running it hidden. It must not acquire the registry mutex: the archive
   * commit holds that mutex while it waits for the very lane this runs on. */
  private async beforeRunAdmission(sessionId: string): Promise<void> {
    // Cheap gate first: an unarchived session pays no store or lane cost. A
    // retained visible override still needs its durable clear, so it continues.
    if (!this.pendingArchiveRestorations.has(sessionId) && this.archive.archivedAt(sessionId) === undefined) return;
    await this.attentionLane.run(async () => {
      await this.flushPendingProjectionRemovals();
      let removed: boolean;
      try {
        removed = await this.archive.remove(sessionId);
      } catch {
        this.archivePersistFailed("auto-unarchive");
        throw new GatewayError("busy", "Session archive state could not be persisted", true);
      }
      this.pendingArchiveRestorations.delete(sessionId);
      if (removed) {
        this.archiveChanged([sessionId]);
        this.options.archiveDiagnostic?.({ outcome: "auto-unarchived", trigger: "admission" });
      }
    });
  }

  /** A run that reached the runtime without Gateway admission is already
   * underway and cannot be rejected, so its row becomes visible immediately and
   * the durable record is cleared behind it. A failed write keeps the session
   * visible and retries on the next publication. */
  private restoreArchivedSession(sessionId: string): void {
    if (!this.pendingArchiveRestorations.has(sessionId) && this.archive.archivedAt(sessionId) === undefined) return;
    const wasPending = this.pendingArchiveRestorations.has(sessionId);
    this.pendingArchiveRestorations.add(sessionId);
    // The effective projection flips on that in-memory override, but this runs
    // inside the slot's own publication (a summary is what noticed the run), so
    // the republish is queued behind the publisher rather than re-entering it.
    // A failed durable clear keeps the override and republishes again on the
    // next active projection.
    if (!wasPending) {
      // Visibility changes at this moment, so clients get the membership change
      // now: waiting for the durable clear would leave the device that archived
      // this session hiding a row that is already working.
      this.revision += 1;
      this.options.sessionListChanged();
      const slot = this.slots.get(sessionId);
      if (slot) queueMicrotask(() => slot.refreshArchiveProjection());
    }
    if (this.archiveRestorationAttempts.has(sessionId)) return;
    // The stored promise removes its own entry before it settles, so a disposal
    // drain can await this map until it is empty.
    const attempt = this.clearArchivedRecord(sessionId).finally(() => {
      if (this.archiveRestorationAttempts.get(sessionId) === attempt) this.archiveRestorationAttempts.delete(sessionId);
    });
    this.archiveRestorationAttempts.set(sessionId, attempt);
  }

  private async clearArchivedRecord(sessionId: string): Promise<void> {
    try {
      const removed = await this.attentionLane.run(async () => {
        await this.flushPendingProjectionRemovals();
        // A re-archive that committed while this clear was queued behind it has
        // already retired the restoration, so the record on disk is the new
        // archive and must survive.
        if (!this.pendingArchiveRestorations.has(sessionId)) return false;
        const removed = await this.archive.remove(sessionId);
        this.pendingArchiveRestorations.delete(sessionId);
        return removed;
      });
      if (removed) {
        this.archiveChanged();
        this.options.archiveDiagnostic?.({ outcome: "auto-unarchived", trigger: "backstop" });
      }
    } catch {
      // The row stays visible through the pending restoration; the next
      // published summary retries this exact record.
      this.archivePersistFailed("auto-unarchive");
    }
  }

  /** The row state a dashboard client sees for one session: the published
   * summary first, then the live slot, so a cold session still reports its row
   * state. Archive admission and archive restoration share it. */
  private dashboardProjection(sessionId: string, slot: RuntimeSlot | undefined): {
    phase: SessionSummary["phase"];
    foregroundPhase: SessionSummary["foregroundPhase"];
    waitingForUser: boolean;
    hasActiveSubagents: boolean;
  } {
    const latest = this.latestSummaries.get(sessionId);
    return {
      phase: latest?.phase ?? (slot ? slot.catalogPhase : "idle"),
      foregroundPhase: latest?.foregroundPhase ?? slot?.catalogForegroundPhase,
      waitingForUser: latest?.waitingForUser ?? slot?.catalogWaitingForUser ?? false,
      hasActiveSubagents: latest?.hasActiveSubagents ?? slot?.catalogHasActiveSubagents ?? false,
    };
  }

  /** An archived session must be idle. The dashboard projection is checked as
   * well as the slot's own run ownership, so a user can never archive a row
   * that still shows running, waiting for input, or working through detached
   * subagents. */
  private assertArchiveIdle(sessionId: string, slot: RuntimeSlot | undefined): void {
    if (sessionShowsWork(this.dashboardProjection(sessionId, slot))) {
      throw new GatewayError("busy", "Stop the session before archiving it", false, undefined, "session_operation_busy");
    }
  }

  /** The durable record can land after a run Pi started on its own (an
   * extension `triggerTurn`) escaped run admission, because the backstop
   * published before the record existed and reads that same record. Visibility
   * wins: the row is restored and the clear retries behind it. */
  private restoreArchivedSessionIfWorking(sessionId: string, slot: RuntimeSlot | undefined): void {
    if (!slot || !sessionShowsWork(this.dashboardProjection(sessionId, slot))) return;
    this.restoreArchivedSession(sessionId);
  }

  private async publishAttentionSummary(
    sessionId: string,
    projection: SessionAttentionProjection = this.attention.projection(sessionId),
  ): Promise<void> {
    // Completion originates from a live slot, whose latest full row projection
    // is already retained. Never reacquire the catalog here: doing so could
    // fabricate a row while duplicate-ID discovery is quarantining membership.
    const summary = this.latestSummaries.get(sessionId);
    if (!summary) return;
    this.publishRevisionedSummary({ ...summary, ...projection });
  }

  attentionProjection(sessionId: string): SessionAttentionProjection {
    return this.attention.projection(sessionId);
  }

  private async resolveAttentionAdmission(sessionId: string): Promise<{
    generation: number;
    entry?: CatalogAcquisitionEntry;
    liveOnlySlot?: RuntimeSlot;
    persistedSlot?: RuntimeSlot;
  }> {
    // A live persisted slot owns its canonical file, which is the same
    // membership proof `acquire` accepts. Opening a chat acknowledges attention
    // immediately, so this must not cost a whole-catalog header walk.
    const persistedSlot = this.slots.get(sessionId);
    if (persistedSlot && !persistedSlot.isDisposed && persistedSlot.persistedSessionFile !== undefined
      && !this.ambiguousSessionIds.has(sessionId)) {
      return { generation: this.catalogAcquisitionInvalidationGeneration, persistedSlot };
    }
    const { acquisition, entry } = await stage("attention.resolve", () => this.catalogMembership(sessionId));
    this.requireUnambiguousSessionId(sessionId, acquisition.ambiguousIDs);
    if (entry) return { generation: this.catalogAcquisitionInvalidationGeneration, entry };
    // Empty sessions are visible before their first canonical append. Their
    // exact runtime owner is a valid attention target until it is persisted or
    // disposed; a disk claimant would already be quarantined above.
    const liveOnlySlot = this.slots.get(sessionId);
    if (liveOnlySlot && !liveOnlySlot.isDisposed && liveOnlySlot.persistedSessionFile === undefined) {
      return { generation: this.catalogAcquisitionInvalidationGeneration, liveOnlySlot };
    }
    throw new GatewayError("not_found", "Tron session was not found");
  }

  async setAttention(sessionId: string, unread: boolean, throughCompletionRevision?: number): Promise<SessionAttentionProjection> {
    // Membership resolution is deliberately outside the attention lane. A cold
    // catalog read must not block completion/rekey/delete ordering for every
    // other session. Internal catalog mutations advance the generation and are
    // rechecked immediately before the durable attention commit.
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const admission = await this.resolveAttentionAdmission(sessionId);
      const result = await this.attentionLane.run(async () => {
        await this.flushPendingProjectionRemovals();
        if (this.deletingSessionIds.has(sessionId)) {
          throw new GatewayError("not_found", "Tron session was not found");
        }
        const current = await this.catalogAcquisition();
        const currentEntry = current.entriesByID.get(sessionId);
        const currentLiveOnly = this.slots.get(sessionId);
        const admittedEntry = admission.entry;
        if (admission.persistedSlot !== undefined) {
          // Runtime ownership, not unrelated catalog churn, fences this commit.
          if (currentLiveOnly !== admission.persistedSlot || currentLiveOnly.isDisposed
            || currentLiveOnly.persistedSessionFile === undefined
            || this.ambiguousSessionIds.has(sessionId)) return undefined;
        } else if (admission.generation !== this.catalogAcquisitionInvalidationGeneration
          || admittedEntry !== undefined && (
            currentEntry === undefined
            || currentEntry.path !== admittedEntry.path
            || currentEntry.id !== admittedEntry.id
            || currentEntry.fileIdentity !== admittedEntry.fileIdentity
          )
          || admission.liveOnlySlot !== undefined && (
            currentEntry !== undefined
            || currentLiveOnly !== admission.liveOnlySlot
            || currentLiveOnly.isDisposed
            || currentLiveOnly.persistedSessionFile !== undefined
          )) {
          return undefined;
        }
        if (admittedEntry !== undefined && !(await this.attentionEntryStillAdmitted(admittedEntry))) {
          return undefined;
        }
        if (admission.liveOnlySlot !== undefined
          && !(await this.attentionLiveOnlyStillAdmitted(sessionId))) {
          return undefined;
        }
        const result = await stage(
          "attention.persist",
          () => this.attention.set(sessionId, unread, throughCompletionRevision),
        );
        if (result.changed) {
          // The store write may suspend while a live summary advances. Merge into
          // the newest retained facts rather than stamping stale catalog fields
          // with a newer summary revision. A missing live summary still advances
          // the captured page-overlay generation directly.
          const latest = this.latestSummaries.get(sessionId);
          if (latest) this.publishRevisionedSummary({ ...latest, sessionId, ...result.projection });
          else {
            // Cold rows have no retained summary to merge. Invalidate every
            // connected catalog owner so it refetches the authoritative
            // attention projection; never fabricate a summary event here.
            this.catalogProjectionGeneration += 1;
            this.options.sessionListChanged();
          }
        }
        return result.projection;
      });
      if (result) return result;
    }
    throw new GatewayError("busy", "Session catalog changed while updating attention", true, undefined, "catalog_changed");
  }

  /** Resolve the inherited transition at runtime bind time. The result is a
   * disposable projection, fenced by catalog admission and the parent inode;
   * snapshots never perform parent I/O. */
  private async resolveForkBoundary(manager: SessionManager): Promise<ForkBoundaryAnchor | undefined> {
    const parentPath = manager.getHeader()?.parentSession;
    if (!parentPath) return undefined;
    try {
      const acquisition = await this.catalogAcquisition();
      const parentCanonical = await realpath(parentPath);
      const parentCandidates = [...acquisition.entriesByID.values()].filter((entry) => resolve(entry.path) === parentCanonical);
      if (parentCandidates.length !== 1 || acquisition.ambiguousIDs.has(parentCandidates[0]!.id)) return undefined;
      const admittedParent = parentCandidates[0]!;
      const parentID = admittedParent.id;
      const admittedIdentity = admittedParent.fileIdentity;
      if (!admittedIdentity) return undefined;
      const parentSlot = this.slots.get(parentID);
      let parentEntries;
      if (parentSlot && !parentSlot.isDisposed && parentSlot.sessionFile) {
        const livePath = await realpath(parentSlot.sessionFile);
        const liveStat = await stat(livePath);
        if (livePath !== parentCanonical || `${liveStat.dev}:${liveStat.ino}` !== admittedIdentity) return undefined;
        parentEntries = parentSlot.canonicalSessionEntries();
      } else {
        const handle = await open(parentCanonical, "r");
        try {
          const metadata = await handle.stat();
          if (!metadata.isFile() || `${metadata.dev}:${metadata.ino}` !== admittedIdentity) return undefined;
          if (metadata.size > 0) {
            const last = Buffer.alloc(1);
            const { bytesRead } = await handle.read(last, 0, 1, metadata.size - 1);
            if (bytesRead !== 1 || last[0] !== 0x0a) return undefined;
          }
          parentEntries = await readOpenedSessionEntries(handle, metadata.size);
          const after = await handle.stat();
          if (after.size < metadata.size
            || after.size === metadata.size && after.mtimeMs !== metadata.mtimeMs) return undefined;
        } finally { await handle.close(); }
      }
      const finalParent = await lstat(parentCanonical);
      if (!finalParent.isFile() || finalParent.isSymbolicLink()
        || `${finalParent.dev}:${finalParent.ino}` !== admittedIdentity) return undefined;
      const childHeader = manager.getHeader();
      if (childHeader?.parentSession !== parentPath) return undefined;
      const childEntries = childHeader ? [childHeader, ...manager.getEntries()] : [];
      if (!parentEntries || !childEntries.length || parentEntries[0]?.type !== "session"
        || parentEntries[0].id !== parentID) return undefined;
      return resolveForkBoundaryAnchor(childEntries, parentEntries, "sessionFork", manager.getLeafId());
    } catch {
      // A missing, replaced, oversized, malformed, or ambiguous parent cannot
      // justify a marker; transcript projection remains fully available.
      return undefined;
    }
  }

  private dependencies() {
    this.options.managedSubagents?.requireBoundArtifactRoot(this.options.tronHome);
    return {
      agentDir: this.options.agentDir,
      ...(this.options.managedSubagents ? { managedSubagents: this.options.managedSubagents } : {}),
      ...(this.options.delegatedArtifactRoot ? { delegatedArtifactRoot: this.options.delegatedArtifactRoot } : {}),
      ...(this.options.mcpAuth ? { mcpAuth: this.options.mcpAuth } : {}),
      openAIModelEligibility: this.openAIModelEligibility,
      createModelRuntime: async () => {
        const runtime = applyJevModelPricing(installKimiK3Policy(await (this.options.modelRuntimeFactory ?? (() => ModelRuntime.create({
          authPath: join(this.options.agentDir, "auth.json"),
          modelsPath: join(this.options.agentDir, "models.json"),
          modelsStorePath: join(this.options.agentDir, "models-store.json"),
          refreshOnCreate: true,
          allowModelNetwork: false,
        })))()));
        return runtime;
      },
      trust: this.options.trust,
      blobs: this.blobs,
      exports: this.exports,
      displayArtifacts: this.displayArtifacts,
      ...(this.options.browserLiveViews ? { browserLiveViews: this.options.browserLiveViews } : {}),
      workspace: this.workspace,
      markers: this.markers,
      extensionActivityRecency: this.extensionActivityRecency,
      processActivityRecency: this.processActivityRecency,
      workRegistry: this.workRegistry,
      noteModelUsed: (sessionId: string, model: { provider: string; id: string }) => { void this.noteModelUsed(sessionId, model); },
      ...(this.options.persistenceDiagnostic ? { persistenceDiagnostic: this.options.persistenceDiagnostic } : {}),
      ...(this.options.compactionDiagnostic ? { compactionDiagnostic: this.options.compactionDiagnostic } : {}),
      ...(this.options.stopSteeringDiagnostic ? { stopSteeringDiagnostic: this.options.stopSteeringDiagnostic } : {}),
      ...(this.options.manualCompactionAdopted ? { manualCompactionAdopted: this.options.manualCompactionAdopted } : {}),
      ...(this.options.codemodeDiagnostic ? { codemodeDiagnostic: this.options.codemodeDiagnostic } : {}),
      isSessionPresented: (sessionId: string) => this.isSessionPresented(sessionId),
      sessionAudience: (sessionId: string) => this.subscribers.get(sessionId)?.size ?? 0,
      ...(this.options.resources ? { resources: this.options.resources } : {}),
      beforeRunAdmission: (sessionId: string) => this.beforeRunAdmission(sessionId),
      archivedAt: (sessionId: string) => this.archivedAt(sessionId),
      ...(this.options.machineId ? { machineId: this.options.machineId } : {}),
      ...(this.options.notifications ? { notifications: this.options.notifications } : {}),
      ...(this.options.extensionArtifactWarning ? { extensionArtifactWarning: this.options.extensionArtifactWarning } : {}),
      ...(this.options.scheduleToolOperations ? { scheduleToolOperations: this.options.scheduleToolOperations } : {}),
      ...(this.knowledgeService ? { knowledge: this.knowledgeService } : {}),
      ...(this.options.jev ? { jev: this.options.jev } : {}),
      ...(this.options.connections ? { connections: this.options.connections } : {}),
      resolveForkBoundary: (manager: SessionManager) => this.resolveForkBoundary(manager),
      ...(this.options.runtimeDisposeTimeout ? { runtimeDisposalTimedOut: this.options.runtimeDisposeTimeout } : {}),
    };
  }

  private configuredSessionDirectory(): string | undefined {
    return this.configuredSessionDir;
  }

  private sessionDirectoryFor(cwd: string): string {
    const configured = this.configuredSessionDirectory();
    if (configured) return configured;
    const safePath = `--${resolve(cwd).replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`;
    return join(this.options.agentDir, "sessions", safePath);
  }

  private catalogDirectory(): string {
    return this.configuredSessionDirectory() ?? join(this.options.agentDir, "sessions");
  }

  private catalogDiscoveryLimits() {
    return { ...DEFAULT_CATALOG_DISCOVERY_LIMITS, ...this.options.catalogDiscoveryLimits };
  }

  private catalogDiscovery(): CatalogDiscovery {
    const options: CatalogDiscoveryOptions = {
      limits: this.catalogDiscoveryLimits(),
      catalogDirectory: () => this.catalogDirectory(),
      catalogCapacityExceeded: () => this.catalogCapacityExceeded(),
      isLiveRuntimeOwnedPath: (path, sessionID) => this.isLiveRuntimeOwnedPath(path, sessionID),
      canonicalSessionPath: (path) => this.canonicalSessionPath(path),
      delegatedTopologyParentPath: delegatedSessionParentPath,
    };
    return new CatalogDiscovery(options);
  }

  private catalogCapacityExceeded(): never {
    throw new GatewayError("busy", "Session catalog discovery exceeds its bounded capacity", true, undefined, "catalog_capacity");
  }

  private invalidateCatalogAdmission(): void {
    this.catalogAcquisitionInvalidationGeneration += 1;
  }

  private invalidateCatalogAcquisition(): void {
    this.invalidateCatalogAdmission();
    this.catalogStructuralGeneration += 1;
    this.catalogProjectionGeneration += 1;
  }

  /** The request path's only membership source (G-1c): the owner's rows, kept
   * current by the Gateway's own commit points and by the folder watcher. No
   * I/O, so no request can walk the session folder. */
  private catalogIndex(scope: "user" | "all"): CatalogIndexCut {
    const rows = this.sessionCatalog.rows();
    const scoped = scope === "user" ? rows.filter((row) => !row.delegated) : rows;
    const allInfos: CatalogSessionInfo[] = scoped.map((row) => ({
      id: row.id,
      path: row.path,
      cwd: row.cwd,
      ...(row.parentSessionPath ? { parentSessionPath: row.parentSessionPath } : {}),
      ...(row.name ? { name: row.name } : {}),
      created: new Date(row.createdAt),
      modified: new Date(row.updatedAt),
      messageCount: row.messageCount,
      firstMessage: row.firstMessage,
      fileIdentity: row.fileIdentity,
      ...(row.creationOrigin ? { creationOrigin: row.creationOrigin } : {}),
    }));
    const ambiguousIDs = this.indexAmbiguousSessionIds();
    return {
      allInfos,
      infos: allInfos.filter((info) => !ambiguousIDs.has(info.id)),
      ambiguousIDs,
    };
  }

  /** A duplicate ID is an admission property of the whole canonical tree, so
   * the quarantine set always comes from every indexed row, not one scope. A
   * live-only runtime that claims an indexed ID is a second claimant too. */
  private indexAmbiguousSessionIds(): Set<string> {
    const ambiguous = new Set(this.sessionCatalog.duplicateSessionIds());
    const indexedIDs = new Set(this.sessionCatalog.rows().map((row) => row.id));
    for (const [id, slot] of this.slots) {
      // A persisted slot is the runtime owner of its indexed canonical file,
      // not a second claimant. Only live-only ownership colliding with any disk
      // identity creates an additional ambiguity.
      if (!slot.isDisposed && slot.persistedSessionFile === undefined && indexedIDs.has(id)) {
        ambiguous.add(id);
      }
    }
    return ambiguous;
  }

  /** A read needs a cut the owner has already published: the durable rows it
   * loaded, or a reconcile it completed. Nothing waits here — a read that lands
   * before either is a retryable `busy`, so a client retries instead of a
   * request parking on an owner that may never publish. The reason is its own,
   * so an unready catalog is never mistaken for capacity pressure. */
  private requireCatalogCut(): void {
    if (this.sessionCatalog.hasCompleteCut()) return;
    throw new GatewayError(
      "busy", "The session catalog has not been read yet", true, undefined, "catalog_not_ready",
    );
  }

  private async canonicalSessionPath(path: string): Promise<string> {
    try { return await realpath(path); }
    catch {
      const resolvedPath = resolve(path);
      const configuredRoot = resolve(this.catalogDirectory());
      const fromCatalog = relative(configuredRoot, resolvedPath);
      if (fromCatalog !== "" && fromCatalog !== ".." && !fromCatalog.startsWith(`..${sep}`)
        && !isAbsolute(fromCatalog)) {
        const canonicalRoot = await realpath(configuredRoot).catch(() => configuredRoot);
        return join(canonicalRoot, fromCatalog);
      }
      return resolvedPath;
    }
  }

  async list(scope: "user" | "all" = "user"): Promise<SessionSummary[]> {
    return (await this.catalog(scope)).sessions;
  }

  /** Artifact retention needs membership, never transcript metadata. The index
   * is that membership, and ambiguous canonical IDs still retain their data.
   * Live-only slots also retain their staged artifacts. */
  async sessionIDsForStorageMaintenance(): Promise<ReadonlySet<string>> {
    // Retention prunes artifacts an owner is not in. An incomplete cut is not
    // membership evidence, so it must refuse rather than tell the store that a
    // session it could not read is gone.
    this.requireCompleteCatalogCut();
    const ids = new Set(this.sessionCatalog.rows().map((row) => row.id));
    for (const slot of this.slots.values()) if (!slot.isDisposed) ids.add(slot.id);
    return ids;
  }

  /** Automation admission and recovery run at startup, before the owner may have
   * published a cut: `initialize()` starts the owner and returns. Wait for its
   * first pass, then require the cut — a catalog that still has none is deferred
   * retryably instead of being reported as a missing session, so a slow first
   * read cannot fail startup or turn into a terminal automation outcome. */
  private async awaitAutomationCatalogCut(): Promise<void> {
    if (!this.sessionCatalog.hasCompleteCut()) {
      await Promise.race([this.sessionCatalog.whenPublished(), this.sessionCatalog.whenReconciled()]);
    }
    this.requireCatalogCut();
  }

  /** Membership for one named session. A Gateway-owned change reaches the index
   * at its commit point (G-1a) but asynchronously, so a read that lands between
   * a slot's close and its row must wait for that change rather than answer
   * that the session does not exist: a session must never become unopenable
   * because its runtime closed. */
  private async catalogMembership(sessionId: string): Promise<{
    acquisition: CatalogAcquisitionResolution;
    entry: CatalogAcquisitionEntry | undefined;
  }> {
    const acquisition = await this.catalogAcquisition();
    const entry = acquisition.entriesByID.get(sessionId);
    if (entry) return { acquisition, entry };
    await this.sessionCatalog.awaitQueuedChanges();
    if (this.sessionCatalog.rows().some((row) => row.id === sessionId)) {
      const refreshed = await this.catalogAcquisition();
      return { acquisition: refreshed, entry: refreshed.entriesByID.get(sessionId) };
    }
    return { acquisition, entry };
  }

  /** An ID that may name a canonical file the owner could not prove is not a
   * missing session: reporting absence would tell a client that a session's
   * records and artifacts are gone when the file is still there. A pass that
   * could read the file's header names the ID exactly; one that could not leaves
   * membership unknown for the whole cut. Both refuse retryably. */
  private unprovenSessionRefusal(sessionId: string): GatewayError | undefined {
    if (this.sessionCatalog.unprovenSessionIds().has(sessionId)) {
      return new GatewayError(
        "busy", "The session's canonical file is not yet provable", true, undefined, "catalog_not_ready",
      );
    }
    if (this.sessionCatalog.hasUnknownMembership()) {
      return new GatewayError(
        "busy", "Session membership is not fully proven yet", true, undefined, "catalog_not_ready",
      );
    }
    return undefined;
  }

  /** A cut no scan has completed cannot prove absence. An unproven file whose
   * ID the owner read has no row to return and is only in the owner's unproven
   * set, so callers that would drop durable records or artifacts for the rows a
   * cut omits fail retryably instead of acting on it: refusing is what keeps
   * that session's record in the retained set. */
  private requireCompleteCatalogCut(): void {
    if (!this.sessionCatalog.hasReconciledCut()) {
      throw new GatewayError("busy", "Session membership could not be validated for storage maintenance", true);
    }
  }

  async requireResolvedAutomationWorkspace(cwd: string): Promise<string> {
    return (await this.options.trust.requireResolved(cwd)).cwd;
  }

  async workspaceForSession(sessionId: string): Promise<string> {
    const { acquisition, entry } = await this.catalogMembership(sessionId);
    this.requireUnambiguousSessionId(sessionId, acquisition.ambiguousIDs);
    if (!entry) throw new GatewayError("not_found", "Tron session was not found");
    return (await this.options.trust.requireResolved(entry.canonicalCwd)).cwd;
  }

  async requirePersistedUserSession(sessionId: string): Promise<void> {
    await this.awaitAutomationCatalogCut();
    const { acquisition, entry } = await this.catalogMembership(sessionId);
    this.requireUnambiguousSessionId(sessionId, acquisition.ambiguousIDs);
    if (!entry) throw this.unprovenSessionRefusal(sessionId)
      ?? new GatewayError("not_found", "Automation target session was not found");
    if (entry.structuralSubagent) {
      throw new GatewayError("conflict", "Automations cannot target runtime-owned subagent sessions");
    }
    if (!await this.attentionEntryStillAdmitted(entry)) {
      throw new GatewayError("busy", "Automation target changed during validation", true);
    }
  }

  async acquireAutomationLease(sessionId: string): Promise<{ slot: RuntimeSlot; release: () => void }> {
    const slot = await this.acquire(sessionId);
    return this.mutex.run(() => {
      if (this.deletingSessionIds.has(sessionId) || this.slots.get(sessionId) !== slot
        || slot.persistedSessionFile === undefined) {
        throw new GatewayError("busy", "Automation target is being removed or is not yet persisted", true);
      }
      return { slot, release: slot.retainLease() };
    });
  }

  async automationRecoveryEvidence(sessionId: string, operationId: string): Promise<{
    marker?: RunMarkerEvidence;
    invocation?: InvocationProjection;
  }> {
    // The scheduler's recovery runs at startup: wait for the owner's first pass
    // rather than deciding an automation's outcome on an unready catalog.
    await this.awaitAutomationCatalogCut();
    const { acquisition, entry } = await this.catalogMembership(sessionId);
    this.requireUnambiguousSessionId(sessionId, acquisition.ambiguousIDs);
    if (!entry || entry.structuralSubagent) return {};
    let manager: SessionManager;
    try { manager = SessionManager.open(entry.path, this.sessionDirectoryFor(entry.canonicalCwd)); }
    catch { return {}; }
    const marker = (await this.markers.evidenceFor(sessionId)).find((candidate) => candidate.operationId === operationId);
    const invocation = invocationProjection(invocationReceipts(manager.getBranch(), sessionId))
      .find((candidate) => candidate.operationId === operationId);
    return {
      ...(marker === undefined ? {} : { marker }),
      ...(invocation === undefined ? {} : { invocation }),
    };
  }

  async clearAutomationMarker(sessionId: string, operationId: string): Promise<void> {
    if (!operationId.startsWith("automation:")) throw new Error("Only automation markers may be cleared through this boundary");
    await this.markers.clear(sessionId, operationId);
    if ((await this.markers.evidenceFor(sessionId)).length === 0) this.noteRecoveredMarkerCleared(sessionId);
  }

  async reconcileStoredAutomationMarkers(
    terminalOperations: ReadonlyMap<string, ReadonlySet<string>>,
  ): Promise<void> {
    const evidence = await this.markers.evidence();
    for (const [sessionId, markers] of evidence) {
      const terminal = terminalOperations.get(sessionId);
      if (!terminal) continue;
      for (const marker of markers) {
        if (marker.operationId.startsWith("automation:") && terminal.has(marker.operationId)) {
          await this.markers.clear(sessionId, marker.operationId);
        }
      }
      if ((await this.markers.evidenceFor(sessionId)).length === 0) this.noteRecoveredMarkerCleared(sessionId);
    }
  }

  /** A recovered marker is a catalog overlay in one place only: a row with no
   * live summary and no slot reads its `phase` from this set. Removing it moves
   * that row from `interrupted` to `idle`, which is a projection change like
   * any other, so the token has to move or a connected owner naming the old one
   * would keep showing `interrupted` (G-7). */
  private noteRecoveredMarkerCleared(sessionId: string): void {
    if (!this.interrupted.delete(sessionId)) return;
    this.catalogProjectionGeneration += 1;
    this.options.sessionListChanged();
  }

  private async catalogStructureEvidence(): Promise<import("./catalog-discovery.js").CatalogStructureEvidence> {
    // The catalog owner's scan is the only whole-folder walk left. It goes
    // through this one seam, which counts it and says whether a request started
    // it: the request path's "zero catalog walks" criterion (G-1c) is readable
    // from the record, and a walk a read *waits on* is still created here.
    const startedAt = performance.now();
    const requestPath = currentRequestSpan() !== undefined;
    const evidence = await this.catalogDiscovery().catalogStructureEvidence();
    this.options.resources?.recordCatalogWalk(
      performance.now() - startedAt,
      evidence.identitiesByPath.size,
      requestPath,
    );
    return evidence;
  }

  /** The catalog owner's canonical readers. Its scan is this registry's counted
   * walk, run by the owner (startup, its interval, or a watcher event the owner
   * cannot resolve from one path), and one file's row is read from that exact
   * file: a live slot summary is a presentation overlay, never catalog
   * authority. No request-path reader calls this. */
  private sessionCatalogSource(): SessionCatalogSource {
    return {
      scan: async () => {
        const evidence = await this.catalogStructureEvidence();
        return {
          complete: evidence.complete,
          candidates: [...evidence.identitiesByPath].map(([path, identity]) => ({
            path, id: identity.id, cwd: identity.cwd, fileIdentity: identity.fileIdentity,
            size: identity.size, mtimeMs: identity.mtimeMs,
          })),
          unproven: [...evidence.unprovenPaths],
        };
      },
      summaryFor: (path, yieldToLoop) => this.canonicalCatalogSummary(path, yieldToLoop),
    };
  }

  private async canonicalCatalogSummary(
    path: string,
    yieldToLoop?: () => Promise<void>,
  ): Promise<CatalogMetadataIndexSummary | undefined> {
    // Pi appends synchronously between this read's awaits, so a summary is only
    // published with the size it actually parsed: the row's counts describe that
    // prefix, and a later size would claim messages it never counted.
    for (let attempt = 0; attempt < CATALOG_SUMMARY_ATTEMPTS; attempt += 1) {
      const before = await lstat(path).catch(() => undefined);
      if (!before?.isFile() || before.isSymbolicLink()) return undefined;
      const info = await buildCatalogSessionInfo(path, yieldToLoop);
      const after = await lstat(path).catch(() => undefined);
      if (!info || !after?.isFile() || after.isSymbolicLink()) return undefined;
      if (after.size !== before.size || after.mtimeMs !== before.mtimeMs) continue;
      return {
        id: info.id, path: info.path, cwd: info.cwd,
        // The row's parent path is the same canonical form every other catalog
        // comparison uses; a header may name its parent through a symlinked root.
        ...(info.parentSessionPath
          ? { parentSessionPath: await this.canonicalSessionPath(info.parentSessionPath) }
          : {}),
        ...(info.creationOrigin ? { creationOrigin: info.creationOrigin } : {}),
        ...(info.name ? { name: info.name } : {}),
        firstMessage: info.firstMessage,
        createdAt: info.created.toISOString(), updatedAt: info.modified.toISOString(),
        messageCount: info.messageCount,
        parsedSize: after.size,
      };
    }
    return undefined;
  }

  private async readCatalogHeader(
    path: string,
    maximumBytes: number,
    reserveBytes: (count: number) => boolean,
    refundBytes: (count: number) => void,
    allowAppendOnlyLiveOwner = false,
  ): Promise<{ identity?: CatalogHeaderIdentity; unstable?: boolean }> {
    return this.catalogDiscovery().readCatalogHeader(
      path, maximumBytes, reserveBytes, refundBytes, allowAppendOnlyLiveOwner,
    );
  }

  private isLiveRuntimeOwnedPath(path: string, sessionID: string): boolean {
    const canonicalPath = resolve(path);
    return [...this.slots.values()].some((slot) => !slot.isDisposed
      && slot.id === sessionID
      && slot.persistedSessionFile !== undefined
      && resolve(slot.persistedSessionFile) === canonicalPath);
  }

  /** An empty runtime that has not persisted yet is a valid attention target
   * only while no indexed row claims its ID. */
  private async attentionLiveOnlyStillAdmitted(sessionId: string): Promise<boolean> {
    return !this.sessionCatalog.rows().some((row) => row.id === sessionId);
  }

  /** The commit fence for one admitted row: the index must still claim this
   * exact file, and that file's own stat and header must still be the ones the
   * index admitted. No other file is read, so a request never walks the tree. */
  private async attentionEntryStillAdmitted(entry: CatalogAcquisitionEntry): Promise<boolean> {
    const claimants = this.sessionCatalog.rows().filter((row) => row.id === entry.id);
    if (claimants.length !== 1 || resolve(claimants[0]!.path) !== entry.path) return false;
    if (claimants[0]!.fileIdentity !== entry.fileIdentity
      || resolve(claimants[0]!.cwd || process.cwd()) !== entry.canonicalCwd) return false;
    let metadata: Awaited<ReturnType<typeof lstat>>;
    try { metadata = await lstat(entry.path); }
    catch { return false; }
    if (!metadata.isFile() || metadata.isSymbolicLink()) return false;
    if (entry.fileIdentity !== undefined && `${metadata.dev}:${metadata.ino}` !== entry.fileIdentity) return false;
    // A same-inode rewrite can change the header without moving the index. Re-read
    // only this bounded header at the commit boundary.
    const headerIdentity = (await this.readCatalogHeader(
      entry.path,
      this.catalogDiscoveryLimits().maximumHeaderBytesPerFile,
      () => true,
      () => {},
    )).identity;
    return headerIdentity?.id === entry.id
      && resolve(headerIdentity.cwd || process.cwd()) === entry.canonicalCwd
      && headerIdentity.fileIdentity === `${metadata.dev}:${metadata.ino}`;
  }

  async pageSource(
    scope: "user" | "all" = "user",
    archived: SessionArchiveFilter = "exclude",
  ): Promise<CatalogPageSource> {
    // Structural materialization is the admission boundary. Live summary,
    // attention and archive overlays are captured synchronously below, after
    // I/O completes, so ordinary heartbeat churn cannot starve catalog reads.
    const materialized = await this.sharedCatalogMaterialization(scope);
    const projectionGeneration = this.catalogProjectionGeneration;
    // The archive filter and its committed revision are part of the generation:
    // one pagination lease can never mix archive states or serve a stale filter.
    const generation = `${materialized.listRevision}:${materialized.factsDigest}:${projectionGeneration}:${scope}:${archived}:${this.archive.revision}`;
    const existing = this.catalogPageSources.get(generation)?.deref();
    if (existing) return existing;
    const seeds = this.buildCatalogPageSeeds(materialized.infos, scope, materialized.ambiguousIDs);
    const archivedCount = seeds.reduce((total, seed) => total + (seed.archivedAt === undefined ? 0 : 1), 0);
    const visible = archived === "only"
      ? orderArchivedSessions(seeds.filter((seed) => seed.archivedAt !== undefined))
      : seeds.filter((seed) => seed.archivedAt === undefined);
    const source = this.createCatalogPageSource(
      generation,
      materialized.listRevision,
      visible,
      archived === "exclude" ? archivedCount : undefined,
    );
    // RuntimeRegistry does not strongly retain disposable sources. Multi-page
    // leases own them; one-page responses become collectible immediately.
    this.catalogPageSources.set(generation, new WeakRef(source));
    for (const [key, reference] of this.catalogPageSources) {
      if (!reference.deref()) this.catalogPageSources.delete(key);
    }
    while (this.catalogPageSources.size > 4) {
      const oldest = this.catalogPageSources.keys().next().value;
      if (oldest === undefined) break;
      this.catalogPageSources.delete(oldest);
    }
    return source;
  }

  /** Read-only archive projection for derived reads such as session search.
   * Archived sessions stay addressable, so this is a label rather than a
   * filter, and the archive store remains the only writer. It shares the
   * effective projection, so a pending restoration is already unarchived. */
  isArchived(sessionId: string): boolean {
    return this.archivedAt(sessionId) !== undefined;
  }

  /** Read-only derived-search seam: the catalog owner's verified identity for
   * every user-scope canonical session, or undefined until one complete cut has
   * been verified against the folder. It reads the catalog's published rows
   * only and parses no transcript. */
  searchCatalogIdentities(): Promise<ReadonlyMap<string, SessionCatalogIdentity> | undefined> {
    return this.sessionCatalog.searchIdentities();
  }

  /** Read-only derived-search owner seam. Open sessions use the SDK-selected
   * branch held by their existing RuntimeSlot; cold sessions use one complete
   * canonical file parse after catalog admission and never create a runtime. */
  async readSearchCut(sessionId: string): Promise<{
    summary: CatalogSessionInfo;
    entries: FileEntry[];
    fileIdentity?: string;
    forkBoundary?: SessionSearchForkBoundary;
    runtimeGeneration?: string;
    leafEntryId?: string;
  }> {
    const catalog = await this.catalogSnapshot("user");
    const info = catalog.infos.find(candidate => candidate.id === sessionId);
    if (!info || !catalog.sessions.some(session => session.id === sessionId)) throw new GatewayError("not_found", "Session is not available for search");
    const slot = this.slots.get(sessionId);
    if (slot) {
      const cut = slot.searchCanonicalCut();
      const gapOrdinal = cut.forkBoundary ? cut.entries.findIndex(entry => entry.id === cut.forkBoundary!.inheritedEntryId) + 1 : 0;
      return { summary: info, entries: cut.entries, ...(info.fileIdentity ? { fileIdentity: info.fileIdentity } : {}), ...(cut.forkBoundary && gapOrdinal > 0 ? { forkBoundary: { kind: cut.forkBoundary.kind, inheritedEntryId: cut.forkBoundary.inheritedEntryId, gapOrdinal } } : {}), runtimeGeneration: cut.runtimeGeneration, ...(cut.leafEntryId ? { leafEntryId: cut.leafEntryId } : {}) };
    }
    const bytes = await readFile(info.path);
    if (bytes.byteLength > MAX_READ_ONLY_SUBAGENT_SESSION_BYTES) throw new GatewayError("busy", "Session exceeds the bounded search read budget", true);
    // Parse the complete file for graph admission, then ask the pinned SDK
    // reader for its canonical leaf/branch. Physical line order is not branch
    // authority when sibling forks are present.
    const entries = parseStrictSessionJSONL(bytes);
    const coldManager = SessionManager.open(info.path);
    const selectedEntries = coldManager.getBranch();
    // Full-file graph validation is an admission gate; retain the SDK-selected
    // branch below as the canonical projection after every sibling is checked.
    validateSearchBranch(entries, undefined, coldManager.getLeafId() ?? undefined);
    const selectedLeafId = coldManager.getLeafId() ?? undefined;
    const selectedFile = coldManager.getHeader() ? [coldManager.getHeader()!, ...selectedEntries] : entries;
    let forkBoundary: SessionSearchForkBoundary | undefined;
    if (info.parentSessionPath) {
      try {
        const parentBytes = await readFile(info.parentSessionPath);
        if (parentBytes.byteLength <= MAX_READ_ONLY_SUBAGENT_SESSION_BYTES) {
          const parentEntries = parseStrictSessionJSONL(parentBytes);
          const anchor = resolveForkBoundaryAnchor(selectedFile, parentEntries, "sessionFork", selectedLeafId);
          if (anchor) {
            const gapOrdinal = selectedFile.findIndex(entry => entry.id === anchor.inheritedEntryId) + 1;
            if (gapOrdinal > 0) forkBoundary = { kind: anchor.kind, inheritedEntryId: anchor.inheritedEntryId, gapOrdinal };
          }
        }
      } catch { /* incomplete parent evidence leaves coverage partial */ }
    }
    return { summary: info, entries: selectedFile, ...(info.fileIdentity ? { fileIdentity: info.fileIdentity } : {}), ...(forkBoundary ? { forkBoundary } : {}), ...(selectedLeafId ? { leafEntryId: selectedLeafId } : {}) };
  }

  async readSearchTranscriptPage(sessionId: string, before: number, expectedRuntimeGeneration?: string, expectedLeafEntryId?: string): Promise<TranscriptPage> {
    const slot = this.slots.get(sessionId) ?? await this.acquire(sessionId);
    return slot.transcriptPage(before, undefined, expectedRuntimeGeneration, expectedLeafEntryId);
  }

  async readSearchTranscriptPageAtEntry(sessionId: string, entryID: string, expectedRuntimeGeneration?: string, expectedLeafEntryId?: string, windowEnd?: number): Promise<TranscriptPage> {
    const slot = this.slots.get(sessionId) ?? await this.acquire(sessionId);
    return slot.transcriptPageAtEntry(entryID, expectedRuntimeGeneration, expectedLeafEntryId, windowEnd);
  }

  async readSearchTranscriptPageAfter(sessionId: string, after: number, expectedPreviousEntryId?: string, expectedRuntimeGeneration?: string, expectedLeafEntryId?: string): Promise<TranscriptPage> {
    const slot = this.slots.get(sessionId) ?? await this.acquire(sessionId);
    return slot.transcriptPageAfter(after, expectedPreviousEntryId, expectedRuntimeGeneration, expectedLeafEntryId);
  }

  async catalog(scope: "user" | "all" = "user"): Promise<{
    sessions: SessionSummary[];
    listRevision: number;
    /** Disposable identity for sharing one immutable page source. */
    generation?: string;
  }> {
    const snapshot = await this.catalogSnapshot(scope);
    return {
      sessions: snapshot.sessions,
      listRevision: snapshot.listRevision,
      generation: snapshot.generation,
    };
  }

  private async catalogSnapshot(scope: "user" | "all"): Promise<{
    infos: CatalogSessionInfo[];
    sessions: SessionSummary[];
    ambiguousIDs: ReadonlySet<string>;
    listRevision: number;
    generation: string;
  }> {
    // Capture mutable overlays only after structural I/O has completed. The
    // seed construction is synchronous, making this one immutable cut without
    // rejecting it when another heartbeat arrives during discovery.
    const materialized = await this.sharedCatalogMaterialization(scope);
    const projectionGeneration = this.catalogProjectionGeneration;
    const seeds = this.buildCatalogPageSeeds(materialized.infos, scope, materialized.ambiguousIDs);
    const source = this.createCatalogPageSource(
      `${materialized.listRevision}:${materialized.factsDigest}:${projectionGeneration}:${scope}`,
      materialized.listRevision,
      seeds,
    );
    return {
      infos: materialized.infos,
      sessions: await source.page(0, seeds.length),
      ambiguousIDs: materialized.ambiguousIDs,
      listRevision: materialized.listRevision,
      generation: source.generation,
    };
  }

  private async sharedCatalogMaterialization(
    scope: "user" | "all",
  ): Promise<Awaited<ReturnType<RuntimeRegistry["materializeCatalogSnapshot"]>>> {
    const generation = `${this.catalogStructuralGeneration}:${this.catalogAcquisitionInvalidationGeneration}`;
    const active = this.catalogMaterializations.get(scope);
    if (active) {
      if (active.generation === generation) return active.promise;
      try { await active.promise; } catch { /* the successor owns its outcome */ }
      return this.sharedCatalogMaterialization(scope);
    }
    const user = scope === "all" ? this.catalogMaterializations.get("user") : undefined;
    if (user) {
      try { await user.promise; } catch { /* all-scope admission remains independent */ }
      return this.sharedCatalogMaterialization(scope);
    }
    const operation = this.materializeCatalogSnapshot(scope);
    this.catalogMaterializations.set(scope, { generation, promise: operation });
    void operation.finally(() => {
      if (this.catalogMaterializations.get(scope)?.promise === operation) this.catalogMaterializations.delete(scope);
    }).catch(() => {});
    return operation;
  }

  /** One immutable read cut of the catalog index. */
  private async materializeCatalogSnapshot(scope: "user" | "all"): Promise<{
    infos: CatalogSessionInfo[];
    ambiguousIDs: ReadonlySet<string>;
    listRevision: number;
    /** The index-owned facts of every row in this cut. A row field can change
     * without moving `listRevision` (a name, a count, a size), and a cached page
     * source that kept serving the previous facts would hand a revalidating
     * client a stale row. The digest is therefore part of the page-source
     * generation, the way the plan's projection token requires. */
    factsDigest: string;
  }> {
    // The owner's own cut is the membership authority. A read that lands before
    // the owner has published one joins that cut instead of walking itself, and
    // never re-derives a row from a transcript it does not return.
    this.requireCatalogCut();
    const cut = this.catalogIndex(scope);
    // Publishing this cut's identity is what moves listRevision when the
    // membership the index holds changed.
    this.updateCatalogIdentity(cut.allInfos, cut.ambiguousIDs, scope);
    const facts = createHash("sha256");
    for (const info of cut.allInfos) {
      facts.update(info.id).update("\0").update(info.path).update("\0")
        .update(info.name ?? "").update("\0").update(info.firstMessage).update("\0")
        .update(String(info.messageCount)).update("\0").update(info.modified.toISOString()).update("\0")
        .update(info.fileIdentity ?? "").update("\n");
    }
    return {
      infos: cut.infos,
      ambiguousIDs: cut.ambiguousIDs,
      listRevision: this.revision,
      factsDigest: facts.digest("base64url"),
    };
  }

  private catalogIdentityFingerprint(infos: readonly CatalogSessionInfo[]): string {
    const delegated = this.delegatedSessionTopologies(infos);
    return JSON.stringify(infos
      // Structural membership and classification own listRevision. Mutable
      // row fields are delivered through revisioned session.summary events.
      .map((session) => [
        session.id,
        session.path,
        session.parentSessionPath,
        session.cwd,
        session.fileIdentity,
        delegated.has(resolve(session.path)),
      ])
      .sort((left, right) => {
        const byId = String(left[0]).localeCompare(String(right[0]));
        return byId !== 0 ? byId : JSON.stringify(left).localeCompare(JSON.stringify(right));
      }));
  }

  private updateCatalogIdentity(
    infos: readonly CatalogSessionInfo[],
    ambiguousIDs: ReadonlySet<string>,
    scope: "user" | "all" = "all",
  ): void {
    const fingerprint = this.catalogIdentityFingerprint(infos);
    if (scope === "user") {
      if (this.catalogUserFingerprint === undefined) this.catalogUserFingerprint = fingerprint;
      else if (this.catalogUserFingerprint !== fingerprint) {
        this.catalogUserFingerprint = fingerprint;
        this.revision += 1;
      }
    } else {
      if (this.catalogFingerprint === undefined) this.catalogFingerprint = fingerprint;
      else if (this.catalogFingerprint !== fingerprint) {
        this.catalogFingerprint = fingerprint;
        this.revision += 1;
      }
      const delegated = this.delegatedSessionTopologies(infos);
      this.catalogUserFingerprint = this.catalogIdentityFingerprint(
        infos.filter((session) => !delegated.has(resolve(session.path))),
      );
    }
    // This set is derived from every indexed row even for a user list, so a
    // live slot cannot fast-path an ID duplicated by an omitted child row.
    this.ambiguousSessionIds = new Set(ambiguousIDs);
  }

  /** The only delegated-session catalog contract. pi-subagents reserves
   * <parent-stem>/forks/<fork-session>.jsonl and
   * <parent-stem>/<producer>/run-N/session.jsonl beneath the canonical catalog.
   * The topology remains mutation-protected without an extant or unambiguous
   * parent. An optional matching header binds the projected parent identity;
   * a contradictory header fails closed and is omitted from catalog rows. */
  private delegatedSessionTopologies(
    sessions: ReadonlyArray<{
      id: string;
      path: string;
      parentSessionPath?: string;
    }>,
  ): ReadonlyMap<string, DelegatedSessionTopology> {
    const sessionsByPath = new Map(sessions.map((session) => [resolve(session.path), session]));
    const delegated = new Map<string, DelegatedSessionTopology>();
    let catalogRoot: string;
    try { catalogRoot = realpathSync(this.catalogDirectory()); }
    catch { catalogRoot = resolve(this.catalogDirectory()); }
    for (const session of sessions) {
      const sessionPath = resolve(session.path);
      const expectedParentPath = delegatedSessionParentPath(sessionPath, catalogRoot);
      if (!expectedParentPath) continue;
      const contradictoryHeader = session.parentSessionPath !== undefined
        && resolve(session.parentSessionPath) !== expectedParentPath;
      const parent = !contradictoryHeader && session.parentSessionPath !== undefined
        ? sessionsByPath.get(expectedParentPath)
        : undefined;
      delegated.set(sessionPath, {
        contradictoryHeader,
        ...(parent ? { parentSessionId: parent.id } : {}),
      });
    }
    return delegated;
  }

  private async buildCatalogAcquisitionFromSessions(
    sessions: ReadonlyArray<{
      id: string;
      path: string;
      cwd: string;
      fileIdentity?: string;
      parentSessionPath?: string;
    }>,
    ambiguousIDs: ReadonlySet<string>,
  ): Promise<CatalogAcquisitionResolution> {
    // Lightweight header and SDK fallback discovery both omit runtime slots.
    // Count live-only ownership here so an on-disk claimant cannot be opened
    // after the full catalog correctly omitted the colliding ID.
    const resolvedAmbiguousIDs = new Set(ambiguousIDs);
    const canonicalIDs = new Set(sessions.map((session) => session.id));
    for (const [id, slot] of this.slots) {
      if (!slot.isDisposed && slot.persistedSessionFile === undefined && canonicalIDs.has(id)) {
        resolvedAmbiguousIDs.add(id);
      }
    }
    const unambiguousSessions = sessions.filter((session) => !resolvedAmbiguousIDs.has(session.id));
    const limits = this.catalogDiscoveryLimits();
    if (unambiguousSessions.length + resolvedAmbiguousIDs.size > limits.maximumSessions) {
      this.catalogCapacityExceeded();
    }
    const delegated = this.delegatedSessionTopologies(unambiguousSessions);
    const sessionIDByPath = new Map(unambiguousSessions.map((session) => [resolve(session.path), session.id]));
    const entriesByID = new Map<string, CatalogAcquisitionEntry>();
    let retainedBytes = 0;
    for (const session of unambiguousSessions) {
      const sessionPath = resolve(session.path);
      const topology = delegated.get(sessionPath);
      const headerParentSessionId = session.parentSessionPath
        ? sessionIDByPath.get(resolve(session.parentSessionPath))
        : undefined;
      const parentSessionId = topology?.parentSessionId ?? headerParentSessionId;
      const entry: CatalogAcquisitionEntry = {
        id: session.id,
        path: sessionPath,
        cwd: session.cwd,
        canonicalCwd: resolve(session.cwd || process.cwd()),
        ...(session.fileIdentity ? { fileIdentity: session.fileIdentity } : {}),
        structuralSubagent: topology !== undefined,
        ...(parentSessionId ? { parentSessionId } : {}),
      };
      retainedBytes += Buffer.byteLength(JSON.stringify(entry));
      if (retainedBytes > limits.maximumAcquisitionBytes) this.catalogCapacityExceeded();
      entriesByID.set(entry.id, entry);
    }
    for (const id of resolvedAmbiguousIDs) {
      retainedBytes += Buffer.byteLength(id);
      if (retainedBytes > limits.maximumAcquisitionBytes) this.catalogCapacityExceeded();
    }
    return { entriesByID, ambiguousIDs: resolvedAmbiguousIDs };
  }

  /** Membership for every open, attention, automation and workspace read. The
   * index is the authority, so this is a pure in-memory projection of the rows
   * the owner keeps current: no request walks the folder, and the entry a
   * caller then fences is re-proved against its own file at the commit. */
  private async catalogAcquisition(): Promise<CatalogAcquisitionResolution> {
    // Every membership read resolves against the cut the owner has published: a
    // cold open, attention resolution, automation and workspace lookups. An
    // owner that has published none yet is a retryable busy, not a wait.
    this.requireCatalogCut();
    const index = this.catalogIndex("all");
    return this.buildCatalogAcquisitionFromSessions(index.allInfos, index.ambiguousIDs);
  }

  private buildCatalogPageSeeds(
    sessions: readonly CatalogSessionInfo[],
    scope: "user" | "all",
    ambiguousIDs: ReadonlySet<string>,
  ): CatalogPageSeed[] {
    const pathToId = new Map(sessions.map((session) => [sessionCatalogPathKey(session.path), session.id]));
    const delegated = this.delegatedSessionTopologies(sessions);
    const persistedIDs = new Set(sessions.map((session) => session.id));
    const seeds: CatalogPageSeed[] = [];
    for (const session of sessions) {
      const topology = delegated.get(resolve(session.path));
      if (topology?.contradictoryHeader) continue;
      const kind: SessionSummary["kind"] = topology ? "subagent" : "user";
      if (scope === "user" && kind === "subagent") continue;
      const headerParentSessionId = session.parentSessionPath
        ? pathToId.get(sessionCatalogPathKey(session.parentSessionPath))
        : undefined;
      const slot = this.slots.get(session.id);
      const parentSessionId = topology?.parentSessionId ?? headerParentSessionId;
      const latest = this.latestSummaries.get(session.id);
      const name = latest?.name ?? session.name;
      const archivedAt = this.archivedAt(session.id);
      seeds.push({
        id: session.id,
        ...(name ? { name } : {}),
        cwd: session.cwd,
        kind,
        ...(parentSessionId ? { parentSessionId } : {}),
        ...(session.creationOrigin ? { creationOrigin: session.creationOrigin } : {}),
        createdAt: session.created.toISOString(),
        updatedAt: latest?.updatedAt ?? session.modified.toISOString(),
        ...(latest?.activeSince ? { activeSince: latest.activeSince } : {}),
        messageCount: latest?.messageCount ?? session.messageCount,
        firstMessage: latest?.firstMessage ?? session.firstMessage,
        phase: latest?.phase ?? (slot ? slot.catalogPhase : this.interrupted.has(session.id) ? "interrupted" : "idle"),
        ...(latest?.foregroundPhase
          ? { foregroundPhase: latest.foregroundPhase }
          : slot ? { foregroundPhase: slot.catalogForegroundPhase } : {}),
        ...(latest?.hasActiveSubagents !== undefined
          ? { hasActiveSubagents: latest.hasActiveSubagents }
          : slot ? { hasActiveSubagents: slot.catalogHasActiveSubagents } : {}),
        ...(latest?.waitingForUser !== undefined
          ? { waitingForUser: latest.waitingForUser }
          : slot ? { waitingForUser: slot.catalogWaitingForUser } : {}),
        summaryRevision: latest?.summaryRevision ?? 0,
        ...(archivedAt === undefined ? {} : { archivedAt }),
        attention: this.attention.projection(session.id),
      });
    }
    if (scope === "all" || scope === "user") {
      for (const [id, slot] of this.slots) {
        if (slot.isDisposed || persistedIDs.has(id) || ambiguousIDs.has(id)) continue;
        const latest = this.latestSummaries.get(id);
        const automationOwner = this.automationSessionOwners.get(slot);
        const archivedAt = this.archivedAt(id);
        seeds.push({
          id,
          ...(latest?.name ? { name: latest.name } : {}),
          cwd: slot.cwd,
          kind: "user",
          ...(automationOwner ? {
            creationOrigin: { kind: "automation", automationId: automationOwner.automationId },
          } as const : {}),
          createdAt: slot.catalogCreatedAt,
          updatedAt: latest?.updatedAt ?? slot.catalogCreatedAt,
          ...(latest?.activeSince ? { activeSince: latest.activeSince } : {}),
          messageCount: latest?.messageCount ?? 0,
          firstMessage: latest?.firstMessage ?? "",
          phase: latest?.phase ?? slot.catalogPhase,
          foregroundPhase: latest?.foregroundPhase ?? slot.catalogForegroundPhase,
          hasActiveSubagents: latest?.hasActiveSubagents ?? slot.catalogHasActiveSubagents,
          waitingForUser: latest?.waitingForUser ?? slot.catalogWaitingForUser,
          summaryRevision: latest?.summaryRevision ?? 0,
          ...(archivedAt === undefined ? {} : { archivedAt }),
          attention: this.attention.projection(id),
        });
      }
    }
    return orderDashboardSessions(seeds);
  }

  private createCatalogPageSource(
    generation: string,
    listRevision: number,
    seeds: readonly CatalogPageSeed[],
    archivedCount?: number,
  ): CatalogPageSource {
    const uniqueIDs = new Set(seeds.map((seed) => seed.id));
    if (uniqueIDs.size !== seeds.length) {
      throw new GatewayError("busy", "Session catalog identity is ambiguous", true, undefined, "catalog_identity_ambiguous");
    }
    const compactByteEstimate = Buffer.byteLength(generation) + 64 + seeds.reduce((total, seed) => total
      + Buffer.byteLength(seed.id) + Buffer.byteLength(seed.cwd) + Buffer.byteLength(seed.kind)
      + Buffer.byteLength(seed.createdAt) + Buffer.byteLength(seed.updatedAt)
      + Buffer.byteLength(seed.firstMessage) + Buffer.byteLength(seed.phase)
      + (seed.foregroundPhase ? Buffer.byteLength(seed.foregroundPhase) : 0)
      + (seed.activeSince ? Buffer.byteLength(seed.activeSince) : 0)
      + (seed.name ? Buffer.byteLength(seed.name) : 0)
      + (seed.archivedAt ? Buffer.byteLength(seed.archivedAt) : 0)
      + (seed.parentSessionId ? Buffer.byteLength(seed.parentSessionId) : 0)
      + (seed.creationOrigin ? Buffer.byteLength(seed.creationOrigin.kind)
        + Buffer.byteLength(seed.creationOrigin.automationId) : 0)
      // Object/reference, number, and boolean storage for the seed and captured
      // summary/attention revision fields. String payloads are counted above.
      + 160, 0);
    return Object.freeze({
      generation,
      projectionToken: `${this.workRegistry.runtimeEpoch}:${generation}`,
      listRevision, count: seeds.length, compactByteEstimate,
      ...(archivedCount === undefined ? {} : { archivedCount }),
      page: async (offset: number, limit: number) => seeds.slice(offset, offset + limit).map((seed) => ({
        id: seed.id,
        ...(seed.name ? { name: seed.name } : {}),
        cwd: seed.cwd,
        kind: seed.kind,
        ...(seed.parentSessionId ? { parentSessionId: seed.parentSessionId } : {}),
        ...(seed.creationOrigin ? { creationOrigin: seed.creationOrigin } : {}),
        createdAt: seed.createdAt,
        updatedAt: seed.updatedAt,
        ...(seed.activeSince ? { activeSince: seed.activeSince } : {}),
        messageCount: seed.messageCount,
        firstMessage: seed.firstMessage,
        phase: seed.phase,
        ...(seed.foregroundPhase ? { foregroundPhase: seed.foregroundPhase } : {}),
        ...(seed.hasActiveSubagents !== undefined
          ? { hasActiveSubagents: seed.hasActiveSubagents }
          : {}),
        ...(seed.waitingForUser !== undefined
          ? { waitingForUser: seed.waitingForUser }
          : {}),
        summaryRevision: seed.summaryRevision,
        ...(seed.archivedAt ? { archivedAt: seed.archivedAt } : {}),
        ...seed.attention,
      })),
    });
  }

  private async projectTrustReloading(cwdInput: string): Promise<boolean> {
    if (this.trustReloadProjects.size === 0) return false;
    try {
      const cwd = await this.options.trust.canonicalDirectory(cwdInput);
      return this.trustReloadProjects.has(cwd);
    } catch (error) {
      if (this.trustReloadProjects.size > 0) return true;
      throw error;
    }
  }

  async createAutomationSession(
    cwdInput: string,
    sessionId: string,
    operationId: string,
    automationId: string,
  ): Promise<{ slot: RuntimeSlot; release: () => void }> {
    if (!isAutomationId(sessionId) || !isAutomationId(automationId)
      || runIdFromAutomationOperationId(operationId) === undefined) {
      throw new GatewayError("invalid_request", "Automation execution identity is invalid");
    }
    const finishAdmission = this.beginSlotAdmission();
    let reserved = false;
    let slot: RuntimeSlot | undefined;
    let published = false;
    try {
      const trust = await stage(
        "automation.session.trust",
        () => this.options.trust.requireResolved(cwdInput),
      );
      await this.evictIdle(true, sessionId);
      // A session that has not written a transcript yet holds no bytes, so this
      // admission adds none to the byte budget's live charge and calls no byte
      // pass: there is no room to make for it.
      const existing = await this.mutex.run(() => {
        this.assertSlotAdmissionOpen();
        if (this.trustReloadProjects.has(trust.cwd)) {
          throw new GatewayError("busy", "Project trust is being reconfigured", true);
        }
        const current = this.slots.get(sessionId);
        if (current) {
          const owner = this.automationSessionOwners.get(current);
          if (current.isDisposed || current.cwd !== trust.cwd
            || owner?.operationId !== operationId || owner.automationId !== automationId) {
            throw new GatewayError("conflict", "Automation execution session identity is already owned");
          }
          return { slot: current, release: current.retainLease() };
        }
        this.requireLiveSlotCapacity();
        this.reservedSlotStarts += 1;
        reserved = true;
        return undefined;
      });
      if (existing) return existing;

      const manager = SessionManager.create(
        trust.cwd,
        this.sessionDirectoryFor(trust.cwd),
        { id: sessionId },
      );
      slot = await stage(
        "automation.session.runtime",
        () => RuntimeSlot.create(manager, this.dependencies(), this.hooks(), false),
      );
      const transcriptBytes = await sessionFileBytes(slot.sessionFile);
      return await this.mutex.run(() => {
        this.assertSlotAdmissionOpen();
        if (this.trustReloadProjects.has(trust.cwd)) {
          throw new GatewayError("busy", "Automation session was retired before publication", true);
        }
        if (this.slots.has(sessionId)) {
          throw new GatewayError("conflict", "Automation execution session identity is already owned");
        }
        const release = slot!.retainLease();
        this.automationSessionOwners.set(slot!, { operationId, automationId });
        this.reservedSlotStarts = Math.max(0, this.reservedSlotStarts - 1);
        reserved = false;
        this.publishRuntime(sessionId, slot!, transcriptBytes, "automation");
        published = true;
        this.invalidateCatalogAdmission();
        void this.sessionCatalog.refresh(slot!.persistedSessionFile);
        this.revision += 1;
        this.options.sessionListChanged();
        return { slot: slot!, release };
      });
    } catch (error) {
      if (slot && !published) await slot.dispose().catch(() => {});
      throw error;
    } finally {
      if (reserved) {
        await this.mutex.run(() => {
          this.reservedSlotStarts = Math.max(0, this.reservedSlotStarts - 1);
        });
      }
      finishAdmission();
    }
  }

  async create(cwdInput: string): Promise<RuntimeSlot> {
    const finishAdmission = this.beginSlotAdmission();
    let reserved = false;
    let slot: RuntimeSlot | undefined;
    try {
      const trust = await stage(
        "session.create.trust",
        () => this.options.trust.requireResolved(cwdInput),
      );
      await this.evictIdle(true);
      // A session that has not written a transcript yet holds no bytes, so this
      // admission adds none to the byte budget's live charge and calls no byte
      // pass: there is no room to make for it.
      await this.mutex.run(() => {
        this.assertSlotAdmissionOpen();
        if (this.trustReloadProjects.has(trust.cwd)) {
          throw new GatewayError("busy", "Project trust is being reconfigured", true);
        }
        this.requireLiveSlotCapacity();
        this.reservedSlotStarts += 1;
        reserved = true;
      });
      const manager = SessionManager.create(trust.cwd, this.sessionDirectoryFor(trust.cwd));
      slot = await stage(
        "session.create.runtime",
        () => RuntimeSlot.create(manager, this.dependencies(), this.hooks(), false),
      );
      const transcriptBytes = await sessionFileBytes(slot.sessionFile);
      await this.mutex.run(() => {
        if (this.trustReloadProjects.has(trust.cwd)) {
          throw new GatewayError("busy", "Session creation was retired before publication", true);
        }
        if (this.slots.has(manager.getSessionId())) {
          throw new GatewayError("conflict", "Replacement session is already active");
        }
        this.reservedSlotStarts = Math.max(0, this.reservedSlotStarts - 1);
        reserved = false;
        this.publishRuntime(manager.getSessionId(), slot!, transcriptBytes, "create");
        this.invalidateCatalogAdmission();
        // A fresh session is live before Pi writes its first canonical entry;
        // the slot's own `changed` commit point adds the row when it does.
        void this.sessionCatalog.refresh(slot!.persistedSessionFile);
        this.revision += 1;
        this.options.sessionListChanged();
      });
      return slot;
    } catch (error) {
      if (slot && this.slots.get(slot.id) !== slot) await slot.dispose().catch(() => {});
      throw error;
    } finally {
      if (reserved) {
        await this.mutex.run(() => {
          this.reservedSlotStarts = Math.max(0, this.reservedSlotStarts - 1);
        });
      }
      finishAdmission();
    }
  }

  /** Resolves an opaque child identity only while its live parent still proves
   * the exact process/tool/run binding. This never acquires a child runtime. */
  async resolveReadOnlySubagentPath(
    childSessionRef: string,
    preferredPath: string | undefined,
    expectedParentSessionId: string,
    expectedProcessId: string,
    expectedRunId: string,
    signal?: AbortSignal,
  ): Promise<ReadOnlySubagentAdmission> {
    assertProcessSessionRef(childSessionRef);
    const acquisition = await abortableRead(signal, () => this.catalogAcquisition());
    this.requireUnambiguousSessionId(expectedParentSessionId, acquisition.ambiguousIDs);
    this.requireUnambiguousSessionId(childSessionRef, acquisition.ambiguousIDs);
    signal?.throwIfAborted();
    const parentSlot = this.slots.get(expectedParentSessionId);
    const binding = parentSlot?.processChildSessionBinding(expectedProcessId);
    const expectedParentPath = parentSlot?.sessionFile;
    if (!parentSlot || parentSlot.isDisposed || !expectedParentPath || !binding
      || binding.ref !== childSessionRef || binding.runId !== expectedRunId) {
      throw new GatewayError("not_found", "Subagent session ownership is unavailable");
    }
    const parentEntry = acquisition.entriesByID.get(expectedParentSessionId);
    const canonicalParentPath = await realpath(expectedParentPath).catch(() => undefined);
    const indexedParentPath = parentEntry
      ? await realpath(parentEntry.path).catch(() => undefined)
      : undefined;
    if (parentEntry && indexedParentPath !== canonicalParentPath) {
      throw new GatewayError("conflict", "Parent session identity is ambiguous", true);
    }
    const entry = acquisition.entriesByID.get(childSessionRef);
    const indexedChildPath = entry ? await realpath(entry.path).catch(() => undefined) : undefined;
    const candidates = preferredPath ? [preferredPath] : indexedChildPath ? [indexedChildPath] : [];
    for (const candidate of candidates) {
      const admitted = await this.validateReadOnlySubagentPath(
        childSessionRef,
        candidate,
        expectedParentSessionId,
        expectedParentPath,
        expectedRunId,
        binding.producerId,
        binding.sessionOwnerId,
      );
      signal?.throwIfAborted();
      if (!admitted) continue;
      if (entry) {
        if (!entry.structuralSubagent
          || (entry.parentSessionId !== undefined && entry.parentSessionId !== expectedParentSessionId)
          || indexedChildPath !== admitted.path) {
          throw new GatewayError("conflict", "Subagent session identity is ambiguous", true);
        }
      }
      return admitted;
    }
    throw new GatewayError(entry ? "conflict" : "not_found", entry
      ? "Subagent session identity changed" : "Subagent session is unavailable", entry !== undefined);
  }

  async readOnlySubagentTranscriptPage(
    childSessionRef: string,
    path: string,
    expectedParentSessionId: string,
    expectedProcessId: string,
    expectedRunId: string,
    before?: number,
    expectedNextEntryId?: string,
    expectedFileIdentity?: string,
    signal?: AbortSignal,
  ): Promise<TranscriptPage & { revision: string; fileIdentity: string }> {
    const admitted = await this.resolveReadOnlySubagentPath(
      childSessionRef,
      path,
      expectedParentSessionId,
      expectedProcessId,
      expectedRunId,
      signal,
    );
    if (admitted.path !== path || (expectedFileIdentity !== undefined && admitted.fileIdentity !== expectedFileIdentity)) {
      throw new GatewayError("conflict", "Subagent session file was replaced", true);
    }
    const handle = await open(admitted.path, "r");
    try {
      signal?.throwIfAborted();
      const metadata = await handle.stat();
      const fileIdentity = `${metadata.dev}:${metadata.ino}`;
      if (!metadata.isFile() || fileIdentity !== admitted.fileIdentity) {
        throw new GatewayError("conflict", "Subagent session file was replaced", true);
      }
      if (metadata.size > 0) {
        const final = Buffer.alloc(1);
        const { bytesRead } = await handle.read(final, 0, 1, metadata.size - 1);
        if (bytesRead !== 1 || final[0] !== 0x0a) {
          throw new GatewayError("busy", "Subagent session append is still in progress", true);
        }
      }
      // Parse the already-open descriptor. Opening the path again here would
      // allow replace/read/swap-back to project a different inode while the
      // final path metadata appeared unchanged.
      const childEntries = await readOpenedSessionEntries(handle, metadata.size, signal);
      signal?.throwIfAborted();
      const parsed = childEntries ? branchFromParsedSession(childEntries) : undefined;
      if (!parsed || parsed.sessionId !== childSessionRef) {
        throw new GatewayError("conflict", "Subagent session identity changed", true);
      }
      const parentSlot = this.slots.get(expectedParentSessionId);
      const parentEntries = parentSlot?.canonicalSessionEntries();
      const forkAnchor = parentEntries
        ? resolveForkBoundaryAnchor(childEntries!, parentEntries, "subagentFork")
        : undefined;
      let page: TranscriptPage;
      try {
        const toolLabels = this.slots.get(expectedParentSessionId)?.toolPresentationLabels();
        page = projectTranscriptPage(
          { getBranch: () => parsed.branch },
          this.blobs,
          before,
          undefined,
          expectedNextEntryId,
          undefined,
          undefined,
          toolLabels,
          undefined,
          forkAnchor,
        );
      } catch (error) {
        if (error instanceof Error && error.message.includes("anchor changed")) {
          throw new GatewayError("conflict", "Subagent transcript changed while loading history", true);
        }
        throw error;
      }
      const afterHandle = await handle.stat();
      const afterPath = await lstat(admitted.path).catch(() => undefined);
      const sameSizeMutation = afterHandle.size === metadata.size && afterHandle.mtimeMs !== metadata.mtimeMs;
      if (!afterPath?.isFile() || afterPath.isSymbolicLink()
        || afterPath.dev !== metadata.dev || afterPath.ino !== metadata.ino
        || afterHandle.dev !== metadata.dev || afterHandle.ino !== metadata.ino
        || afterHandle.size < metadata.size || sameSizeMutation) {
        throw new GatewayError("busy", "Subagent session changed during projection", true);
      }
      signal?.throwIfAborted();
      const confirmedHeader = await readOpenedSessionHeader(handle, afterHandle.size);
      if (!confirmedHeader || confirmedHeader.sessionId !== childSessionRef
        || confirmedHeader.parentSession !== parsed.parentSession) {
        throw new GatewayError("conflict", "Subagent session identity changed", true);
      }
      const leafEntryId = parsed.leafEntryId;
      // The page owns the immutable prefix ending at metadata.size. A concurrent
      // canonical append belongs to the next watcher revision and must not
      // invalidate this already-open snapshot.
      const revision = createHash("sha256")
        .update(`${childSessionRef}\0${metadata.dev}\0${metadata.ino}\0${metadata.size}\0${metadata.mtimeMs}\0${leafEntryId ?? ""}\0${JSON.stringify(page.forkBoundary ?? null)}`)
        .digest("hex").slice(0, 32);
      return { ...page, ...(leafEntryId ? { leafEntryId } : {}), revision, fileIdentity };
    } finally {
      await handle.close();
    }
  }

  private async validateReadOnlySubagentPath(
    childSessionRef: string,
    input: string,
    expectedParentSessionId: string,
    expectedParentPath: string,
    expectedRunId: string,
    expectedProducerId: string,
    expectedSessionOwnerId?: string,
  ): Promise<ReadOnlySubagentAdmission | undefined> {
    if (!expectedRunId || /[\\/\0]/u.test(expectedRunId)
      || !expectedProducerId || /[\\/\0]/u.test(expectedProducerId)
      || expectedSessionOwnerId !== undefined
        && (Buffer.byteLength(expectedSessionOwnerId) > 256 || /[\\/\0]/u.test(expectedSessionOwnerId))) return undefined;
    let canonical: string;
    let metadata: Awaited<ReturnType<typeof lstat>>;
    try {
      metadata = await lstat(input);
      if (!metadata.isFile() || metadata.isSymbolicLink()) return undefined;
      canonical = await realpath(input);
    } catch { return undefined; }
    if (canonical !== input) return undefined;
    const roots = await Promise.all([join(this.options.agentDir, "sessions"), this.catalogDirectory()]
      .map(async (root) => realpath(root).catch(() => resolve(root))));
    if (!roots.some((root) => canonical === root || canonical.startsWith(root + sep))) return undefined;
    let parentCanonical: string;
    try { parentCanonical = await realpath(expectedParentPath); }
    catch { return undefined; }
    const childRoot = join(dirname(parentCanonical), basename(parentCanonical, ".jsonl"));
    const ownedRelative = relative(childRoot, canonical);
    const parts = ownedRelative.split(sep);
    if (ownedRelative === "" || ownedRelative === ".." || ownedRelative.startsWith(`..${sep}`)
      || isAbsolute(ownedRelative)) return undefined;
    const forkContext = parts.length === 2 && parts[0] === "forks"
      && parts[1] !== ".jsonl" && parts[1]!.endsWith(".jsonl");
    const freshContext = parts.length === 3 && parts[0] !== "forks"
      && (parts[0] === expectedRunId || parts[0] === expectedSessionOwnerId)
      && SUBAGENT_RUN_DIRECTORY.test(parts[1]!)
      && parts[2] === "session.jsonl";
    if (!forkContext && !freshContext) return undefined;
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    try {
      handle = await open(canonical, "r");
      const opened = await handle.stat();
      if (!opened.isFile() || opened.dev !== metadata.dev || opened.ino !== metadata.ino) return undefined;
      const header = await readOpenedSessionHeader(handle, opened.size);
      if (!header || header.sessionId !== childSessionRef) return undefined;
      if (header.parentSession) {
        const headerParent = await realpath(header.parentSession).catch(() => undefined);
        if (headerParent !== parentCanonical) return undefined;
      } else if (forkContext) {
        return undefined;
      }
      const after = await lstat(canonical);
      if (!after.isFile() || after.isSymbolicLink() || after.dev !== opened.dev || after.ino !== opened.ino) return undefined;
      const afterOpened = await handle.stat();
      if (afterOpened.dev !== opened.dev || afterOpened.ino !== opened.ino
        || afterOpened.size < opened.size
        || (afterOpened.size === opened.size && afterOpened.mtimeMs !== opened.mtimeMs)) return undefined;
      const confirmedHeader = await readOpenedSessionHeader(handle, afterOpened.size);
      if (!confirmedHeader || confirmedHeader.sessionId !== header.sessionId
        || confirmedHeader.parentSession !== header.parentSession) return undefined;
      return { path: canonical, fileIdentity: `${opened.dev}:${opened.ino}` };
    } catch { return undefined; }
    finally { await handle?.close().catch(() => {}); }
  }

  /** Retain one already-live session operation before its first await. The
   * release uses the slot's shared automation/operation lease authority. */
  retainLiveSession(sessionId: string): (() => void) | undefined {
    this.assertSlotAdmissionOpen();
    const slot = this.slots.get(sessionId);
    if (!slot || slot.isDisposed || this.deletingSessionIds.has(sessionId)
      || this.ambiguousSessionIds.has(sessionId)) return undefined;
    const eviction = this.idleEvictions.get(sessionId);
    if (eviction?.slot === slot && eviction.committed) return undefined;
    this.cancelIdleEviction(sessionId, slot);
    return slot.retainLease();
  }

  async acquire(sessionId: string, signal?: AbortSignal): Promise<RuntimeSlot> {
    this.assertSlotAdmissionOpen();
    const existing = this.slots.get(sessionId);
    if (existing && !existing.isDisposed && !this.ambiguousSessionIds.has(sessionId)) {
      const eviction = this.idleEvictions.get(sessionId);
      if (eviction?.slot === existing && eviction.committed && eviction.completion) {
        await eviction.completion;
        return this.acquire(sessionId, signal);
      }
      this.cancelIdleEviction(sessionId, existing);
      existing.touch();
      return existing;
    }
    const finishAdmission = this.beginSlotAdmission();
    try {
      return await this.acquireMissing(sessionId, signal);
    } finally {
      finishAdmission();
    }
  }

  private async acquireMissing(sessionId: string, signal?: AbortSignal): Promise<RuntimeSlot> {
    const alreadyStarting = this.pendingSlotStarts.get(sessionId);
    if (alreadyStarting) return this.joinColdLoad(alreadyStarting, signal);
    const existing = this.slots.get(sessionId);
    const { acquisition, entry } = await stage(
      "session.open.catalog",
      () => this.catalogMembership(sessionId),
    );
    this.requireUnambiguousSessionId(sessionId, acquisition.ambiguousIDs);
    if (existing && !existing.isDisposed) {
      if (entry?.structuralSubagent) {
        throw new GatewayError("conflict", "Subagent sessions are informational and remain owned by their originating runtime");
      }
      existing.touch();
      return existing;
    }
    if (!entry) throw this.unprovenSessionRefusal(sessionId)
      ?? new GatewayError("not_found", "Tron session was not found");
    if (entry.structuralSubagent) {
      throw new GatewayError("conflict", "Subagent sessions are informational and remain owned by their originating runtime");
    }
    await this.evictIdle(true, sessionId);
    const transcriptBytes = await sessionFileBytes(entry.path);
    const incomingBytes = estimateRuntimeHeapBytes(transcriptBytes);
    await this.makeRoomForRuntimeBytes({ requestedSessionID: sessionId, incomingBytes });
    const selectedAcquisitionGeneration = this.catalogAcquisitionInvalidationGeneration;
    const selected = await this.mutex.run(() => {
      let raced = this.slots.get(sessionId);
      if (raced?.isDisposed) {
        if (this.slots.get(sessionId) === raced) {
          this.slots.delete(sessionId);
          // The slot was already disposed by a path that did not record its own
          // eviction (a close in flight, for example), so this clearing names only
          // that fact rather than claiming a reason this path did not observe.
          this.recordRuntimeEviction(sessionId, "disposed");
        }
        raced = undefined;
      }
      if (raced && !this.ambiguousSessionIds.has(sessionId)) {
        const eviction = this.idleEvictions.get(sessionId);
        if (eviction?.slot === raced && eviction.committed && eviction.completion) {
          return { operation: eviction.completion.then(() => this.acquire(sessionId)) };
        }
        this.cancelIdleEviction(sessionId, raced);
        raced.touch();
        return { operation: Promise.resolve(raced) };
      }
      if (raced) this.requireUnambiguousSessionId(sessionId, acquisition.ambiguousIDs);
      const pending = this.pendingSlotStarts.get(sessionId);
      if (pending) return { operation: this.joinColdLoad(pending, signal) };
      this.assertSlotAdmissionOpen();
      this.requireLiveSlotCapacity();
      this.reservedSlotStarts += 1;
      this.reservedRuntimeBytes.set(sessionId, incomingBytes);
      const controller = new AbortController();
      const operation = this.startAcquiredSlot(
        sessionId,
        entry,
        acquisition,
        selectedAcquisitionGeneration,
        transcriptBytes,
        controller.signal,
      );
      const coldLoad: PendingColdLoad = { operation, controller, waiters: 0 };
      this.pendingSlotStarts.set(sessionId, coldLoad);
      return { operation: this.joinColdLoad(coldLoad, signal) };
    });
    return selected.operation;
  }

  /**
   * Wait for the cold start already running for a session (`C-6`, `G-12`). The
   * start is shared, so one requester leaving must not end it for the others: a
   * phone reconnecting on a new socket joins the load the retiring connection
   * is still waiting for, and the queued load is dropped only when the last
   * waiter leaves. Per-requester abandonment stays at the caller's own
   * `abortableRead`; this only counts who is still waiting.
   */
  private joinColdLoad(pending: PendingColdLoad, signal: AbortSignal | undefined): Promise<RuntimeSlot> {
    pending.waiters += 1;
    if (signal !== undefined) {
      const leave = (): void => {
        pending.waiters -= 1;
        if (pending.waiters <= 0) pending.controller.abort(signal.reason);
      };
      if (signal.aborted) leave();
      else {
        signal.addEventListener("abort", leave, { once: true });
        // The listener outlives the start only until it settles, so a requester
        // that leaves after the load finished cannot end a later one.
        const settled = (): void => signal.removeEventListener("abort", leave);
        pending.operation.then(settled, settled);
      }
    }
    return pending.operation;
  }

  private async startAcquiredSlot(
    sessionId: string,
    entry: CatalogAcquisitionEntry,
    acquisition: CatalogAcquisitionResolution,
    selectedAcquisitionGeneration: number,
    transcriptBytes: number,
    signal?: AbortSignal,
  ): Promise<RuntimeSlot> {
    let slot: RuntimeSlot | undefined;
    let reservationReleased = false;
    try {
      let canonicalPath: string;
      try { canonicalPath = await realpath(entry.path); }
      catch { throw new GatewayError("not_found", "Tron session was removed before it could be opened"); }
      if (resolve(canonicalPath) !== entry.path) {
        throw new GatewayError("conflict", "Tron session identity changed after catalog discovery", true);
      }
      if (await this.projectTrustReloading(entry.canonicalCwd)) {
        throw new GatewayError("busy", "Project trust is being reconfigured", true);
      }
      // The SDK repairs incomplete tails on open. Reject an in-progress append
      // before handing this exact file to it; unrelated child tails do not block
      // header-only catalog acquisition.
      const header = await this.readCatalogHeader(
        canonicalPath, this.catalogDiscoveryLimits().maximumHeaderBytesPerFile,
        () => true, () => {},
      );
      if (header.unstable) throw new GatewayError("busy", "Session append is still in progress", true);
      if (header.identity?.id !== entry.id
        || (entry.fileIdentity !== undefined && header.identity.fileIdentity !== entry.fileIdentity)) {
        throw new GatewayError("conflict", "Tron session identity changed after catalog discovery", true);
      }
      let manager: SessionManager;
      try {
        manager = await stage(
          "session.open.manager",
          async () => SessionManager.open(canonicalPath, this.sessionDirectoryFor(entry.canonicalCwd)),
        );
      } catch {
        throw new GatewayError("conflict", "Tron session is not a valid canonical session");
      }
      if (manager.getSessionId() !== entry.id
        || resolve(manager.getCwd()) !== entry.canonicalCwd) {
        throw new GatewayError("conflict", "Tron session identity changed after catalog discovery", true);
      }
      // Membership is the index and the file fence above is this exact file:
      // exactly one indexed claimant that is still this path with this identity.
      // Unrelated churn (active subagents create child files continuously) must
      // not make every cold open fail as catalog_changed, and no read here walks
      // the folder.
      const claimants = this.sessionCatalog.rows().filter((row) => row.id === sessionId);
      if (claimants.length !== 1
        || resolve(claimants[0]!.path) !== canonicalPath
        || (entry.fileIdentity !== undefined && claimants[0]!.fileIdentity !== entry.fileIdentity)) {
        throw new GatewayError("busy", "Session catalog changed while opening the session", true, undefined, "catalog_changed");
      }
      if (selectedAcquisitionGeneration !== this.catalogAcquisitionInvalidationGeneration) {
        throw new GatewayError("busy", "Session catalog changed while opening the session", true, undefined, "catalog_changed");
      }
      // The refusal names a cold load rather than the RPC that asked for it:
      // `acquire` serves reads, leases and automation alike (`G-12`).
      await this.admitColdLoadUnderHeapPressure("open");
      slot = await this.coldLoadGate.run(signal, () => stage(
        "session.open.runtime",
        () => RuntimeSlot.create(
          manager,
          this.dependencies(),
          this.hooks(),
          this.interrupted.has(sessionId),
        ),
      ));
      await this.mutex.run(() => {
        if (selectedAcquisitionGeneration !== this.catalogAcquisitionInvalidationGeneration
            || this.trustReloadProjects.has(entry.canonicalCwd)) {
          throw new GatewayError("busy", "Session runtime start was retired before publication", true);
        }
        const ambiguous = this.indexAmbiguousSessionIds();
        this.requireUnambiguousSessionId(sessionId, ambiguous);
        const raced = this.slots.get(sessionId);
        if (raced && raced !== slot && !raced.isDisposed) {
          throw new GatewayError("conflict", "Replacement session is already active", true);
        }
        this.reservedSlotStarts = Math.max(0, this.reservedSlotStarts - 1);
        this.reservedRuntimeBytes.delete(sessionId);
        reservationReleased = true;
        this.publishRuntime(sessionId, slot!, transcriptBytes, "open");
      });
      return slot;
    } catch (error) {
      if (slot && this.slots.get(sessionId) !== slot) await slot.dispose().catch(() => {});
      throw error;
    } finally {
      await this.mutex.run(() => {
        if (this.pendingSlotStarts.get(sessionId) !== undefined) {
          this.pendingSlotStarts.delete(sessionId);
        }
        if (!reservationReleased) {
          this.reservedSlotStarts = Math.max(0, this.reservedSlotStarts - 1);
          this.reservedRuntimeBytes.delete(sessionId);
        }
      });
    }
  }

  async importFromJsonl(path: string, cwdInput: string): Promise<RuntimeSlot> {
    const finishAdmission = this.beginSlotAdmission();
    try {
      const trust = await this.options.trust.requireResolved(cwdInput);
      await this.evictIdle(true);
      // The fork copies the source transcript, so the source's bytes are the
      // bytes this admission has to fit beside the runtimes already loaded.
      const incomingBytes = estimateRuntimeHeapBytes(await sessionFileBytes(path));
      await this.makeRoomForRuntimeBytes({ incomingBytes });
      // An import is the one mutation that is a cold load, and the heap bound
      // refuses it here, before the fork it would otherwise have to settle:
      // nothing has been written yet, so the retry hint is the whole recovery
      // (`G-12`).
      await this.admitColdLoadUnderHeapPressure("import");
      // The import's own copy is a cold load like an open, so it takes one of
      // the same places (`G-12`). It has no requester signal: an admitted import
      // is a mutation whose owner settles it.
      return await this.coldLoadGate.run(undefined, () => this.mutex.run(async () => {
        this.assertSlotAdmissionOpen();
        if (this.trustReloadProjects.has(trust.cwd)) {
          throw new GatewayError("busy", "Project trust is being reconfigured", true);
        }
        this.requireLiveSlotCapacity();
        const sessionDirectory = this.sessionDirectoryFor(trust.cwd);
        const manager = SessionManager.forkFrom(path, trust.cwd, sessionDirectory);
        const importedId = manager.getSessionId();
        const importedPath = manager.getSessionFile();
        let slot: RuntimeSlot | undefined;
        let published = false;
        try {
          if (!importedPath) throw new GatewayError("internal", "Imported session was not persisted");
          const existingPath = SessionManager.findById(trust.cwd, importedId, sessionDirectory);
          if (this.slots.has(importedId) || (existingPath && resolve(existingPath) !== resolve(importedPath))) {
            throw new GatewayError("conflict", "Imported session identity is already registered");
          }
          slot = await RuntimeSlot.create(manager, this.dependencies(), this.hooks(), false);
          if (this.slots.has(importedId)) {
            throw new GatewayError("conflict", "Imported session identity became registered");
          }
          this.publishRuntime(importedId, slot, await sessionFileBytes(slot.sessionFile), "import");
          published = true;
          this.invalidateCatalogAcquisition();
          void this.sessionCatalog.refresh(slot.persistedSessionFile);
          this.revision += 1;
          this.options.sessionListChanged();
          return slot;
        } catch (error) {
          if (!published) {
            await slot?.dispose().catch(() => {});
            if (importedPath) await rm(importedPath, { force: true });
          }
          throw error;
        }
      }));
    } finally {
      finishAdmission();
    }
  }

  async reloadProject(cwdInput: string, projectTrusted?: boolean, publish = true): Promise<void> {
    const cwd = await this.options.trust.canonicalDirectory(cwdInput);
    const transactional = !publish;
    const slots = await this.mutex.run(() => {
      const current = [...this.slots.values()].filter((slot) => slot.cwd === cwd);
      if (current.some((slot) => slot.isBusy)) {
        throw new GatewayError("busy", "Stop active sessions before changing project trust", true);
      }
      if (transactional) {
        current.forEach((slot) => slot.beginTrustReload());
        this.trustReloadProjects.add(cwd);
      }
      return current;
    });
    const results = await Promise.allSettled(
      slots.map((slot) => slot.reload(projectTrusted, false, transactional)),
    );
    const failures = results.flatMap((result, index) => result.status === "rejected"
      ? [{ sessionId: slots[index]!.id, reason: result.reason }]
      : []);
    if (failures.length === 1) {
      const { sessionId, reason } = failures[0]!;
      if (reason instanceof GatewayError) {
        throw new GatewayError(reason.code, reason.message, reason.retryable, {
          sessionId,
          ...(reason.details === undefined ? {} : { cause: reason.details }),
        });
      }
      throw new GatewayError(
        "internal",
        reason instanceof Error ? reason.message : "Project runtime rejected the trust reload",
        false,
        { sessionId },
      );
    }
    if (failures.length > 1) {
      throw new GatewayError(
        "internal",
        "One or more project runtimes rejected the trust reload",
        false,
        { failures: failures.map(({ sessionId, reason }) => ({
          sessionId,
          message: reason instanceof Error ? reason.message : "Unknown runtime reload failure",
        })) },
      );
    }
    if (publish) slots.forEach((slot) => slot.commitReload());
  }

  refreshCompactionPolicies(scope: "global" | "project", cwd: string): void {
    for (const slot of this.slots.values()) {
      if (scope === "global" || slot.cwd === cwd) slot.refreshCompactionPolicy();
    }
  }

  async commitProjectReload(cwdInput: string): Promise<void> {
    const cwd = await this.options.trust.canonicalDirectory(cwdInput);
    await this.mutex.run(() => {
      const slots = [...this.slots.values()].filter((slot) => slot.cwd === cwd);
      slots.forEach((slot) => slot.commitReload());
      this.trustReloadProjects.delete(cwd);
    });
  }

  /** Archive or unarchive one canonical session. Archiving is a dashboard
   * projection: it never rewrites a session file, never changes its transcript
   * or `updatedAt`, and never starts a runtime for an inactive session. */
  async setArchived(
    sessionId: string,
    archived: boolean,
    initiatingWorkToken?: string,
  ): Promise<{ archived: boolean; archivedAt?: string }> {
    return this.mutex.run(async () => {
      // Archive state is written for an admitted canonical session, so it needs
      // the same index membership delete uses rather than a mutable
      // presentation projection.
      const { acquisition, entry } = await this.catalogMembership(sessionId);
      this.requireUnambiguousSessionId(sessionId, acquisition.ambiguousIDs);
      const slot = this.slots.get(sessionId);
      if (!entry && (!slot || slot.persistedSessionFile !== undefined)) {
        throw new GatewayError("not_found", "Tron session was not found");
      }
      if (entry?.structuralSubagent) {
        throw new GatewayError("conflict", "Archive the originating user session instead of mutating its runtime-owned subagent session");
      }
      if (archived) {
        if (this.deletingSessionIds.has(sessionId)) {
          throw new GatewayError("busy", "Session deletion is already in progress", true);
        }
        if (this.options.sessionAutomationReserved?.(sessionId)) {
          throw new GatewayError("busy", "Stop the session before archiving it", false, undefined, "session_operation_busy");
        }
        this.assertArchiveIdle(sessionId, slot);
      }
      const commit = () => this.attentionLane.run(async () => {
        await this.flushPendingProjectionRemovals();
        if (this.deletingSessionIds.has(sessionId)) {
          throw new GatewayError("busy", "Session deletion is already in progress", true);
        }
        if (this.slots.get(sessionId) !== slot) {
          throw new GatewayError("busy", "Session identity changed while archiving", true, undefined, "catalog_changed");
        }
        if (!archived) {
          let removed: boolean;
          try {
            removed = await this.archive.remove(sessionId);
          } catch {
            this.archivePersistFailed("remove");
            throw new GatewayError("busy", "Session archive state could not be persisted", true);
          }
          this.pendingArchiveRestorations.delete(sessionId);
          if (removed) this.archiveChanged([sessionId]);
          return { archived: false };
        }
        let archivedAt: string;
        try {
          // A pending restoration means the durable record is stale: its clear
          // failed while the session was visibly working. Retire it first, or
          // the new archive would resurrect the old row position.
          if (this.pendingArchiveRestorations.has(sessionId)) await this.archive.remove(sessionId);
          archivedAt = await this.archive.archive(sessionId);
        } catch {
          this.archivePersistFailed("set");
          throw new GatewayError("busy", "Session archive state could not be persisted", true);
        }
        this.pendingArchiveRestorations.delete(sessionId);
        this.archiveChanged([sessionId]);
        return { archived: true, archivedAt };
      });
      // A live slot owns the lane that admits runs, so its idle admission and
      // the durable commit must be one critical section: a run admitted in the
      // gap would otherwise be working while this record commits over it. A
      // cold session has no lane to interleave with, and the recheck inside
      // `commit` rejects any slot published while the commit was in flight.
      if (archived && slot && !slot.isDisposed) {
        // A long lane holder (a branch summary, Bash before its phase lands, a
        // reload) is invisible to the published projection and would otherwise
        // hold this Gateway-wide mutex for its whole duration, so it is rejected
        // here before the lane wait. The lane re-checks the same rule.
        slot.assertArchivable(initiatingWorkToken);
        await slot.commitArchiveWhileIdle(initiatingWorkToken, commit);
        // A run Pi started on its own during the durable write makes the row
        // visible again, so the effective projection—not the record this request
        // just wrote—is the authoritative response and the value the command
        // receipt replays.
        this.restoreArchivedSessionIfWorking(sessionId, slot);
        const effective = this.archivedAt(sessionId);
        return effective === undefined ? { archived: false } : { archived: true, archivedAt: effective };
      }
      return commit();
    });
  }

  async delete(sessionId: string, initiatingWorkToken?: string): Promise<void> {
    await this.attentionLane.run(async () => {
      await this.flushPendingProjectionRemovals();
      if (this.deletingSessionIds.has(sessionId)) throw new GatewayError("busy", "Session deletion is already in progress", true);
      this.deletingSessionIds.add(sessionId);
    });
    let deleted = false;
    try {
      await this.mutex.run(async () => {
        // Deletion needs structural identity and ownership, not a mutable
        // presentation projection. The index is that membership, and
        // removeCanonicalCatalogFile re-proves this exact file's path and inode
        // at the commit.
        const { acquisition, entry } = await this.catalogMembership(sessionId);
        this.requireUnambiguousSessionId(sessionId, acquisition.ambiguousIDs);
        const slot = this.slots.get(sessionId);
        if (!entry && (!slot || slot.persistedSessionFile !== undefined)) {
          throw this.unprovenSessionRefusal(sessionId)
            ?? new GatewayError("not_found", "Tron session was removed before it could be deleted");
        }
        if (entry?.structuralSubagent) {
          throw new GatewayError("conflict", "Delete the originating user session instead of mutating its runtime-owned subagent session");
        }
        const cwd = entry?.cwd ?? slot?.cwd;
        if (!cwd) throw new GatewayError("not_found", "Tron session was not found");
        if (await this.projectTrustReloading(cwd)) {
          throw new GatewayError("busy", "Project trust is being reconfigured", true);
        }
        if (slot && slot.isBusyExceptWorkToken(initiatingWorkToken)) {
          throw new GatewayError("busy", "Stop the active session before deleting it", false, undefined, "session_operation_busy");
        }
        this.searchInvalidator?.(sessionId);
        await this.options.beforeSessionDelete?.(sessionId);
        this.cancelIdleEviction(sessionId, slot);
        if (slot) await slot.dispose(initiatingWorkToken);
        if (this.slots.get(sessionId) !== undefined) {
          this.slots.delete(sessionId);
          this.recordRuntimeEviction(sessionId, "deleted");
        }
        this.subscribers.delete(sessionId);
        this.presentationPresence.removeSession(sessionId);
        this.summaryRevisions.delete(sessionId);
        this.latestSummaries.delete(sessionId);
        this.interrupted.delete(sessionId);
        await this.markers.clear(sessionId);
        if (entry) {
          // Canonical deletion commits before projection cleanup. If cleanup fails,
          // restart reconciliation prunes the now-unowned record; it can never
          // resurrect catalog membership or publish a summary.
          await this.removeCanonicalCatalogFile(
            entry.path,
            sessionId,
            entry.fileIdentity,
          );
          // The deletion is committed; the owner announces it because an
          // unreadable path proves neither absence nor presence.
          this.sessionCatalog.remove(entry.path);
          this.invalidateCatalogAcquisition();
        } else {
          this.invalidateCatalogAdmission();
        }
        this.revision += 1;
        this.options.sessionListChanged();
        deleted = true;
      });
    } finally {
      await this.attentionLane.run(async () => {
        try {
          if (deleted) {
            try {
              await this.attention.remove(sessionId);
            } catch {
              this.pendingAttentionRemovals.add(sessionId);
            }
            let archiveRemoved = false;
            try {
              archiveRemoved = await this.archive.remove(sessionId);
            } catch {
              // Report the first failure at the boundary that owned the attempt;
              // the flush retries this exact removal silently.
              this.archivePersistFailed("remove");
              this.pendingArchiveRemovals.add(sessionId);
            }
            this.pendingArchiveRestorations.delete(sessionId);
            if (archiveRemoved) this.archiveChanged([sessionId]);
          }
        } finally {
          this.deletingSessionIds.delete(sessionId);
        }
      });
    }
  }

  private async removeCanonicalCatalogFile(
    path: string,
    expectedSessionId: string,
    expectedFileIdentity: string | undefined,
  ): Promise<void> {
    if (!expectedFileIdentity) {
      throw new GatewayError("busy", "Session file identity is unavailable for deletion", true);
    }

    // Deletion is the only catalog mutation committed from a prior row
    // admission. The index must still claim this exact file, and the file's own
    // inode and header below are the destructive boundary; no other file is
    // read, so a delete request never walks the folder.
    const acquisition = await this.catalogAcquisition();
    const entry = acquisition.entriesByID.get(expectedSessionId);
    if (acquisition.ambiguousIDs.has(expectedSessionId)
      || !entry || entry.structuralSubagent || entry.path !== resolve(path)) {
      throw new GatewayError("conflict", "Session catalog identity changed before deletion", true);
    }

    let current: Awaited<ReturnType<typeof lstat>>;
    try { current = await lstat(path); }
    catch { throw new GatewayError("not_found", "Tron session was removed before it could be deleted"); }
    if (!current.isFile() || current.isSymbolicLink()
      || `${current.dev}:${current.ino}` !== expectedFileIdentity) {
      throw new GatewayError("conflict", "Tron session file was replaced before deletion", true);
    }

    const quarantine = `${path}.tron-delete-${randomUUID()}`;
    await rename(path, quarantine).catch(() => {
      throw new GatewayError("busy", "Tron session changed while deletion was committing", true);
    });
    let committed = false;
    try {
      const moved = await lstat(quarantine);
      if (!moved.isFile() || moved.isSymbolicLink()
        || `${moved.dev}:${moved.ino}` !== expectedFileIdentity) {
        throw new GatewayError("conflict", "Tron session file was replaced before deletion", true);
      }
      const header = await this.readCatalogHeader(quarantine, 64 * 1_024, () => true, () => {});
      if (header.identity?.id !== expectedSessionId
        || header.identity.fileIdentity !== expectedFileIdentity) {
        throw new GatewayError("conflict", "Tron session identity changed before deletion", true);
      }
      await rm(quarantine);
      committed = true;
    } finally {
      if (!committed) {
        const originalExists = await lstat(path).then(() => true).catch(() => false);
        if (!originalExists) await rename(quarantine, path).catch(() => {});
      }
    }
  }

  /**
   * Cold runtime loads are queued through this gate (`G-12`): a load parses a
   * transcript into the runtime the byte budget then has to hold, so
   * `MAXIMUM_CONCURRENT_COLD_LOADS` of them at once keep the disk, the event
   * loop and the libuv pool shared with interactive reads. The queue, not the
   * load, is what a requester that leaves abandons: the start already in flight
   * keeps running and is shared with whatever retry joins it (`C-6`).
   */
  private readonly coldLoadGate = new QueuedWorkGate(MAXIMUM_CONCURRENT_COLD_LOADS);

  /**
   * The heap-pressure gate in front of a cold runtime load (`G-12`). Above
   * `HEAP_EVICTION_SHARE` of the V8 heap limit, idle runtimes are retired
   * largest first — the largest reclaims the most — until the share is back
   * under it or no runtime is eligible. Above `HEAP_REFUSAL_SHARE` after that,
   * the load is refused with a retryable `busy`, its retry hint, and one
   * `gateway.shed` record naming the admission: past that point this load is
   * what would take the process to the limit the memory criterion measures. A
   * protected runtime is never retired, so a heap made of protected runtimes
   * refuses instead of pretending it made room.
   */
  private async admitColdLoadUnderHeapPressure(admission: ColdLoadAdmission): Promise<void> {
    const reclaimedBytes = this.projectedHeapShare(0) > HEAP_EVICTION_SHARE
      ? await this.retireIdleRuntimesForHeap()
      : 0;
    const sample = this.readHeapSample();
    if (!(sample.limitBytes > 0)
      || (sample.usedBytes - reclaimedBytes) / sample.limitBytes <= HEAP_REFUSAL_SHARE) return;
    this.options.capacityShedRecord?.({
      reason: "heap",
      admission,
      heapUsedBytes: Math.max(0, Math.round(sample.usedBytes)),
      heapLimitBytes: sample.limitBytes,
      retryAfterMs: HEAP_REFUSAL_RETRY_AFTER_MS,
    });
    throw new GatewayError(
      "busy",
      "Gateway heap pressure refuses new runtime loads",
      true,
      { retryAfterMs: HEAP_REFUSAL_RETRY_AFTER_MS },
    );
  }

  /** Retire idle runtimes largest first while the heap is over
   * `HEAP_EVICTION_SHARE`, and answer how many estimated bytes the pass gave
   * back. The eligible set is what terminates the pass: every runtime in the
   * inventory is considered once, and a protected one is skipped. Progress is
   * measured from the registry's own accounting — `process.memoryUsage()` does
   * not fall until V8 collects, so a sampled heap alone would keep every
   * candidate over the share and retire the whole live set for one load. */
  private async retireIdleRuntimesForHeap(): Promise<number> {
    const candidates = [...await this.resourceInventory()].sort((left, right) => right.bytes - left.bytes);
    let reclaimedBytes = 0;
    for (const candidate of candidates) {
      if (this.projectedHeapShare(reclaimedBytes) <= HEAP_EVICTION_SHARE) return reclaimedBytes;
      const slot = this.slots.get(candidate.sessionId);
      if (slot === undefined) continue;
      // The charge the eviction will record, read before the retirement clears
      // it; the byte pass refreshed every live charge from its own stat in the
      // same admission, so this is the size the pass is reclaiming.
      const reclaimed = this.publishedRuntimeBytes.get(candidate.sessionId)?.estimatedHeapBytes
        ?? estimateRuntimeHeapBytes(candidate.bytes);
      const retired = await this.retireIdleRuntime({
        sessionId: candidate.sessionId,
        slot,
        reason: "heap",
        eligible: () => this.projectedHeapShare(reclaimedBytes) > HEAP_EVICTION_SHARE
          && this.isIdleEvictionEligible(candidate.sessionId, slot, Infinity),
      });
      if (retired) reclaimedBytes += reclaimed;
    }
    return reclaimedBytes;
  }

  /** The heap share this admission expects once `reclaimedBytes` of accounted
   * runtimes are given back. The eviction pass and the refusal behind it both
   * read this, so neither waits for a garbage collection the process cannot
   * schedule (`G-12`). */
  private projectedHeapShare(reclaimedBytes: number): number {
    const sample = this.readHeapSample();
    if (!(sample.limitBytes > 0) || !Number.isFinite(sample.usedBytes)) return 0;
    return Math.max(0, sample.usedBytes - reclaimedBytes) / sample.limitBytes;
  }

  private requireLiveSlotCapacity(): void {
    const maximum = this.options.maximumLiveRuntimes;
    if (maximum !== undefined && this.slots.size + this.reservedSlotStarts >= maximum) {
      throw new GatewayError("busy", "Gateway live runtime capacity is full; close or wait for an idle session", true);
    }
  }

  /** Byte pressure on the admission path: retires idle runtimes largest first
   * until the projected total fits `LIVE_RUNTIME_BYTE_BUDGET`. The budget is
   * pressure, not a gate: an admission that still does not fit is admitted beside
   * what it could not reclaim, and its `runtime.loaded` record carries
   * `overBudget` — the runtime count and the launcher's heap limit are the
   * backstop, and refusal under real heap pressure belongs to the memory owner,
   * not here. Largest first, because the runtime holding the most heap is the one
   * whose retirement reclaims the most headroom; only a reloadable, unprotected
   * idle runtime is a candidate, so a subscriber, run or lease keeps its runtime
   * live.
   * Nothing is retired when that could not help: a start that adds no bytes
   * cannot raise the total, a charge larger than the whole budget could never fit
   * however many runtimes are retired, and retiring every eligible runtime is
   * skipped as a set when even that would not clear the excess. A start already
   * pending for the requested session leaves this pass nothing to make room for:
   * a second open of one session waits for the first, so evicting idle runtimes
   * for it would buy nothing. */
  private async makeRoomForRuntimeBytes(
    input: { requestedSessionID?: string; incomingBytes: number },
  ): Promise<void> {
    return await stage("session.runtime-budget", async () => {
      const { requestedSessionID, incomingBytes } = input;
      const estimates = new Map<string, number>();
      for (const runtime of await this.resourceInventory()) {
        // The session being opened is charged as `incomingBytes` instead, so it
        // is never summed here or retired below.
        if (runtime.sessionId === requestedSessionID) continue;
        const estimatedHeapBytes = estimateRuntimeHeapBytes(runtime.bytes);
        estimates.set(runtime.sessionId, estimatedHeapBytes);
        // This stat is newer than the charge the runtime published with, and an
        // eviction here gives back what this pass measured rather than what the
        // load charged: record the size this pass saw.
        this.publishedRuntimeBytes.set(runtime.sessionId, { transcriptBytes: runtime.bytes, estimatedHeapBytes });
      }
      const pendingStart = requestedSessionID !== undefined && this.pendingSlotStarts.has(requestedSessionID);
      if (incomingBytes === 0 || incomingBytes > LIVE_RUNTIME_BYTE_BUDGET || pendingStart) {
        this.blobs.prune();
        return;
      }
      let liveBytes = 0;
      for (const bytes of estimates.values()) liveBytes += bytes;
      const projectedBytes = () => this.projectedRuntimeBytes(liveBytes, incomingBytes, requestedSessionID);
      if (projectedBytes() <= LIVE_RUNTIME_BYTE_BUDGET) {
        this.blobs.prune();
        return;
      }
      const candidates = [...estimates].sort(([, left], [, right]) => right - left);
      const eligibleSlot = (sessionId: string): RuntimeSlot | undefined => {
        const slot = this.slots.get(sessionId);
        if (slot === undefined || slot.persistedSessionFile === undefined) return undefined;
        return this.isIdleEvictionEligible(sessionId, slot, Infinity) ? slot : undefined;
      };
      let retireableBytes = 0;
      for (const [sessionId] of candidates) {
        if (eligibleSlot(sessionId) === undefined) continue;
        retireableBytes += estimates.get(sessionId) ?? 0;
      }
      if (projectedBytes() - retireableBytes > LIVE_RUNTIME_BYTE_BUDGET) {
        // Retiring every eligible runtime still would not fit, so nothing is
        // retired and the admission is served beside them instead.
        this.blobs.prune();
        return;
      }
      for (const [sessionId] of candidates) {
        if (projectedBytes() <= LIVE_RUNTIME_BYTE_BUDGET) break;
        const slot = eligibleSlot(sessionId);
        if (slot === undefined) continue;
        const retired = await this.retireIdleRuntime({
          sessionId,
          slot,
          reason: "bytes",
          // Room may already have been made by a concurrent pass, and a slot may
          // have become busy since the sort above; neither is a reason to retire
          // this one.
          eligible: () => projectedBytes() > LIVE_RUNTIME_BYTE_BUDGET
            && this.isIdleEvictionEligible(sessionId, slot, Infinity),
        });
        if (retired) liveBytes = Math.max(0, liveBytes - (estimates.get(sessionId) ?? 0));
      }
      this.blobs.prune();
    });
  }

  /** The total the byte budget is applied to: the live estimate, every start
   * already reserved for, and this admission's own charge. The requested
   * session's own reservation is left out because `incomingBytes` *is* that
   * charge; counting both is what made a second open of one session evict idle
   * runtimes for room its first open had already taken and would not use. */
  private projectedRuntimeBytes(liveBytes: number, incomingBytes: number, requestedSessionID?: string): number {
    let total = liveBytes + incomingBytes;
    for (const [sessionId, bytes] of this.reservedRuntimeBytes) {
      if (sessionId === requestedSessionID) continue;
      total += bytes;
    }
    return total;
  }

  private recordRuntimeTransition(record: RuntimeLifecycleRecord): void {
    this.options.runtimeLifecycleRecord?.(record);
  }

  /** Records one published runtime that stopped being live, from the charge it
   * published with. Every path that removes a slot from `slots` calls this, so
   * the charge cannot outlive its runtime and an eviction is recorded exactly
   * once. A slot the registry never published has no charge and is not an
   * eviction. */
  private recordRuntimeEviction(sessionId: string, reason: RuntimeEvictionReason): void {
    const charge = this.publishedRuntimeBytes.get(sessionId);
    if (charge === undefined) return;
    this.publishedRuntimeBytes.delete(sessionId);
    this.recordRuntimeTransition({
      event: "runtime.evicted",
      sessionId,
      reason,
      transcriptBytes: charge.transcriptBytes,
      estimatedHeapBytes: charge.estimatedHeapBytes,
    });
  }

  private requireUnambiguousSessionId(
    sessionId: string,
    ambiguousIDs: ReadonlySet<string> = this.ambiguousSessionIds,
  ): void {
    if (ambiguousIDs.has(sessionId)) {
      throw new GatewayError(
        "conflict",
        "Multiple canonical session files claim this ID; repair or remove the duplicate before continuing",
      );
    }
  }

  /**
   * Publishes one newly live runtime, charges it to the byte budget in the same
   * synchronous turn, and counts it for the resource sample. A runtime loaded
   * and evicted inside one sample window would be invisible to a comparison of
   * live sets, so the transition is counted where it happens; the slot only
   * counts its disposal as an eviction once it was published here.
   */
  private publishRuntime(
    sessionId: string,
    slot: RuntimeSlot,
    transcriptBytes: number,
    reason: Exclude<RuntimeLoadReason, "oversize">,
  ): void {
    const estimatedHeapBytes = estimateRuntimeHeapBytes(transcriptBytes);
    this.publishedRuntimeBytes.set(sessionId, { transcriptBytes, estimatedHeapBytes });
    this.slots.set(sessionId, slot);
    slot.markPublished();
    this.options.resources?.recordRuntimeLoaded();
    this.recordRuntimeTransition({
      event: "runtime.loaded",
      sessionId,
      // A session whose own transcript is over the whole budget is admitted
      // alone (see `makeRoomForRuntimeBytes`); name that so the record explains
      // why the byte pass could not reclaim anything for it.
      reason: estimatedHeapBytes > LIVE_RUNTIME_BYTE_BUDGET ? "oversize" : reason,
      transcriptBytes,
      estimatedHeapBytes,
      // The byte budget retires idle runtimes for an admission it cannot fit but
      // admits it anyway (it is pressure, not a gate), so the load record names
      // the over-budget state its readers would otherwise have to infer from the
      // sampler's next minute.
      ...(this.liveChargeExceedsBudget() ? { overBudget: true as const } : {}),
    });
  }

  /** True when the charge of the live runtimes together is over the byte budget.
   * Every live runtime published its charge, and the byte pass refreshes it from
   * its own stat, so this is the live set the budget is applied to. */
  private liveChargeExceedsBudget(): boolean {
    let total = 0;
    for (const charge of this.publishedRuntimeBytes.values()) total += charge.estimatedHeapBytes;
    return total > LIVE_RUNTIME_BYTE_BUDGET;
  }

  /**
   * The live runtimes and the canonical transcript bytes each holds, for the
   * transport's resource sample and for the byte budget. Bytes come from one
   * `stat` per live runtime, not from a projection kept in step with every
   * append. A slot that has already been disposed is not live even while its
   * removal from `slots` is still in flight.
   */
  async resourceInventory(): Promise<readonly ResourceRuntimeEntry[]> {
    const entries: ResourceRuntimeEntry[] = [];
    for (const [sessionId, slot] of this.slots) {
      if (slot.isDisposed) continue;
      // `sessionFile` rather than `persistedSessionFile`: the stat handles a
      // file that is not there yet, and this path must not add a sync check.
      const file = slot.sessionFile;
      const bytes = file === undefined ? 0 : await stat(file).then((metadata) => metadata.size).catch(() => 0);
      entries.push({ sessionId, bytes, subscribers: this.subscribers.get(sessionId)?.size ?? 0 });
    }
    return entries;
  }

  subscribe(clientId: string, sessionId: string): void {
    this.cancelIdleEviction(sessionId, this.slots.get(sessionId));
    const clients = this.subscribers.get(sessionId) ?? new Set<string>();
    clients.add(clientId);
    this.subscribers.set(sessionId, clients);
  }

  setPresentationVisibility(input: {
    clientId: string;
    sessionId: string;
    subscriptionToken: string;
    revision: number;
    visible: boolean;
  }): SessionPresentationPresenceProjection {
    if (!this.isSubscribed(input.clientId, input.sessionId)) {
      throw new GatewayError("conflict", "Session presentation subscription is not current", true);
    }
    return this.presentationPresence.set(input, () => {
      // Transport has resolved aliases and admitted the exact mobile token.
      // Notification persistence must not block chat or die with its socket;
      // the notification owner retains captured IDs for its background drain.
      void this.options.notifications?.markSessionInboxRead(input.sessionId).catch(() => {});
    });
  }

  isSessionPresented(sessionId: string): boolean {
    return this.presentationPresence.isVisible(sessionId);
  }

  unsubscribe(clientId: string, sessionId: string): void {
    const clients = this.subscribers.get(sessionId);
    clients?.delete(clientId);
    if (clients?.size === 0) this.subscribers.delete(sessionId);
    this.presentationPresence.remove(clientId, sessionId);
  }

  unsubscribeClient(clientId: string): void {
    for (const [sessionId, clients] of this.subscribers) {
      clients.delete(clientId);
      if (clients.size === 0) this.subscribers.delete(sessionId);
    }
    this.presentationPresence.remove(clientId);
  }

  isSubscribed(clientId: string, sessionId: string): boolean {
    return this.subscribers.get(sessionId)?.has(clientId) ?? false;
  }

  private cancelIdleEviction(sessionId: string, slot: RuntimeSlot | undefined): void {
    const eviction = this.idleEvictions.get(sessionId);
    if (slot && eviction?.slot === slot && !eviction.committed) this.idleEvictions.delete(sessionId);
  }

  private isIdleEvictionEligible(sessionId: string, slot: RuntimeSlot, cutoff: number): boolean {
    return this.slots.get(sessionId) === slot
      && !slot.isDisposed
      && !slot.isEvictionProtected
      && slot.touchedAt < cutoff
      && (this.subscribers.get(sessionId)?.size ?? 0) === 0;
  }

  /** One bounded Gateway owner discovers shared extension artifacts. Exact
   * live bindings are refreshed first; ambient enumeration and routed reads
   * share one hard work budget and cannot starve a known drain owner. */
  private async discoverExtensionArtifacts(): Promise<void> {
    if (this.artifactDiscoveryInFlight || this.shutdownState !== "active") return;
    this.artifactDiscoveryInFlight = true;
    let truncated: ExtensionArtifactDiscoveryCounts | undefined;
    try {
      truncated = await this.runArtifactDiscoveryPass();
    } finally {
      this.artifactDiscoveryInFlight = false;
    }
    if (truncated) {
      const now = Date.now();
      // Two episodes are tracked so a pass that only drops candidates the
      // routing budget cut off still reports once: the end of either episode is
      // not a record of its own, and a lasting one repeats hourly.
      if (this.artifactDiscoveryStoppedSince === 0) this.artifactDiscoveryStoppedSince = now;
      if (truncated.dropped === 0) this.artifactDiscoveryDroppedSince = 0;
      else if (this.artifactDiscoveryDroppedSince === 0) this.artifactDiscoveryDroppedSince = now;
      this.reportArtifactDiscoveryTruncation(truncated);
    } else {
      this.artifactDiscoveryStoppedSince = 0;
      this.artifactDiscoveryDroppedSince = 0;
    }
  }

  /** One discovery pass. It returns this pass's counts when it stopped at a
   * budget rather than at the end of its roots, so the stop is reported instead
   * of silent. The next pass walks from the start again, and because an
   * unchanged artifact spends no read budget it reaches the entries this pass
   * did not examine. */
  private async runArtifactDiscoveryPass(): Promise<ExtensionArtifactDiscoveryCounts | undefined> {
    const counts: ExtensionArtifactDiscoveryCounts = { entries: 0, statusReads: 0, work: 0, dropped: 0 };
    const slots = [...this.slots.values()];
    const exact = new Set<string>();
    for (const slot of slots) {
      for (const asyncDir of slot.ownedExtensionArtifactDirectories()) {
        const key = `${slot.id}\0${asyncDir}`;
        if (!exact.add(key)) continue;
        if (counts.work >= MAX_EXTENSION_DISCOVERY_WORK) return counts;
        counts.work += 1;
        await slot.discoverExtensionArtifact(asyncDir);
      }
    }

    const roots = new Set<string>();
    if (this.options.delegatedArtifactRoot) {
      const providerRunsRoot = join(this.options.delegatedArtifactRoot, "async-subagent-runs");
      try { if ((await stat(providerRunsRoot)).isDirectory()) roots.add(providerRunsRoot); } catch { /* provider root is created on first admitted run */ }
    } else for (const slot of slots) {
      if (roots.size >= MAX_EXTENSION_DISCOVERY_ROOTS) break;
      const projectRoot = join(resolve(slot.cwd), ".pi", "subagents", "async-subagent-runs");
      try { if ((await stat(projectRoot)).isDirectory()) roots.add(projectRoot); } catch { /* isolated pre-cutover fixture */ }
    }
    try {
      let examined = 0;
      // A configured provider root is the sole ambient source after the
      // cutover. Temporary/project roots are only scanned by test fixtures
      // that omit the explicit production root.
      if (this.options.delegatedArtifactRoot) {
        // The exact root was admitted above; do not inspect unrelated temp
        // trees that could become a second delegated authority.
      } else {
      const entries = await opendir(tmpdir());
      for await (const entry of entries) {
        examined += 1;
        if (examined > MAX_EXTENSION_TEMP_ENTRIES || roots.size >= MAX_EXTENSION_DISCOVERY_ROOTS) break;
        if (!entry.isDirectory() || !entry.name.startsWith("pi-subagents-")) continue;
        const root = join(tmpdir(), entry.name, "async-subagent-runs");
        try { if ((await stat(root)).isDirectory()) roots.add(root); } catch { /* disappearing runtime root */ }
      }
      }
    } catch { /* an unavailable artifact root leaves exact bindings authoritative */ }

    const rootList = [...roots];
    this.artifactDiscoveryPass += 1;
    const pass = this.artifactDiscoveryPass;
    // `walkStopped` ends the walk at a budget and `routedOut` ends this pass's
    // routing at the work budget; the entries this pass already read are still
    // routed before it returns.
    let walkStopped = false;
    let routedOut = false;
    let dropped = 0;
    const attributed = new Map<string, ReadonlySet<string>>();
    for (const slot of slots) {
      attributed.set(slot.id, slot.extensionAmbientArtifactAttribution());
    }
    for (let rootIndex = 0; rootIndex < rootList.length; rootIndex += 1) {
      if (counts.work >= MAX_EXTENSION_DISCOVERY_WORK
        || counts.entries >= MAX_EXTENSION_ROOT_ENTRIES
        || counts.statusReads >= MAX_EXTENSION_DISCOVERY_WORK) {
        walkStopped = true;
        break;
      }
      const root = rootList[rootIndex]!;
      const rootsRemaining = rootList.length - rootIndex;
      const routedSlots = Math.max(1, slots.length);
      const rootBudget = Math.max(1, Math.floor(
        (MAX_EXTENSION_DISCOVERY_WORK - counts.work) / (rootsRemaining * routedSlots),
      ));
      const candidates: Array<{ asyncDir: string; runId: string; identity: string; active: boolean; timestamp: number }> = [];
      try {
        const entries = await opendir(root);
        for await (const entry of entries) {
          counts.entries += 1;
          if (counts.entries > MAX_EXTENSION_ROOT_ENTRIES) {
            walkStopped = true;
            break;
          }
          if (!entry.isDirectory()) continue;
          const asyncDir = join(root, entry.name);
          let fact: { identity: string; active: boolean; timestamp: number } | "budget" | undefined;
          try {
            const metadata = await stat(join(asyncDir, "status.json"));
            if (metadata.isFile()) fact = await this.ambientArtifactFact(asyncDir, metadata, pass, counts);
          } catch { /* a replaced or malformed artifact belongs to the next pass */ }
          if (fact === "budget") {
            walkStopped = true;
            break;
          }
          if (fact) candidates.push({ asyncDir, runId: entry.name, ...fact });
        }
      } catch { continue; }
      // Terminal evidence releases accepted work; live exact bindings were
      // already refreshed above and do not outrank it in ambient discovery.
      candidates.sort((left, right) => Number(right.active) - Number(left.active)
        || right.timestamp - left.timestamp || left.asyncDir.localeCompare(right.asyncDir));
      // A candidate is pending offerable work only when a live slot can still
      // attribute the run and has not already dealt with this exact artifact
      // identity: the exact-binding lane keeps a live run current (G-8d), an
      // unattributable directory can only be rejected, and a decision already
      // recorded for these bytes cannot change. Filtering before the per-root
      // budget slice keeps an unchanged root from spending that budget on
      // candidates nobody would accept, which used to starve the same
      // attributed run on every pass.
      const waiting = new Map<string, RuntimeSlot[]>();
      for (const candidate of candidates) {
        const owed: RuntimeSlot[] = [];
        for (const slot of slots) {
          const known = attributed.get(slot.id);
          if (!known || (!known.has(candidate.runId) && !known.has(candidate.asyncDir))) continue;
          const record = this.ambientArtifactRoutes.get(slot.id)?.get(candidate.asyncDir);
          if (record?.identity === candidate.identity) {
            // Seen again this pass: keep the decision alive while the root holds it.
            record.pass = pass;
            continue;
          }
          owed.push(slot);
        }
        if (owed.length > 0) waiting.set(candidate.asyncDir, owed);
      }
      const pending = candidates.filter((candidate) => waiting.has(candidate.asyncDir));
      // Offer only the amount this pass can safely project to live slots; a
      // pending candidate cut off here is reported instead of silently lost.
      const offerable = pending.slice(0, rootBudget);
      dropped += pending.length - offerable.length;
      for (const candidate of offerable) {
        for (const slot of waiting.get(candidate.asyncDir)!) {
          if (counts.work >= MAX_EXTENSION_DISCOVERY_WORK) {
            routedOut = true;
            break;
          }
          counts.work += 1;
          // An offer the slot could not decide leaves no record, so the next
          // pass offers the same artifact again; only an accepted or
          // permanently rejected artifact is dealt with (G-8a).
          const outcome = await slot.discoverExtensionArtifact(candidate.asyncDir);
          if (outcome === "transient") continue;
          let routed = this.ambientArtifactRoutes.get(slot.id);
          if (!routed) {
            routed = new Map();
            this.ambientArtifactRoutes.set(slot.id, routed);
          }
          routed.set(candidate.asyncDir, { identity: candidate.identity, pass });
        }
        if (routedOut) break;
      }
      if (walkStopped || routedOut) break;
    }
    counts.dropped = dropped;
    this.pruneAmbientArtifactFacts(pass);
    this.pruneAmbientArtifactRoutes(pass);
    if (walkStopped || routedOut || dropped > 0) return counts;
    return undefined;
  }

  /** The ambient decision for one run directory, re-read only when the identity
   * of its status.json changed. `"budget"` means this pass spent its read budget
   * on changed artifacts, so the walk stops there instead of skipping the entry
   * and calling the directory examined. */
  private async ambientArtifactFact(
    asyncDir: string,
    metadata: { dev: number; ino: number; size: number; mtimeMs: number },
    pass: number,
    counts: ExtensionArtifactDiscoveryCounts,
  ): Promise<{ identity: string; active: boolean; timestamp: number } | "budget" | undefined> {
    const identity = `${metadata.dev}:${metadata.ino}:${metadata.size}:${metadata.mtimeMs}`;
    const known = this.ambientArtifactFacts.get(asyncDir);
    if (known && known.identity === identity) {
      known.pass = pass;
      return known;
    }
    if (counts.statusReads >= MAX_EXTENSION_DISCOVERY_WORK) return "budget";
    counts.statusReads += 1;
    const decision = await this.readAmbientExtensionArtifact(asyncDir, metadata);
    if (!decision) {
      // A replacement that raced the read or a malformed artifact is not
      // cached, so the next pass decides again.
      this.ambientArtifactFacts.delete(asyncDir);
      return undefined;
    }
    const fact = { identity, active: decision.active, timestamp: decision.timestamp, pass };
    this.ambientArtifactFacts.set(asyncDir, fact);
    return fact;
  }

  /** Read one ambient artifact's bounded lifecycle decision, verifying that the
   * inode the read opened is the one the caller's stat identity named: a replace
   * that raced the read waits for the next pass instead of being projected. */
  private async readAmbientExtensionArtifact(
    asyncDir: string,
    expected: { dev: number; ino: number },
  ): Promise<{ active: boolean; timestamp: number } | undefined> {
    const handle = await open(join(asyncDir, "status.json"), "r");
    try {
      const metadata = await handle.stat();
      if (!metadata.isFile() || metadata.dev !== expected.dev || metadata.ino !== expected.ino) return undefined;
      const headerBuffer = Buffer.alloc(MAX_EXTENSION_LIFECYCLE_HEADER_BYTES);
      const { bytesRead: headerBytesRead } = await handle.read(headerBuffer, 0, headerBuffer.length, 0);
      const headerBytes = headerBuffer.subarray(0, headerBytesRead);
      let parsed: unknown;
      if (hasExtensionLifecycleProjectionProperty(headerBytes)) {
        const projection = inspectExtensionLifecycleProjection(
          parseExtensionLifecycleProjectionHeader(headerBytes),
        );
        if (!projection) return undefined;
        parsed = lifecycleProjectionArtifact(projection);
      } else {
        // Legacy artifacts still require the old whole-document cap.
        // The bounded modern first property is the only permitted
        // route through a report-bearing file larger than that cap.
        if (metadata.size > MAX_EXTENSION_ARTIFACT_BYTES) return undefined;
        const buffer = Buffer.alloc(MAX_EXTENSION_ARTIFACT_BYTES + 1);
        const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
        if (bytesRead > MAX_EXTENSION_ARTIFACT_BYTES) return undefined;
        parsed = JSON.parse(buffer.subarray(0, bytesRead).toString("utf8"));
      }
      const value = admitExtensionLifecycleArtifact(parsed, { exactOwnedLegacy: true });
      if (!value) return undefined;
      const state = value.state ?? value.status;
      const runId = typeof value.runId === "string" ? value.runId : undefined;
      // A settled paused artifact owns no live work: it must not outrank
      // live artifacts for the bounded discovery budget. Without the
      // proof (or a run identity to bind it) the artifact stays active.
      const settledPaused = state === "paused" && runId !== undefined
        && observedPausedProcessTerminalAt(value, runId) !== undefined;
      const active = !settledPaused && (state === "queued" || state === "running" || state === "pending"
        || state === "detached" || state === "paused");
      const timestamps = [value.lastUpdate, value.startedAt, value.endedAt]
        .filter((item): item is number => typeof item === "number" && Number.isSafeInteger(item) && item >= 0);
      return { active, timestamp: Math.max(0, ...timestamps) };
    } finally {
      await handle.close();
    }
  }

  /** Drop the decisions of directories no pass saw within the last few passes,
   * so the cache follows the artifact root instead of growing with every run it
   * ever held. A pass that stopped at a budget ages the entries past its stop
   * too; dropping one early costs a single re-read. */
  private pruneAmbientArtifactFacts(pass: number): void {
    for (const [asyncDir, fact] of this.ambientArtifactFacts) {
      if (pass - fact.pass >= AMBIENT_ARTIFACT_FACT_PASSES) this.ambientArtifactFacts.delete(asyncDir);
    }
  }

  /** Drop the routing records of closed slots and of directories no pass offered
   * within the last few passes, so the records follow the live slots. */
  private pruneAmbientArtifactRoutes(pass: number): void {
    for (const [slotId, routed] of this.ambientArtifactRoutes) {
      if (!this.slots.has(slotId)) {
        this.ambientArtifactRoutes.delete(slotId);
        continue;
      }
      for (const [asyncDir, record] of routed) {
        if (pass - record.pass >= AMBIENT_ARTIFACT_FACT_PASSES) routed.delete(asyncDir);
      }
    }
  }

  private reportArtifactDiscoveryTruncation(counts: ExtensionArtifactDiscoveryCounts): void {
    if (!this.options.artifactDiscoveryTruncated) return;
    const now = Date.now();
    // A stop already reported within the running episode repeats at most hourly.
    const episodeStart = Math.max(this.artifactDiscoveryStoppedSince, this.artifactDiscoveryDroppedSince);
    if (this.artifactDiscoveryStopReportedAt >= episodeStart
      && now - this.artifactDiscoveryStopReportedAt < EXTENSION_DISCOVERY_TRUNCATION_REPORT_MS) return;
    this.artifactDiscoveryStopReportedAt = now;
    this.options.artifactDiscoveryTruncated(counts);
  }

  private async evictIdle(forCapacity = false, requestedSessionID?: string): Promise<void> {
    const maximum = this.options.maximumLiveRuntimes;
    const needsCapacity = () => maximum !== undefined && this.slots.size + this.reservedSlotStarts >= maximum;
    if (forCapacity && !needsCapacity()) return;
    const cutoff = forCapacity ? Infinity : Date.now() - this.options.idleRuntimeMs;
    const candidates = [...this.slots].sort(([, left], [, right]) => left.touchedAt - right.touchedAt);
    for (const [id, slot] of candidates) {
      if (forCapacity && !needsCapacity()) break;
      // Reclaim only reloadable, unobserved idle runtimes under pressure.
      // Unsent drafts keep their normal idle lifetime; runs/leases stay protected.
      // A duplicate acquisition must preserve its own already-published slot.
      const eligible = () => id !== requestedSessionID
        && (!forCapacity || (needsCapacity() && slot.persistedSessionFile !== undefined))
        && this.isIdleEvictionEligible(id, slot, cutoff);
      await this.retireIdleRuntime({ sessionId: id, slot, reason: forCapacity ? "capacity" : "idle", eligible });
    }
    this.blobs.prune();
  }

  /** One idle runtime's retirement under an eligibility closure that is checked
   * under the mutex and again inside the slot's own disposal commit, so a
   * subscription or a run that arrives mid-eviction keeps the runtime live. */
  private async retireIdleRuntime(input: {
    sessionId: string;
    slot: RuntimeSlot;
    reason: Extract<RuntimeEvictionReason, "idle" | "capacity" | "bytes" | "heap">;
    eligible: () => boolean;
  }): Promise<boolean> {
    const { sessionId: id, slot, eligible, reason } = input;
    const selected = await this.mutex.run(() => {
      if (this.idleEvictions.has(id) || !eligible()) return false;
      this.idleEvictions.set(id, { slot, committed: false });
      return true;
    });
    if (!selected) return false;
    try {
      const eviction = this.idleEvictions.get(id);
      if (eviction?.slot !== slot) return false;
      let removedLiveOnlySession = false;
      const disposal = slot.disposeIf(() => {
        if (this.idleEvictions.get(id) !== eviction || !eligible()) return false;
        eviction.committed = true;
        removedLiveOnlySession = slot.persistedSessionFile === undefined;
        return true;
      });
      eviction.completion = disposal;
      const disposed = await disposal;
      if (disposed && this.slots.get(id) === slot && this.idleEvictions.get(id) === eviction) {
        this.slots.delete(id);
        this.recordRuntimeEviction(id, reason);
        if (removedLiveOnlySession) {
          this.subscribers.delete(id);
          this.interrupted.delete(id);
          this.summaryRevisions.delete(id);
          this.latestSummaries.delete(id);
          this.invalidateCatalogAdmission();
          this.revision += 1;
          this.options.sessionListChanged();
        }
      }
      return disposed;
    } catch {
      // A slot may have become busy after the eligibility check; retain it.
      return false;
    } finally {
      if (this.idleEvictions.get(id)?.slot === slot) this.idleEvictions.delete(id);
    }
  }

  activeSessionIds(): string[] {
    return [...this.slots.values()].filter((slot) => slot.isBusy).map((slot) => slot.id);
  }

  /** Close every Gateway work admission in the same synchronous turn as the
   * accepted restart RPC and return its initial bounded identity. */
  beginAdministrativeDrain(): AdministrativeDrainSnapshot {
    if (!this.administrativeDrainStarted) {
      this.administrativeDrainStarted = true;
      this.workRegistry.beginDrain();
      // Existing slot preflights close in this same synchronous turn. Queue
      // clearing remains asynchronous preparation after the response boundary.
      for (const slot of this.slots.values()) slot.beginAdministrativeDrainCutoff();
      this.drainId = randomUUID();
      this.drainPhase = "preparing";
      this.drainFingerprint = "";
      this.drainRevision += 1;
    }
    return this.administrativeDrainSnapshot();
  }

  private setDrainPhase(phase: AdministrativeDrainPhase): void {
    if (this.drainPhase === phase) return;
    this.drainPhase = phase;
    this.drainRevision += 1;
    this.drainFingerprint = "";
  }

  administrativeDrainSnapshot(): AdministrativeDrainSnapshot {
    const now = Date.now();
    const facts: Array<{
      key: string;
      sessionId?: string;
      method?: string;
      category: AdministrativeDrainBlockerCategory;
      state: AdministrativeDrainBlockerSummary["state"];
      admittedAt?: string;
      progressAt?: string;
    }> = [];
    const workFacts = this.workRegistry.facts();
    const suspectForegroundTokens = new Set([...this.slots.values()].flatMap((slot) =>
      [...slot.administrativeSuspectForegroundWorkTokens()]
    ));
    for (const work of workFacts) {
      const foregroundIsSuspect = work.kind === "foreground-agent-operation"
        && (work.sessionId === undefined
          || !this.slots.has(work.sessionId)
          || suspectForegroundTokens.has(work.token));
      facts.push({
        key: `work:${work.token}`,
        ...(work.sessionId ? { sessionId: work.sessionId } : {}),
        ...(work.method ? { method: work.method } : {}),
        category: work.kind,
        state: foregroundIsSuspect || work.suspect
          ? "suspect"
          : work.kind === "terminal-receipt-persistence" ? "settling" : "active",
        admittedAt: work.admittedAt,
        progressAt: work.progressAt,
      });
    }
    for (const slot of this.slots.values()) {
      for (const fact of slot.administrativeDrainBlockers()) {
        facts.push({ ...fact, sessionId: slot.id, key: `slot:${slot.id}:${fact.key}` });
      }
    }
    facts.sort((left, right) => (left.admittedAt ?? "").localeCompare(right.admittedAt ?? "")
      || left.category.localeCompare(right.category) || left.key.localeCompare(right.key));
    const counts: Partial<Record<AdministrativeDrainBlockerCategory, number>> = {};
    for (const fact of facts) counts[fact.category] = (counts[fact.category] ?? 0) + 1;
    const summaries = facts.slice(0, 64).map((fact) => {
      const admittedMilliseconds = fact.admittedAt ? Date.parse(fact.admittedAt) : Number.NaN;
      return {
        id: `blocker-${createHash("sha256").update(`${this.drainId}\0${fact.key}`).digest("hex").slice(0, 20)}`,
        category: fact.category,
        ...(fact.sessionId ? { sessionId: fact.sessionId } : {}),
        ...(fact.method ? { method: fact.method } : {}),
        state: fact.state,
        ...(fact.admittedAt && Number.isFinite(admittedMilliseconds) ? {
          admittedAt: fact.admittedAt,
          ageMs: Math.max(0, now - admittedMilliseconds),
        } : {}),
        ...(fact.progressAt ? { progressAt: fact.progressAt } : {}),
      } satisfies AdministrativeDrainBlockerSummary;
    });
    const fingerprint = JSON.stringify({
      phase: this.drainPhase,
      facts: facts.map((fact) => [fact.key, fact.category, fact.state, fact.admittedAt, fact.progressAt]),
    });
    if (fingerprint !== this.drainFingerprint) {
      this.drainFingerprint = fingerprint;
      this.drainRevision += 1;
    }
    return {
      drainId: this.drainId,
      revision: this.drainRevision,
      phase: this.drainPhase,
      blockerCount: facts.length,
      blockerCounts: counts,
      blockers: summaries,
      omittedCount: Math.max(0, facts.length - summaries.length),
      suspectProjectionCount: facts.filter((fact) => fact.state === "suspect").length,
    };
  }

  drainBusySessionCount(): number { return this.administrativeDrainSnapshot().blockerCount; }

  async waitUntilIdle(continueDrain?: (snapshot: AdministrativeDrainSnapshot) => boolean): Promise<boolean> {
    // Freeze slot/admin admissions synchronously, then wait for every operation
    // admitted before the cutoff. Graceful restart never cancels accepted work.
    this.beginAdministrativeDrain();
    try {
      while (this.slotAdmissionsInFlight > 0) {
        if (continueDrain && !continueDrain(this.administrativeDrainSnapshot())) {
          this.failAdministrativeDrain();
          return false;
        }
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
      const slots = await this.mutex.run(() => [...this.slots.values()]);
      const capturedSlotIDs = new Set(slots.map((slot) => slot.id));
      const assertForegroundOwnersHaveSlots = () => {
        const stranded = this.workRegistry.facts().some((work) =>
          work.kind === "foreground-agent-operation"
            && (work.sessionId === undefined || !capturedSlotIDs.has(work.sessionId))
        );
        if (stranded) {
          throw new Error("Administrative drain found foreground ownership without a captured runtime slot");
        }
      };
      assertForegroundOwnersHaveSlots();
      let preparationSettled = false;
      let preparationError: unknown;
      void Promise.all(slots.map((slot) => slot.prepareForAdministrativeDrain())).then(
        () => { preparationSettled = true; },
        (error) => { preparationError = error; preparationSettled = true; },
      );
      let lastArtifactReconciliation = Number.NEGATIVE_INFINITY;
      this.setDrainPhase("waiting");
      while (!preparationSettled || this.workRegistry.size > 0 || slots.some((slot) => slot.isDrainBusy)) {
        const snapshot = this.administrativeDrainSnapshot();
        if (continueDrain && !continueDrain(snapshot)) {
          this.failAdministrativeDrain();
          return false;
        }
        assertForegroundOwnersHaveSlots();
        const monotonic = performance.now();
        if (preparationSettled && preparationError === undefined
          && monotonic - lastArtifactReconciliation >= 750) {
          lastArtifactReconciliation = monotonic;
          await Promise.all(slots
            .filter((slot) => slot.isDrainBusy)
            .map((slot) => slot.reconcileOwnedExtensionArtifactsForDrain()));
          continue;
        }
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
      if (preparationError !== undefined) throw preparationError;
      const finalWaiting = this.administrativeDrainSnapshot();
      if (continueDrain && !continueDrain(finalWaiting)) {
        this.failAdministrativeDrain();
        return false;
      }
      if (finalWaiting.blockerCount !== 0) {
        throw new Error("Administrative drain cannot complete while blockers remain");
      }
      this.workRegistry.completeDrain();
      this.setDrainPhase("complete");
      const completed = this.administrativeDrainSnapshot();
      if (completed.blockerCount !== 0) {
        throw new Error("Administrative drain completion invariant was violated");
      }
      return true;
    } catch (error) {
      this.failAdministrativeDrain();
      throw error;
    }
  }

  /** Records an unproved process-retirement stage without reopening admission. */
  failAdministrativeDrain(): void {
    if (this.drainPhase === "idle") this.beginAdministrativeDrain();
    this.setDrainPhase("failed");
    this.administrativeDrainSnapshot();
  }

  async dispose(): Promise<void> {
    if (this.shutdownState === "disposed") return;
    if (this.disposalPromise) return this.disposalPromise;

    // Close admission synchronously before waiting for any in-flight critical
    // section. The mutex snapshot then includes every slot whose insertion had
    // already begun and excludes every later create/acquire/import attempt.
    this.shutdownState = "shuttingDown";
    if (this.evictionTimer) clearInterval(this.evictionTimer);
    if (this.artifactDiscoveryTimer) clearInterval(this.artifactDiscoveryTimer);
    const operation = this.performDispose();
    this.disposalPromise = operation;
    try {
      await operation;
    } catch (error) {
      // Keep shuttingDown admission closed, but do not memoize a failed
      // retirement forever. Successful slots/stores remain retired; failed
      // owners stay in place for the next attempt and surface the original
      // error again if that attempt also fails.
      if (this.disposalPromise === operation) this.disposalPromise = undefined;
      throw error;
    }
  }

  private async performDispose(): Promise<void> {
    while (this.slotAdmissionsInFlight > 0) {
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    const entries = await this.mutex.run(() => [...this.slots.entries()]);
    const results = await Promise.allSettled(entries.map(([, slot]) => slot.shutdown()));
    const failures: unknown[] = [];
    for (let index = 0; index < entries.length; index += 1) {
      const [id, slot] = entries[index]!;
      const result = results[index]!;
      if (result.status === "fulfilled") {
        if (this.slots.get(id) === slot) {
          this.slots.delete(id);
          this.recordRuntimeEviction(id, "shutdown");
        }
      } else {
        failures.push(result.reason);
      }
    }
    if (failures.length > 0) {
      throw new AggregateError(failures, "One or more session runtimes failed to shut down");
    }
    await this.disposeSharedStores();
    this.shutdownState = "disposed";
  }

  private async disposeSharedStores(): Promise<void> {
    const pending: Promise<void>[] = [];
    if (!this.blobsDisposed) {
      pending.push(this.blobs.dispose().then(() => { this.blobsDisposed = true; }));
    }
    if (!this.exportsDisposed) {
      pending.push(this.exports.dispose().then(() => { this.exportsDisposed = true; }));
    }
    if (!this.workspaceDisposed) {
      pending.push(this.workspace.dispose().then(() => { this.workspaceDisposed = true; }));
    }
    // The catalog owner applies its own Gateway-owned changes and writes the
    // durable document; settle it before the document's writer refuses writes.
    if (!this.sessionCatalogDisposed || !this.catalogIndexDisposed) {
      pending.push((async () => {
        if (!this.sessionCatalogDisposed) {
          await this.sessionCatalog.dispose();
          this.sessionCatalogDisposed = true;
        }
        if (!this.catalogIndexDisposed) {
          await this.catalogMetadataIndex.dispose();
          this.catalogIndexDisposed = true;
        }
      })());
    }
    // Model recency is recorded fire-and-forget from an admitted run, so a
    // preference write can equally outlive this owner.
    if (!this.recentModelsDisposed) {
      pending.push(this.recentModels.dispose().then(() => { this.recentModelsDisposed = true; }));
    }
    // The archive backstop clears records fire-and-forget while sessions
    // publish, and a summary published during slot shutdown can start one more.
    // Drain until no attempt remains, so none writes after disposal resolves.
    for (const attempt of this.archiveRestorationAttempts.values()) pending.push(attempt);
    const results = await Promise.allSettled(pending);
    while (this.archiveRestorationAttempts.size > 0) {
      await Promise.allSettled([...this.archiveRestorationAttempts.values()]);
    }
    const failure = results.find((result): result is PromiseRejectedResult => result.status === "rejected");
    if (failure) throw failure.reason;
  }

  private beginSlotAdmission(): () => void {
    this.assertSlotAdmissionOpen();
    if (this.administrativeDrainStarted) {
      throw new GatewayError("busy", "Gateway restart is draining admitted session work", true);
    }
    const work = this.workRegistry.begin({
      kind: "slot-admission",
      hostEpoch: this.workRegistry.runtimeEpoch,
    });
    this.slotAdmissionsInFlight += 1;
    let finished = false;
    return () => {
      if (finished) return;
      finished = true;
      this.slotAdmissionsInFlight -= 1;
      work.settle();
    };
  }

  private assertSlotAdmissionOpen(): void {
    if (this.shutdownState !== "active") {
      throw new GatewayError("conflict", "Session runtime registry is shutting down", true);
    }
  }

  registerWorkspaceBlob(data: Buffer, mimeType: string): string {
    return this.blobs.registerData(data, mimeType);
  }

  async acquireBlob(id: string, range?: import("./blob-store.js").BlobByteRange, signal?: AbortSignal) {
    try {
      return await this.blobs.acquire(id, range, signal);
    } catch (error) {
      if (!(error instanceof GatewayError) || error.code !== "not_found") throw error;
      return this.exports.acquire(id, range, signal);
    }
  }

  private async authorizeDisplayArtifact(sessionID: string, artifactID: string): Promise<boolean> {
    // Retention ownership is necessary but never sufficient: every read must
    // also be backed by an exact reference on this session's canonical branch.
    // Do not repair owner links from an arbitrary transcript reference; fork
    // ownership is committed transactionally by the rekey path above.
    if (!this.displayArtifacts.hasOwner(artifactID, sessionID)) return false;
    const slot = await this.acquire(sessionID);
    return slot.referencesDisplayArtifact(artifactID);
  }

  authorizeBrowserLiveView(sessionID: string, viewId: string, generation: string): boolean {
    if (this.deletingSessionIds.has(sessionID)) return false;
    const slot = this.slots.get(sessionID);
    return slot !== undefined && !slot.isDisposed && slot.referencesBrowserLiveView(viewId, generation);
  }

  async acquireDisplayArtifact(
    sessionID: string,
    artifactID: string,
    requestedRange?: import("./blob-store.js").BlobByteRange,
    signal?: AbortSignal,
  ) {
    return abortableRead(signal, () => this.displayArtifactLane.run(async () => {
      if (this.deletingSessionIds.has(sessionID)
        || !await this.authorizeDisplayArtifact(sessionID, artifactID)) {
        throw new GatewayError("not_found", "Display artifact is unavailable");
      }
      signal?.throwIfAborted();
      return this.displayArtifacts.acquire(artifactID, sessionID, requestedRange);
    }, signal), lease => lease.release());
  }
}
