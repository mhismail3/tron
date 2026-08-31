import { createHash, randomUUID } from "node:crypto";
import { createReadStream, realpathSync } from "node:fs";
import { lstat, open, opendir, readFile, readdir, realpath, rename, rm, stat } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { tmpdir } from "node:os";
import { performance } from "node:perf_hooks";
import { createInterface } from "node:readline";
import {
  ModelRuntime,
  parseSessionEntries,
  SessionManager,
  SettingsManager,
  type FileEntry,
  type SessionEntry,
} from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import { installKimiK3Policy } from "../providers/kimi-k3-policy.js";
import type {
  AdministrativeDrainBlockerCategory,
  AdministrativeDrainBlockerSummary,
  AdministrativeDrainPhase,
  AdministrativeDrainSnapshot,
  SessionSummary,
  SessionSummaryUpdate,
} from "../protocol/types.js";
import { SessionAttentionStore, type SessionAttentionProjection } from "./session-attention-store.js";
import {
  SessionPresentationPresenceRegistry,
  type SessionPresentationPresenceProjection,
} from "./session-presentation-presence.js";
import { AsyncMutex } from "../util/async-mutex.js";
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
  completionOwnedByMarker,
  type CanonicalAssistantCompletion,
  type SessionAttentionRebindDisposition,
  type SessionBroadcast,
} from "./runtime-slot.js";
import { ExtensionActivityRecency } from "./extension-activity-recency.js";
import { ProcessActivityRecency } from "./process-activity-recency.js";
import { admitExtensionLifecycleArtifact } from "./extension-run-projection.js";
import type { NotificationService } from "../notifications/notification-service.js";
import { GatewayWorkRegistry } from "./gateway-work-registry.js";
import { projectTranscriptPage, type TranscriptPage } from "./projection.js";
import {
  CatalogMetadataIndex,
  type CatalogMetadataIndexRow,
  type CatalogMetadataIndexSummary,
  type CatalogMetadataAccumulator,
  applyCatalogMetadataEntry,
} from "./catalog-metadata-index.js";

const MAX_EXTENSION_ARTIFACT_BYTES = 256 * 1_024;
/** A read-only child observer may page only canonical sessions that fit this
 * explicit parse budget. The parser needs the selected branch graph, so it
 * reads one bounded file rather than maintaining an incremental mirror. */
const MAX_READ_ONLY_SUBAGENT_SESSION_BYTES = 64 * 1_024 * 1_024;
// MaximumLiveRuntimes is 16 and each slot retains at most 64 owned activity
// bindings, so this covers every exact drain owner before ambient work.
const MAX_EXTENSION_DISCOVERY_WORK = 1_024;
const MAX_EXTENSION_DISCOVERY_ROOTS = 64;
const MAX_EXTENSION_TEMP_ENTRIES = 1_024;
// Ambient enumeration shares these global pass bounds. Exact-owned artifact
// reconciliation above is intentionally outside this ambient budget.
const MAX_EXTENSION_ROOT_ENTRIES = 4_096;
const SUBAGENT_RUN_DIRECTORY = /^run-\d+$/u;

function isMissingFilesystemError(error: unknown): boolean {
  return (error as NodeJS.ErrnoException | undefined)?.code === "ENOENT";
}

function assertProcessSessionRef(value: string): void {
  if (!value || Buffer.byteLength(value) > 256 || /[\\/\0]/u.test(value)) {
    throw new GatewayError("invalid_request", "Invalid subagent session reference");
  }
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

function branchFromParsedSession(entries: FileEntry[]): {
  sessionId: string;
  parentSession?: string;
  branch: SessionEntry[];
  leafEntryId?: string;
} | undefined {
  const header = entries[0];
  if (!header || header.type !== "session" || !header.id) return undefined;
  const sessionEntries = entries.slice(1).filter((entry): entry is SessionEntry => entry.type !== "session");
  const byID = new Map(sessionEntries.map((entry) => [entry.id, entry]));
  const leaf = sessionEntries[sessionEntries.length - 1];
  const reversed: SessionEntry[] = [];
  const seen = new Set<string>();
  let cursor = leaf;
  while (cursor) {
    if (!seen.add(cursor.id)) return undefined;
    reversed.push(cursor);
    cursor = cursor.parentId === null ? undefined : byID.get(cursor.parentId);
    if (reversed[reversed.length - 1]!.parentId !== null && cursor === undefined) return undefined;
  }
  return {
    sessionId: header.id,
    ...(header.parentSession ? { parentSession: header.parentSession } : {}),
    branch: reversed.reverse(),
    ...(leaf ? { leafEntryId: leaf.id } : {}),
  };
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

async function readOpenedSession(
  handle: Awaited<ReturnType<typeof open>>,
  byteCount: number,
): Promise<ReturnType<typeof branchFromParsedSession>> {
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
    const read = await handle.read(bytes, offset, bytes.length - offset, offset);
    if (read.bytesRead <= 0) return undefined;
    offset += read.bytesRead;
  }
  try {
    return branchFromParsedSession(parseSessionEntries(bytes.toString("utf8")));
  } catch {
    return undefined;
  }
}

const DEFAULT_CATALOG_DISCOVERY_LIMITS = {
  maximumDirectories: 25_001,
  maximumEntries: 50_001,
  maximumTraversalBytes: 8 * 1_024 * 1_024,
  maximumSessions: 25_000,
  maximumRetainedBytes: 8 * 1_024 * 1_024,
  maximumAcquisitionBytes: 4 * 1_024 * 1_024,
  maximumHeaderBytes: 64 * 1_024 * 1_024,
  maximumHeaderBytesPerFile: 64 * 1_024,
  normalizationConcurrency: 16,
};

type SessionInfo = Awaited<ReturnType<typeof SessionManager.listAll>>[number];
type CatalogSessionInfo = Omit<SessionInfo, "allMessagesText"> & {
  fileIdentity?: string;
};

/** SDK-compatible row metadata without constructing its unused transcript-wide
 * `allMessagesText` accumulator. The complete JSONL remains authoritative for
 * RuntimeSlot.open; this pass is only catalog discovery metadata. */
async function buildCatalogSessionInfo(filePath: string): Promise<CatalogSessionInfo | null> {
  try {
    const physical = await lstat(filePath);
    if (!physical.isFile() || physical.isSymbolicLink()) return null;
    const stats = await stat(filePath);
    let header: Record<string, unknown> | undefined;
    const metadata: CatalogMetadataAccumulator = {
      messageCount: 0,
      firstMessage: "(no messages)",
      name: undefined,
      updatedAt: "",
    };
    const lines = createInterface({
      input: createReadStream(filePath, { encoding: "utf8" }),
      crlfDelay: Infinity,
    });
    for await (const line of lines) {
      let value: unknown;
      try { value = JSON.parse(line); } catch { continue; }
      if (!value || typeof value !== "object" || Array.isArray(value)) continue;
      const entry = value as Record<string, unknown>;
      if (!header) {
        if (entry.type !== "session") return null;
        header = entry;
        continue;
      }
      applyCatalogMetadataEntry(metadata, entry);
    }
    if (!header || typeof header.id !== "string") return null;
    const cwd = typeof header.cwd === "string" ? header.cwd : "";
    const headerTime = typeof header.timestamp === "string" ? Date.parse(header.timestamp) : NaN;
    const modified = metadata.updatedAt ? new Date(metadata.updatedAt)
      : Number.isFinite(headerTime) ? new Date(headerTime) : stats.mtime;
    return {
      path: filePath,
      id: header.id,
      cwd,
      ...(metadata.name ? { name: metadata.name } : {}),
      ...(typeof header.parentSession === "string" ? { parentSessionPath: header.parentSession } : {}),
      created: new Date(typeof header.timestamp === "string" ? header.timestamp : stats.birthtime),
      modified,
      messageCount: metadata.messageCount,
      firstMessage: metadata.firstMessage,
    };
  } catch {
    return null;
  }
}

async function buildCatalogSessionInfos(files: readonly string[]): Promise<CatalogSessionInfo[]> {
  const results: Array<CatalogSessionInfo | null> = new Array(files.length).fill(null);
  let next = 0;
  const worker = async (): Promise<void> => {
    while (true) {
      const index = next++;
      if (index >= files.length) return;
      results[index] = await buildCatalogSessionInfo(files[index]!);
    }
  };
  await Promise.all(Array.from({ length: Math.min(10, files.length) }, worker));
  return results.filter((info): info is CatalogSessionInfo => info !== null);
}

interface CatalogHeaderIdentity {
  id: string;
  cwd: string;
  fileIdentity: string;
  size: number;
  mtimeMs: number;
  parentSessionPath?: string;
}

interface DelegatedSessionTopology {
  parentSessionId?: string;
  contradictoryHeader: boolean;
}

interface CatalogStructureEvidence {
  digest: string;
  factsDigest: string;
  identitiesByPath: ReadonlyMap<string, CatalogHeaderIdentity>;
  complete: boolean;
  unstableCanonicalFiles: boolean;
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
  structureDigest: string;
  indexedStructuralGeneration?: number;
  fallbackIdentityFingerprint?: string;
  fallbackInvalidationGeneration?: number;
}

interface CatalogAcquisitionAdmission extends CatalogAcquisitionResolution {
  invalidationGeneration: number;
}

export interface ReadOnlySubagentAdmission {
  path: string;
  fileIdentity: string;
}

interface CatalogPageSeed {
  readonly id: string;
  readonly name?: string;
  readonly cwd: string;
  readonly kind: SessionSummary["kind"];
  readonly parentSessionId?: string;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly activeSince?: string;
  readonly messageCount: number;
  readonly firstMessage: string;
  readonly phase: SessionSummary["phase"];
  readonly summaryRevision: number;
  readonly attention: SessionAttentionProjection;
}

interface CatalogPageSource {
  readonly generation: string;
  readonly listRevision: number;
  readonly count: number;
  readonly compactByteEstimate: number;
  readonly page: (offset: number, limit: number) => Promise<SessionSummary[]>;
}

interface CatalogStructuralIndex {
  allInfos: readonly CatalogSessionInfo[];
  ambiguousDiskIDs: ReadonlySet<string>;
  structureDigest: string;
  factsDigest: string;
  structuralGeneration: number;
  invalidationGeneration: number;
}

interface IdleEviction {
  slot: RuntimeSlot;
  committed: boolean;
  completion?: Promise<boolean>;
}

export class RuntimeRegistry {
  private readonly slots = new Map<string, RuntimeSlot>();
  private readonly mutex = new AsyncMutex();
  /** Shares one authoritative materialization across concurrent callers. The
   * promise is disposable and keyed by the structural/invalidation generation;
   * canonical evidence still gates every publication. */
  private catalogMaterializationPromise: Promise<Awaited<ReturnType<RuntimeRegistry["materializeCatalogSnapshot"]>>> | undefined;
  private catalogMaterializationKey: string | undefined;
  /** One bounded structural walk can serve catalog and acquisition callers.
   * `refresh` is reserved for a post-materialization stability check. */
  private catalogEvidencePromise: Promise<CatalogStructureEvidence> | undefined;
  private catalogEvidenceKey: string | undefined;
  private catalogSessionInfosPromise: Promise<CatalogSessionInfo[]> | undefined;
  private catalogSessionInfosKey: string | undefined;
  private catalogEvidenceRefresh = 0;
  private readonly catalogAcquisitionMutex = new AsyncMutex();
  private catalogAcquisitionPromise: Promise<CatalogAcquisitionResolution> | undefined;
  private catalogAcquisitionPromiseKey: string | undefined;
  /** Serializes attention membership checks with set/delete/rekey. */
  private readonly attentionLane = new AsyncMutex();
  private readonly blobs: BlobStore;
  private readonly exports: BlobStore;
  private readonly markers: RunMarkerStore;
  private readonly extensionActivityRecency = new ExtensionActivityRecency();
  private readonly processActivityRecency = new ProcessActivityRecency();
  private readonly attention: SessionAttentionStore;
  private readonly presentationPresence = new SessionPresentationPresenceRegistry();
  private readonly catalogMetadataIndex: CatalogMetadataIndex;
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
  private readonly deletingSessionIds = new Set<string>();
  private ambiguousSessionIds = new Set<string>();
  private readonly trustReloadProjects = new Set<string>();
  private revision = 0;
  private catalogFingerprint: string | undefined;
  private catalogAcquisitionInvalidationGeneration = 0;
  private catalogStructuralGeneration = 0;
  private catalogAcquisitionAdmission: CatalogAcquisitionAdmission | undefined;
  private catalogStructuralIndex: CatalogStructuralIndex | undefined;
  /** Mutable page overlays are separate from structural listRevision. This
   * generation keys immutable compact page seeds without making them catalog
   * authority. */
  private catalogProjectionGeneration = 0;
  private readonly catalogPageSources = new Map<string, WeakRef<CatalogPageSource>>();
  private readonly pendingSlotStarts = new Map<string, Promise<RuntimeSlot>>();
  private reservedSlotStarts = 0;
  private evictionTimer?: NodeJS.Timeout;
  private artifactDiscoveryTimer?: NodeJS.Timeout;
  private artifactDiscoveryInFlight = false;
  private slotAdmissionsInFlight = 0;
  private administrativeDrainStarted = false;
  private readonly workRegistry: GatewayWorkRegistry;
  private drainId: string;
  private drainRevision = 0;
  private drainPhase: AdministrativeDrainPhase = "idle";
  private drainStartedAt: string | undefined;
  private drainLastProgressAt: string | undefined;
  private drainFingerprint = "";
  private shutdownState: "active" | "shuttingDown" | "disposed" = "active";
  private disposalPromise: Promise<void> | undefined;

  constructor(
    private readonly options: {
      agentDir: string;
      tronHome: string;
      idleRuntimeMs: number;
      maximumLiveRuntimes?: number;
      modelRuntimeFactory?: () => Promise<ModelRuntime>;
      trust: TrustService;
      broadcast: SessionBroadcast;
      sessionSummaryChanged: (summary: SessionSummaryUpdate) => void;
      sessionListChanged: () => void;
      sessionRekeyed?: (previousId: string, nextId: string) => void;
      sessionClosed?: (sessionId: string) => void;
      catalogDiscoveryLimits?: Partial<typeof DEFAULT_CATALOG_DISCOVERY_LIMITS>;
      stageTiming?: (stage: string, durationMs: number, outcome: "success" | "failure") => void;
      machineId?: string;
      notifications?: NotificationService;
      workRegistry?: GatewayWorkRegistry;
      extensionArtifactWarning?: (warning: { reason: import("./extension-run-projection.js").ExtensionArtifactRejectionReason; owner: string }) => void;
    },
  ) {
    this.blobs = new BlobStore(undefined, Date.now, join(options.tronHome, "gateway", "blobs"));
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
    this.catalogMetadataIndex = new CatalogMetadataIndex(
      join(options.tronHome, "gateway"),
      (stage, durationMs, outcome) => this.options.stageTiming?.(`catalog-index.${stage}`, durationMs, outcome),
    );
    this.workRegistry = options.workRegistry ?? new GatewayWorkRegistry();
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

  get administrativeWorkRegistry(): GatewayWorkRegistry { return this.workRegistry; }

  async initialize(onPhase?: (phase: "catalog-warming" | "attention-recovery") => void): Promise<void> {
    // Load the durable recovery inputs before capturing catalog membership, as
    // before this optimization. The later evidence cut therefore cannot omit a
    // marker that was already admitted to this reconciliation pass.
    await this.timedStage("startup.attention.initialize", () => this.attention.initialize());
    const markerEvidence = await this.timedStage("startup.run-marker.read", () => this.markers.evidence());
    // Capture one bounded structural cut and pass it through recovery. This
    // prevents reconciliation from silently performing a second catalog walk
    // and keeps incomplete evidence fail-closed.
    onPhase?.("catalog-warming");
    const catalogEvidence = await this.timedStage("startup.catalog.evidence", () => this.sharedCatalogStructureEvidence());
    onPhase?.("attention-recovery");
    await this.timedStage("startup.attention.reconcile", () => this.reconcileCanonicalAttention(markerEvidence, catalogEvidence));
    this.interrupted = await this.timedStage("startup.run-marker.interrupted", () => this.markers.interruptedSessionIds());
    this.evictionTimer = setInterval(() => void this.evictIdle(), 60_000);
    this.evictionTimer.unref();
    this.artifactDiscoveryTimer = setInterval(() => void this.discoverExtensionArtifacts(), 750);
    this.artifactDiscoveryTimer.unref();
    void this.discoverExtensionArtifacts();
  }

  async initializeBlobStorage(): Promise<void> {
    await Promise.all([this.blobs.initialize(), this.exports.initialize()]);
  }

  private async reconcileCanonicalAttention(
    markerEvidence: ReadonlyMap<string, readonly RunMarkerEvidence[]>,
    evidence: CatalogStructureEvidence,
  ): Promise<void> {
    const scanBoundary = new Date().toISOString();
    // Startup recovery uses the exact bounded structural cut acquired by
    // initialize(). It must not start a second walk while attention is being
    // reconciled.
    if (!evidence.complete) {
      // Incomplete discovery cannot prove either membership or absence. Keep
      // attention records and the reconciliation cursor for the next startup.
      return;
    }
    const byID = new Map<string, Array<{ path: string; identity: CatalogHeaderIdentity }>>();
    for (const [path, identity] of evidence.identitiesByPath) {
      const candidates = byID.get(identity.id) ?? [];
      candidates.push({ path, identity });
      byID.set(identity.id, candidates);
    }
    await this.attention.prune(new Set(byID.keys()));
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
        await this.markers.clear(sessionId, marker.operationId);
      }
    }
    await this.attention.advanceReconciliationCursor(scanBoundary);
  }

  private hooks() {
    return {
      broadcast: this.options.broadcast,
      summaryChanged: (summary: SessionSummaryUpdate) => {
        this.publishRevisionedSummary({ ...summary, ...this.attention.projection(summary.sessionId) });
      },
      changed: () => {
        this.invalidateCatalogAcquisition();
        this.revision += 1;
        this.options.sessionListChanged();
      },
      settled: (sessionId: string) => { this.interrupted.delete(sessionId); },
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
          && this.catalogStructuralIndex?.allInfos.some((info) => info.id === sessionId
            && resolve(info.path) === resolve(persistedPath)) === true;
        if (removed) this.slots.delete(sessionId);
        this.cancelIdleEviction(sessionId, slot);
        this.subscribers.delete(sessionId);
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
          // runtime ownership is no longer available as the row projection.
          this.invalidateCatalogAcquisition();
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
        await this.flushPendingAttentionRemovals();
        if (this.deletingSessionIds.has(previousId) || this.deletingSessionIds.has(nextId)) {
          throw new GatewayError("busy", "Session identity is being deleted", true);
        }
        const existing = this.slots.get(nextId);
        if (existing && existing !== slot) throw new GatewayError("conflict", "Replacement session is already active");
        // Complete every fallible attention write while the slot and registry
        // still own previousId, then commit both in one synchronous turn.
        if (disposition === "migrate") await this.attention.rekey(previousId, nextId);
        if (disposition === "reset" || disposition === "discard") await this.attention.assertAbsent(nextId);
        if (disposition === "discard") await this.attention.remove(previousId);
        commitIdentity();
        if (this.slots.get(previousId) === slot) this.slots.delete(previousId);
        this.slots.set(nextId, slot);
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
        try { this.options.sessionRekeyed?.(previousId, nextId); } catch {}
        this.invalidateCatalogAcquisition();
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
    this.options.sessionSummaryChanged(revisioned);
  }

  private async flushPendingAttentionRemovals(): Promise<void> {
    for (const sessionId of [...this.pendingAttentionRemovals]) {
      try {
        await this.attention.remove(sessionId);
        this.pendingAttentionRemovals.delete(sessionId);
      } catch {
        // Retain for the next attention operation; restart reconciliation also
        // prunes records with no canonical catalog owner.
      }
    }
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
    acquisition: CatalogAcquisitionResolution;
    generation: number;
    entry?: CatalogAcquisitionEntry;
    liveOnlySlot?: RuntimeSlot;
  }> {
    const acquisition = await this.timedStage("attention.resolve", () => this.catalogAcquisition());
    this.requireUnambiguousSessionId(sessionId, acquisition.ambiguousIDs);
    const entry = acquisition.entriesByID.get(sessionId);
    if (entry) return { acquisition, generation: this.catalogAcquisitionInvalidationGeneration, entry };
    // Empty sessions are visible before their first canonical append. Their
    // exact runtime owner is a valid attention target until it is persisted or
    // disposed; a disk claimant would already be quarantined above.
    const liveOnlySlot = this.slots.get(sessionId);
    if (liveOnlySlot && !liveOnlySlot.isDisposed && liveOnlySlot.persistedSessionFile === undefined) {
      return { acquisition, generation: this.catalogAcquisitionInvalidationGeneration, liveOnlySlot };
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
        await this.flushPendingAttentionRemovals();
        if (this.deletingSessionIds.has(sessionId)) {
          throw new GatewayError("not_found", "Tron session was not found");
        }
        const current = this.catalogAcquisitionAdmission;
        const currentEntry = current?.entriesByID.get(sessionId);
        const currentLiveOnly = this.slots.get(sessionId);
        const admittedEntry = admission.entry;
        if (admission.generation !== this.catalogAcquisitionInvalidationGeneration
          || current !== undefined && admittedEntry !== undefined && (
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
        const result = await this.timedStage(
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
    throw new GatewayError("busy", "Session catalog changed while updating attention", true);
  }

  private dependencies() {
    return {
      agentDir: this.options.agentDir,
      createModelRuntime: async () => installKimiK3Policy(await (this.options.modelRuntimeFactory ?? (() => ModelRuntime.create({
        authPath: join(this.options.agentDir, "auth.json"),
        modelsPath: join(this.options.agentDir, "models.json"),
        modelsStorePath: join(this.options.agentDir, "models-store.json"),
        refreshOnCreate: true,
        allowModelNetwork: false,
      })))()),
      trust: this.options.trust,
      blobs: this.blobs,
      exports: this.exports,
      markers: this.markers,
      extensionActivityRecency: this.extensionActivityRecency,
      processActivityRecency: this.processActivityRecency,
      workRegistry: this.workRegistry,
      isSessionPresented: (sessionId: string) => this.isSessionPresented(sessionId),
      ...(this.options.machineId ? { machineId: this.options.machineId } : {}),
      ...(this.options.notifications ? { notifications: this.options.notifications } : {}),
      ...(this.options.extensionArtifactWarning ? { extensionArtifactWarning: this.options.extensionArtifactWarning } : {}),
      ...(this.options.stageTiming ? {
        runtimeDisposalTimedOut: (graceMs: number) => this.options.stageTiming!("runtime.dispose-timeout", graceMs, "failure"),
      } : {}),
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

  /** pi-subagents writes diagnostic transcripts beneath the exact reserved
   * `<catalog-root>/<workspace>/subagent-artifacts` subtree. A legitimate
   * deeper project directory with the same name remains canonical. */
  private isIgnoredCatalogDirectory(directory: string, canonicalRoot: string): boolean {
    const fromRoot = relative(canonicalRoot, resolve(directory));
    if (fromRoot === ".." || fromRoot.startsWith(`..${sep}`) || isAbsolute(fromRoot)) return true;
    const parts = fromRoot.split(sep);
    return parts.length === 2 && parts[1] === "subagent-artifacts";
  }

  private catalogDiscoveryLimits() {
    return { ...DEFAULT_CATALOG_DISCOVERY_LIMITS, ...this.options.catalogDiscoveryLimits };
  }

  private catalogCapacityExceeded(): never {
    throw new GatewayError("busy", "Session catalog discovery exceeds its bounded capacity", true);
  }

  private invalidateCatalogAdmission(): void {
    this.catalogAcquisitionInvalidationGeneration += 1;
    this.catalogAcquisitionAdmission = undefined;
  }

  private invalidateCatalogAcquisition(): void {
    this.invalidateCatalogAdmission();
    this.catalogStructuralGeneration += 1;
    this.catalogStructuralIndex = undefined;
    this.catalogProjectionGeneration += 1;
  }

  private dynamicAmbiguousSessionIDs(index: CatalogStructuralIndex): Set<string> {
    const ambiguous = new Set(index.ambiguousDiskIDs);
    const persistedIDs = new Set(index.allInfos.map((session) => session.id));
    for (const [id, slot] of this.slots) {
      // A persisted slot is the runtime owner of its indexed canonical file,
      // not a second claimant. Only live-only ownership colliding with any disk
      // identity creates an additional ambiguity.
      if (!slot.isDisposed && slot.persistedSessionFile === undefined && persistedIDs.has(id)) {
        ambiguous.add(id);
      }
    }
    return ambiguous;
  }

  private diskAmbiguousSessionIDs(infos: readonly CatalogSessionInfo[]): Set<string> {
    const counts = new Map<string, number>();
    for (const info of infos) counts.set(info.id, (counts.get(info.id) ?? 0) + 1);
    return new Set([...counts].filter(([, count]) => count > 1).map(([id]) => id));
  }

  private async timedStage<T>(stage: string, operation: () => Promise<T>): Promise<T> {
    const startedAt = performance.now();
    try {
      const result = await operation();
      this.options.stageTiming?.(stage, Math.max(0, Math.round(performance.now() - startedAt)), "success");
      return result;
    } catch (error) {
      this.options.stageTiming?.(stage, Math.max(0, Math.round(performance.now() - startedAt)), "failure");
      throw error;
    }
  }

  private async validatedStructuralIndex(): Promise<CatalogStructuralIndex | undefined> {
    const index = this.catalogStructuralIndex;
    if (!index || index.structuralGeneration !== this.catalogStructuralGeneration) return undefined;
    const structuralGeneration = this.catalogStructuralGeneration;
    const evidence = await this.sharedCatalogStructureEvidence(true);
    if (this.catalogStructuralIndex === index
        && structuralGeneration === this.catalogStructuralGeneration
        && evidence.complete
        && evidence.digest === index.structureDigest
        && evidence.factsDigest === index.factsDigest) return index;
    if (this.catalogStructuralIndex === index) this.invalidateCatalogAcquisition();
    return undefined;
  }

  private async removeIndexedCatalogFile(path: string): Promise<boolean> {
    const index = this.catalogStructuralIndex;
    if (!index || index.structuralGeneration !== this.catalogStructuralGeneration) return false;
    const canonicalPath = resolve(path);
    const remaining = index.allInfos.filter((info) => resolve(info.path) !== canonicalPath);
    if (remaining.length === index.allInfos.length) return false;
    const admittedGeneration = this.catalogStructuralGeneration;
    const evidence = await this.catalogStructureEvidence();
    if (this.catalogStructuralIndex !== index
        || this.catalogStructuralGeneration !== admittedGeneration) return false;
    const exact = evidence.complete && remaining.every((info) => {
      const identity = evidence.identitiesByPath.get(resolve(info.path));
      return identity?.id === info.id && resolve(identity.cwd || process.cwd()) === resolve(info.cwd);
    });
    if (!exact || evidence.identitiesByPath.size !== remaining.length) return false;
    this.invalidateCatalogAdmission();
    this.catalogStructuralGeneration += 1;
    this.catalogStructuralIndex = {
      allInfos: remaining,
      ambiguousDiskIDs: this.diskAmbiguousSessionIDs(remaining),
      structureDigest: evidence.digest,
      factsDigest: evidence.factsDigest,
      structuralGeneration: this.catalogStructuralGeneration,
      invalidationGeneration: this.catalogAcquisitionInvalidationGeneration,
    };
    this.catalogFingerprint = this.catalogIdentityFingerprint(remaining);
    return true;
  }

  private async catalogStructureEvidence(): Promise<CatalogStructureEvidence> {
    const limits = this.catalogDiscoveryLimits();
    const catalogRoot = await realpath(resolve(this.catalogDirectory())).catch(() => resolve(this.catalogDirectory()));
    const pending = [catalogRoot];
    const seenDirectories = new Set<string>();
    const candidatePaths = new Set<string>();
    let entriesExamined = 0;
    let traversalBytes = Buffer.byteLength(pending[0]!);
    let complete = true;
    let unstableCanonicalFiles = false;
    while (pending.length > 0) {
      const candidate = pending.pop()!;
      let directory: string;
      try { directory = await realpath(candidate); }
      catch (error) {
        if (!isMissingFilesystemError(error)) complete = false;
        continue;
      }
      if (this.isIgnoredCatalogDirectory(directory, catalogRoot)) continue;
      if (!seenDirectories.add(directory)) continue;
      traversalBytes += Buffer.byteLength(directory);
      if (seenDirectories.size > limits.maximumDirectories
        || traversalBytes > limits.maximumTraversalBytes) this.catalogCapacityExceeded();
      try {
        const entries = await opendir(directory);
        for await (const entry of entries) {
          entriesExamined += 1;
          if (entriesExamined > limits.maximumEntries) this.catalogCapacityExceeded();
          const child = join(directory, entry.name);
          if (entry.isDirectory()) {
            if (this.isIgnoredCatalogDirectory(child, catalogRoot)) continue;
            traversalBytes += Buffer.byteLength(child);
            if (traversalBytes > limits.maximumTraversalBytes) this.catalogCapacityExceeded();
            pending.push(child);
            continue;
          }
          if (!entry.name.endsWith(".jsonl") || (!entry.isFile() && !entry.isSymbolicLink())) continue;
          // Symlinked JSONL is never canonical authority. Following it could
          // import a session outside the configured root or create an alias
          // that changes inode identity between admission and open.
          if (entry.isSymbolicLink()) continue;
          let canonicalPath: string;
          try { canonicalPath = await realpath(child); }
          catch { continue; }
          const fromRoot = relative(catalogRoot, canonicalPath);
          if (fromRoot === ".." || fromRoot.startsWith(`..${sep}`) || isAbsolute(fromRoot)) continue;
          traversalBytes += Buffer.byteLength(canonicalPath);
          if (traversalBytes > limits.maximumTraversalBytes) this.catalogCapacityExceeded();
          candidatePaths.add(canonicalPath);
          if (candidatePaths.size > limits.maximumSessions) this.catalogCapacityExceeded();
        }
      } catch (error) {
        if (error instanceof GatewayError) throw error;
        if (!isMissingFilesystemError(error)) complete = false;
      }
    }

    const paths = [...candidatePaths].sort();
    let remainingHeaderBytes = limits.maximumHeaderBytes;
    const perCandidateHeaderBytes = Math.min(
      limits.maximumHeaderBytesPerFile,
      Math.floor(limits.maximumHeaderBytes / Math.max(1, paths.length)),
    );
    let retainedIdentityBytes = 0;
    const reserveHeaderBytes = (count: number): boolean => {
      if (count > remainingHeaderBytes) return false;
      remainingHeaderBytes -= count;
      return true;
    };
    const refundHeaderBytes = (count: number): void => { remainingHeaderBytes += count; };
    const digest = createHash("sha256");
    const factsDigest = createHash("sha256");
    const identitiesByPath = new Map<string, CatalogHeaderIdentity>();
    digest.update(`count:${paths.length}\n`);
    factsDigest.update(`count:${paths.length}\n`);
    for (let start = 0; start < paths.length; start += limits.normalizationConcurrency) {
      const batchPaths = paths.slice(start, start + limits.normalizationConcurrency);
      const identities = await Promise.all(batchPaths.map(async (path) => {
        try {
          const header = await this.readCatalogHeader(
            path,
            perCandidateHeaderBytes,
            reserveHeaderBytes,
            refundHeaderBytes,
            true,
          );
          if (header.unstable) unstableCanonicalFiles = true;
          const identity = header.identity;
          if (!identity) return undefined;
          return identity.parentSessionPath
            ? { ...identity, parentSessionPath: await this.canonicalSessionPath(identity.parentSessionPath) }
            : identity;
        } catch {
          return undefined;
        }
      }));
      for (let index = 0; index < batchPaths.length; index += 1) {
        const path = batchPaths[index]!;
        let identity = identities[index];
        if (identity) {
          const identityBytes = Buffer.byteLength(JSON.stringify({ path, ...identity }));
          if (retainedIdentityBytes + identityBytes > limits.maximumAcquisitionBytes) identity = undefined;
          else retainedIdentityBytes += identityBytes;
        }
        if (!identity) complete = false;
        digest.update(path).update("\0")
          .update(identity?.id ?? "").update("\0")
          .update(identity?.cwd ?? "").update("\0")
          .update(identity?.fileIdentity ?? "").update("\0")
          .update(identity?.parentSessionPath ?? "").update("\n");
        const liveOwner = identity !== undefined && this.isLiveRuntimeOwnedPath(path, identity.id);
        factsDigest.update(path).update("\0")
          .update(identity?.id ?? "").update("\0")
          .update(identity?.cwd ?? "").update("\0")
          .update(identity?.fileIdentity ?? "").update("\0")
          // A Gateway-owned JSONL may grow while its header is being read. Its
          // inode and identity remain structural authority; cold/unowned files
          // retain size/mtime validation so external rewrites cannot slip by.
          .update(identity ? (liveOwner ? "live-append" : String(identity.size)) : "").update("\0")
          .update(identity ? (liveOwner ? "live-append" : String(identity.mtimeMs)) : "").update("\n");
        if (identity) identitiesByPath.set(path, identity);
      }
    }
    return {
      digest: digest.digest("base64url"),
      factsDigest: factsDigest.digest("base64url"),
      identitiesByPath,
      complete,
      unstableCanonicalFiles,
    };
  }

  private isLiveRuntimeOwnedPath(path: string, sessionID: string): boolean {
    const canonicalPath = resolve(path);
    return [...this.slots.values()].some((slot) => !slot.isDisposed
      && slot.id === sessionID
      && slot.persistedSessionFile !== undefined
      && resolve(slot.persistedSessionFile) === canonicalPath);
  }

  private async readCatalogHeader(
    path: string,
    maximumBytes: number,
    reserveBytes: (count: number) => boolean,
    refundBytes: (count: number) => void,
    allowAppendOnlyLiveOwner = false,
  ): Promise<{ identity?: CatalogHeaderIdentity; unstable?: boolean }> {
    const firstReadLength = Math.min(512, maximumBytes);
    if (!reserveBytes(firstReadLength)) return {};
    let handle: Awaited<ReturnType<typeof open>>;
    try { handle = await open(path, "r"); }
    catch (error) {
      refundBytes(firstReadLength);
      throw error;
    }
    let opened: Awaited<ReturnType<typeof handle.stat>>;
    try { opened = await handle.stat(); }
    catch (error) {
      refundBytes(firstReadLength);
      await handle.close().catch(() => {});
      throw error;
    }
    if (!opened.isFile()) {
      refundBytes(firstReadLength);
      await handle.close();
      return {};
    }
    const fileIdentity = `${opened.dev}:${opened.ino}`;
    if (opened.size === 0) {
      refundBytes(firstReadLength);
      await handle.close();
      return {};
    }
    const finalByte = Buffer.alloc(1);
    const finalRead = await handle.read(finalByte, 0, 1, opened.size - 1);
    if (finalRead.bytesRead !== 1 || finalByte[0] !== 0x0a) {
      refundBytes(firstReadLength);
      await handle.close();
      return { unstable: true };
    }
    const buffer = Buffer.allocUnsafe(maximumBytes);
    const parseHeader = (line: Buffer): CatalogHeaderIdentity | undefined => {
      if (line.length === 0 || !line.toString("utf8").trim()) return undefined;
      let value: unknown;
      try { value = JSON.parse(line.toString("utf8")); }
      catch { return undefined; }
      if (!value || typeof value !== "object") return undefined;
      const record = value as Record<string, unknown>;
      if (record.type !== "session" || typeof record.id !== "string") return undefined;
      return {
        id: record.id,
        cwd: typeof record.cwd === "string" ? record.cwd : "",
        fileIdentity,
        size: opened.size,
        mtimeMs: opened.mtimeMs,
        ...(typeof record.parentSession === "string"
          ? { parentSessionPath: record.parentSession }
          : {}),
      };
    };
    const stableIdentity = async (identity: CatalogHeaderIdentity | undefined): Promise<CatalogHeaderIdentity | undefined> => {
      if (!identity) return undefined;
      const after = await handle.stat();
      const afterPath = await lstat(path);
      const sameFile = after.isFile() && after.dev === opened.dev && after.ino === opened.ino
        && afterPath.isFile() && !afterPath.isSymbolicLink()
        && afterPath.dev === opened.dev && afterPath.ino === opened.ino;
      const unchanged = after.size === opened.size && after.mtimeMs === opened.mtimeMs
        && afterPath.size === opened.size && afterPath.mtimeMs === opened.mtimeMs;
      const appendOnly = allowAppendOnlyLiveOwner
        && this.isLiveRuntimeOwnedPath(path, identity.id)
        && (after.size > opened.size || afterPath.size > opened.size);
      if (!sameFile || (!unchanged && !appendOnly)) return undefined;
      return identity;
    };
    try {
      let bytesReadTotal = 0;
      let lineStart = 0;
      while (bytesReadTotal < maximumBytes) {
        const readLength = Math.min(512, maximumBytes - bytesReadTotal);
        if (bytesReadTotal > 0 && !reserveBytes(readLength)) return {};
        let bytesRead: number;
        try {
          ({ bytesRead } = await handle.read(buffer, bytesReadTotal, readLength, bytesReadTotal));
        } catch (error) {
          refundBytes(readLength);
          throw error;
        }
        refundBytes(readLength - bytesRead);
        if (bytesRead === 0) {
          if (lineStart >= bytesReadTotal) return {};
          const identity = parseHeader(buffer.subarray(lineStart, bytesReadTotal));
          const stable = await stableIdentity(identity);
          return stable ? { identity: stable } : {};
        }
        bytesReadTotal += bytesRead;
        const newline = buffer.indexOf(0x0a, lineStart);
        if (newline >= 0 && newline < bytesReadTotal) {
          const identity = parseHeader(buffer.subarray(lineStart, newline));
          const stable = await stableIdentity(identity);
          return stable ? { identity: stable } : {};
        }
      }
      return {};
    } finally {
      await handle.close();
    }
  }

  private async sessionInfos() {
    const limits = this.catalogDiscoveryLimits();
    const catalogRoot = await realpath(resolve(this.catalogDirectory())).catch(() => resolve(this.catalogDirectory()));
    const pending = [catalogRoot];
    const seen = new Set<string>();
    const sessions: CatalogSessionInfo[] = [];
    let entriesExamined = 0;
    let traversalBytes = Buffer.byteLength(pending[0]!);
    let retainedBytes = 0;
    while (pending.length > 0) {
      const candidate = pending.pop()!;
      let directory: string;
      try { directory = await realpath(candidate); }
      catch (error) {
        if (isMissingFilesystemError(error)) continue;
        throw new GatewayError("busy", "Session catalog directory could not be validated", true);
      }
      if (this.isIgnoredCatalogDirectory(directory, catalogRoot)) continue;
      if (!seen.add(directory)) continue;
      traversalBytes += Buffer.byteLength(directory);
      if (seen.size > limits.maximumDirectories
        || traversalBytes > limits.maximumTraversalBytes) this.catalogCapacityExceeded();

      const files: string[] = [];
      try {
        const entries = await opendir(directory);
        for await (const entry of entries) {
          entriesExamined += 1;
          if (entriesExamined > limits.maximumEntries) this.catalogCapacityExceeded();
          if (entry.isDirectory()) {
            const child = join(directory, entry.name);
            if (this.isIgnoredCatalogDirectory(child, catalogRoot)) continue;
            traversalBytes += Buffer.byteLength(child);
            if (traversalBytes > limits.maximumTraversalBytes) this.catalogCapacityExceeded();
            pending.push(child);
          } else if (entry.name.endsWith(".jsonl") && entry.isFile()) {
            files.push(join(directory, entry.name));
          }
        }
      } catch (error) {
        if (error instanceof GatewayError) throw error;
        if (isMissingFilesystemError(error)) continue;
        throw new GatewayError("busy", "Session catalog directory could not be enumerated", true);
      }

      // RuntimeRegistry owns recursion and uses a bounded metadata scanner here;
      // the SDK list helper also builds an unused transcript-wide search string.
      const discovered = await buildCatalogSessionInfos(files);
      if (sessions.length + discovered.length > limits.maximumSessions) this.catalogCapacityExceeded();
      for (const session of discovered) {
        retainedBytes += Buffer.byteLength(JSON.stringify(session));
        if (retainedBytes > limits.maximumRetainedBytes) this.catalogCapacityExceeded();
        sessions.push(session);
      }
    }

    const normalized = new Array<CatalogSessionInfo>(sessions.length);
    let nextIndex = 0;
    const normalize = async () => {
      while (true) {
        const index = nextIndex;
        nextIndex += 1;
        const session = sessions[index];
        if (!session) return;
        const path = await this.canonicalSessionPath(session.path);
        normalized[index] = {
          ...session,
          path,
          ...(session.parentSessionPath
            ? { parentSessionPath: await this.canonicalSessionPath(session.parentSessionPath) }
            : {}),
        };
      }
    };
    await Promise.all(Array.from(
      { length: Math.min(limits.normalizationConcurrency, sessions.length) },
      normalize,
    ));
    // Overlapping recursive discovery roots may report the same canonical file
    // more than once. Canonical path aliases are one file, not an ID collision.
    return [...new Map(normalized.map((session) => [resolve(session.path), session])).values()];
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

  private async attentionLiveOnlyStillAdmitted(sessionId: string): Promise<boolean> {
    const evidence = await this.catalogStructureEvidence();
    if (!evidence.complete) return false;
    return ![...evidence.identitiesByPath].some(([, identity]) => identity.id === sessionId);
  }

  private async attentionEntryStillAdmitted(entry: CatalogAcquisitionEntry): Promise<boolean> {
    // Refresh the complete bounded header set at commit. This closes the race
    // where an external writer creates a same-ID file after admission without
    // changing Gateway's generation counters.
    const evidence = await this.catalogStructureEvidence();
    if (!evidence.complete) return false;
    const matches = [...evidence.identitiesByPath]
      .filter(([, identity]) => identity.id === entry.id);
    if (matches.length !== 1 || resolve(matches[0]![0]) !== entry.path) return false;
    const identity = matches[0]![1];
    if (identity.fileIdentity !== entry.fileIdentity
      || resolve(identity.cwd || process.cwd()) !== entry.canonicalCwd) return false;
    let metadata: Awaited<ReturnType<typeof lstat>>;
    try { metadata = await lstat(entry.path); }
    catch { return false; }
    if (!metadata.isFile() || metadata.isSymbolicLink()) return false;
    if (entry.fileIdentity !== undefined && `${metadata.dev}:${metadata.ino}` !== entry.fileIdentity) return false;
    // A same-inode rewrite can change the header without changing the catalog
    // generation. Re-read only this bounded header at the commit boundary.
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

  async pageSource(scope: "user" | "all" = "user"): Promise<CatalogPageSource> {
    // Structural materialization is the admission boundary. Live summary and
    // attention overlays are captured synchronously below, after I/O completes,
    // so ordinary heartbeat churn cannot starve catalog reads.
    const materialized = await this.sharedCatalogMaterialization();
    const projectionGeneration = this.catalogProjectionGeneration;
    const generation = `${materialized.listRevision}:${projectionGeneration}:${scope}`;
    const existing = this.catalogPageSources.get(generation)?.deref();
    if (existing) return existing;
    const seeds = this.buildCatalogPageSeeds(materialized.infos, scope, materialized.ambiguousIDs);
    const source = this.createCatalogPageSource(generation, materialized.listRevision, seeds);
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
    structureDigest: string;
    generation: string;
  }> {
    // Capture mutable overlays only after structural I/O has completed. The
    // seed construction is synchronous, making this one immutable cut without
    // rejecting it when another heartbeat arrives during discovery.
    const materialized = await this.sharedCatalogMaterialization();
    const projectionGeneration = this.catalogProjectionGeneration;
    const seeds = this.buildCatalogPageSeeds(materialized.infos, scope, materialized.ambiguousIDs);
    const source = this.createCatalogPageSource(`${materialized.listRevision}:${projectionGeneration}:${scope}`, materialized.listRevision, seeds);
    return {
      infos: materialized.infos,
      sessions: await source.page(0, seeds.length),
      ambiguousIDs: materialized.ambiguousIDs,
      listRevision: materialized.listRevision,
      structureDigest: materialized.structureDigest,
      generation: source.generation,
    };
  }

  private sharedCatalogSessionInfos(refresh = false): Promise<CatalogSessionInfo[]> {
    const key = `${this.catalogStructuralGeneration}:${this.catalogAcquisitionInvalidationGeneration}:${refresh ? `refresh:${++this.catalogEvidenceRefresh}` : "current"}`;
    if (!refresh && this.catalogSessionInfosPromise && this.catalogSessionInfosKey === key) return this.catalogSessionInfosPromise;
    const operation = this.sessionInfos();
    this.catalogSessionInfosPromise = operation;
    this.catalogSessionInfosKey = key;
    void operation.finally(() => {
      if (this.catalogSessionInfosPromise === operation) {
        this.catalogSessionInfosPromise = undefined;
        this.catalogSessionInfosKey = undefined;
      }
    }).catch(() => {});
    return operation;
  }

  private sharedCatalogStructureEvidence(refresh = false): Promise<CatalogStructureEvidence> {
    const generationKey = `${this.catalogStructuralGeneration}:${this.catalogAcquisitionInvalidationGeneration}`;
    const key = refresh ? `${generationKey}:refresh:${++this.catalogEvidenceRefresh}` : generationKey;
    if (this.catalogEvidencePromise && this.catalogEvidenceKey === key) return this.catalogEvidencePromise;
    const operation = this.catalogStructureEvidence();
    this.catalogEvidencePromise = operation;
    this.catalogEvidenceKey = key;
    void operation.finally(() => {
      if (this.catalogEvidencePromise === operation) {
        this.catalogEvidencePromise = undefined;
        this.catalogEvidenceKey = undefined;
      }
    }).catch(() => {});
    return operation;
  }

  private sharedCatalogMaterialization(): Promise<Awaited<ReturnType<RuntimeRegistry["materializeCatalogSnapshot"]>>> {
    const key = `${this.catalogStructuralGeneration}:${this.catalogAcquisitionInvalidationGeneration}`;
    if (this.catalogMaterializationPromise && this.catalogMaterializationKey === key) {
      return this.catalogMaterializationPromise;
    }
    const operation = this.materializeCatalogSnapshot();
    const settled = operation.then((value) => {
      if (this.catalogMaterializationKey === key) {
        this.catalogMaterializationPromise = undefined;
        this.catalogMaterializationKey = undefined;
      }
      return value;
    }, (error) => {
      if (this.catalogMaterializationKey === key) {
        this.catalogMaterializationPromise = undefined;
        this.catalogMaterializationKey = undefined;
      }
      throw error;
    });
    this.catalogMaterializationPromise = settled;
    this.catalogMaterializationKey = key;
    return settled;
  }

  private async loadDurableCatalogIndex(): Promise<void> {
    const structuralGeneration = this.catalogStructuralGeneration;
    const invalidationGeneration = this.catalogAcquisitionInvalidationGeneration;
    const before = await this.sharedCatalogStructureEvidence();
    if (!before.complete) return;
    const candidates = [...before.identitiesByPath].map(([path, identity]) => ({
      path, id: identity.id, cwd: identity.cwd, fileIdentity: identity.fileIdentity,
      size: identity.size, mtimeMs: identity.mtimeMs,
    }));
    // reconcile admits and reads the durable document once. A missing/corrupt
    // document deliberately falls through to the canonical first-cut scan.
    const rows = await this.catalogMetadataIndex.reconcile(
      this.catalogDirectory(),
      candidates,
      async (candidate) => {
        const info = await buildCatalogSessionInfo(candidate.path);
        if (!info || info.id !== candidate.id || info.cwd !== candidate.cwd) return undefined;
        return {
          id: info.id, path: info.path, cwd: info.cwd,
          ...(info.parentSessionPath ? { parentSessionPath: info.parentSessionPath } : {}),
          ...(info.name ? { name: info.name } : {}),
          firstMessage: info.firstMessage,
          createdAt: info.created.toISOString(), updatedAt: info.modified.toISOString(),
          messageCount: info.messageCount,
        };
      },
    );
    if (!rows) return;
    const after = await this.sharedCatalogStructureEvidence(true);
    const rowsMatchAfterFacts = rows.length === after.identitiesByPath.size
      && rows.every((row) => {
        const identity = after.identitiesByPath.get(resolve(row.path));
        return identity?.id === row.id && identity.cwd === row.cwd
          && identity.fileIdentity === row.fileIdentity
          && identity.size === row.size && identity.mtimeMs === row.mtimeMs;
      });
    if (structuralGeneration !== this.catalogStructuralGeneration
      || invalidationGeneration !== this.catalogAcquisitionInvalidationGeneration
      || !after.complete || after.digest !== before.digest || !rowsMatchAfterFacts) return;
    const infos: CatalogSessionInfo[] = rows.map((row) => ({
      path: row.path,
      id: row.id,
      cwd: row.cwd,
      ...(row.parentSessionPath ? { parentSessionPath: row.parentSessionPath } : {}),
      ...(row.name ? { name: row.name } : {}),
      created: new Date(row.createdAt),
      modified: new Date(row.updatedAt),
      messageCount: row.messageCount,
      firstMessage: row.firstMessage,
      fileIdentity: row.fileIdentity,
    }));
    this.catalogStructuralIndex = {
      allInfos: infos,
      ambiguousDiskIDs: this.diskAmbiguousSessionIDs(infos),
      structureDigest: before.digest,
      factsDigest: after.factsDigest,
      structuralGeneration,
      invalidationGeneration,
    };
    // A durable generation can differ from the admission cached before this
    // filesystem cut (for example, a newly duplicated ID). Force acquisition
    // to rebuild from the exact index rather than pairing stale membership
    // with the freshly published rows.
    this.catalogAcquisitionAdmission = undefined;
  }

  private async persistDurableCatalogIndex(
    infos: readonly CatalogSessionInfo[],
    structuralGeneration: number,
    invalidationGeneration: number,
  ): Promise<void> {
    const rows: CatalogMetadataIndexRow[] = [];
    for (const info of infos) {
      const summary: CatalogMetadataIndexSummary = {
        id: info.id,
        path: info.path,
        cwd: info.cwd,
        ...(info.parentSessionPath ? { parentSessionPath: info.parentSessionPath } : {}),
        ...(info.name ? { name: info.name } : {}),
        firstMessage: info.firstMessage,
        createdAt: info.created.toISOString(),
        updatedAt: info.modified.toISOString(),
        messageCount: info.messageCount,
      };
      const row = await this.catalogMetadataIndex.entryFromSummary(summary);
      if (!row) return;
      if (info.fileIdentity !== undefined) row.fileIdentity = info.fileIdentity;
      rows.push(row);
    }
    if (structuralGeneration !== this.catalogStructuralGeneration
      || invalidationGeneration !== this.catalogAcquisitionInvalidationGeneration) return;
    await this.catalogMetadataIndex.save(this.catalogDirectory(), rows).catch(() => {});
  }

  private async materializeCatalogSnapshot(): Promise<{
    infos: CatalogSessionInfo[];
    ambiguousIDs: ReadonlySet<string>;
    listRevision: number;
    structureDigest: string;
  }> {
    let cached = await this.validatedStructuralIndex();
    if (!cached) {
      await this.loadDurableCatalogIndex();
      cached = await this.validatedStructuralIndex();
    }
    if (cached) {
      const ambiguousIDs = this.dynamicAmbiguousSessionIDs(cached);
      const infos = cached.allInfos.filter((session) => !ambiguousIDs.has(session.id));
      this.ambiguousSessionIds = ambiguousIDs;
      return {
        infos: [...infos],
        ambiguousIDs,
        listRevision: this.revision,
        structureDigest: cached.structureDigest,
      };
    }

    let materialized = await this.timedStage("catalog.scan", () => this.scanCatalogMaterialization());
    if (!materialized.stable) {
      materialized = await this.timedStage("catalog.scan-retry", () => this.scanCatalogMaterialization());
    }
    if (!materialized.stable) {
      await this.catalogAcquisitionMutex.run(() => { this.catalogAcquisitionAdmission = undefined; });
      throw new GatewayError("busy", "Session catalog changed during discovery", true);
    }

    const admitted = await this.publishCatalogAcquisition(
      materialized.after,
      materialized.invalidationGeneration,
    );
    if (materialized.invalidationGeneration !== this.catalogAcquisitionInvalidationGeneration
        || materialized.structuralGeneration !== this.catalogStructuralGeneration) {
      if (admitted) this.catalogAcquisitionAdmission = undefined;
      throw new GatewayError("busy", "Session catalog changed during publication", true);
    }
    const index: CatalogStructuralIndex = {
      allInfos: materialized.allInfos,
      ambiguousDiskIDs: materialized.ambiguousDiskIDs,
      structureDigest: materialized.after.digest,
      factsDigest: materialized.after.factsDigest,
      structuralGeneration: materialized.structuralGeneration,
      invalidationGeneration: materialized.invalidationGeneration,
    };
    const indexIsExact = materialized.after.complete
      && materialized.after.identitiesByPath.size === materialized.allInfos.length
      && materialized.allInfos.every((info) => {
        const identity = materialized.after.identitiesByPath.get(resolve(info.path));
        return identity?.id === info.id && resolve(identity.cwd || process.cwd()) === resolve(info.cwd);
      });
    this.catalogStructuralIndex = indexIsExact ? index : undefined;
    const ambiguousIDs = this.dynamicAmbiguousSessionIDs(index);
    const infos = index.allInfos.filter((session) => !ambiguousIDs.has(session.id));
    if (indexIsExact && admitted && this.catalogAcquisitionAdmission) {
      this.catalogAcquisitionAdmission = {
        ...this.catalogAcquisitionAdmission,
        indexedStructuralGeneration: index.structuralGeneration,
      };
    }
    // No await may separate the final generation confirmation from publication
    // of catalog identity and its matching revision.
    this.updateCatalogIdentity(materialized.allInfos, ambiguousIDs);
    // Persistence is acceleration only. Failure leaves the in-memory canonical
    // projection usable and is reported by the index owner without affecting
    // authority or list success.
    void this.persistDurableCatalogIndex(
      materialized.allInfos,
      materialized.structuralGeneration,
      materialized.invalidationGeneration,
    ).catch(() => {});
    return {
      infos: [...infos],
      ambiguousIDs,
      listRevision: this.revision,
      structureDigest: materialized.after.digest,
    };
  }

  private async scanCatalogMaterialization(): Promise<{
    allInfos: CatalogSessionInfo[];
    ambiguousDiskIDs: Set<string>;
    after: CatalogStructureEvidence;
    invalidationGeneration: number;
    structuralGeneration: number;
    stable: boolean;
  }> {
    const invalidationGeneration = this.catalogAcquisitionInvalidationGeneration;
    const structuralGeneration = this.catalogStructuralGeneration;
    const before = await this.timedStage("catalog.validate.before", () => this.sharedCatalogStructureEvidence());
    const discoveredInfos = await this.timedStage("catalog.metadata-materialize", () => this.sharedCatalogSessionInfos());
    const after = await this.timedStage("catalog.validate.after", () => this.sharedCatalogStructureEvidence(true));
    const allInfos = this.withCatalogEvidence(discoveredInfos, after);
    const ambiguousDiskIDs = this.diskAmbiguousSessionIDs(allInfos);
    return {
      allInfos,
      ambiguousDiskIDs,
      after,
      invalidationGeneration,
      structuralGeneration,
      stable: invalidationGeneration === this.catalogAcquisitionInvalidationGeneration
        && structuralGeneration === this.catalogStructuralGeneration
        && !before.unstableCanonicalFiles && !after.unstableCanonicalFiles
        && before.digest === after.digest
        && before.factsDigest === after.factsDigest,
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

  private updateCatalogIdentity(infos: CatalogSessionInfo[], ambiguousIDs: Set<string>): void {
    const fingerprint = this.catalogIdentityFingerprint(infos);
    if (this.catalogFingerprint === undefined) this.catalogFingerprint = fingerprint;
    else if (this.catalogFingerprint !== fingerprint) {
      this.catalogFingerprint = fingerprint;
      this.revision += 1;
    }
    this.ambiguousSessionIds = ambiguousIDs;
  }

  private withCatalogEvidence(
    sessions: readonly CatalogSessionInfo[],
    evidence: CatalogStructureEvidence,
  ): CatalogSessionInfo[] {
    return sessions.map((session) => {
      const identity = evidence.identitiesByPath.get(resolve(session.path));
      if (identity?.id !== session.id) return session;
      return { ...session, fileIdentity: identity.fileIdentity };
    });
  }

  private delegatedTopologyParentPath(sessionPath: string, catalogRoot: string): string | undefined {
    const resolvedPath = resolve(sessionPath);
    const fromCatalog = relative(catalogRoot, resolvedPath);
    if (fromCatalog === "" || fromCatalog === ".." || fromCatalog.startsWith(`..${sep}`)
      || isAbsolute(fromCatalog) || !resolvedPath.endsWith(".jsonl")) return undefined;

    const containingDirectory = dirname(resolvedPath);
    let expectedParent: string | undefined;
    if (basename(containingDirectory) === "forks" && basename(resolvedPath) !== ".jsonl") {
      expectedParent = resolve(`${dirname(containingDirectory)}.jsonl`);
    } else if (basename(resolvedPath) === "session.jsonl"
      && SUBAGENT_RUN_DIRECTORY.test(basename(containingDirectory))) {
      const producerDirectory = dirname(containingDirectory);
      const producer = basename(producerDirectory);
      if (producer && producer !== "forks") expectedParent = resolve(`${dirname(producerDirectory)}.jsonl`);
    }
    if (!expectedParent) return undefined;
    const parentFromCatalog = relative(catalogRoot, expectedParent);
    return parentFromCatalog !== "" && parentFromCatalog !== ".."
      && !parentFromCatalog.startsWith(`..${sep}`) && !isAbsolute(parentFromCatalog)
      ? expectedParent : undefined;
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
      const expectedParentPath = this.delegatedTopologyParentPath(sessionPath, catalogRoot);
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
    structureDigest: string,
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
    return { entriesByID, ambiguousIDs: resolvedAmbiguousIDs, structureDigest };
  }

  private async buildCatalogAcquisition(
    evidence: CatalogStructureEvidence,
  ): Promise<CatalogAcquisitionResolution> {
    if (!evidence.complete) {
      throw new GatewayError("busy", "Session catalog headers could not be validated", true);
    }
    const identities = [...evidence.identitiesByPath].map(([path, identity]) => ({ path, ...identity }));
    const counts = new Map<string, number>();
    for (const identity of identities) counts.set(identity.id, (counts.get(identity.id) ?? 0) + 1);
    const ambiguousIDs = new Set(
      [...counts].filter(([, count]) => count > 1).map(([id]) => id),
    );
    return this.buildCatalogAcquisitionFromSessions(
      identities.filter((identity) => !ambiguousIDs.has(identity.id)),
      ambiguousIDs,
      evidence.digest,
    );
  }

  private async publishCatalogAcquisition(
    evidence: CatalogStructureEvidence,
    invalidationGeneration: number,
  ): Promise<boolean> {
    return this.catalogAcquisitionMutex.run(async () => {
      if (invalidationGeneration !== this.catalogAcquisitionInvalidationGeneration) return false;
      if (!evidence.complete) return false;
      const resolution = await this.buildCatalogAcquisition(evidence);
      if (invalidationGeneration !== this.catalogAcquisitionInvalidationGeneration) return false;
      this.catalogAcquisitionAdmission = { ...resolution, invalidationGeneration };
      return true;
    });
  }

  private async catalogAcquisition(): Promise<CatalogAcquisitionResolution> {
    const key = `${this.catalogStructuralGeneration}:${this.catalogAcquisitionInvalidationGeneration}`;
    if (this.catalogAcquisitionPromise && this.catalogAcquisitionPromiseKey === key) {
      return this.catalogAcquisitionPromise;
    }
    const operation = this.resolveCatalogAcquisition();
    const settled = operation.then((value) => {
      if (this.catalogAcquisitionPromiseKey === key) {
        this.catalogAcquisitionPromise = undefined;
        this.catalogAcquisitionPromiseKey = undefined;
      }
      return value;
    }, (error) => {
      if (this.catalogAcquisitionPromiseKey === key) {
        this.catalogAcquisitionPromise = undefined;
        this.catalogAcquisitionPromiseKey = undefined;
      }
      throw error;
    });
    this.catalogAcquisitionPromise = settled;
    this.catalogAcquisitionPromiseKey = key;
    return settled;
  }

  private async resolveCatalogAcquisition(): Promise<CatalogAcquisitionResolution> {
    const candidateIndex = this.catalogStructuralIndex;
    const cachedIndex = candidateIndex?.structuralGeneration === this.catalogStructuralGeneration
      ? candidateIndex : undefined;
    const cachedAdmission = this.catalogAcquisitionAdmission;
    if (cachedAdmission?.invalidationGeneration === this.catalogAcquisitionInvalidationGeneration
        && cachedIndex) {
      const validated = await this.validatedStructuralIndex();
      if (validated) {
        return {
          ...cachedAdmission,
          indexedStructuralGeneration: cachedIndex.structuralGeneration,
        };
      }
    }
    if (cachedIndex && cachedIndex.structuralGeneration === this.catalogStructuralGeneration) {
      const indexed = await this.catalogAcquisitionMutex.run(async () => {
        const invalidationGeneration = this.catalogAcquisitionInvalidationGeneration;
        const structuralGeneration = this.catalogStructuralGeneration;
        const current = this.catalogAcquisitionAdmission;
        if (current?.invalidationGeneration === invalidationGeneration) return current;
        const ambiguousIDs = this.dynamicAmbiguousSessionIDs(cachedIndex);
        const resolution = await this.buildCatalogAcquisitionFromSessions(
          cachedIndex.allInfos.filter((session) => !ambiguousIDs.has(session.id)),
          ambiguousIDs,
          cachedIndex.structureDigest,
        );
        if (invalidationGeneration !== this.catalogAcquisitionInvalidationGeneration
            || structuralGeneration !== this.catalogStructuralGeneration) {
          throw new GatewayError("busy", "Session catalog changed during acquisition", true);
        }
        const admission: CatalogAcquisitionAdmission = {
          ...resolution,
          indexedStructuralGeneration: structuralGeneration,
          invalidationGeneration,
        };
        this.catalogAcquisitionAdmission = admission;
        return admission;
      });
      return indexed;
    }

    const lightweight = await this.catalogAcquisitionMutex.run(async () => {
      for (let attempt = 0; attempt < 2; attempt += 1) {
        const invalidationGeneration = this.catalogAcquisitionInvalidationGeneration;
        const evidence = await this.sharedCatalogStructureEvidence();
        if (invalidationGeneration !== this.catalogAcquisitionInvalidationGeneration) continue;
        if (!evidence.complete) return undefined;
        const admission = this.catalogAcquisitionAdmission;
        if (admission
          && admission.invalidationGeneration === invalidationGeneration
          && admission.structureDigest === evidence.digest) {
          return admission;
        }
        const resolution = await this.buildCatalogAcquisition(evidence);
        if (invalidationGeneration !== this.catalogAcquisitionInvalidationGeneration) continue;
        this.catalogAcquisitionAdmission = { ...resolution, invalidationGeneration };
        return resolution;
      }
      throw new GatewayError("busy", "Session catalog changed during acquisition", true);
    });
    if (lightweight) return lightweight;
    return this.fallbackCatalogAcquisition();
  }

  private sdkCatalogIdentityFingerprint(infos: readonly CatalogSessionInfo[]): string {
    const delegated = this.delegatedSessionTopologies(infos);
    const records = infos.map((session) => JSON.stringify([
      resolve(session.path),
      session.id,
      session.cwd,
      session.fileIdentity ?? "",
      session.parentSessionPath ? resolve(session.parentSessionPath) : "",
      delegated.has(resolve(session.path)),
    ])).sort();
    const digest = createHash("sha256");
    for (const record of records) digest.update(record).update("\n");
    return digest.digest("base64url");
  }

  private async fallbackCatalogAcquisition(): Promise<CatalogAcquisitionResolution> {
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const invalidationGeneration = this.catalogAcquisitionInvalidationGeneration;
      const before = await this.sharedCatalogStructureEvidence();
      const firstInfos = this.withCatalogEvidence(await this.sharedCatalogSessionInfos(), before);
      const firstFingerprint = this.sdkCatalogIdentityFingerprint(firstInfos);
      const discoveredInfos = await this.sessionInfos();
      const after = await this.sharedCatalogStructureEvidence(true);
      const allInfos = this.withCatalogEvidence(discoveredInfos, after);
      const identityFingerprint = this.sdkCatalogIdentityFingerprint(allInfos);
      if (firstFingerprint !== identityFingerprint) continue;
      const counts = new Map<string, number>();
      for (const session of allInfos) counts.set(session.id, (counts.get(session.id) ?? 0) + 1);
      const ambiguousIDs = new Set(
        [...counts].filter(([, count]) => count > 1).map(([id]) => id),
      );
      const resolution = await this.buildCatalogAcquisitionFromSessions(
        allInfos.filter((session) => !ambiguousIDs.has(session.id)),
        ambiguousIDs,
        before.digest,
      );
      if (invalidationGeneration === this.catalogAcquisitionInvalidationGeneration
        && before.digest === after.digest) {
        return {
          ...resolution,
          fallbackIdentityFingerprint: identityFingerprint,
          fallbackInvalidationGeneration: invalidationGeneration,
        };
      }
    }
    throw new GatewayError("busy", "Session catalog changed during acquisition", true);
  }

  private buildCatalogPageSeeds(
    sessions: readonly CatalogSessionInfo[],
    scope: "user" | "all",
    ambiguousIDs: ReadonlySet<string>,
  ): CatalogPageSeed[] {
    const pathToId = new Map(sessions.map((session) => [resolve(session.path), session.id]));
    const delegated = this.delegatedSessionTopologies(sessions);
    const persistedIDs = new Set(sessions.map((session) => session.id));
    const seeds: CatalogPageSeed[] = [];
    for (const session of sessions) {
      const topology = delegated.get(resolve(session.path));
      if (topology?.contradictoryHeader) continue;
      const kind: SessionSummary["kind"] = topology ? "subagent" : "user";
      if (scope === "user" && kind === "subagent") continue;
      const headerParentSessionId = session.parentSessionPath ? pathToId.get(resolve(session.parentSessionPath)) : undefined;
      const parentSessionId = topology?.parentSessionId ?? headerParentSessionId;
      const latest = this.latestSummaries.get(session.id);
      const name = latest?.name ?? session.name;
      seeds.push({
        id: session.id,
        ...(name ? { name } : {}),
        cwd: session.cwd,
        kind,
        ...(parentSessionId ? { parentSessionId } : {}),
        createdAt: session.created.toISOString(),
        updatedAt: latest?.updatedAt ?? session.modified.toISOString(),
        ...(latest?.activeSince ? { activeSince: latest.activeSince } : {}),
        messageCount: latest?.messageCount ?? session.messageCount,
        firstMessage: latest?.firstMessage ?? session.firstMessage,
        phase: latest?.phase ?? (this.slots.get(session.id) ? this.slots.get(session.id)!.catalogPhase : this.interrupted.has(session.id) ? "interrupted" : "idle"),
        summaryRevision: latest?.summaryRevision ?? 0,
        attention: this.attention.projection(session.id),
      });
    }
    if (scope === "all" || scope === "user") {
      for (const [id, slot] of this.slots) {
        if (slot.isDisposed || persistedIDs.has(id) || ambiguousIDs.has(id)) continue;
        const latest = this.latestSummaries.get(id);
        seeds.push({
          id,
          ...(latest?.name ? { name: latest.name } : {}),
          cwd: slot.cwd,
          kind: "user",
          createdAt: slot.catalogCreatedAt,
          updatedAt: latest?.updatedAt ?? slot.catalogCreatedAt,
          ...(latest?.activeSince ? { activeSince: latest.activeSince } : {}),
          messageCount: latest?.messageCount ?? 0,
          firstMessage: latest?.firstMessage ?? "",
          phase: latest?.phase ?? slot.catalogPhase,
          summaryRevision: latest?.summaryRevision ?? 0,
          attention: this.attention.projection(id),
        });
      }
    }
    return orderDashboardSessions(seeds);
  }

  private createCatalogPageSource(generation: string, listRevision: number, seeds: readonly CatalogPageSeed[]): CatalogPageSource {
    const uniqueIDs = new Set(seeds.map((seed) => seed.id));
    if (uniqueIDs.size !== seeds.length) {
      throw new GatewayError("busy", "Session catalog identity is ambiguous", true);
    }
    const compactByteEstimate = Buffer.byteLength(generation) + 64 + seeds.reduce((total, seed) => total
      + Buffer.byteLength(seed.id) + Buffer.byteLength(seed.cwd) + Buffer.byteLength(seed.kind)
      + Buffer.byteLength(seed.createdAt) + Buffer.byteLength(seed.updatedAt)
      + Buffer.byteLength(seed.firstMessage) + Buffer.byteLength(seed.phase)
      + (seed.activeSince ? Buffer.byteLength(seed.activeSince) : 0)
      + (seed.name ? Buffer.byteLength(seed.name) : 0)
      + (seed.parentSessionId ? Buffer.byteLength(seed.parentSessionId) : 0)
      // Object/reference, number, and boolean storage for the seed and captured
      // summary/attention revision fields. String payloads are counted above.
      + 160, 0);
    return Object.freeze({
      generation, listRevision, count: seeds.length, compactByteEstimate,
      page: async (offset: number, limit: number) => seeds.slice(offset, offset + limit).map((seed) => ({
        id: seed.id,
        ...(seed.name ? { name: seed.name } : {}),
        cwd: seed.cwd,
        kind: seed.kind,
        ...(seed.parentSessionId ? { parentSessionId: seed.parentSessionId } : {}),
        createdAt: seed.createdAt,
        updatedAt: seed.updatedAt,
        ...(seed.activeSince ? { activeSince: seed.activeSince } : {}),
        messageCount: seed.messageCount,
        firstMessage: seed.firstMessage,
        phase: seed.phase,
        summaryRevision: seed.summaryRevision,
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

  async create(cwdInput: string): Promise<RuntimeSlot> {
    const finishAdmission = this.beginSlotAdmission();
    let reserved = false;
    let slot: RuntimeSlot | undefined;
    try {
      const trust = await this.timedStage(
        "session.create.trust",
        () => this.options.trust.requireResolved(cwdInput),
      );
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
      slot = await this.timedStage(
        "session.create.runtime",
        () => RuntimeSlot.create(manager, this.dependencies(), this.hooks(), false),
      );
      await this.mutex.run(() => {
        if (this.trustReloadProjects.has(trust.cwd)) {
          throw new GatewayError("busy", "Session creation was retired before publication", true);
        }
        if (this.slots.has(manager.getSessionId())) {
          throw new GatewayError("conflict", "Replacement session is already active");
        }
        this.reservedSlotStarts = Math.max(0, this.reservedSlotStarts - 1);
        reserved = false;
        this.slots.set(manager.getSessionId(), slot!);
        this.invalidateCatalogAdmission();
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
  ): Promise<ReadOnlySubagentAdmission> {
    assertProcessSessionRef(childSessionRef);
    const acquisition = await this.catalogAcquisition();
    this.requireUnambiguousSessionId(expectedParentSessionId, acquisition.ambiguousIDs);
    this.requireUnambiguousSessionId(childSessionRef, acquisition.ambiguousIDs);
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
  ): Promise<TranscriptPage & { revision: string; fileIdentity: string }> {
    const admitted = await this.resolveReadOnlySubagentPath(
      childSessionRef,
      path,
      expectedParentSessionId,
      expectedProcessId,
      expectedRunId,
    );
    if (admitted.path !== path || (expectedFileIdentity !== undefined && admitted.fileIdentity !== expectedFileIdentity)) {
      throw new GatewayError("conflict", "Subagent session file was replaced", true);
    }
    const handle = await open(admitted.path, "r");
    try {
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
      const parsed = await readOpenedSession(handle, metadata.size);
      if (!parsed || parsed.sessionId !== childSessionRef) {
        throw new GatewayError("conflict", "Subagent session identity changed", true);
      }
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
        .update(`${childSessionRef}\0${metadata.dev}\0${metadata.ino}\0${metadata.size}\0${metadata.mtimeMs}\0${leafEntryId ?? ""}`)
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

  async acquire(sessionId: string): Promise<RuntimeSlot> {
    this.assertSlotAdmissionOpen();
    const existing = this.slots.get(sessionId);
    if (existing && !existing.isDisposed && !this.ambiguousSessionIds.has(sessionId)) {
      const eviction = this.idleEvictions.get(sessionId);
      if (eviction?.slot === existing && eviction.committed && eviction.completion) {
        await eviction.completion;
        return this.acquire(sessionId);
      }
      this.cancelIdleEviction(sessionId, existing);
      existing.touch();
      return existing;
    }
    const finishAdmission = this.beginSlotAdmission();
    try {
      return await this.acquireMissing(sessionId);
    } finally {
      finishAdmission();
    }
  }

  private async acquireMissing(sessionId: string): Promise<RuntimeSlot> {
    const alreadyStarting = this.pendingSlotStarts.get(sessionId);
    if (alreadyStarting) return alreadyStarting;
    const existing = this.slots.get(sessionId);
    const acquisition = await this.timedStage(
      "session.open.catalog",
      () => this.catalogAcquisition(),
    );
    this.requireUnambiguousSessionId(sessionId, acquisition.ambiguousIDs);
    const entry = acquisition.entriesByID.get(sessionId);
    if (existing && !existing.isDisposed) {
      if (entry?.structuralSubagent) {
        throw new GatewayError("conflict", "Subagent sessions are informational and remain owned by their originating runtime");
      }
      existing.touch();
      return existing;
    }
    if (!entry) throw new GatewayError("not_found", "Tron session was not found");
    if (entry.structuralSubagent) {
      throw new GatewayError("conflict", "Subagent sessions are informational and remain owned by their originating runtime");
    }
    const selectedAcquisitionGeneration = this.catalogAcquisitionInvalidationGeneration;
    const selected = await this.mutex.run(() => {
      let raced = this.slots.get(sessionId);
      if (raced?.isDisposed) {
        if (this.slots.get(sessionId) === raced) this.slots.delete(sessionId);
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
      if (pending) return { operation: pending };
      this.assertSlotAdmissionOpen();
      this.requireLiveSlotCapacity();
      this.reservedSlotStarts += 1;
      const operation = this.startAcquiredSlot(
        sessionId,
        entry,
        acquisition,
        selectedAcquisitionGeneration,
      );
      this.pendingSlotStarts.set(sessionId, operation);
      return { operation };
    });
    return selected.operation;
  }

  private async startAcquiredSlot(
    sessionId: string,
    entry: CatalogAcquisitionEntry,
    acquisition: CatalogAcquisitionResolution,
    selectedAcquisitionGeneration: number,
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
      let manager: SessionManager;
      try {
        manager = await this.timedStage(
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
      if (acquisition.indexedStructuralGeneration !== undefined) {
        const indexed = this.catalogStructuralIndex;
        const validated = await this.sharedCatalogStructureEvidence(true);
        if (acquisition.indexedStructuralGeneration !== this.catalogStructuralGeneration
            || indexed?.structuralGeneration !== acquisition.indexedStructuralGeneration
            || !validated.complete
            || validated.digest !== indexed.structureDigest) {
          if (this.catalogStructuralIndex === indexed) this.invalidateCatalogAcquisition();
          throw new GatewayError("busy", "Session catalog changed while opening the session", true);
        }
      } else if (acquisition.fallbackIdentityFingerprint !== undefined) {
        const invalidationGeneration = acquisition.fallbackInvalidationGeneration;
        if (invalidationGeneration === undefined
          || invalidationGeneration !== this.catalogAcquisitionInvalidationGeneration) {
          throw new GatewayError("busy", "Session catalog changed while opening the session", true);
        }
        const finalEvidence = await this.sharedCatalogStructureEvidence(true);
        const finalInfos = this.withCatalogEvidence(await this.sessionInfos(), finalEvidence);
        if (invalidationGeneration !== this.catalogAcquisitionInvalidationGeneration
          || this.sdkCatalogIdentityFingerprint(finalInfos) !== acquisition.fallbackIdentityFingerprint) {
          throw new GatewayError("busy", "Session catalog changed while opening the session", true);
        }
      } else {
        const validated = await this.catalogStructureEvidence();
        if (validated.digest !== acquisition.structureDigest) {
          throw new GatewayError("busy", "Session catalog changed while opening the session", true);
        }
      }
      if (selectedAcquisitionGeneration !== this.catalogAcquisitionInvalidationGeneration) {
        throw new GatewayError("busy", "Session catalog changed while opening the session", true);
      }
      slot = await this.timedStage(
        "session.open.runtime",
        () => RuntimeSlot.create(
          manager,
          this.dependencies(),
          this.hooks(),
          this.interrupted.has(sessionId),
        ),
      );
      await this.mutex.run(() => {
        if (selectedAcquisitionGeneration !== this.catalogAcquisitionInvalidationGeneration
            || this.trustReloadProjects.has(entry.canonicalCwd)) {
          throw new GatewayError("busy", "Session runtime start was retired before publication", true);
        }
        const ambiguous = this.catalogStructuralIndex
          ? this.dynamicAmbiguousSessionIDs(this.catalogStructuralIndex)
          : this.ambiguousSessionIds;
        this.requireUnambiguousSessionId(sessionId, ambiguous);
        const raced = this.slots.get(sessionId);
        if (raced && raced !== slot && !raced.isDisposed) {
          throw new GatewayError("conflict", "Replacement session is already active", true);
        }
        this.reservedSlotStarts = Math.max(0, this.reservedSlotStarts - 1);
        reservationReleased = true;
        this.slots.set(sessionId, slot!);
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
        }
      });
    }
  }

  async importFromJsonl(path: string, cwdInput: string): Promise<RuntimeSlot> {
    const finishAdmission = this.beginSlotAdmission();
    try {
      const trust = await this.options.trust.requireResolved(cwdInput);
      return await this.mutex.run(async () => {
        this.assertSlotAdmissionOpen();
        if (this.trustReloadProjects.has(trust.cwd)) {
          throw new GatewayError("busy", "Project trust is being reconfigured", true);
        }
        this.requireLiveSlotCapacity();
        const manager = SessionManager.inMemory(trust.cwd);
        const slot = await RuntimeSlot.create(manager, this.dependencies(), this.hooks(), false);
        this.slots.set(slot.id, slot);
        try {
          await slot.importFromJsonl(path, trust.cwd);
          this.slots.set(slot.id, slot);
          this.invalidateCatalogAcquisition();
          this.revision += 1;
          this.options.sessionListChanged();
          return slot;
        } catch (error) {
          this.slots.delete(slot.id);
          await slot.dispose().catch(() => {});
          throw error;
        }
      });
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

  async commitProjectReload(cwdInput: string): Promise<void> {
    const cwd = await this.options.trust.canonicalDirectory(cwdInput);
    await this.mutex.run(() => {
      const slots = [...this.slots.values()].filter((slot) => slot.cwd === cwd);
      slots.forEach((slot) => slot.commitReload());
      this.trustReloadProjects.delete(cwd);
    });
  }

  async delete(sessionId: string): Promise<void> {
    await this.attentionLane.run(async () => {
      await this.flushPendingAttentionRemovals();
      if (this.deletingSessionIds.has(sessionId)) throw new GatewayError("busy", "Session deletion is already in progress", true);
      this.deletingSessionIds.add(sessionId);
    });
    let deleted = false;
    try {
      await this.mutex.run(async () => {
        // Deletion needs structural identity and ownership, not a mutable
        // presentation projection. Acquisition admission remains hardened by
        // exact path/inode and is revalidated by removeCanonicalCatalogFile.
        // Take a fresh bounded structural cut rather than trusting a cached
        // admission that another client may have populated before a duplicate
        // or replacement appeared on disk.
        const evidence = await this.catalogStructureEvidence();
        const acquisition = await this.buildCatalogAcquisition(evidence);
        this.requireUnambiguousSessionId(sessionId, acquisition.ambiguousIDs);
        const entry = acquisition.entriesByID.get(sessionId);
        const slot = this.slots.get(sessionId);
        if (!entry && (!slot || slot.persistedSessionFile !== undefined)) {
          throw new GatewayError("not_found", "Tron session was removed before it could be deleted");
        }
        if (entry?.structuralSubagent) {
          throw new GatewayError("conflict", "Delete the originating user session instead of mutating its runtime-owned subagent session");
        }
        const cwd = entry?.cwd ?? slot?.cwd;
        if (!cwd) throw new GatewayError("not_found", "Tron session was not found");
        if (await this.projectTrustReloading(cwd)) {
          throw new GatewayError("busy", "Project trust is being reconfigured", true);
        }
        if (slot?.isBusy) throw new GatewayError("busy", "Stop the active session before deleting it");
        this.cancelIdleEviction(sessionId, slot);
        if (slot) await slot.dispose();
        this.slots.delete(sessionId);
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
            acquisition.structureDigest,
          );
          if (!(await this.removeIndexedCatalogFile(entry.path))) this.invalidateCatalogAcquisition();
        } else {
          this.invalidateCatalogAdmission();
        }
        this.revision += 1;
        this.options.sessionListChanged();
        deleted = true;
      });
    } finally {
      await this.attentionLane.run(async () => {
        if (deleted) {
          try {
            await this.attention.remove(sessionId);
          } catch {
            this.pendingAttentionRemovals.add(sessionId);
          }
        }
        this.deletingSessionIds.delete(sessionId);
      });
    }
  }

  private async removeCanonicalCatalogFile(
    path: string,
    expectedSessionId: string,
    expectedFileIdentity: string | undefined,
    admittedStructureDigest: string,
  ): Promise<void> {
    if (!expectedFileIdentity) {
      throw new GatewayError("busy", "Session file identity is unavailable for deletion", true);
    }

    // Deletion is the only catalog mutation committed from a prior row
    // admission. Rebuild the bounded structural classification at the commit
    // boundary so a newly created parent, duplicate ID, or topology change
    // cannot make a stale user admission destructive.
    const evidence = await this.catalogStructureEvidence();
    if (!evidence.complete || evidence.digest !== admittedStructureDigest) {
      throw new GatewayError("busy", "Session catalog changed before deletion", true);
    }
    const acquisition = await this.buildCatalogAcquisition(evidence);
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

  private requireLiveSlotCapacity(): void {
    const maximum = this.options.maximumLiveRuntimes;
    if (maximum !== undefined && this.slots.size + this.reservedSlotStarts >= maximum) {
      throw new GatewayError("busy", "Gateway live runtime capacity is full; close or wait for an idle session", true);
    }
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
    return this.presentationPresence.set(input);
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
    try {
      let work = 0;
      const slots = [...this.slots.values()];
      const exact = new Set<string>();
      for (const slot of slots) {
        for (const asyncDir of slot.ownedExtensionArtifactDirectories()) {
          const key = `${slot.id}\0${asyncDir}`;
          if (!exact.add(key)) continue;
          if (work >= MAX_EXTENSION_DISCOVERY_WORK) return;
          work += 1;
          await slot.discoverExtensionArtifact(asyncDir);
        }
      }

      const roots = new Set<string>();
      for (const slot of slots) {
        if (roots.size >= MAX_EXTENSION_DISCOVERY_ROOTS) break;
        const root = join(resolve(slot.cwd), ".pi", "subagents", "async-subagent-runs");
        try { if ((await stat(root)).isDirectory()) roots.add(root); } catch { /* no project artifacts */ }
      }
      try {
        let examined = 0;
        const entries = await opendir(tmpdir());
        for await (const entry of entries) {
          examined += 1;
          if (examined > MAX_EXTENSION_TEMP_ENTRIES || roots.size >= MAX_EXTENSION_DISCOVERY_ROOTS) break;
          if (!entry.isDirectory() || !entry.name.startsWith("pi-subagents-")) continue;
          const root = join(tmpdir(), entry.name, "async-subagent-runs");
          try { if ((await stat(root)).isDirectory()) roots.add(root); } catch { /* disappearing runtime root */ }
        }
      } catch { /* an unavailable temp directory leaves exact bindings authoritative */ }

      const rootList = [...roots];
      let ambientStructuralEntries = 0;
      let ambientStatusReads = 0;
      for (let rootIndex = 0; rootIndex < rootList.length
        && work < MAX_EXTENSION_DISCOVERY_WORK
        && ambientStructuralEntries < MAX_EXTENSION_ROOT_ENTRIES
        && ambientStatusReads < MAX_EXTENSION_DISCOVERY_WORK; rootIndex += 1) {
        const root = rootList[rootIndex]!;
        const rootsRemaining = rootList.length - rootIndex;
        const routedSlots = Math.max(1, slots.length);
        const rootBudget = Math.max(1, Math.floor(
          (MAX_EXTENSION_DISCOVERY_WORK - work) / (rootsRemaining * routedSlots),
        ));
        const candidates: Array<{ asyncDir: string; active: boolean; timestamp: number }> = [];
        try {
          const entries = await opendir(root);
          for await (const entry of entries) {
            ambientStructuralEntries += 1;
            if (ambientStructuralEntries > MAX_EXTENSION_ROOT_ENTRIES) break;
            if (!entry.isDirectory()) continue;
            if (ambientStatusReads >= MAX_EXTENSION_DISCOVERY_WORK) break;
            ambientStatusReads += 1;
            const asyncDir = join(root, entry.name);
            try {
              const statusPath = join(asyncDir, "status.json");
              const handle = await open(statusPath, "r");
              let parsed: unknown;
              try {
                const metadata = await handle.stat();
                if (!metadata.isFile() || metadata.size > MAX_EXTENSION_ARTIFACT_BYTES) continue;
                const buffer = Buffer.alloc(MAX_EXTENSION_ARTIFACT_BYTES + 1);
                const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
                if (bytesRead > MAX_EXTENSION_ARTIFACT_BYTES) continue;
                parsed = JSON.parse(buffer.subarray(0, bytesRead).toString("utf8"));
              } finally {
                await handle.close();
              }
              const value = admitExtensionLifecycleArtifact(parsed, { exactOwnedLegacy: true });
              if (!value) continue;
              const state = value.state ?? value.status;
              const active = state === "queued" || state === "running" || state === "pending"
                || state === "detached" || state === "paused";
              const timestamps = [value.lastUpdate, value.startedAt, value.endedAt]
                .filter((item): item is number => typeof item === "number" && Number.isSafeInteger(item) && item >= 0);
              candidates.push({ asyncDir, active, timestamp: Math.max(0, ...timestamps) });
            } catch { /* replacement or malformed artifact */ }
          }
        } catch { continue; }
        // Terminal evidence releases accepted work; live exact bindings were
        // already refreshed above and do not outrank it in ambient discovery.
        candidates.sort((left, right) => Number(right.active) - Number(left.active)
          || right.timestamp - left.timestamp || left.asyncDir.localeCompare(right.asyncDir));
        // Route only the amount this pass can safely project to live slots.
        for (const candidate of candidates.slice(0, rootBudget)) {
          for (const slot of slots) {
            if (work >= MAX_EXTENSION_DISCOVERY_WORK) return;
            work += 1;
            await slot.discoverExtensionArtifact(candidate.asyncDir);
          }
        }
      }
    } finally {
      this.artifactDiscoveryInFlight = false;
    }
  }

  private async evictIdle(): Promise<void> {
    const cutoff = Date.now() - this.options.idleRuntimeMs;
    for (const [id, slot] of this.slots) {
      const selected = await this.mutex.run(() => {
        if (!this.isIdleEvictionEligible(id, slot, cutoff)) return false;
        this.idleEvictions.set(id, { slot, committed: false });
        return true;
      });
      if (!selected) continue;
      try {
        const eviction = this.idleEvictions.get(id);
        if (eviction?.slot !== slot) continue;
        let removedLiveOnlySession = false;
        const disposal = slot.disposeIf(() => {
          if (this.idleEvictions.get(id) !== eviction || !this.isIdleEvictionEligible(id, slot, cutoff)) return false;
          eviction.committed = true;
          removedLiveOnlySession = slot.persistedSessionFile === undefined;
          return true;
        });
        eviction.completion = disposal;
        const disposed = await disposal;
        if (disposed && this.slots.get(id) === slot && this.idleEvictions.get(id) === eviction) {
          this.slots.delete(id);
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
      } catch {
        // A slot may have become busy after the eligibility check; retain it.
      } finally {
        if (this.idleEvictions.get(id)?.slot === slot) this.idleEvictions.delete(id);
      }
    }
    this.blobs.prune();
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
      this.drainStartedAt = new Date().toISOString();
      this.drainLastProgressAt = this.drainStartedAt;
      this.drainFingerprint = "";
      this.drainRevision += 1;
    }
    return this.administrativeDrainSnapshot();
  }

  private setDrainPhase(phase: AdministrativeDrainPhase): void {
    if (this.drainPhase === phase) return;
    this.drainPhase = phase;
    this.drainRevision += 1;
    this.drainLastProgressAt = new Date().toISOString();
    this.drainFingerprint = "";
  }

  administrativeDrainSnapshot(): AdministrativeDrainSnapshot {
    const now = Date.now();
    const facts: Array<{
      key: string;
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
        category: work.kind,
        state: foregroundIsSuspect
          ? "suspect"
          : work.kind === "terminal-receipt-persistence" ? "settling" : "active",
        admittedAt: work.admittedAt,
        progressAt: work.progressAt,
      });
    }
    for (const slot of this.slots.values()) {
      for (const fact of slot.administrativeDrainBlockers()) {
        facts.push({ ...fact, key: `slot:${slot.id}:${fact.key}` });
      }
    }
    facts.sort((left, right) => (left.admittedAt ?? "").localeCompare(right.admittedAt ?? "")
      || left.category.localeCompare(right.category) || left.key.localeCompare(right.key));
    const counts: Partial<Record<AdministrativeDrainBlockerCategory, number>> = {};
    for (const fact of facts) counts[fact.category] = (counts[fact.category] ?? 0) + 1;
    const admitted = facts.flatMap((fact) => {
      if (!fact.admittedAt) return [];
      const milliseconds = Date.parse(fact.admittedAt);
      return Number.isFinite(milliseconds) ? [{ timestamp: fact.admittedAt, milliseconds }] : [];
    }).sort((left, right) => left.milliseconds - right.milliseconds);
    const oldest = admitted[0];
    const summaries = facts.slice(0, 64).map((fact) => {
      const admittedMilliseconds = fact.admittedAt ? Date.parse(fact.admittedAt) : Number.NaN;
      return {
        id: `blocker-${createHash("sha256").update(`${this.drainId}\0${fact.key}`).digest("hex").slice(0, 20)}`,
        category: fact.category,
        state: fact.state,
        ...(fact.admittedAt && Number.isFinite(admittedMilliseconds) ? {
          admittedAt: fact.admittedAt,
          ageMs: Math.max(0, now - admittedMilliseconds),
        } : {}),
      } satisfies AdministrativeDrainBlockerSummary;
    });
    const fingerprint = JSON.stringify({
      phase: this.drainPhase,
      facts: facts.map((fact) => [fact.key, fact.category, fact.state, fact.admittedAt, fact.progressAt]),
    });
    if (fingerprint !== this.drainFingerprint) {
      this.drainFingerprint = fingerprint;
      this.drainRevision += 1;
      if (this.administrativeDrainStarted) this.drainLastProgressAt = new Date(now).toISOString();
    }
    return {
      drainId: this.drainId,
      revision: this.drainRevision,
      phase: this.drainPhase,
      ...(this.drainStartedAt ? { startedAt: this.drainStartedAt } : {}),
      ...(this.drainLastProgressAt ? { lastProgressAt: this.drainLastProgressAt } : {}),
      blockerCount: facts.length,
      blockerCounts: counts,
      ...(oldest ? {
        oldestAdmissionAt: oldest.timestamp,
        oldestAdmissionAgeMs: Math.max(0, now - oldest.milliseconds),
      } : {}),
      blockers: summaries,
      omittedCount: Math.max(0, facts.length - summaries.length),
      suspectProjectionCount: facts.filter((fact) => fact.state === "suspect").length,
    };
  }

  drainBusySessionCount(): number { return this.administrativeDrainSnapshot().blockerCount; }

  async waitUntilIdle(): Promise<void> {
    // Freeze slot/admin admissions synchronously, then wait for every operation
    // admitted before the cutoff. Graceful restart never cancels accepted work.
    this.beginAdministrativeDrain();
    try {
      while (this.slotAdmissionsInFlight > 0) {
        this.administrativeDrainSnapshot();
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
        this.administrativeDrainSnapshot();
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
      if (finalWaiting.blockerCount !== 0) {
        throw new Error("Administrative drain cannot complete while blockers remain");
      }
      this.workRegistry.completeDrain();
      this.setDrainPhase("complete");
      const completed = this.administrativeDrainSnapshot();
      if (completed.blockerCount !== 0) {
        throw new Error("Administrative drain completion invariant was violated");
      }
    } catch (error) {
      this.setDrainPhase("failed");
      this.administrativeDrainSnapshot();
      throw error;
    }
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
    return operation;
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
        if (this.slots.get(id) === slot) this.slots.delete(id);
      } else {
        failures.push(result.reason);
      }
    }
    if (failures.length > 0) {
      throw new AggregateError(failures, "One or more session runtimes failed to shut down");
    }
    await Promise.all([this.blobs.dispose(), this.exports.dispose()]);
    this.shutdownState = "disposed";
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

  async acquireBlob(id: string, range?: import("./blob-store.js").BlobByteRange) {
    try {
      return await this.blobs.acquire(id, range);
    } catch (error) {
      if (!(error instanceof GatewayError) || error.code !== "not_found") throw error;
      return this.exports.acquire(id, range);
    }
  }
}
