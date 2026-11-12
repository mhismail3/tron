import type { TaskWorkerDiagnostic } from "../delegation/worker-contract.js";
import { DelegationOperations, type OwnedSessions } from "../delegation/delegation-operations.js";
import type { HomeTaskReportOwner } from "../delegation/task-report.js";
import { interruptToolCalls, ToolCallInterrupt } from "../run/bounded-tool-cancellation.js";
import type { SettingsSchema } from "../settings/settings-schema.js";
import { ORDINARY_SESSION_PROFILE } from "../host/session-profile.js";
import type { LineageRuntimePort, SessionLineagePolicy } from "../host/session-lineage.js";
import type { KernelLifecycleObserver, TaskLedgerPolicy } from "../host/kernel-lifecycle.js";
import type { ManagedSubagents } from "../delegation/managed-subagents.js";
import { createHash, randomUUID } from "node:crypto";
import { getHeapStatistics } from "node:v8";
import { realpathSync } from "node:fs";
import { lstat, open, readFile, realpath, rename, rm, stat } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { performance } from "node:perf_hooks";
import {
  type ModelRuntime,
  parseSessionEntries,
  SessionManager,
  type FileEntry,
  type SessionEntry,
} from "../pi/coding-agent.js";
import { GatewayError } from "../../errors.js";
import type {
  AdministrativeDrainBlockerCategory,
  AdministrativeDrainBlockerSummary,
  AdministrativeDrainPhase,
  AdministrativeDrainSnapshot,
  SessionArchiveFilter,
  SessionCreationOrigin,
  SessionSummary,
  SessionSummaryUpdate,
} from "../../protocol/types.js";
import { SessionAttentionStore, type SessionAttentionProjection } from "../projection/session-attention-store.js";
import { SessionArchiveStore } from "../../sessions/session-archive-store.js";
import {
  SessionPresentationPresenceRegistry,
  type SessionPresentationPresenceProjection,
} from "../projection/session-presentation-presence.js";
import { QueuedWorkGate } from "../../util/queued-work-gate.js";
import { abortableRead } from "../../util/abortable-read.js";
import { currentRequestSpan, RequestSpanLane, stage } from "../../util/request-span.js";
import type { ResourceRecorder, ResourceRuntimeEntry } from "../../util/resource-recorder.js";
import type { TrustService } from "../resources/trust-service.js";
import { BlobStore } from "../../sessions/blob-store.js";
import {
  SESSION_EXPORT_MAX_ITEM_BYTES,
  SESSION_EXPORT_MAX_ITEMS,
  SESSION_EXPORT_MAX_PRODUCTIONS,
  SESSION_EXPORT_MAX_READERS,
  SESSION_EXPORT_MINIMUM_FREE_BYTES,
  SESSION_EXPORT_MAX_TOTAL_BYTES,
} from "../../sessions/session-export.js";
import { RunMarkerStore, type RunMarkerEvidence } from "../run/run-markers.js";
import {
  RuntimeSlot,
  type SessionBroadcast,
  type RuntimeSlotDependencies,
} from "../run/runtime-slot.js";
import { completionOwnedByMarker, type CanonicalAssistantCompletion, type SessionAttentionRebindDisposition } from "../run/completion-facts.js";
import { ResourceFreshness, type ResourceFreshnessRecord } from "../run/resource-freshness.js";
import { ExtensionActivityRecency } from "../../sessions/extension-activity-recency.js";
import { ProcessActivityRecency } from "../projection/process-activity-recency.js";
import { ExtensionArtifactDiscovery, type ExtensionArtifactDiscoveryCounts } from "../../sessions/extension-artifact-discovery.js";
import type { ResourceRoot } from "../resources/resource-root.js";
import type { ModuleHost } from "../host/module-host.js";
import { GatewayWorkRegistry } from "../run/gateway-work-registry.js";
import { readCanonicalSessionFile } from "./canonical-reader.js";
import { syncDurably } from "../../foundation/durable-json.js";
import {
  invocationProjection,
  invocationReceipts,
  type InvocationProjection,
} from "../receipts/invocation-receipts.js";
import { projectTranscriptPage, type TranscriptPage } from "../projection/projection.js";
import {
  CatalogMetadataIndex,
  type CatalogMetadataIndexFailure,
  type CatalogMetadataIndexPressure,
  type CatalogMetadataIndexSummary,
} from "../../sessions/catalog-metadata-index.js";
import { branchFromParsedSession, validateSearchBranch, type SessionSearchForkBoundary } from "../../sessions/session-branch.js";
import {
  SessionCatalog,
  SUBAGENT_RUN_DIRECTORY,
  delegatedSessionParentPath,
  type SessionCatalogChange,
  type SessionCatalogIdentity,
  type SessionCatalogReconcileOutcome,
  type SessionCatalogSource,
  type SessionCatalogWatcherReset,
} from "../../sessions/session-catalog.js";
import { resolveForkBoundaryAnchor, type ForkBoundaryAnchor } from "../../sessions/fork-boundary.js";
import { modelQueueKey } from "../settings/tool-contract.js";
import {
  CatalogDiscovery,
  DEFAULT_CATALOG_DISCOVERY_LIMITS,
  buildCatalogSessionInfo,
  type CatalogDiscoveryOptions,
  type CatalogHeaderIdentity,
  type CatalogSessionInfo,
  type DelegatedSessionTopology,
} from "../../sessions/catalog-discovery.js";
import { tronHomePath } from "../../foundation/tron-home-layout.js";

const MAX_READ_ONLY_SUBAGENT_SESSION_BYTES = 64 * 1_024 * 1_024;
const CATALOG_SUMMARY_ATTEMPTS = 3;

const LIVE_RUNTIME_BYTE_BUDGET = 1_536 * 1_024 * 1_024;

export const LIVE_RUNTIME_HEAP_ESTIMATE_FACTOR = 3;

const MAXIMUM_CONCURRENT_COLD_LOADS = 2;

const HEAP_EVICTION_SHARE = 0.70;

const HEAP_REFUSAL_SHARE = 0.85;

export const HEAP_REFUSAL_RETRY_AFTER_MS = 5_000;

type RuntimeLoadReason = "open" | "create" | "automation" | "import" | "oversize";

export type RuntimeEvictionReason =
  | "idle" | "capacity" | "bytes" | "heap" | "publication-uncertain" | "closed" | "disposed" | "deleted" | "shutdown";

export type RuntimeLifecycleReason = RuntimeLoadReason | RuntimeEvictionReason;

export interface RuntimeLifecycleRecord {
  event: "runtime.loaded" | "runtime.evicted";
  sessionId: string;
  reason: RuntimeLifecycleReason;
  transcriptBytes: number;
  estimatedHeapBytes: number;
  overBudget?: true;
}

interface PublishedRuntimeBytes {
  transcriptBytes: number;
  estimatedHeapBytes: number;
}

export type ColdLoadAdmission = "open" | "import";

interface PendingColdLoad {
  operation: Promise<RuntimeSlot>;
  readonly controller: AbortController;
  waiters: number;
}

export interface CapacityShedRecord {
  reason: "heap";
  admission: ColdLoadAdmission;
  heapUsedBytes: number;
  heapLimitBytes: number;
  retryAfterMs: number;
}

interface HeapSample {
  usedBytes: number;
  limitBytes: number;
}

function estimateRuntimeHeapBytes(transcriptBytes: number): number {
  return Math.ceil(Math.max(0, transcriptBytes) * LIVE_RUNTIME_HEAP_ESTIMATE_FACTOR);
}

async function sessionFileBytes(path: string | undefined): Promise<number> {
  if (path === undefined) return 0;
  return stat(path).then((metadata) => metadata.size).catch(() => 0);
}

function assertProcessSessionRef(value: string): void {
  if (!value || Buffer.byteLength(value) > 256 || /[\\/\0]/u.test(value)) {
    throw new GatewayError("invalid_request", "Invalid subagent session reference");
  }
}

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

type ArchiveDiagnostic =
  | { outcome: "failure"; stage: "set" | "remove" | "auto-unarchive" }
  | { outcome: "auto-unarchived"; trigger: "admission" | "backstop" };

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
): Promise<import("../pi/coding-agent.js").FileEntry[] | undefined> {
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
  readonly homeTaskId?: string;
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
  readonly projectionToken: string;
  readonly listRevision: number;
  readonly count: number;
  readonly compactByteEstimate: number;
  readonly page: (offset: number, limit: number) => Promise<SessionSummary[]>;
}

interface CatalogIndexCut {
  allInfos: Array<CatalogSessionInfo & { delegated: boolean }>;
  infos: Array<CatalogSessionInfo & { delegated: boolean }>;
  ambiguousIDs: ReadonlySet<string>;
}

interface IdleEviction {
  slot: RuntimeSlot;
  committed: boolean;
  completion?: Promise<boolean>;
}

export type LiveTaskEvidence =
  | { state: "present"; entries: FileEntry[]; branch: FileEntry[] }
  | { state: "absent"; operationSettled: boolean };

export interface SessionOperations extends LineageRuntimePort<RuntimeSlot>, OwnedSessions<RuntimeSlot> {
  create(cwd: string, profile?: string, taskWorker?: HomeTaskReportOwner): Promise<RuntimeSlot>;
  readonly delegation: DelegationOperations<RuntimeSlot>;
  readonly administrativeWorkRegistry: GatewayWorkRegistry;
  readTaskEvidence(sessionId: string, options?: { appendStable?: boolean }): Promise<FileEntry[]>;
  readLiveTaskEvidence(sessionId: string, operationId: string): Promise<LiveTaskEvidence>;
  readTaskWorkerEntries(sessionId: string): Promise<FileEntry[]>;
  recordTaskWorkers(workers: Iterable<readonly [sessionId: string, taskId: string]>): void;
  taskWorkerSettled(sessionId: string, taskId: string): Promise<void>;
  taskWorkerModel(sessionId: string): Promise<{ provider: string; id: string } | undefined>;
  taskWorkerName(sessionId: string): Promise<string | undefined>;
  acquire(sessionId: string, signal?: AbortSignal): Promise<RuntimeSlot>;
  runtimeEntries(): ReadonlyArray<readonly [string, RuntimeSlot]>;
  retireIdleRuntime(input: {
    sessionId: string;
    slot: RuntimeSlot;
    reason: Extract<RuntimeEvictionReason, "idle" | "capacity" | "bytes" | "heap" | "publication-uncertain">;
    eligible: () => boolean;
  }): Promise<boolean>;
  sessionFile(sessionId: string): Promise<string | undefined>;
  sessionPresent(sessionId: string): Promise<boolean>;
  serializeSessionMutation<T>(sessionId: string, operation: () => Promise<T>): Promise<T>;
  replaceRuntimeForProfile(sessionId: string, commit: () => Promise<void>): Promise<void>;
  noteSessionListChanged(): void;
  readSearchCut: RuntimeRegistry["readSearchCut"];
  modelQueueOf(role: Parameters<typeof modelQueueKey>[0], scope?: "global" | "home"): Promise<string[]>;
}

export class RuntimeRegistry implements SessionOperations {
  readonly delegation: DelegationOperations<RuntimeSlot>;
  private readonly slots = new Map<string, RuntimeSlot>();
  private readonly automationSessionOwners = new WeakMap<RuntimeSlot, {
    operationId: string;
    automationId: string;
  }>();
  private readonly mutex = new RequestSpanLane("registry.mutex");
  private readonly sessionMutations = new Map<string, Promise<void>>();

  async serializeSessionMutation<T>(sessionId: string, operation: () => Promise<T>): Promise<T> {
    const previous = this.sessionMutations.get(sessionId) ?? Promise.resolve();
    const result = previous.then(operation, operation);
    const tail = result.then(() => {}, () => {});
    this.sessionMutations.set(sessionId, tail);
    try { return await result; }
    finally {
      if (this.sessionMutations.get(sessionId) === tail) this.sessionMutations.delete(sessionId);
    }
  }
  private readonly catalogMaterializations = new Map<"user" | "all", {
    generation: string;
    promise: Promise<Awaited<ReturnType<RuntimeRegistry["materializeCatalogSnapshot"]>>>;
  }>();
  private readonly attentionLane = new RequestSpanLane("registry.attention-lane");
  private readonly blobs: BlobStore;
  private readonly exports: BlobStore;
  private readonly workspace: ResourceRoot;
  private settingsOwners: Readonly<{ model: import("../settings/settings-model.js").SettingsModel; changes: import("../settings/settings-change.js").SettingsChangePath }> | undefined;
  private readonly homeMaterializations = new Map<string, Promise<RuntimeSlot>>();
  private searchInvalidator: ((sessionID: string, nextSessionID?: string) => void) | undefined;
  private readonly markers: RunMarkerStore;
  private readonly extensionActivityRecency = new ExtensionActivityRecency();
  private readonly processActivityRecency = new ProcessActivityRecency();
  private readonly attention: SessionAttentionStore;
  private readonly archive: SessionArchiveStore;
  private readonly presentationPresence = new SessionPresentationPresenceRegistry();
  private readonly catalogMetadataIndex: CatalogMetadataIndex;
  private readonly sessionCatalog: SessionCatalog;
  private interrupted = new Set<string>();
  private readonly subscribers = new Map<string, Set<string>>();
  private readonly idleEvictions = new Map<string, IdleEviction>();
  private readonly summaryRevisions = new Map<string, number>();
  private readonly latestSummaries = new Map<string, SessionSummaryUpdate>();
  private readonly pendingAttentionRemovals = new Set<string>();
  private readonly pendingArchiveRemovals = new Set<string>();
  private readonly pendingArchiveRestorations = new Set<string>();
  private readonly archiveRestorationAttempts = new Map<string, Promise<void>>();
  private readonly deletingSessionIds = new Set<string>();
  private readonly trustReloadProjects = new Set<string>();
  private revision = 0;
  private catalogFingerprint: string | undefined;
  private catalogUserFingerprint: string | undefined;
  private catalogAcquisitionInvalidationGeneration = 0;
  private catalogStructuralGeneration = 0;
  private catalogProjectionGeneration = 0;
  private readonly catalogPageSources = new Map<string, WeakRef<CatalogPageSource>>();
  private readonly pendingSlotStarts = new Map<string, PendingColdLoad>();
  private reservedSlotStarts = 0;
  private readonly reservedRuntimeBytes = new Map<string, number>();
  private readonly publishedRuntimeBytes = new Map<string, PublishedRuntimeBytes>();
  private readonly readHeapSample: () => HeapSample;
  private evictionTimer?: NodeJS.Timeout;
  private artifactDiscoveryTimer?: NodeJS.Timeout;
  private readonly artifactDiscovery: ExtensionArtifactDiscovery;
  private artifactDiscoveryInFlight: Promise<void> | undefined;
  private slotAdmissionsInFlight = 0;
  readonly freshness: ResourceFreshness;
  private readonly slotAdmissionIdleWaiters: Array<() => void> = [];
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

  constructor(
    private readonly options: {
      agentDir: string;
      tronHome: string;
      modules: ModuleHost;
      delegatedArtifactRoot?: string;
      managedSubagents?: ManagedSubagents;
      mcpAuth?: RuntimeSlotDependencies["mcpAuth"];
      idleRuntimeMs: number;
      maximumLiveRuntimes?: number;
      createModelRuntime: () => Promise<ModelRuntime>;
      trust: TrustService;
      broadcast: SessionBroadcast;
      sessionSummaryChanged: (summary: SessionSummaryUpdate) => void;
      sessionListChanged: () => void;
      sessionRekeyed?: (previousId: string, nextId: string) => void;
      beforeSessionRekey?: (previousId: string, nextId: string, runtime: RuntimeSlot) => Promise<void>;
      beforeSessionDelete?: (sessionId: string) => Promise<void>;
      sessionClosed?: (sessionId: string) => void;
      persistenceDiagnostic?: (sessionId: string, code: string) => void;
      runtimeLifecycleRecord?: (record: RuntimeLifecycleRecord) => void;
      capacityShedRecord?: (record: CapacityShedRecord) => void;
      heapSample?: () => HeapSample;
      archiveDiagnostic?: (diagnostic: ArchiveDiagnostic) => void;
      sessionAutomationReserved?: (sessionId: string) => boolean;
      compactionDiagnostic?: RuntimeSlotDependencies["compactionDiagnostic"];
      stopSteeringDiagnostic?: RuntimeSlotDependencies["stopSteeringDiagnostic"];
      manualCompactionAdopted?: RuntimeSlotDependencies["manualCompactionAdopted"];
      requestRecord?: RuntimeSlotDependencies["requestRecord"];
      resourceFreshnessDiagnostic?: (record: ResourceFreshnessRecord) => void;
      capabilityDiagnostic?: RuntimeSlotDependencies["capabilityDiagnostic"];
      codemodeDiagnostic?: RuntimeSlotDependencies["codemodeDiagnostic"];
      catalogDiscoveryLimits?: Partial<typeof DEFAULT_CATALOG_DISCOVERY_LIMITS>;
      catalogIndexFailure?: CatalogMetadataIndexFailure;
      catalogIndexPressure?: (pressure: CatalogMetadataIndexPressure) => void;
      catalogReconciled?: (reconciled: SessionCatalogReconcileOutcome) => void;
      catalogChanged?: (change: SessionCatalogChange) => void;
      catalogWatcherReset?: (reset: SessionCatalogWatcherReset) => void;
      runtimeDisposeTimeout?: (graceMs: number) => void;
      resources?: ResourceRecorder;
      machineId?: string;
      readonly settingsSchema: SettingsSchema;
      workRegistry?: GatewayWorkRegistry;
      artifactDiscoveryTruncated?: (counts: ExtensionArtifactDiscoveryCounts) => void;
      extensionArtifactWarning?: (warning: { reason: import("../projection/extension-run-projection.js").ExtensionArtifactRejectionReason; owner: string }) => void;
      gatewayModelRuntime?: ModelRuntime;
      homeTaskDiagnostic?: (record: TaskWorkerDiagnostic) => void;
    },
  ) {
    this.freshness = new ResourceFreshness({ agentDir: options.agentDir, diagnostic: options.resourceFreshnessDiagnostic });
    this.delegation = new DelegationOperations(this,
      (slot, by, before) => interruptToolCalls(slot.runtime.session, new ToolCallInterrupt(by), before), options);
    this.artifactDiscovery = new ExtensionArtifactDiscovery(this.slots, options);
    this.blobs = new BlobStore(undefined, Date.now, tronHomePath(options.tronHome, "state/blobs"));
    const workspace = options.modules.policy("resourceRoot")?.();
    if (!workspace) throw new Error("Kernel resource root is not installed");
    this.workspace = workspace;
    this.exports = new BlobStore({
      maximumItemBytes: SESSION_EXPORT_MAX_ITEM_BYTES,
      maximumItems: SESSION_EXPORT_MAX_ITEMS,
      maximumTotalBytes: SESSION_EXPORT_MAX_TOTAL_BYTES,
      maximumReaders: SESSION_EXPORT_MAX_READERS,
      maximumFileProductions: SESSION_EXPORT_MAX_PRODUCTIONS,
      minimumFreeBytes: SESSION_EXPORT_MINIMUM_FREE_BYTES,
    }, Date.now, tronHomePath(options.tronHome, "state/exports"));
    this.markers = new RunMarkerStore(options.tronHome);
    this.attention = new SessionAttentionStore(options.tronHome);
    this.archive = new SessionArchiveStore(options.tronHome);
    this.catalogMetadataIndex = new CatalogMetadataIndex(tronHomePath(options.tronHome, "cache"), options.catalogIndexFailure, options.catalogIndexPressure);
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
    for (const [name, value] of Object.entries(this.catalogDiscoveryLimits())) {
      if (!Number.isSafeInteger(value) || value < 1) throw new Error(`Invalid session catalog ${name} bound`);
    }
  }

  get listRevision(): number {
    return this.revision;
  }

  get moduleHost(): ModuleHost { return this.options.modules; }

  noteSessionListChanged(): void {
    this.revision += 1;
    this.options.sessionListChanged();
  }

  setSearchInvalidator(invalidator: (sessionID: string, nextSessionID?: string) => void): void {
    this.searchInvalidator = invalidator;
  }

  setSettings(model: import("../settings/settings-model.js").SettingsModel, changes: import("../settings/settings-change.js").SettingsChangePath): void {
    if (this.settingsOwners && this.settingsOwners.changes !== changes) throw new Error("Settings are already installed");
    this.settingsOwners = { model, changes };
  }

  get administrativeWorkRegistry(): GatewayWorkRegistry { return this.workRegistry; }

  isLineageMember(sessionId: string): boolean { return this.lineage().state(sessionId).lineageId !== undefined; }

  async materializeRuntime(sessionId: string, construct: () => Promise<RuntimeSlot>): Promise<{ slot: RuntimeSlot; existing: boolean }> {
    let existingSlot: RuntimeSlot | undefined;
    let selected!: Promise<RuntimeSlot>;
    await this.mutex.run(() => {
      existingSlot = this.slots.get(sessionId);
      if (existingSlot) return;
      const existing = this.homeMaterializations.get(sessionId);
      if (existing) selected = existing;
      else {
        selected = Promise.resolve().then(construct);
        this.homeMaterializations.set(sessionId, selected);
      }
    });
    if (existingSlot) return { slot: existingSlot, existing: true };
    try {
      return { slot: await selected, existing: false };
    } finally {
      await this.mutex.run(() => {
        if (this.homeMaterializations.get(sessionId) === selected) this.homeMaterializations.delete(sessionId);
      });
    }
  }

  async canonicalEntries(sessionId: string): Promise<{ entries: readonly FileEntry[] | null; live: boolean }> {
    const live = this.slots.get(sessionId);
    if (live !== undefined && !live.isDisposed) return { entries: live.canonicalSessionEntries(), live: true };
    return { entries: await this.canonicalSessionEvidenceCut(sessionId), live: false };
  }

  async createRuntimeOver(sessionId: string, build: Parameters<LineageRuntimePort<RuntimeSlot>["createRuntimeOver"]>[1]): Promise<RuntimeSlot> {
    return this.startRuntime<RuntimeSlot>({
      reason: "create", failed: build.failed, manager: build.prepare, admitted: build.admitted, published: build.published,
      create: manager => {
        const authority = build.authority();
        return RuntimeSlot.create(manager, this.dependencies(), this.hooks(), false, this.options.modules.profile(build.profile), authority);
      },
      publish: () => { if (this.slots.has(sessionId)) throw new GatewayError("conflict", "Reserved Home chapter runtime is already active"); },
    });
  }

  private async startRuntime<R = RuntimeSlot>(start: {
    reason: "create" | "automation";
    admit?(): Promise<void>;
    evictFor?: string;
    reserve?: () => R | undefined;
    manager(): SessionManager | Promise<SessionManager>;
    create(manager: SessionManager): Promise<RuntimeSlot>;
    admitted?(slot: RuntimeSlot): void;
    publish(slot: RuntimeSlot, manager: SessionManager): R | void;
    published?(slot: RuntimeSlot): Promise<void>;
    failed?(): void;
  }): Promise<R> {
    const finishAdmission = this.beginSlotAdmission();
    let reserved = false;
    let slot: RuntimeSlot | undefined;
    try {
      await start.admit?.();
      await this.evictIdle(true, start.evictFor);
      const existing = await this.mutex.run(() => {
        this.assertSlotAdmissionOpen();
        const owner = start.reserve?.();
        if (owner !== undefined) return owner;
        this.requireLiveSlotCapacity();
        this.reservedSlotStarts += 1;
        reserved = true;
        return undefined;
      });
      if (existing !== undefined) return existing;
      const manager = await start.manager();
      slot = await start.create(manager);
      await this.freshness.attach(slot);
      start.admitted?.(slot);
      const transcriptBytes = await sessionFileBytes(slot.sessionFile);
      const result = await this.mutex.run(() => {
        const result = start.publish(slot!, manager) ?? slot as R;
        this.reservedSlotStarts = Math.max(0, this.reservedSlotStarts - 1);
        reserved = false;
        this.publishRuntime(manager.getSessionId(), slot!, transcriptBytes, start.reason);
        this.invalidateCatalogAdmission();
        void this.sessionCatalog.refresh(slot!.persistedSessionFile);
        this.revision += 1;
        this.options.sessionListChanged();
        return result;
      });
      await start.published?.(slot);
      return result;
    } catch (error) {
      start.failed?.();
      if (slot && this.slots.get(slot.id) !== slot) { this.freshness.detach(slot); await slot.dispose().catch(() => {}); }
      throw error;
    } finally {
      if (reserved) {
        await this.mutex.run(() => { this.reservedSlotStarts = Math.max(0, this.reservedSlotStarts - 1); });
      }
      finishAdmission();
    }
  }

  async replaceRuntimeForProfile(sessionId: string, commit: () => Promise<void>): Promise<void> {
    const selected = await this.mutex.run(async () => {
      const flight = this.homeMaterializations.get(sessionId) ?? this.pendingSlotStarts.get(sessionId)?.operation;
      if (flight) return { flight };
      const slot = this.slots.get(sessionId);
      if (slot && !slot.isDisposed) return { slot };
      await commit();
      return {};
    });
    if (selected.flight) {
      await selected.flight.catch(() => {});
      await this.replaceRuntimeForProfile(sessionId, commit);
    } else if (selected.slot) {
      await selected.slot.replaceRuntimeForProfile(commit);
    }
  }

  get isAdministrativeDrainStarted(): boolean { return this.drainPhase !== "idle"; }

  async initialize(onPhase?: (phase: "catalog-warming" | "attention-recovery") => void): Promise<void> {
    for (const lifecycle of this.lifecycles()) await lifecycle.initialize();
    await this.workspace.initialize();
    await this.attention.initialize();
    await this.archive.initialize();
    this.sessionCatalog.start();
    this.freshness.start();
    for (const lifecycle of this.lifecycles()) lifecycle.started();
    const markerEvidence = await this.markers.evidence();
    this.interrupted = await this.markers.interruptedSessionIds();
    for (const [sessionId, markers] of markerEvidence) {
      if (markers.every((marker) => marker.assistantCompletionId !== undefined && !marker.operationId.startsWith("automation:"))) {
        this.interrupted.delete(sessionId);
      }
    }
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
    await this.sessionCatalog.whenReconciled();
    this.pendingStartupPhaseObserver?.("attention-recovery");
    this.pendingStartupPhaseObserver = undefined;
    await this.reconcileCanonicalAttention(markerEvidence);
    const recovered = await this.markers.interruptedSessionIds();
    const changed = recovered.size !== this.interrupted.size || [...recovered].some((id) => !this.interrupted.has(id));
    this.interrupted = recovered;
    if (changed) {
      this.catalogProjectionGeneration += 1;
      this.options.sessionListChanged();
    }
  }

  async initializeBlobStorage(): Promise<void> {
    await Promise.all([
      this.blobs.initialize(),
      this.exports.initialize(),
      this.options.modules.policy("toolResultProjection")?.().initializeStorage(),
    ]);
    await Promise.all([...this.slots.values()].map((slot) => slot.reconcileToolResultOwnership()));
  }

  private async reconcileCanonicalAttention(
    markerEvidence: ReadonlyMap<string, readonly RunMarkerEvidence[]>,
  ): Promise<void> {
    const scanBoundary = new Date().toISOString();
    if (!this.sessionCatalog.hasReconciledCut()) return;
    const byID = new Map<string, Array<{ path: string }>>();
    for (const row of this.sessionCatalog.rows()) {
      const candidates = byID.get(row.id) ?? [];
      candidates.push({ path: row.path });
      byID.set(row.id, candidates);
    }
    const retainedSessionIds = new Set(byID.keys());
    for (const sessionId of this.slots.keys()) retainedSessionIds.add(sessionId);
    await this.attention.prune(retainedSessionIds);
    await this.attentionLane.run(async () => {
      const archiveRetained = new Set(retainedSessionIds);
      for (const sessionId of this.slots.keys()) archiveRetained.add(sessionId);
      const pruned = await this.archive.prune(archiveRetained);
      if (pruned.length > 0) this.archiveChanged(pruned);
    });
    for (const [sessionId, markers] of markerEvidence) {
      const candidates = byID.get(sessionId);
      if (!candidates || candidates.length !== 1) continue;
      const path = candidates[0]!.path;
      let manager: SessionManager;
      try {
        const openRefusal = await this.lineage().openRefusal(sessionId, path);
        if (openRefusal) throw openRefusal;
        manager = SessionManager.open(path);
      }
      catch { continue; }
      for (const marker of markers) {
        const completion = completionOwnedByMarker(manager, marker);
        if (!completion) continue;
        await this.attention.complete(sessionId, completion.id);
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
        if (this.pendingArchiveRestorations.has(summary.sessionId) || sessionShowsWork(summary)) {
          this.restoreArchivedSession(summary.sessionId);
        }
        this.publishRevisionedSummary({ ...summary, ...this.attention.projection(summary.sessionId) });
        void this.sessionCatalog.refresh(this.slots.get(summary.sessionId)?.persistedSessionFile);
      },
      changed: (sessionId: string) => {
        this.invalidateCatalogAcquisition();
        void this.sessionCatalog.refresh(this.slots.get(sessionId)?.persistedSessionFile);
        this.revision += 1;
        this.options.sessionListChanged();
      },
      settled: (sessionId: string) => { this.interrupted.delete(sessionId); },
      idle: (slot: RuntimeSlot) => this.freshness.idle(slot),
      assistantResponseCompleted: async (
        sessionId: string,
        completion: CanonicalAssistantCompletion,
        recovery: boolean,
        observed: boolean,
      ) => this.attentionLane.run(async () => {
        const read = (!recovery && observed) || this.delegation.hasWorkerAttribution(sessionId);
        const result = await this.attention.complete(sessionId, completion.id, read);
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
        this.presentationPresence.removeSession(sessionId);
        this.interrupted.delete(sessionId);
        if (removedLiveOnlySession) {
          this.summaryRevisions.delete(sessionId);
          this.latestSummaries.delete(sessionId);
          this.invalidateCatalogAdmission();
          this.revision += 1;
          this.options.sessionListChanged();
        } else if (removed && persistedPath !== undefined && !persistedPathWasIndexed) {
          this.invalidateCatalogAcquisition();
          void this.sessionCatalog.refresh(persistedPath);
        }
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
        if (previousId !== nextId && disposition !== "preserve") {
          await this.attention.assertAbsent(nextId);
          await this.archive.assertAbsent(nextId);
        }
        if (disposition === "migrate") {
          await this.attention.rekey(previousId, nextId);
          await this.archive.rekey(previousId, nextId);
          await this.options.modules.policy("sessionNotifications")?.()?.rekeySession(previousId, nextId);
        } else if (disposition === "discard") {
          await this.attention.remove(previousId);
          await this.archive.remove(previousId);
        }
        this.pendingArchiveRestorations.delete(previousId);
        this.pendingArchiveRestorations.delete(nextId);
        await this.options.beforeSessionRekey?.(previousId, nextId, slot);
        const previousCatalogPath = slot.persistedSessionFile;
        commitIdentity();
        if (this.slots.get(previousId) === slot) this.slots.delete(previousId);
        this.slots.set(nextId, slot);
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

  private async flushPendingProjectionRemovals(): Promise<void> {
    for (const sessionId of [...this.pendingAttentionRemovals]) {
      try {
        await this.attention.remove(sessionId);
        this.pendingAttentionRemovals.delete(sessionId);
      } catch {
      }
    }
    for (const sessionId of [...this.pendingArchiveRemovals]) {
      try {
        if (await this.archive.remove(sessionId)) this.archiveChanged([sessionId]);
        this.pendingArchiveRemovals.delete(sessionId);
        this.pendingArchiveRestorations.delete(sessionId);
      } catch {
      }
    }
  }

  private archiveChanged(sessionIds: readonly string[] = []): void {
    this.revision += 1;
    this.options.sessionListChanged();
    for (const sessionId of sessionIds) this.slots.get(sessionId)?.refreshArchiveProjection();
  }

  private archivePersistFailed(stage: "set" | "remove" | "auto-unarchive"): void {
    this.options.archiveDiagnostic?.({ outcome: "failure", stage });
  }

  private archivedAt(sessionId: string): string | undefined {
    if (this.pendingArchiveRestorations.has(sessionId) || this.pendingArchiveRemovals.has(sessionId)) return undefined;
    return this.archive.archivedAt(sessionId);
  }

  private async beforeRunAdmission(sessionId: string): Promise<void> {
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

  private restoreArchivedSession(sessionId: string): void {
    if (!this.pendingArchiveRestorations.has(sessionId) && this.archive.archivedAt(sessionId) === undefined) return;
    const wasPending = this.pendingArchiveRestorations.has(sessionId);
    this.pendingArchiveRestorations.add(sessionId);
    if (!wasPending) {
      this.revision += 1;
      this.options.sessionListChanged();
      const slot = this.slots.get(sessionId);
      if (slot) queueMicrotask(() => slot.refreshArchiveProjection());
    }
    if (this.archiveRestorationAttempts.has(sessionId)) return;
    const attempt = this.clearArchivedRecord(sessionId).finally(() => {
      if (this.archiveRestorationAttempts.get(sessionId) === attempt) this.archiveRestorationAttempts.delete(sessionId);
    });
    this.archiveRestorationAttempts.set(sessionId, attempt);
  }

  private async clearArchivedRecord(sessionId: string): Promise<void> {
    try {
      const removed = await this.attentionLane.run(async () => {
        await this.flushPendingProjectionRemovals();
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
      this.archivePersistFailed("auto-unarchive");
    }
  }

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

  private assertArchiveIdle(sessionId: string, slot: RuntimeSlot | undefined): void {
    if (sessionShowsWork(this.dashboardProjection(sessionId, slot))) {
      throw new GatewayError("busy", "Stop the session before archiving it", false, undefined, "session_operation_busy");
    }
  }

  private restoreArchivedSessionIfWorking(sessionId: string, slot: RuntimeSlot | undefined): void {
    if (!slot || !sessionShowsWork(this.dashboardProjection(sessionId, slot))) return;
    this.restoreArchivedSession(sessionId);
  }

  private async publishAttentionSummary(
    sessionId: string,
    projection: SessionAttentionProjection = this.attention.projection(sessionId),
  ): Promise<void> {
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
    const persistedSlot = this.slots.get(sessionId);
    if (persistedSlot && !persistedSlot.isDisposed && persistedSlot.persistedSessionFile !== undefined
      && !this.indexAmbiguousSessionIds().has(sessionId)) {
      return { generation: this.catalogAcquisitionInvalidationGeneration, persistedSlot };
    }
    const { acquisition, entry } = await stage("attention.resolve", () => this.catalogMembership(sessionId));
    this.requireUnambiguousSessionId(sessionId, acquisition.ambiguousIDs);
    if (entry) return { generation: this.catalogAcquisitionInvalidationGeneration, entry };
    const liveOnlySlot = this.slots.get(sessionId);
    if (liveOnlySlot && !liveOnlySlot.isDisposed && liveOnlySlot.persistedSessionFile === undefined) {
      return { generation: this.catalogAcquisitionInvalidationGeneration, liveOnlySlot };
    }
    throw new GatewayError("not_found", "Tron session was not found");
  }

  private lifecycles(): KernelLifecycleObserver[] {
    return this.options.modules.observers("kernelLifecycle").map(hook => hook());
  }

  private taskLedger(): TaskLedgerPolicy {
    const hook = this.options.modules.policy("taskLedger");
    if (!hook) throw new Error("No task ledger owner is composed");
    return hook();
  }

  private lineage(): SessionLineagePolicy {
    const hook = this.options.modules.policy("sessionLineage");
    if (!hook) throw new Error("No session lineage owner is composed");
    return hook();
  }

  private assertChapterWritable(sessionId: string): void {
    this.lineage().assertWritable(sessionId);
  }

  async setAttention(sessionId: string, unread: boolean, throughCompletionRevision?: number): Promise<SessionAttentionProjection> {
    return this.serializeSessionMutation(sessionId, () => this.setAttentionSerialized(sessionId, unread, throughCompletionRevision));
  }

  private async setAttentionSerialized(sessionId: string, unread: boolean, throughCompletionRevision?: number): Promise<SessionAttentionProjection> {
    this.assertChapterWritable(sessionId);
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
          if (currentLiveOnly !== admission.persistedSlot || currentLiveOnly.isDisposed
            || currentLiveOnly.persistedSessionFile === undefined
            || current.ambiguousIDs.has(sessionId)) return undefined;
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
          const latest = this.latestSummaries.get(sessionId);
          if (latest) this.publishRevisionedSummary({ ...latest, sessionId, ...result.projection });
          else {
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
      createModelRuntime: this.options.createModelRuntime,
      trust: this.options.trust,
      blobs: this.blobs,
      exports: this.exports,
      settingsSchema: this.options.settingsSchema,
      workspace: this.workspace,
      markers: this.markers,
      extensionActivityRecency: this.extensionActivityRecency,
      processActivityRecency: this.processActivityRecency,
      workRegistry: this.workRegistry,
      ...(this.options.persistenceDiagnostic ? { persistenceDiagnostic: this.options.persistenceDiagnostic } : {}),
      ...(this.options.compactionDiagnostic ? { compactionDiagnostic: this.options.compactionDiagnostic } : {}),
      ...(this.options.stopSteeringDiagnostic ? { stopSteeringDiagnostic: this.options.stopSteeringDiagnostic } : {}),
      ...(this.options.manualCompactionAdopted ? { manualCompactionAdopted: this.options.manualCompactionAdopted } : {}),
      ...(this.options.requestRecord ? { requestRecord: this.options.requestRecord } : {}),
      ...(this.options.capabilityDiagnostic ? { capabilityDiagnostic: this.options.capabilityDiagnostic } : {}),
      ...(this.options.codemodeDiagnostic ? { codemodeDiagnostic: this.options.codemodeDiagnostic } : {}),
      isSessionPresented: (sessionId: string) => this.isSessionPresented(sessionId),
      sessionAudience: (sessionId: string) => this.subscribers.get(sessionId)?.size ?? 0,
      ...(this.options.resources ? { resources: this.options.resources } : {}),
      beforeRunAdmission: (sessionId: string) => this.beforeRunAdmission(sessionId),
      archivedAt: (sessionId: string) => this.archivedAt(sessionId),
      ...(this.options.machineId ? { machineId: this.options.machineId } : {}),
      ...(this.options.extensionArtifactWarning ? { extensionArtifactWarning: this.options.extensionArtifactWarning } : {}),
      modules: this.options.modules,
      settings: () => this.settingsOwners,
      sessionLineage: () => this.lineage(),
      homeTaskSettings: async (sessionId: string, taskId: string, purpose: "resolve" | "change") => {
        const target = await this.taskLedger().settingsTarget(sessionId, taskId, purpose);
        return { ...target, slot: await this.acquire(target.sessionId) };
      },
      validateTaskMarker: (sessionId: string, marker: unknown) => this.taskLedger().validateMarker(sessionId, marker),
      ...(this.options.homeTaskDiagnostic ? { homeTaskDiagnostic: this.options.homeTaskDiagnostic } : {}),
      resolveForkBoundary: (manager: SessionManager) => this.resolveForkBoundary(manager),
      ...(this.options.runtimeDisposeTimeout ? { runtimeDisposalTimedOut: this.options.runtimeDisposeTimeout } : {}),
    };
  }

  sessionDirectory(cwd: string): string {
    const safePath = `--${resolve(cwd).replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`;
    return join(this.options.agentDir, "sessions", safePath);
  }

  private catalogDirectory(): string {
    return join(this.options.agentDir, "sessions");
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

  private catalogIndex(scope: "user" | "all"): CatalogIndexCut {
    const rows = this.sessionCatalog.rows();
    const scoped = scope === "user" ? rows.filter((row) => !row.delegated) : rows;
    const allInfos: Array<CatalogSessionInfo & { delegated: boolean }> = scoped.map((row) => ({
      id: row.id,
      delegated: row.delegated,
      path: row.path,
      cwd: row.cwd,
      ...(row.parentSessionPath ? { parentSessionPath: row.parentSessionPath } : {}),
      ...(this.lineage().state(row.id).lineageId ? { name: "Home" } : row.name ? { name: row.name } : {}),
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

  private indexAmbiguousSessionIds(): Set<string> {
    const ambiguous = new Set(this.sessionCatalog.duplicateSessionIds());
    const indexedIDs = new Set(this.sessionCatalog.rows().map((row) => row.id));
    for (const [id, slot] of this.slots) {
      if (!slot.isDisposed && slot.persistedSessionFile === undefined && indexedIDs.has(id)) {
        ambiguous.add(id);
      }
    }
    return ambiguous;
  }

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

  async sessionIDsForStorageMaintenance(): Promise<ReadonlySet<string>> {
    this.requireCompleteCatalogCut();
    const ids = new Set(this.sessionCatalog.rows().map((row) => row.id));
    for (const slot of this.slots.values()) if (!slot.isDisposed) ids.add(slot.id);
    return ids;
  }

  private async awaitFirstCatalogCut(): Promise<void> {
    if (!this.sessionCatalog.hasCompleteCut()) {
      await Promise.race([this.sessionCatalog.whenPublished(), this.sessionCatalog.whenReconciled()]);
    }
    this.requireCatalogCut();
  }

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
    await this.awaitFirstCatalogCut();
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

  async acquireOwnedSessionLease(sessionId: string): Promise<{ slot: RuntimeSlot; release: () => void }> {
    const slot = await this.acquire(sessionId);
    return this.mutex.run(() => {
      if (this.deletingSessionIds.has(sessionId) || this.slots.get(sessionId) !== slot
        || slot.persistedSessionFile === undefined) {
        throw new GatewayError("busy", "Automation target is being removed or is not yet persisted", true);
      }
      return { slot, release: slot.retainLease() };
    });
  }

  async ownedOperationRecoveryEvidence(sessionId: string, operationId: string): Promise<{
    marker?: RunMarkerEvidence;
    invocation?: InvocationProjection;
  }> {
    await this.awaitFirstCatalogCut();
    const { acquisition, entry } = await this.catalogMembership(sessionId);
    this.requireUnambiguousSessionId(sessionId, acquisition.ambiguousIDs);
    if (!entry || entry.structuralSubagent) return {};
    let manager: SessionManager;
    try {
      const openRefusal = await this.lineage().openRefusal(sessionId, entry.path);
      if (openRefusal) throw openRefusal;
      manager = SessionManager.open(entry.path, this.sessionDirectory(entry.canonicalCwd));
    }
    catch { return {}; }
    const marker = (await this.markers.evidenceFor(sessionId)).find((candidate) => candidate.operationId === operationId);
    const invocation = invocationProjection(invocationReceipts(manager.getBranch(), sessionId))
      .find((candidate) => candidate.operationId === operationId);
    return {
      ...(marker === undefined ? {} : { marker }),
      ...(invocation === undefined ? {} : { invocation }),
    };
  }

  async clearOwnedOperationMarker(sessionId: string, operationId: string): Promise<void> {
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

  private noteRecoveredMarkerCleared(sessionId: string): void {
    if (!this.interrupted.delete(sessionId)) return;
    this.catalogProjectionGeneration += 1;
    this.options.sessionListChanged();
  }

  private async catalogStructureEvidence(): Promise<import("../../sessions/catalog-discovery.js").CatalogStructureEvidence> {
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

  private sessionCatalogSource(): SessionCatalogSource {
    return {
      scan: async () => {
        const evidence = await this.catalogStructureEvidence();
        return {
          catalogRoot: evidence.catalogRoot,
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
    for (let attempt = 0; attempt < CATALOG_SUMMARY_ATTEMPTS; attempt += 1) {
      const before = await lstat(path).catch(() => undefined);
      if (!before?.isFile() || before.isSymbolicLink()) return undefined;
      const info = await buildCatalogSessionInfo(path, yieldToLoop, this.options.catalogIndexFailure);
      const after = await lstat(path).catch(() => undefined);
      if (!info || !after?.isFile() || after.isSymbolicLink()) return undefined;
      if (after.size !== before.size || after.mtimeMs !== before.mtimeMs) continue;
      return {
        id: info.id, path: info.path, cwd: info.cwd,
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

  private async attentionLiveOnlyStillAdmitted(sessionId: string): Promise<boolean> {
    return !this.sessionCatalog.rows().some((row) => row.id === sessionId);
  }

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
    const materialized = await this.sharedCatalogMaterialization(scope);
    const projectionGeneration = this.catalogProjectionGeneration;
    const generation = `${materialized.listRevision}:${materialized.factsDigest}:${projectionGeneration}:${scope}:${archived}:${this.archive.revision}`;
    const existing = this.catalogPageSources.get(generation)?.deref();
    if (existing) return existing;
    const seeds = this.buildCatalogPageSeeds(materialized.infos, scope, materialized.ambiguousIDs)
      .filter((seed) => scope !== "user" || this.lineage().state(seed.id).lineageId === undefined);
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

  isArchived(sessionId: string): boolean {
    return this.archivedAt(sessionId) !== undefined;
  }

  searchCatalogIdentities(): Promise<ReadonlyMap<string, SessionCatalogIdentity> | undefined> {
    return this.sessionCatalog.searchIdentities();
  }

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
    const entries = parseStrictSessionJSONL(bytes);
    const openRefusal = await this.lineage().openRefusal(sessionId, info.path);
    if (openRefusal) throw openRefusal;
    const coldManager = SessionManager.open(info.path);
    const selectedEntries = coldManager.getBranch();
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
      } catch { }
    }
    return { summary: info, entries: selectedFile, ...(info.fileIdentity ? { fileIdentity: info.fileIdentity } : {}), ...(forkBoundary ? { forkBoundary } : {}), ...(selectedLeafId ? { leafEntryId: selectedLeafId } : {}) };
  }

  async catalog(scope: "user" | "all" = "user"): Promise<{
    sessions: SessionSummary[];
    listRevision: number;
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
      try { await active.promise; } catch { }
      return this.sharedCatalogMaterialization(scope);
    }
    const user = scope === "all" ? this.catalogMaterializations.get("user") : undefined;
    if (user) {
      try { await user.promise; } catch { }
      return this.sharedCatalogMaterialization(scope);
    }
    const operation = this.materializeCatalogSnapshot(scope);
    this.catalogMaterializations.set(scope, { generation, promise: operation });
    void operation.finally(() => {
      if (this.catalogMaterializations.get(scope)?.promise === operation) this.catalogMaterializations.delete(scope);
    }).catch(() => {});
    return operation;
  }

  private async materializeCatalogSnapshot(scope: "user" | "all"): Promise<{
    infos: CatalogSessionInfo[];
    ambiguousIDs: ReadonlySet<string>;
    listRevision: number;
    factsDigest: string;
  }> {
    this.requireCatalogCut();
    const cut = this.catalogIndex(scope);
    this.updateCatalogIdentity(cut.allInfos, scope);
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
  }

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
      delegated: boolean;
    }>,
    ambiguousIDs: ReadonlySet<string>,
  ): Promise<CatalogAcquisitionResolution> {
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
    const sessionIDByPath = new Map(unambiguousSessions.map((session) => [resolve(session.path), session.id]));
    const entriesByID = new Map<string, CatalogAcquisitionEntry>();
    let retainedBytes = 0;
    for (const session of unambiguousSessions) {
      const sessionPath = resolve(session.path);
      const parentSessionId = session.parentSessionPath
        ? sessionIDByPath.get(resolve(session.parentSessionPath))
        : undefined;
      const entry: CatalogAcquisitionEntry = {
        id: session.id,
        path: sessionPath,
        cwd: session.cwd,
        canonicalCwd: resolve(session.cwd || process.cwd()),
        ...(session.fileIdentity ? { fileIdentity: session.fileIdentity } : {}),
        structuralSubagent: session.delegated,
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

  private async catalogAcquisition(): Promise<CatalogAcquisitionResolution> {
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
        ...(this.delegation.hasWorkerAttribution(session.id) ? { homeTaskId: this.delegation.workerTaskId(session.id)! } : {}),
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
          ...(this.delegation.hasWorkerAttribution(id) ? { homeTaskId: this.delegation.workerTaskId(id)! } : {}),
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
      + (seed.homeTaskId ? Buffer.byteLength(seed.homeTaskId) : 0)
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
        ...(seed.homeTaskId ? { homeTaskId: seed.homeTaskId } : {}),
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
      const { projectDir } = await this.options.trust.inspect(cwdInput);
      return this.trustReloadProjects.has(projectDir);
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
    let trust!: { cwd: string; projectDir: string };
    return this.startRuntime({
      reason: "automation", evictFor: sessionId,
      admit: async () => { trust = await stage("automation.session.trust", () => this.options.trust.requireResolved(cwdInput)); },
      reserve: () => {
        if (this.trustReloadProjects.has(trust.projectDir)) {
          throw new GatewayError("busy", "Project trust is being reconfigured", true);
        }
        const current = this.slots.get(sessionId);
        if (!current) return undefined;
        const owner = this.automationSessionOwners.get(current);
        if (current.isDisposed || current.cwd !== trust.cwd
          || owner?.operationId !== operationId || owner.automationId !== automationId) {
          throw new GatewayError("conflict", "Automation execution session identity is already owned");
        }
        return { slot: current, release: current.retainLease() };
      },
      manager: () => SessionManager.create(trust.cwd, this.sessionDirectory(trust.cwd), { id: sessionId }),
      create: manager => stage("automation.session.runtime", () => RuntimeSlot.create(manager, this.dependencies(), this.hooks(), false)),
      publish: slot => {
        this.assertSlotAdmissionOpen();
        if (this.trustReloadProjects.has(trust.projectDir)) {
          throw new GatewayError("busy", "Automation session was retired before publication", true);
        }
        if (this.slots.has(sessionId)) {
          throw new GatewayError("conflict", "Automation execution session identity is already owned");
        }
        const release = slot.retainLease();
        this.automationSessionOwners.set(slot, { operationId, automationId });
        return { slot, release };
      },
    });
  }

  async modelQueueOf(role: Parameters<typeof modelQueueKey>[0], scope: "global" | "home" = "global"): Promise<string[]> {
    const settings = this.settingsOwners?.model;
    if (!settings) return [];
    const keys = role === "background" ? [modelQueueKey("background"), modelQueueKey("subagent")] : [modelQueueKey(role)];
    const resolution = await settings.resolve({ kind: scope }, undefined, keys, { storeState: false });
    const value = (key: string) => (resolution.keys.find(row => row.key === key)?.value as string[] | undefined) ?? [];
    const own = value(keys[0]!);
    return own.length > 0 || role !== "background" ? own : value(keys[1]!);
  }

  async create(cwdInput: string, profile: string = ORDINARY_SESSION_PROFILE.name, taskWorker?: import("../delegation/task-report.js").HomeTaskReportOwner): Promise<RuntimeSlot> {
    let trust!: { cwd: string; projectDir: string };
    return this.startRuntime<RuntimeSlot>({
      reason: "create",
      admit: async () => { trust = await stage("session.create.trust", () => this.options.trust.requireResolved(cwdInput)); },
      reserve: () => {
        if (this.trustReloadProjects.has(trust.projectDir)) {
          throw new GatewayError("busy", "Project trust is being reconfigured", true);
        }
        return undefined;
      },
      manager: () => SessionManager.create(trust.cwd, this.sessionDirectory(trust.cwd)),
      create: manager => stage("session.create.runtime",
        () => RuntimeSlot.create(manager, this.dependencies(), this.hooks(), false, this.options.modules.profile(profile), undefined, taskWorker)),
      publish: (_slot, manager) => {
        if (this.trustReloadProjects.has(trust.projectDir)) {
          throw new GatewayError("busy", "Session creation was retired before publication", true);
        }
        if (this.slots.has(manager.getSessionId())) {
          throw new GatewayError("conflict", "Replacement session is already active");
        }
      },
    });
  }

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
        page = projectTranscriptPage((...args) => this.options.modules.policy("toolResultProjection")?.().display(...args),
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
    const root = await realpath(this.catalogDirectory()).catch(() => resolve(this.catalogDirectory()));
    if (canonical !== root && !canonical.startsWith(root + sep)) return undefined;
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

  retainLiveSession(sessionId: string): (() => void) | undefined {
    this.assertSlotAdmissionOpen();
    if (this.lineage().publicationUncertain() && this.lineage().state(sessionId).lineageId) return undefined;
    const slot = this.slots.get(sessionId);
    if (!slot || slot.isDisposed || this.deletingSessionIds.has(sessionId)
      || this.indexAmbiguousSessionIds().has(sessionId)) return undefined;
    const eviction = this.idleEvictions.get(sessionId);
    if (eviction?.slot === slot && eviction.committed) return undefined;
    this.cancelIdleEviction(sessionId, slot);
    return slot.retainLease();
  }

  liveToolCatalog(sessionId: string): Array<{ name: string; description?: string; resource: Record<string, unknown> }> {
    const slot = this.slots.get(sessionId);
    if (!slot || slot.isDisposed) throw new GatewayError("busy", "Session runtime is no longer available", true);
    return slot.settingsToolCatalog();
  }

  runtimeEntries(): ReadonlyArray<readonly [string, RuntimeSlot]> { return [...this.slots]; }

  async acquire(sessionId: string, signal?: AbortSignal): Promise<RuntimeSlot> {
    this.assertSlotAdmissionOpen();
    if (this.lineage().publicationUncertain() && this.lineage().state(sessionId).lineageId) {
      throw new GatewayError("conflict", "Tron Home is rebuilding after uncertain ledger publication", true);
    }
    const existing = this.slots.get(sessionId);
    if (existing && !existing.isDisposed && !this.indexAmbiguousSessionIds().has(sessionId)) {
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
          this.recordRuntimeEviction(sessionId, "disposed");
        }
        raced = undefined;
      }
      if (raced) {
        this.requireUnambiguousSessionId(sessionId, this.indexAmbiguousSessionIds());
        const eviction = this.idleEvictions.get(sessionId);
        if (eviction?.slot === raced && eviction.committed && eviction.completion) {
          return { operation: eviction.completion.then(() => this.acquire(sessionId)) };
        }
        this.cancelIdleEviction(sessionId, raced);
        raced.touch();
        return { operation: Promise.resolve(raced) };
      }
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
      const openRefusal = await this.lineage().openRefusal(sessionId, canonicalPath);
      if (openRefusal) throw openRefusal;
      if (await this.projectTrustReloading(entry.canonicalCwd)) {
        throw new GatewayError("busy", "Project trust is being reconfigured", true);
      }
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
          async () => SessionManager.open(canonicalPath, this.sessionDirectory(entry.canonicalCwd)),
        );
      } catch {
        throw new GatewayError("conflict", "Tron session is not a valid canonical session");
      }
      if (manager.getSessionId() !== entry.id
        || resolve(manager.getCwd()) !== entry.canonicalCwd) {
        throw new GatewayError("conflict", "Tron session identity changed after catalog discovery", true);
      }
      const claimants = this.sessionCatalog.rows().filter((row) => row.id === sessionId);
      if (claimants.length !== 1
        || resolve(claimants[0]!.path) !== canonicalPath
        || (entry.fileIdentity !== undefined && claimants[0]!.fileIdentity !== entry.fileIdentity)) {
        throw new GatewayError("busy", "Session catalog changed while opening the session", true, undefined, "catalog_changed");
      }
      if (selectedAcquisitionGeneration !== this.catalogAcquisitionInvalidationGeneration) {
        throw new GatewayError("busy", "Session catalog changed while opening the session", true, undefined, "catalog_changed");
      }
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
      await this.freshness.attach(slot!);
      await this.mutex.run(() => {
        if (selectedAcquisitionGeneration !== this.catalogAcquisitionInvalidationGeneration
            || this.trustReloadProjects.has(slot!.projectDir)) {
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
      if (slot && this.slots.get(sessionId) !== slot) { this.freshness.detach(slot); await slot.dispose().catch(() => {}); }
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
      const incomingBytes = estimateRuntimeHeapBytes(await sessionFileBytes(path));
      await this.makeRoomForRuntimeBytes({ incomingBytes });
      await this.admitColdLoadUnderHeapPressure("import");
      return await this.coldLoadGate.run(undefined, () => this.mutex.run(async () => {
        this.assertSlotAdmissionOpen();
        if (this.trustReloadProjects.has(trust.projectDir)) {
          throw new GatewayError("busy", "Project trust is being reconfigured", true);
        }
        this.requireLiveSlotCapacity();
        const sessionDirectory = this.sessionDirectory(trust.cwd);
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
          await this.freshness.attach(slot);
          this.publishRuntime(importedId, slot, await sessionFileBytes(slot.sessionFile), "import");
          published = true;
          this.invalidateCatalogAcquisition();
          void this.sessionCatalog.refresh(slot.persistedSessionFile);
          this.revision += 1;
          this.options.sessionListChanged();
          return slot;
        } catch (error) {
          if (!published) {
            if (slot) this.freshness.detach(slot);
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

  async reloadProject(projectDirInput: string, projectTrusted?: boolean, publish = true): Promise<void> {
    const projectDir = await this.options.trust.canonicalDirectory(projectDirInput);
    const transactional = !publish;
    const { slots, alreadyReloading } = await this.mutex.run(() => {
      const alreadyReloading = this.trustReloadProjects.has(projectDir);
      if (!transactional && alreadyReloading) {
        throw new GatewayError("busy", "Project trust is being reconfigured", true);
      }
      if (transactional) this.trustReloadProjects.add(projectDir);
      return { slots: [...this.slots.values()].filter(slot => slot.projectDir === projectDir), alreadyReloading };
    });
    try {
      await Promise.all(slots.map(slot => this.freshness.pause(slot)));
      await this.mutex.run(() => {
        if (slots.some(slot => slot.isBusy)) {
          throw new GatewayError("busy", "Stop active sessions before changing project trust", true);
        }
        if (transactional) {
          slots.forEach(slot => slot.beginTrustReload());
        }
      });
    } catch (error) {
      if (!alreadyReloading) {
        await this.mutex.run(() => this.trustReloadProjects.delete(projectDir));
        slots.forEach(slot => this.freshness.resume(slot));
      }
      throw error;
    }
    const results = await Promise.allSettled(
      slots.map((slot) => slot.reload(projectTrusted, false, transactional)),
    );
    if (!transactional) slots.forEach(slot => this.freshness.resume(slot));
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

  refreshCompactionPolicies(scope: "global" | "project", projectDir: string): void {
    for (const slot of this.slots.values()) {
      if (scope === "global" || slot.projectDir === projectDir) slot.refreshCompactionPolicy();
    }
  }

  async releaseInheritedImageBlock(projectDir?: string): Promise<void> {
    const slots = [...this.slots.values()].filter(slot => !slot.isDisposed && (projectDir === undefined || slot.projectDir === projectDir));
    await Promise.all(slots.map(slot => slot.releaseInheritedImageBlock(projectDir === undefined ? "global" : "project")));
  }

  async abortProjectReload(projectDirInput: string): Promise<void> {
    const projectDir = await this.options.trust.canonicalDirectory(projectDirInput).catch(() => projectDirInput);
    const slots = await this.mutex.run(() => this.trustReloadProjects.has(projectDir)
      ? [...this.slots.entries()].filter(([, slot]) => slot.projectDir === projectDir)
      : undefined);
    if (slots === undefined) return;
    try {
      const results = await Promise.allSettled(slots.map(async ([sessionId, slot]) => {
        await slot.abortTrustReload();
        const retired = await this.retireIdleRuntime({
          sessionId, slot, reason: "publication-uncertain",
          eligible: () => this.slots.get(sessionId) === slot,
        });
        if (!retired && !slot.isDisposed) throw new GatewayError("internal", "Failed trust runtime could not be retired");
      }));
      const failures = results.flatMap((result, index) => result.status === "rejected"
        ? [{ sessionId: slots[index]![0], message: result.reason instanceof Error ? result.reason.message : String(result.reason) }] : []);
      if (failures.length) throw new GatewayError("internal", "Failed project runtimes could not all retire", false, { failures });
    } finally {
      await this.mutex.run(() => this.trustReloadProjects.delete(projectDir));
      slots.forEach(([, slot]) => this.freshness.resume(slot));
    }
  }

  async commitProjectReload(projectDirInput: string): Promise<void> {
    const projectDir = await this.options.trust.canonicalDirectory(projectDirInput).catch(() => projectDirInput);
    await this.mutex.run(() => {
      const slots = [...this.slots.values()].filter((slot) => slot.projectDir === projectDir);
      slots.forEach((slot) => { slot.commitReload(); this.freshness.resume(slot); });
      this.trustReloadProjects.delete(projectDir);
    });
  }

  async setArchived(
    sessionId: string,
    archived: boolean,
    initiatingWorkToken?: string,
  ): Promise<{ archived: boolean; archivedAt?: string }> {
    return this.serializeSessionMutation(sessionId, () => this.setArchivedSerialized(sessionId, archived, initiatingWorkToken));
  }

  private async setArchivedSerialized(
    sessionId: string, archived: boolean, initiatingWorkToken?: string,
  ): Promise<{ archived: boolean; archivedAt?: string }> {
    this.assertChapterWritable(sessionId);
    return this.mutex.run(async () => {
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
      if (archived && slot && !slot.isDisposed) {
        slot.assertArchivable(initiatingWorkToken);
        await slot.commitArchiveWhileIdle(initiatingWorkToken, commit);
        this.restoreArchivedSessionIfWorking(sessionId, slot);
        const effective = this.archivedAt(sessionId);
        return effective === undefined ? { archived: false } : { archived: true, archivedAt: effective };
      }
      return commit();
    });
  }

  async delete(sessionId: string, initiatingWorkToken?: string): Promise<void> {
    return this.serializeSessionMutation(sessionId, () => this.deleteSerialized(sessionId, initiatingWorkToken));
  }

  private async deleteSerialized(sessionId: string, initiatingWorkToken?: string): Promise<void> {
    this.assertChapterWritable(sessionId);
    await this.attentionLane.run(async () => {
      await this.flushPendingProjectionRemovals();
      if (this.deletingSessionIds.has(sessionId)) throw new GatewayError("busy", "Session deletion is already in progress", true);
      this.deletingSessionIds.add(sessionId);
    });
    let deleted = false;
    try {
      await this.mutex.run(async () => {
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
          await this.removeCanonicalCatalogFile(
            entry.path,
            sessionId,
            entry.fileIdentity,
          );
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
    let deletionFailure: unknown;
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
    } catch (error) {
      deletionFailure = error;
      throw error;
    } finally {
      if (!committed) {
        const originalExists = await lstat(path).then(() => true).catch(() => false);
        if (!originalExists) await rename(quarantine, path).catch((error: unknown) => {
          const failure = new GatewayError("conflict",
            "Tron session deletion failed and its file could not be restored; it remains beside the original as a .tron-delete file");
          failure.cause = new AggregateError([deletionFailure, error], "Session deletion and its restore both failed");
          throw failure;
        });
      }
    }
  }

  private readonly coldLoadGate = new QueuedWorkGate(MAXIMUM_CONCURRENT_COLD_LOADS);

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

  private async retireIdleRuntimesForHeap(): Promise<number> {
    const candidates = [...await this.resourceInventory()].sort((left, right) => right.bytes - left.bytes);
    let reclaimedBytes = 0;
    for (const candidate of candidates) {
      if (this.projectedHeapShare(reclaimedBytes) <= HEAP_EVICTION_SHARE) return reclaimedBytes;
      const slot = this.slots.get(candidate.sessionId);
      if (slot === undefined) continue;
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

  private async makeRoomForRuntimeBytes(
    input: { requestedSessionID?: string; incomingBytes: number },
  ): Promise<void> {
    return await stage("session.runtime-budget", async () => {
      const { requestedSessionID, incomingBytes } = input;
      const estimates = new Map<string, number>();
      for (const runtime of await this.resourceInventory()) {
        if (runtime.sessionId === requestedSessionID) continue;
        const estimatedHeapBytes = estimateRuntimeHeapBytes(runtime.bytes);
        estimates.set(runtime.sessionId, estimatedHeapBytes);
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
          eligible: () => projectedBytes() > LIVE_RUNTIME_BYTE_BUDGET
            && this.isIdleEvictionEligible(sessionId, slot, Infinity),
        });
        if (retired) liveBytes = Math.max(0, liveBytes - (estimates.get(sessionId) ?? 0));
      }
      this.blobs.prune();
    });
  }

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

  private recordRuntimeEviction(sessionId: string, reason: RuntimeEvictionReason): void {
    this.freshness.detach(sessionId);
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
    ambiguousIDs: ReadonlySet<string>,
  ): void {
    if (ambiguousIDs.has(sessionId)) {
      throw new GatewayError(
        "conflict",
        "Multiple canonical session files claim this ID; repair or remove the duplicate before continuing",
      );
    }
  }

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
    this.freshness.idle(slot);
    this.options.resources?.recordRuntimeLoaded();
    this.recordRuntimeTransition({
      event: "runtime.loaded",
      sessionId,
      reason: estimatedHeapBytes > LIVE_RUNTIME_BYTE_BUDGET ? "oversize" : reason,
      transcriptBytes,
      estimatedHeapBytes,
      ...(this.liveChargeExceedsBudget() ? { overBudget: true as const } : {}),
    });
  }

  private liveChargeExceedsBudget(): boolean {
    let total = 0;
    for (const charge of this.publishedRuntimeBytes.values()) total += charge.estimatedHeapBytes;
    return total > LIVE_RUNTIME_BYTE_BUDGET;
  }

  async resourceInventory(): Promise<readonly ResourceRuntimeEntry[]> {
    const entries: ResourceRuntimeEntry[] = [];
    for (const [sessionId, slot] of this.slots) {
      if (slot.isDisposed) continue;
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
      void this.options.modules.policy("sessionNotifications")?.()?.markSessionInboxRead(input.sessionId).catch(() => {});
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

  private discoverExtensionArtifacts(): Promise<void> {
    if (this.artifactDiscoveryInFlight || this.shutdownState !== "active") return Promise.resolve();
    const pass = (async () => {
      let truncated: ExtensionArtifactDiscoveryCounts | undefined;
      try {
        truncated = await this.artifactDiscovery.runPass();
      } finally {
        this.artifactDiscoveryInFlight = undefined;
      }
      this.artifactDiscovery.recordPassOutcome(truncated);
    })();
    this.artifactDiscoveryInFlight = pass;
    return pass;
  }

  private async evictIdle(forCapacity = false, requestedSessionID?: string): Promise<void> {
    const maximum = this.options.maximumLiveRuntimes;
    const needsCapacity = () => maximum !== undefined && this.slots.size + this.reservedSlotStarts >= maximum;
    if (forCapacity && !needsCapacity()) return;
    const cutoff = forCapacity ? Infinity : Date.now() - this.options.idleRuntimeMs;
    const candidates = [...this.slots].sort(([, left], [, right]) => left.touchedAt - right.touchedAt);
    for (const [id, slot] of candidates) {
      if (forCapacity && !needsCapacity()) break;
      const eligible = () => id !== requestedSessionID
        && (!forCapacity || (needsCapacity() && slot.persistedSessionFile !== undefined))
        && this.isIdleEvictionEligible(id, slot, cutoff);
      await this.retireIdleRuntime({ sessionId: id, slot, reason: forCapacity ? "capacity" : "idle", eligible });
    }
    this.blobs.prune();
  }

  async retireIdleRuntime(input: {
    sessionId: string;
    slot: RuntimeSlot;
    reason: Extract<RuntimeEvictionReason, "idle" | "capacity" | "bytes" | "heap" | "publication-uncertain">;
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
      return false;
    } finally {
      if (this.idleEvictions.get(id)?.slot === slot) this.idleEvictions.delete(id);
    }
  }

  async sessionFile(sessionId: string): Promise<string | undefined> {
    const live = this.slots.get(sessionId)?.sessionFile;
    if (live) return live;
    await this.awaitFirstCatalogCut();
    const indexed = () => {
      if (this.indexAmbiguousSessionIds().has(sessionId)) return undefined;
      const row = this.sessionCatalog.rows().find((candidate) => candidate.id === sessionId);
      return row ? resolve(row.path) : undefined;
    };
    const found = indexed();
    if (found) return found;
    await this.sessionCatalog.awaitQueuedChanges();
    return indexed();
  }

  async taskWorkerModel(sessionId: string): Promise<{ provider: string; id: string } | undefined> {
    const change = (await this.readTaskWorkerEntries(sessionId)).findLast(entry => entry.type === "model_change");
    return change?.type === "model_change" ? { provider: change.provider, id: change.modelId } : undefined;
  }

  recordTaskWorkers(workers: Iterable<readonly [sessionId: string, taskId: string]>): void {
    let changed = false;
    const acknowledge: string[] = [];
    for (const [sessionId, taskId] of workers) {
      if (!this.delegation.registerWorkerAttribution(sessionId, taskId)) continue;
      changed = true;
      if (this.attention.hasUnacknowledgedCompletion(sessionId)) acknowledge.push(sessionId);
    }
    if (acknowledge.length > 0) void this.acknowledgeTaskWorkers(acknowledge);
    if (!changed) return;
    this.catalogProjectionGeneration += 1;
    this.options.sessionListChanged();
  }

  private async acknowledgeTaskWorkers(sessionIds: readonly string[]): Promise<void> {
    await this.attentionLane.run(async () => {
      let cold = false;
      for (const sessionId of sessionIds) {
        try {
          const result = await this.attention.acknowledgeCompletions(sessionId);
          if (!result.changed) continue;
          const latest = this.latestSummaries.get(sessionId);
          if (latest) this.publishRevisionedSummary({ ...latest, sessionId, ...result.projection });
          else cold = true;
        } catch {
          this.options.persistenceDiagnostic?.(sessionId, "home-worker-attention-failed");
        }
      }
      if (cold) {
        this.catalogProjectionGeneration += 1;
        this.options.sessionListChanged();
      }
    });
  }

  taskWorkerSettled(sessionId: string, taskId: string): Promise<void> {
    return this.attentionLane.run(async () => {
      const result = await this.attention.complete(sessionId, `task:${taskId}`, true);
      if (!result.changed) return;
      const latest = this.latestSummaries.get(sessionId);
      if (latest) this.publishRevisionedSummary({ ...latest, sessionId, ...result.projection });
      else {
        this.catalogProjectionGeneration += 1;
        this.options.sessionListChanged();
      }
    });
  }

  async taskWorkerName(sessionId: string): Promise<string | undefined> {
    const live = this.slots.get(sessionId);
    if (live) return live.displayName;
    const path = await this.sessionFile(sessionId);
    return path ? this.sessionCatalog.row(path)?.name : undefined;
  }

  async readTaskWorkerEntries(sessionId: string): Promise<FileEntry[]> {
    const live = this.slots.get(sessionId);
    if (live) return live.canonicalSessionEntries();
    if (await this.sessionFile(sessionId)) return await this.canonicalSessionEvidenceCut(sessionId) ?? [];
    return [];
  }

  async readTaskEvidence(sessionId: string, options: { appendStable?: boolean } = {}): Promise<FileEntry[]> {
    const entries = await this.canonicalSessionEvidenceCut(sessionId, options.appendStable === true);
    if (!entries) throw new GatewayError("conflict", "Task canonical session is missing");
    return entries;
  }

  async readLiveTaskEvidence(sessionId: string, operationId: string): Promise<LiveTaskEvidence> {
    return this.serializeSessionMutation(sessionId, async () => {
      const slot = this.slots.get(sessionId);
      if (!slot) throw new GatewayError("conflict", "Task runtime is missing");
      return slot.inspectTaskSettlement(operationId, async operationSettled => {
        const entries = await this.canonicalSessionEvidenceCut(sessionId);
        return entries ? { state: "present" as const, entries, branch: slot.canonicalSessionEntries() }
          : { state: "absent" as const, operationSettled };
      });
    });
  }

  private async canonicalSessionEvidenceCut(sessionId: string, appendStable = false): Promise<SessionEntry[] | null> {
    await this.sessionCatalog.whenReconciled();
    const path = await this.sessionFile(sessionId);
    if (!path) throw new GatewayError("conflict", "Canonical session is missing");
    const before = await lstat(path).catch(error => {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
      throw error;
    });
    if (!before) {
      const directory = await open(dirname(path), "r");
      try { await syncDurably(directory); } finally { await directory.close(); }
      const after = await lstat(path).catch(error => {
        if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
        throw error;
      });
      if (after) throw new GatewayError("conflict", "Canonical session changed during inspection");
      return null;
    }
    if (!before.isFile() || before.isSymbolicLink()) throw new GatewayError("conflict", "Canonical session is unsafe");
    for (const durablePath of [path, dirname(path)]) {
      const handle = await open(durablePath, "r");
      try { await syncDurably(handle); } finally { await handle.close(); }
    }
    const entries = await readCanonicalSessionFile({ path, sessionId, appendStable });
    const after = await lstat(path);
    const appended = appendStable && after.size >= before.size;
    if (after.isSymbolicLink() || before.dev !== after.dev || before.ino !== after.ino || (!appended && (before.size !== after.size
      || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs))) throw new GatewayError("conflict", "Canonical session changed during inspection");
    return entries.map(entry => entry.raw as unknown as SessionEntry);
  }

  async sessionPresent(sessionId: string): Promise<boolean> {
    if (this.slots.has(sessionId)) return true;
    try {
      return (await this.catalogMembership(sessionId)).entry !== undefined;
    } catch {
      return true;
    }
  }

  activeSessionIds(): string[] {
    return [...this.slots.values()].filter((slot) => slot.isBusy).map((slot) => slot.id);
  }

  beginAdministrativeDrain(answeringWorkToken?: string): AdministrativeDrainSnapshot {
    if (!this.administrativeDrainStarted) {
      this.administrativeDrainStarted = true;
      this.workRegistry.beginDrain();
      for (const slot of this.slots.values()) slot.beginAdministrativeDrainCutoff();
      this.drainId = randomUUID();
      this.drainPhase = "preparing";
      this.drainFingerprint = "";
      this.drainRevision += 1;
    }
    return this.administrativeDrainSnapshot(answeringWorkToken);
  }

  private setDrainPhase(phase: AdministrativeDrainPhase): void {
    if (this.drainPhase === phase) return;
    this.drainPhase = phase;
    this.drainRevision += 1;
    this.drainFingerprint = "";
  }

  administrativeDrainSnapshot(answeringWorkToken?: string): AdministrativeDrainSnapshot {
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
    const answered = answeringWorkToken === undefined ? facts : facts.filter((fact) => fact.key !== `work:${answeringWorkToken}`);
    const counts: Partial<Record<AdministrativeDrainBlockerCategory, number>> = {};
    for (const fact of answered) counts[fact.category] = (counts[fact.category] ?? 0) + 1;
    const summaries = answered.slice(0, 64).map((fact) => {
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
      blockerCount: answered.length,
      blockerCounts: counts,
      blockers: summaries,
      omittedCount: Math.max(0, answered.length - summaries.length),
      suspectProjectionCount: answered.filter((fact) => fact.state === "suspect").length,
    };
  }

  async waitUntilIdle(continueDrain?: (snapshot: AdministrativeDrainSnapshot) => boolean): Promise<boolean> {
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
            .map((slot) => slot.ownedTurns.reconcileOwnedExtensionArtifactsForDrain()));
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

  failAdministrativeDrain(): void {
    if (this.drainPhase === "idle") this.beginAdministrativeDrain();
    this.setDrainPhase("failed");
    this.administrativeDrainSnapshot();
  }

  async dispose(): Promise<void> {
    if (this.shutdownState === "disposed") return;
    if (this.disposalPromise) return this.disposalPromise;

    this.shutdownState = "shuttingDown";
    if (this.evictionTimer) clearInterval(this.evictionTimer);
    if (this.artifactDiscoveryTimer) clearInterval(this.artifactDiscoveryTimer);
    for (const lifecycle of this.lifecycles()) lifecycle.closing();
    const operation = this.performDispose();
    this.disposalPromise = operation;
    try {
      await operation;
    } catch (error) {
      if (this.disposalPromise === operation) this.disposalPromise = undefined;
      throw error;
    }
  }

  private async performDispose(): Promise<void> {
    await this.freshness.close();
    await this.waitForSlotAdmissionsIdle();
    const entries = await this.mutex.run(() => [...this.slots.entries()]);
    const results = await Promise.allSettled(entries.map(([, slot]) => slot.shutdown()));
    await Promise.allSettled([this.artifactDiscoveryInFlight]);
    this.artifactDiscovery.close();
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
    await this.settingsOwners?.changes.dispose();
    for (const lifecycle of this.lifecycles()) await lifecycle.dispose().catch(() => {});
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
      if (this.slotAdmissionsInFlight === 0) {
        for (const waiter of this.slotAdmissionIdleWaiters.splice(0)) waiter();
      }
      work.settle();
    };
  }

  private waitForSlotAdmissionsIdle(): Promise<void> {
    if (this.slotAdmissionsInFlight === 0) return Promise.resolve();
    return new Promise((resolve) => this.slotAdmissionIdleWaiters.push(resolve));
  }

  private assertSlotAdmissionOpen(): void {
    if (this.shutdownState !== "active") {
      throw new GatewayError("conflict", "Session runtime registry is shutting down", true);
    }
  }

  registerWorkspaceBlob(data: Buffer, mimeType: string): string {
    return this.blobs.registerData(data, mimeType);
  }

  async acquireBlob(id: string, range?: import("../../sessions/blob-store.js").BlobByteRange, signal?: AbortSignal) {
    try {
      return await this.blobs.acquire(id, range, signal);
    } catch (error) {
      if (!(error instanceof GatewayError) || error.code !== "not_found") throw error;
      return this.exports.acquire(id, range, signal);
    }
  }

  liveRuntime(sessionID: string): RuntimeSlot | undefined { return this.slots.get(sessionID); }
  orderedRuntime(sessionID: string): Promise<RuntimeSlot | undefined> { return this.mutex.run(() => this.slots.get(sessionID)); }

  isDeletingSession(sessionID: string): boolean { return this.deletingSessionIds.has(sessionID); }
}
