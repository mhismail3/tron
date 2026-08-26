import { createHash, randomUUID } from "node:crypto";
import { lstat, open, opendir, readFile, readdir, realpath, rm, stat } from "node:fs/promises";
import { dirname, join, relative, resolve, sep } from "node:path";
import { tmpdir } from "node:os";
import { performance } from "node:perf_hooks";
import { ModelRuntime, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
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
import { AsyncMutex } from "../util/async-mutex.js";
import type { TrustService } from "../admin/trust-service.js";
import { BlobStore } from "./blob-store.js";
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

const MAX_EXTENSION_ARTIFACT_BYTES = 256 * 1_024;
// MaximumLiveRuntimes is 16 and each slot retains at most 64 owned activity
// bindings, so this covers every exact drain owner before ambient work.
const MAX_EXTENSION_DISCOVERY_WORK = 1_024;
const MAX_EXTENSION_DISCOVERY_ROOTS = 64;
const MAX_EXTENSION_TEMP_ENTRIES = 1_024;
// Ambient enumeration shares these global pass bounds. Exact-owned artifact
// reconciliation above is intentionally outside this ambient budget.
const MAX_EXTENSION_ROOT_ENTRIES = 4_096;
const MAX_FORK_PROVENANCE_SUFFIX_BYTES = 64 * 1_024;

function isMissingFilesystemError(error: unknown): boolean {
  return (error as NodeJS.ErrnoException | undefined)?.code === "ENOENT";
}

function assertProcessSessionRef(value: string): void {
  if (!value || Buffer.byteLength(value) > 256 || /[\\/\0]/u.test(value)) {
    throw new GatewayError("invalid_request", "Invalid subagent session reference");
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
  maximumForkProvenanceBytes: 64 * 1_024 * 1_024,
  normalizationConcurrency: 16,
};

type SessionInfo = Awaited<ReturnType<typeof SessionManager.listAll>>[number];
type CatalogSessionInfo = Omit<SessionInfo, "allMessagesText"> & {
  frozenForkSnapshot?: boolean;
};

interface CatalogHeaderIdentity {
  id: string;
  cwd: string;
  timestamp?: string;
  parentSessionPath?: string;
  frozenForkSnapshot?: boolean;
}

interface CatalogStructureEvidence {
  digest: string;
  identitiesByPath: ReadonlyMap<string, CatalogHeaderIdentity>;
  complete: boolean;
}

interface CatalogAcquisitionEntry {
  id: string;
  path: string;
  cwd: string;
  canonicalCwd: string;
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

interface CatalogStructuralIndex {
  allInfos: readonly CatalogSessionInfo[];
  ambiguousDiskIDs: ReadonlySet<string>;
  structureDigest: string;
  structuralGeneration: number;
}

interface IdleEviction {
  slot: RuntimeSlot;
  committed: boolean;
  completion?: Promise<boolean>;
}

export class RuntimeRegistry {
  private readonly slots = new Map<string, RuntimeSlot>();
  private readonly mutex = new AsyncMutex();
  private readonly catalogMutex = new AsyncMutex();
  private readonly catalogAcquisitionMutex = new AsyncMutex();
  /** Serializes attention membership checks with set/delete/rekey. */
  private readonly attentionLane = new AsyncMutex();
  private readonly blobs: BlobStore;
  private readonly markers: RunMarkerStore;
  private readonly extensionActivityRecency = new ExtensionActivityRecency();
  private readonly processActivityRecency = new ProcessActivityRecency();
  private readonly attention: SessionAttentionStore;
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
    this.markers = new RunMarkerStore(options.tronHome);
    this.attention = new SessionAttentionStore(options.tronHome);
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

  async initialize(): Promise<void> {
    await this.attention.initialize();
    const markerEvidence = await this.markers.evidence();
    await this.reconcileCanonicalAttention(markerEvidence);
    this.interrupted = await this.markers.interruptedSessionIds();
    this.evictionTimer = setInterval(() => void this.evictIdle(), 60_000);
    this.evictionTimer.unref();
    this.artifactDiscoveryTimer = setInterval(() => void this.discoverExtensionArtifacts(), 750);
    this.artifactDiscoveryTimer.unref();
    void this.discoverExtensionArtifacts();
  }

  initializeBlobStorage(): Promise<void> {
    return this.blobs.initialize();
  }

  private async reconcileCanonicalAttention(markerEvidence: ReadonlyMap<string, readonly RunMarkerEvidence[]>): Promise<void> {
    const scanBoundary = new Date().toISOString();
    // Canonical JSONL alone never creates unread state. Recovery considers only
    // exact durable run-marker ownership and does not warm the catalog cache.
    const infos = await this.sessionInfos();
    const retainedIDs = new Set(infos.map((info) => info.id));
    await this.attention.prune(retainedIDs);
    for (const info of infos) {
      const markers = markerEvidence.get(info.id);
      if (!markers) continue;
      const manager = SessionManager.open(info.path);
      for (const marker of markers) {
        const completion = completionOwnedByMarker(manager, marker);
        if (!completion) continue;
        await this.attention.complete(info.id, completion.id);
        await this.markers.clear(info.id, marker.operationId);
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
        _recovery: boolean,
      ) => this.attentionLane.run(async () => {
        const result = await this.attention.complete(sessionId, completion.id);
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

  async setAttention(sessionId: string, unread: boolean, throughCompletionRevision?: number): Promise<SessionAttentionProjection> {
    return this.attentionLane.run(async () => {
      await this.flushPendingAttentionRemovals();
      if (this.deletingSessionIds.has(sessionId)) {
        throw new GatewayError("not_found", "Tron session was not found");
      }
      const catalog = await this.catalog("all");
      const summary = catalog.sessions.find((session) => session.id === sessionId);
      if (!summary) throw new GatewayError("not_found", "Tron session was not found");
      const result = await this.attention.set(sessionId, unread, throughCompletionRevision);
      if (result.changed) {
        // The store write may suspend while a live summary advances. Merge into
        // the newest retained facts rather than stamping stale catalog fields
        // with a newer summary revision.
        const latest = this.latestSummaries.get(sessionId) ?? summary;
        this.publishRevisionedSummary({ ...latest, sessionId, ...result.projection });
      }
      return result.projection;
    });
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
      markers: this.markers,
      extensionActivityRecency: this.extensionActivityRecency,
      processActivityRecency: this.processActivityRecency,
      workRegistry: this.workRegistry,
      ...(this.options.machineId ? { machineId: this.options.machineId } : {}),
      ...(this.options.notifications ? { notifications: this.options.notifications } : {}),
      ...(this.options.extensionArtifactWarning ? { extensionArtifactWarning: this.options.extensionArtifactWarning } : {}),
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
    const evidence = await this.catalogStructureEvidence();
    if (this.catalogStructuralIndex === index
        && structuralGeneration === this.catalogStructuralGeneration
        && evidence.complete
        && evidence.digest === index.structureDigest) return index;
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
      structuralGeneration: this.catalogStructuralGeneration,
    };
    this.catalogFingerprint = this.catalogIdentityFingerprint(remaining);
    return true;
  }

  private async catalogStructureEvidence(): Promise<CatalogStructureEvidence> {
    const limits = this.catalogDiscoveryLimits();
    const pending = [resolve(this.catalogDirectory())];
    const seenDirectories = new Set<string>();
    const candidatePaths = new Set<string>();
    let entriesExamined = 0;
    let traversalBytes = Buffer.byteLength(pending[0]!);
    let complete = true;
    while (pending.length > 0) {
      const candidate = pending.pop()!;
      let directory: string;
      try { directory = await realpath(candidate); }
      catch (error) {
        if (!isMissingFilesystemError(error)) complete = false;
        continue;
      }
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
            traversalBytes += Buffer.byteLength(child);
            if (traversalBytes > limits.maximumTraversalBytes) this.catalogCapacityExceeded();
            pending.push(child);
            continue;
          }
          if (!entry.name.endsWith(".jsonl") || (!entry.isFile() && !entry.isSymbolicLink())) continue;
          let canonicalPath: string;
          try {
            canonicalPath = await realpath(child);
            if (entry.isSymbolicLink() && !(await stat(canonicalPath)).isFile()) continue;
          } catch {
            if (entry.isSymbolicLink()) continue;
            canonicalPath = resolve(child);
          }
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
    const perCandidateProvenanceBytes = Math.min(
      MAX_FORK_PROVENANCE_SUFFIX_BYTES,
      Math.floor(limits.maximumForkProvenanceBytes / Math.max(1, paths.length)),
    );
    let retainedIdentityBytes = 0;
    const reserveHeaderBytes = (count: number): boolean => {
      if (count > remainingHeaderBytes) return false;
      remainingHeaderBytes -= count;
      return true;
    };
    const refundHeaderBytes = (count: number): void => { remainingHeaderBytes += count; };
    const digest = createHash("sha256");
    const identitiesByPath = new Map<string, CatalogHeaderIdentity>();
    for (let start = 0; start < paths.length; start += limits.normalizationConcurrency) {
      const batchPaths = paths.slice(start, start + limits.normalizationConcurrency);
      const identities = await Promise.all(batchPaths.map(async (path) => {
        try {
          const identity = (await this.readCatalogHeader(
            path,
            perCandidateHeaderBytes,
            reserveHeaderBytes,
            refundHeaderBytes,
          )).identity;
          if (!identity) return undefined;
          return {
            ...identity,
            ...(await this.isFrozenForkSnapshot(
              path,
              identity.timestamp,
              identity.parentSessionPath,
              (count) => count <= perCandidateProvenanceBytes,
              () => {},
            ) ? { frozenForkSnapshot: true } : {}),
          };
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
          .update(identity?.parentSessionPath ?? "").update("\0")
          .update(identity?.frozenForkSnapshot ? "frozen" : "active").update("\n");
        if (identity) identitiesByPath.set(path, identity);
      }
    }
    return {
      digest: digest.digest("base64url"),
      identitiesByPath,
      complete,
    };
  }

  private async readCatalogHeader(
    path: string,
    maximumBytes: number,
    reserveBytes: (count: number) => boolean,
    refundBytes: (count: number) => void,
  ): Promise<{ identity?: CatalogHeaderIdentity }> {
    const firstReadLength = Math.min(512, maximumBytes);
    if (!reserveBytes(firstReadLength)) return {};
    let handle: Awaited<ReturnType<typeof open>>;
    try { handle = await open(path, "r"); }
    catch (error) {
      refundBytes(firstReadLength);
      throw error;
    }
    const buffer = Buffer.allocUnsafe(maximumBytes);
    const parseCandidate = (line: Buffer): CatalogHeaderIdentity | null | undefined => {
      if (line.length === 0 || !line.toString("utf8").trim()) return undefined;
      let value: unknown;
      try { value = JSON.parse(line.toString("utf8")); }
      catch { return undefined; }
      if (!value || typeof value !== "object") return undefined;
      const record = value as Record<string, unknown>;
      if (record.type !== "session" || typeof record.id !== "string") return null;
      return {
        id: record.id,
        cwd: typeof record.cwd === "string" ? record.cwd : "",
        ...(typeof record.timestamp === "string" ? { timestamp: record.timestamp } : {}),
        ...(typeof record.parentSession === "string"
          ? { parentSessionPath: record.parentSession }
          : {}),
      };
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
          const identity = parseCandidate(buffer.subarray(lineStart, bytesReadTotal));
          return identity ? { identity } : {};
        }
        const previousEnd = bytesReadTotal;
        bytesReadTotal += bytesRead;
        let newline = buffer.indexOf(0x0a, Math.max(lineStart, previousEnd));
        while (newline >= 0 && newline < bytesReadTotal) {
          const identity = parseCandidate(buffer.subarray(lineStart, newline));
          if (identity === null) return {};
          if (identity) return { identity };
          lineStart = newline + 1;
          newline = buffer.indexOf(0x0a, lineStart);
        }
      }
      return {};
    } finally {
      await handle.close();
    }
  }

  private async sessionInfos() {
    const limits = this.catalogDiscoveryLimits();
    const pending = [resolve(this.catalogDirectory())];
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
      if (!seen.add(directory)) continue;
      traversalBytes += Buffer.byteLength(directory);
      if (seen.size > limits.maximumDirectories
        || traversalBytes > limits.maximumTraversalBytes) this.catalogCapacityExceeded();

      try {
        const entries = await opendir(directory);
        for await (const entry of entries) {
          entriesExamined += 1;
          if (entriesExamined > limits.maximumEntries) this.catalogCapacityExceeded();
          if (entry.isDirectory()) {
            const child = join(directory, entry.name);
            traversalBytes += Buffer.byteLength(child);
            if (traversalBytes > limits.maximumTraversalBytes) this.catalogCapacityExceeded();
            pending.push(child);
          }
        }
      } catch (error) {
        if (error instanceof GatewayError) throw error;
        if (isMissingFilesystemError(error)) continue;
        throw new GatewayError("busy", "Session catalog directory could not be enumerated", true);
      }

      // With an explicit directory the pinned SDK lists only that directory's
      // JSONL files. RuntimeRegistry owns recursion and invokes it once for each
      // canonical directory, avoiding overlapping descendant materializations.
      const discovered = await SessionManager.listAll(directory);
      if (sessions.length + discovered.length > limits.maximumSessions) this.catalogCapacityExceeded();
      for (const { allMessagesText: _discardedSearchText, ...session } of discovered) {
        // Gateway search never consumes the SDK's transcript-wide picker text.
        // Drop it at the SDK boundary instead of retaining a second transcript
        // projection for the lifetime of catalog materialization.
        retainedBytes += Buffer.byteLength(JSON.stringify(session));
        if (retainedBytes > limits.maximumRetainedBytes) this.catalogCapacityExceeded();
        sessions.push(session);
      }
    }

    const normalized = new Array<CatalogSessionInfo>(sessions.length);
    const perSessionProvenanceBytes = Math.min(
      MAX_FORK_PROVENANCE_SUFFIX_BYTES,
      Math.floor(limits.maximumForkProvenanceBytes / Math.max(1, sessions.length)),
    );
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
          ...(await this.isFrozenForkSnapshot(
            path,
            session.created.toISOString(),
            session.parentSessionPath,
            (count) => count <= perSessionProvenanceBytes,
            () => {},
          ) ? { frozenForkSnapshot: true } : {}),
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

  private canonicalSessionPath(path: string): Promise<string> {
    return realpath(path).catch(() => resolve(path));
  }

  /** A same-directory fork is user-visible only after it owns some entry at or
   * after its own header timestamp. Read one bounded suffix and fail open on
   * partial, oversized, or malformed evidence so uncertainty never hides data. */
  private async isFrozenForkSnapshot(
    path: string,
    headerTimestamp: string | undefined,
    parentSessionPath: string | undefined,
    reserveBytes: (count: number) => boolean,
    refundBytes: (count: number) => void,
  ): Promise<boolean> {
    if (!parentSessionPath || !headerTimestamp) return false;
    const headerTime = Date.parse(headerTimestamp);
    if (!Number.isFinite(headerTime)) return false;
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    try {
      // Only same-directory frozen branches are extension-clone evidence.
      // Cross-project and otherwise nonlocal forks remain ordinary user data.
      const [childPath, childDirectory, parentDirectory] = await Promise.all([
        realpath(path),
        realpath(dirname(path)),
        realpath(dirname(parentSessionPath)),
      ]);
      if (childDirectory !== parentDirectory) return false;

      handle = await open(childPath, "r");
      const before = await handle.stat();
      const length = Math.min(before.size, MAX_FORK_PROVENANCE_SUFFIX_BYTES);
      if (length <= 0 || !reserveBytes(length)) return false;
      const start = before.size - length;
      const buffer = Buffer.allocUnsafe(length);
      const { bytesRead } = await handle.read(buffer, 0, length, start);
      if (bytesRead !== length) {
        refundBytes(length - bytesRead);
        return false;
      }
      const after = await handle.stat();
      if (after.size !== before.size) return false;
      let text = buffer.toString("utf8");
      if (start > 0) {
        const newline = text.indexOf("\n");
        if (newline < 0) return false;
        text = text.slice(newline + 1);
      }
      const lines = text.split("\n").filter((line) => line.trim().length > 0);
      const last = lines.at(-1);
      if (!last) return false;
      let value: unknown;
      try { value = JSON.parse(last); } catch { return false; }
      if (!value || typeof value !== "object") return false;
      const record = value as Record<string, unknown>;
      if (record.type === "custom" && record.customType === "tron.gateway-user-fork") {
        return false;
      }
      if (record.type === "session" || typeof record.timestamp !== "string") return false;
      const entryTime = Date.parse(record.timestamp);
      return Number.isFinite(entryTime) && entryTime < headerTime;
    } catch {
      return false;
    } finally {
      // Reserved bytes represent actual bounded I/O and deliberately stay
      // charged. Only unread bytes above were refunded.
      await handle?.close().catch(() => {});
    }
  }

  async list(scope: "user" | "all" = "user"): Promise<SessionSummary[]> {
    return (await this.catalog(scope)).sessions;
  }

  async catalog(scope: "user" | "all" = "user"): Promise<{ sessions: SessionSummary[]; listRevision: number }> {
    const snapshot = await this.catalogSnapshot(scope);
    return { sessions: snapshot.sessions, listRevision: snapshot.listRevision };
  }

  private catalogSnapshot(scope: "user" | "all") {
    return this.catalogMutex.run(async () => {
      const materialized = await this.materializeCatalogSnapshot();
      return {
        infos: materialized.infos,
        sessions: scope === "all"
          ? materialized.sessions
          : materialized.sessions.filter((session) => session.kind === "user"),
        listRevision: materialized.listRevision,
      };
    });
  }

  private async materializeCatalogSnapshot(): Promise<{
    infos: CatalogSessionInfo[];
    sessions: SessionSummary[];
    listRevision: number;
  }> {
    const cached = await this.validatedStructuralIndex();
    if (cached) {
      const ambiguousIDs = this.dynamicAmbiguousSessionIDs(cached);
      const infos = cached.allInfos.filter((session) => !ambiguousIDs.has(session.id));
      this.ambiguousSessionIds = ambiguousIDs;
      return {
        infos: [...infos],
        sessions: await this.projectSessions(infos, "all", ambiguousIDs),
        listRevision: this.revision,
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
      structuralGeneration: materialized.structuralGeneration,
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
    return {
      infos: [...infos],
      sessions: await this.projectSessions(infos, "all", ambiguousIDs),
      listRevision: this.revision,
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
    const before = await this.catalogStructureEvidence();
    const allInfos = await this.sessionInfos();
    const ambiguousDiskIDs = this.diskAmbiguousSessionIDs(allInfos);
    const after = await this.catalogStructureEvidence();
    return {
      allInfos,
      ambiguousDiskIDs,
      after,
      invalidationGeneration,
      structuralGeneration,
      stable: invalidationGeneration === this.catalogAcquisitionInvalidationGeneration
        && structuralGeneration === this.catalogStructuralGeneration
        && before.digest === after.digest,
    };
  }

  private catalogIdentityFingerprint(infos: readonly CatalogSessionInfo[]): string {
    return JSON.stringify(infos
      // Structural membership and classification own listRevision. Mutable
      // row fields are delivered through revisioned session.summary events.
      .map((session) => [
        session.id,
        session.path,
        session.parentSessionPath,
        session.cwd,
        session.name,
        session.frozenForkSnapshot === true,
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

  private nestedOwners(
    sessions: ReadonlyArray<{ id: string; path: string }>,
  ): ReadonlyMap<string, string> {
    const roots = new Map(sessions.map((session) => [
      resolve(session.path).replace(/\.jsonl$/i, ""),
      session.id,
    ]));
    const owners = new Map<string, string>();
    for (const session of sessions) {
      const sessionPath = resolve(session.path);
      let ancestor = dirname(sessionPath);
      while (true) {
        const owner = roots.get(ancestor);
        if (owner !== undefined && owner !== session.id) {
          owners.set(sessionPath, owner);
          break;
        }
        const parent = dirname(ancestor);
        if (parent === ancestor) break;
        ancestor = parent;
      }
    }
    return owners;
  }

  private async buildCatalogAcquisitionFromSessions(
    sessions: ReadonlyArray<{
      id: string;
      path: string;
      cwd: string;
      name?: string;
      parentSessionPath?: string;
      frozenForkSnapshot?: boolean;
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
    const nestedOwners = this.nestedOwners(unambiguousSessions);
    const sessionIDByPath = new Map(unambiguousSessions.map((session) => [resolve(session.path), session.id]));
    const configuredDirectory = this.configuredSessionDirectory();
    const catalogDirectory = await realpath(this.catalogDirectory()).catch(() => resolve(this.catalogDirectory()));
    const userDirectoryDepth = configuredDirectory ? 0 : 1;
    const entriesByID = new Map<string, CatalogAcquisitionEntry>();
    let retainedBytes = 0;
    for (const session of unambiguousSessions) {
      const sessionPath = resolve(session.path);
      const directoryFromCatalog = relative(catalogDirectory, dirname(sessionPath));
      const directoryDepth = directoryFromCatalog === "" ? 0 : directoryFromCatalog.split(sep).length;
      const entry: CatalogAcquisitionEntry = {
        id: session.id,
        path: sessionPath,
        cwd: session.cwd,
        canonicalCwd: resolve(session.cwd || process.cwd()),
        structuralSubagent: nestedOwners.has(sessionPath)
          || session.name?.startsWith("subagent-") === true
          || session.frozenForkSnapshot === true
          || directoryDepth > userDirectoryDepth,
        ...(nestedOwners.get(sessionPath)
          ?? (session.parentSessionPath ? sessionIDByPath.get(resolve(session.parentSessionPath)) : undefined)
          ? { parentSessionId: nestedOwners.get(sessionPath)
            ?? sessionIDByPath.get(resolve(session.parentSessionPath!))! }
          : {}),
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
    const candidateIndex = this.catalogStructuralIndex;
    const cachedIndex = candidateIndex?.structuralGeneration === this.catalogStructuralGeneration
      ? candidateIndex : undefined;
    const cachedAdmission = this.catalogAcquisitionAdmission;
    if (cachedAdmission?.invalidationGeneration === this.catalogAcquisitionInvalidationGeneration
        && cachedIndex) {
      const validated = await this.validatedStructuralIndex();
      if (!validated) return this.catalogAcquisition();
      return {
        ...cachedAdmission,
        indexedStructuralGeneration: cachedIndex.structuralGeneration,
      };
    }
    if (cachedIndex) {
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
        const evidence = await this.catalogStructureEvidence();
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
    const records = infos.map((session) => JSON.stringify([
      resolve(session.path),
      session.id,
      session.cwd,
      session.parentSessionPath ? resolve(session.parentSessionPath) : "",
      session.name ?? "",
      session.frozenForkSnapshot === true,
    ])).sort();
    const digest = createHash("sha256");
    for (const record of records) digest.update(record).update("\n");
    return digest.digest("base64url");
  }

  private async fallbackCatalogAcquisition(): Promise<CatalogAcquisitionResolution> {
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const invalidationGeneration = this.catalogAcquisitionInvalidationGeneration;
      const before = await this.catalogStructureEvidence();
      const firstInfos = await this.sessionInfos();
      const firstFingerprint = this.sdkCatalogIdentityFingerprint(firstInfos);
      const allInfos = await this.sessionInfos();
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
      const after = await this.catalogStructureEvidence();
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

  private async projectSessions(
    sessions: Awaited<ReturnType<RuntimeRegistry["sessionInfos"]>>,
    scope: "user" | "all",
    ambiguousIDs: ReadonlySet<string> = new Set(),
  ): Promise<SessionSummary[]> {
    const pathToId = new Map(sessions.map((session) => [resolve(session.path), session.id]));
    const configuredDirectory = this.configuredSessionDirectory();
    const catalogDirectory = await realpath(this.catalogDirectory()).catch(() => resolve(this.catalogDirectory()));
    const userDirectoryDepth = configuredDirectory ? 0 : 1;
    const nestedOwners = this.nestedOwners(sessions);

    const persistedIDs = new Set(sessions.map((session) => session.id));
    const persisted = sessions.flatMap((session) => {
      const sessionPath = resolve(session.path);
      const nestedOwnerId = nestedOwners.get(sessionPath);
      // Pi's default catalog groups user sessions one directory per cwd; an
      // explicit sessionDir stores them directly. Anything deeper is extension-
      // owned child state, even if its parent file was later removed.
      const directoryFromCatalog = relative(catalogDirectory, dirname(sessionPath));
      const directoryDepth = directoryFromCatalog === "" ? 0 : directoryFromCatalog.split(sep).length;
      const namedSubagent = session.name?.startsWith("subagent-") === true;
      const kind: SessionSummary["kind"] = nestedOwnerId
        || namedSubagent
        || session.frozenForkSnapshot === true
        || directoryDepth > userDirectoryDepth ? "subagent" : "user";
      if (scope === "user" && kind === "subagent") return [];
      const headerParentSessionId = session.parentSessionPath ? pathToId.get(resolve(session.parentSessionPath)) : undefined;
      const parentSessionId = nestedOwnerId ?? headerParentSessionId;
      const slot = this.slots.get(session.id);
      const latest = this.latestSummaries.get(session.id);
      const name = latest?.name ?? session.name;
      return [{
        id: session.id,
        ...(name ? { name } : {}),
        cwd: session.cwd,
        kind,
        ...(parentSessionId ? { parentSessionId } : {}),
        createdAt: session.created.toISOString(),
        updatedAt: latest?.updatedAt ?? session.modified.toISOString(),
        messageCount: latest?.messageCount ?? session.messageCount,
        firstMessage: latest?.firstMessage ?? session.firstMessage,
        phase: latest?.phase ?? (slot ? slot.catalogPhase : this.interrupted.has(session.id) ? "interrupted" : "idle"),
        summaryRevision: latest?.summaryRevision ?? 0,
        ...this.attention.projection(session.id),
      }];
    });
    const liveOnly: SessionSummary[] = [...this.slots].flatMap(([id, slot]) => {
      // A runtime may create its canonical file after the cached disk
      // generation. Keep its exact-owned row visible until structural
      // invalidation discovers the file; never create a catalog gap.
      if (slot.isDisposed || persistedIDs.has(id) || ambiguousIDs.has(id)) return [];
      const latest = this.latestSummaries.get(id);
      const name = latest?.name;
      return [{
        id,
        ...(name ? { name } : {}),
        cwd: slot.cwd,
        kind: "user",
        createdAt: slot.catalogCreatedAt,
        updatedAt: latest?.updatedAt ?? slot.catalogCreatedAt,
        messageCount: latest?.messageCount ?? 0,
        firstMessage: latest?.firstMessage ?? "",
        phase: latest?.phase ?? slot.catalogPhase,
        summaryRevision: latest?.summaryRevision ?? 0,
        ...this.attention.projection(id),
      }];
    });
    return [...persisted, ...liveOnly]
      .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
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

  /** Resolves an opaque child-session identity without acquiring a runtime.
   * A live producer-validated path may bridge the catalog's next invalidation;
   * persisted history resolves only structurally indexed subagent sessions. */
  async resolveReadOnlySubagentPath(childSessionRef: string, preferredPath?: string, expectedParentSessionId?: string): Promise<string> {
    assertProcessSessionRef(childSessionRef);
    if (preferredPath) {
      const admitted = await this.validateReadOnlySubagentPath(childSessionRef, preferredPath, false);
      if (admitted) return admitted;
    }
    const acquisition = await this.catalogAcquisition();
    this.requireUnambiguousSessionId(childSessionRef, acquisition.ambiguousIDs);
    const entry = acquisition.entriesByID.get(childSessionRef);
    if (!entry || !entry.structuralSubagent
      || (expectedParentSessionId !== undefined && entry.parentSessionId !== expectedParentSessionId)) {
      throw new GatewayError("not_found", "Subagent session is unavailable");
    }
    const admitted = await this.validateReadOnlySubagentPath(childSessionRef, entry.path, true);
    if (!admitted) throw new GatewayError("conflict", "Subagent session identity changed", true);
    return admitted;
  }

  async readOnlySubagentTranscriptPage(
    childSessionRef: string,
    path: string,
    before?: number,
    expectedNextEntryId?: string,
  ): Promise<TranscriptPage & { revision: string }> {
    const admitted = await this.validateReadOnlySubagentPath(childSessionRef, path, false);
    if (!admitted) throw new GatewayError("conflict", "Subagent session identity changed", true);
    const handle = await open(admitted, "r");
    try {
      const metadata = await handle.stat();
      if (!metadata.isFile()) throw new GatewayError("conflict", "Subagent session is no longer a regular file", true);
      if (metadata.size > 0) {
        const final = Buffer.alloc(1);
        const { bytesRead } = await handle.read(final, 0, 1, metadata.size - 1);
        if (bytesRead !== 1 || final[0] !== 0x0a) {
          throw new GatewayError("busy", "Subagent session append is still in progress", true);
        }
      }
      const manager = SessionManager.open(admitted);
      if (manager.getSessionId() !== childSessionRef) throw new GatewayError("conflict", "Subagent session identity changed", true);
      let page: TranscriptPage;
      try {
        page = projectTranscriptPage(manager, this.blobs, before, undefined, expectedNextEntryId);
      } catch (error) {
        if (error instanceof Error && error.message.includes("anchor changed")) {
          throw new GatewayError("conflict", "Subagent transcript changed while loading history", true);
        }
        throw error;
      }
      const after = await stat(admitted);
      if (after.dev !== metadata.dev || after.ino !== metadata.ino || after.size < metadata.size) {
        throw new GatewayError("conflict", "Subagent session file changed during projection", true);
      }
      const leafEntryId = manager.getLeafId();
      const revision = createHash("sha256")
        .update(`${childSessionRef}\0${after.dev}\0${after.ino}\0${after.size}\0${after.mtimeMs}\0${leafEntryId ?? ""}`)
        .digest("hex").slice(0, 32);
      return { ...page, ...(leafEntryId ? { leafEntryId } : {}), revision };
    } finally {
      await handle.close();
    }
  }

  private async validateReadOnlySubagentPath(childSessionRef: string, input: string, _catalogStructuralEvidence: boolean): Promise<string | undefined> {
    let canonical: string;
    try { canonical = await realpath(input); } catch { return undefined; }
    const roots = await Promise.all([join(this.options.agentDir, "sessions"), this.catalogDirectory()]
      .map(async (root) => realpath(root).catch(() => resolve(root))));
    if (!roots.some((root) => canonical === root || canonical.startsWith(root + sep))) return undefined;
    const canonicalInput = await realpath(input).catch(() => undefined);
    if (!canonicalInput || canonicalInput !== canonical) return undefined;
    try {
      const metadata = await lstat(input);
      if (!metadata.isFile() || metadata.isSymbolicLink()) return undefined;
      const manager = SessionManager.open(canonical);
      if (manager.getSessionId() !== childSessionRef) return undefined;
      // Catalog callers establish structural subagent classification before
      // this path/identity check. Live callers supply an exact producer-bound
      // path that RuntimeSlot already admitted.
      return canonical;
    } catch { return undefined; }
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
        manager = SessionManager.open(canonicalPath, this.sessionDirectoryFor(entry.canonicalCwd));
      } catch {
        throw new GatewayError("conflict", "Tron session is not a valid canonical session");
      }
      if (manager.getSessionId() !== entry.id
        || resolve(manager.getCwd()) !== entry.canonicalCwd) {
        throw new GatewayError("conflict", "Tron session identity changed after catalog discovery", true);
      }
      if (manager.getSessionName()?.startsWith("subagent-") === true) {
        throw new GatewayError("conflict", "Subagent sessions are informational and remain owned by their originating runtime");
      }
      if (acquisition.indexedStructuralGeneration !== undefined) {
        const indexed = this.catalogStructuralIndex;
        const validated = await this.catalogStructureEvidence();
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
        const finalInfos = await this.sessionInfos();
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
        const catalog = await this.catalogSnapshot("all");
        this.requireUnambiguousSessionId(sessionId);
        const summary = catalog.sessions.find((session) => session.id === sessionId);
        if (!summary) throw new GatewayError("not_found", "Tron session was not found");
        if (await this.projectTrustReloading(summary.cwd)) {
          throw new GatewayError("busy", "Project trust is being reconfigured", true);
        }
        const slot = this.slots.get(sessionId);
        if (slot?.isBusy) throw new GatewayError("busy", "Stop the active session before deleting it");
        if (summary.kind === "subagent") {
          throw new GatewayError("conflict", "Delete the originating user session instead of mutating its runtime-owned subagent session");
        }
        const info = catalog.infos.find((candidate) => candidate.id === sessionId);
        if (!info && (!slot || slot.persistedSessionFile !== undefined)) {
          throw new GatewayError("not_found", "Tron session was removed before it could be deleted");
        }
        this.cancelIdleEviction(sessionId, slot);
        if (slot) await slot.dispose();
        this.slots.delete(sessionId);
        this.subscribers.delete(sessionId);
        this.summaryRevisions.delete(sessionId);
        this.latestSummaries.delete(sessionId);
        this.interrupted.delete(sessionId);
        await this.markers.clear(sessionId);
        if (info) {
          // Canonical deletion commits before projection cleanup. If cleanup fails,
          // restart reconciliation prunes the now-unowned record; it can never
          // resurrect catalog membership or publish a summary.
          await rm(info.path, { force: true });
          if (!(await this.removeIndexedCatalogFile(info.path))) this.invalidateCatalogAcquisition();
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

  unsubscribe(clientId: string, sessionId: string): void {
    const clients = this.subscribers.get(sessionId);
    clients?.delete(clientId);
    if (clients?.size === 0) this.subscribers.delete(sessionId);
  }

  unsubscribeClient(clientId: string): void {
    for (const [sessionId, clients] of this.subscribers) {
      clients.delete(clientId);
      if (clients.size === 0) this.subscribers.delete(sessionId);
    }
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
    for (const work of workFacts) {
      facts.push({
        key: `work:${work.token}`,
        category: work.kind,
        state: work.kind === "terminal-receipt-persistence" ? "settling" : "active",
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
      // No projection is currently retired without exact settlement evidence.
      // Keep this additive lane explicit rather than conflating it with blockers.
      suspectProjectionCount: 0,
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
    await this.blobs.dispose();
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

  acquireBlob(id: string) {
    return this.blobs.acquire(id);
  }
}
