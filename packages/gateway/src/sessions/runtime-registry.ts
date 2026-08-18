import { createHash } from "node:crypto";
import { open, opendir, realpath, rm, stat } from "node:fs/promises";
import { dirname, join, relative, resolve, sep } from "node:path";
import { ModelRuntime, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import { installKimiK3Policy } from "../providers/kimi-k3-policy.js";
import type { SessionSummary, SessionSummaryUpdate } from "../protocol/types.js";
import { AsyncMutex } from "../util/async-mutex.js";
import type { TrustService } from "../admin/trust-service.js";
import { BlobStore } from "./blob-store.js";
import { RunMarkerStore } from "./run-markers.js";
import { RuntimeSlot, type SessionBroadcast } from "./runtime-slot.js";

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
type CatalogSessionInfo = Omit<SessionInfo, "allMessagesText">;

interface CatalogHeaderIdentity {
  id: string;
  cwd: string;
  parentSessionPath?: string;
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
}

interface CatalogAcquisitionResolution {
  entriesByID: ReadonlyMap<string, CatalogAcquisitionEntry>;
  ambiguousIDs: ReadonlySet<string>;
  structureDigest: string;
  fallbackIdentityFingerprint?: string;
  fallbackInvalidationGeneration?: number;
}

interface CatalogAcquisitionAdmission extends CatalogAcquisitionResolution {
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
  private readonly catalogMutex = new AsyncMutex();
  private readonly catalogAcquisitionMutex = new AsyncMutex();
  private readonly blobs: BlobStore;
  private readonly markers: RunMarkerStore;
  private interrupted = new Set<string>();
  private readonly subscribers = new Map<string, Set<string>>();
  // A reservation is intentionally separate from slot ownership. Acquiring or
  // subscribing cancels it before RuntimeSlot crosses its lane-protected
  // disposal boundary, so an idle scan cannot retire a newly live session.
  private readonly idleEvictions = new Map<string, IdleEviction>();
  private readonly summaryRevisions = new Map<string, number>();
  private readonly latestSummaries = new Map<string, SessionSummaryUpdate>();
  private ambiguousSessionIds = new Set<string>();
  private readonly trustReloadProjects = new Set<string>();
  private revision = 0;
  private catalogFingerprint: string | undefined;
  private catalogAcquisitionInvalidationGeneration = 0;
  private catalogAcquisitionAdmission: CatalogAcquisitionAdmission | undefined;
  private evictionTimer?: NodeJS.Timeout;
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
    },
  ) {
    this.blobs = new BlobStore(undefined, Date.now, join(options.tronHome, "gateway", "blobs"));
    this.markers = new RunMarkerStore(options.tronHome);
    for (const [name, value] of Object.entries(this.catalogDiscoveryLimits())) {
      if (!Number.isSafeInteger(value) || value < 1) throw new Error(`Invalid session catalog ${name} bound`);
    }
  }

  get listRevision(): number {
    return this.revision;
  }

  async initialize(): Promise<void> {
    this.interrupted = await this.markers.interruptedSessionIds();
    this.evictionTimer = setInterval(() => void this.evictIdle(), 60_000);
    this.evictionTimer.unref();
  }

  initializeBlobStorage(): Promise<void> {
    return this.blobs.initialize();
  }

  private hooks() {
    return {
      broadcast: this.options.broadcast,
      summaryChanged: (summary: SessionSummaryUpdate) => {
        const summaryRevision = (this.summaryRevisions.get(summary.sessionId) ?? 0) + 1;
        this.summaryRevisions.set(summary.sessionId, summaryRevision);
        const revisioned = { ...summary, summaryRevision };
        // Store fields and revision atomically. A catalog materialization may
        // observe either this whole summary or an older whole summary, never
        // stale fields stamped with a newer revision.
        this.latestSummaries.set(summary.sessionId, revisioned);
        // Row activity is revisioned independently from catalog structure.
        // A running session must not invalidate an immutable list traversal.
        this.options.sessionSummaryChanged(revisioned);
      },
      changed: () => {
        this.invalidateCatalogAcquisition();
        this.revision += 1;
        this.options.sessionListChanged();
      },
      settled: (sessionId: string) => { this.interrupted.delete(sessionId); },
      closed: (sessionId: string, slot: RuntimeSlot) => {
        if (this.slots.get(sessionId) === slot) this.slots.delete(sessionId);
        this.cancelIdleEviction(sessionId, slot);
        this.interrupted.delete(sessionId);
        this.subscribers.delete(sessionId);
        this.latestSummaries.delete(sessionId);
        this.invalidateCatalogAcquisition();
        this.revision += 1;
        this.options.sessionListChanged();
        this.options.sessionClosed?.(sessionId);
      },
      rekey: (previousId: string, nextId: string, slot: RuntimeSlot) => {
        const existing = this.slots.get(nextId);
        if (existing && existing !== slot) throw new GatewayError("conflict", "Replacement session is already active");
        if (this.slots.get(previousId) === slot) this.slots.delete(previousId);
        this.slots.set(nextId, slot);
        const previousSummaryRevision = this.summaryRevisions.get(previousId);
        this.summaryRevisions.delete(previousId);
        if (previousSummaryRevision !== undefined) this.summaryRevisions.set(nextId, previousSummaryRevision);
        const previousSummary = this.latestSummaries.get(previousId);
        this.latestSummaries.delete(previousId);
        if (previousSummary) this.latestSummaries.set(nextId, { ...previousSummary, sessionId: nextId });
        if (this.interrupted.delete(previousId)) this.interrupted.add(nextId);
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
        this.options.sessionRekeyed?.(previousId, nextId);
        this.invalidateCatalogAcquisition();
        this.revision += 1;
        this.options.sessionListChanged();
      },
    };
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
    };
  }

  private configuredSessionDirectory(): string | undefined {
    return SettingsManager.create(process.cwd(), this.options.agentDir, { projectTrusted: false }).getSessionDir();
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

  private invalidateCatalogAcquisition(): void {
    this.catalogAcquisitionInvalidationGeneration += 1;
    this.catalogAcquisitionAdmission = undefined;
  }

  private async catalogStructureEvidence(): Promise<CatalogStructureEvidence> {
    const limits = this.catalogDiscoveryLimits();
    const pending = [resolve(this.catalogDirectory())];
    const seenDirectories = new Set<string>();
    const candidatePaths = new Set<string>();
    let entriesExamined = 0;
    let traversalBytes = Buffer.byteLength(pending[0]!);
    while (pending.length > 0) {
      const candidate = pending.pop()!;
      let directory: string;
      try { directory = await realpath(candidate); }
      catch { continue; }
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
      }
    }

    const paths = [...candidatePaths].sort();
    let remainingHeaderBytes = limits.maximumHeaderBytes;
    const perCandidateHeaderBytes = Math.min(
      limits.maximumHeaderBytesPerFile,
      Math.floor(limits.maximumHeaderBytes / Math.max(1, paths.length)),
    );
    let retainedIdentityBytes = 0;
    let complete = true;
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
          return (await this.readCatalogHeader(
            path,
            perCandidateHeaderBytes,
            reserveHeaderBytes,
            refundHeaderBytes,
          )).identity;
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
          .update(identity?.parentSessionPath ?? "").update("\n");
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
      catch { continue; }
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
        continue;
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
    let nextIndex = 0;
    const normalize = async () => {
      while (true) {
        const index = nextIndex;
        nextIndex += 1;
        const session = sessions[index];
        if (!session) return;
        normalized[index] = {
          ...session,
          path: await this.canonicalSessionPath(session.path),
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

  private canonicalSessionPath(path: string): Promise<string> {
    return realpath(path).catch(() => resolve(path));
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
    let materialized = await this.scanCatalogMaterialization();
    if (!materialized.stable) materialized = await this.scanCatalogMaterialization();
    if (!materialized.stable) {
      await this.catalogAcquisitionMutex.run(() => { this.catalogAcquisitionAdmission = undefined; });
      throw new GatewayError("busy", "Session catalog changed during discovery", true);
    }

    const admitted = await this.publishCatalogAcquisition(
      materialized.after,
      materialized.invalidationGeneration,
    );
    if (materialized.invalidationGeneration !== this.catalogAcquisitionInvalidationGeneration) {
      if (admitted) this.catalogAcquisitionAdmission = undefined;
      throw new GatewayError("busy", "Session catalog changed during publication", true);
    }
    // No await may separate the final generation confirmation from publication
    // of catalog identity and its matching revision.
    this.updateCatalogIdentity(materialized.allInfos, materialized.ambiguousIDs);
    return {
      infos: materialized.infos,
      sessions: materialized.sessions,
      listRevision: this.revision,
    };
  }

  private async scanCatalogMaterialization(): Promise<{
    allInfos: CatalogSessionInfo[];
    infos: CatalogSessionInfo[];
    sessions: SessionSummary[];
    ambiguousIDs: Set<string>;
    after: CatalogStructureEvidence;
    invalidationGeneration: number;
    stable: boolean;
  }> {
    const invalidationGeneration = this.catalogAcquisitionInvalidationGeneration;
    const before = await this.catalogStructureEvidence();
    const allInfos = await this.sessionInfos();
    const counts = new Map<string, number>();
    for (const session of allInfos) counts.set(session.id, (counts.get(session.id) ?? 0) + 1);
    const ambiguousIDs = new Set(
      [...counts].filter(([, count]) => count > 1).map(([id]) => id),
    );
    const infos = allInfos.filter((session) => !ambiguousIDs.has(session.id));
    const sessions = await this.projectSessions(infos, "all");
    const after = await this.catalogStructureEvidence();
    return {
      allInfos,
      infos,
      sessions,
      ambiguousIDs,
      after,
      invalidationGeneration,
      stable: invalidationGeneration === this.catalogAcquisitionInvalidationGeneration
        && before.digest === after.digest,
    };
  }

  private updateCatalogIdentity(infos: CatalogSessionInfo[], ambiguousIDs: Set<string>): void {
    const fingerprint = JSON.stringify(infos
      // Structural membership and classification own listRevision. Mutable
      // row fields are delivered through revisioned session.summary events.
      .map((session) => [session.id, session.path, session.parentSessionPath, session.cwd, session.name])
      .sort((left, right) => {
        const byId = String(left[0]).localeCompare(String(right[0]));
        return byId !== 0 ? byId : JSON.stringify(left).localeCompare(JSON.stringify(right));
      }));
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
    sessions: ReadonlyArray<{ id: string; path: string; cwd: string; name?: string }>,
    ambiguousIDs: ReadonlySet<string>,
    structureDigest: string,
  ): Promise<CatalogAcquisitionResolution> {
    const limits = this.catalogDiscoveryLimits();
    if (sessions.length + ambiguousIDs.size > limits.maximumSessions) this.catalogCapacityExceeded();
    const nestedOwners = this.nestedOwners(sessions);
    const configuredDirectory = this.configuredSessionDirectory();
    const catalogDirectory = await realpath(this.catalogDirectory()).catch(() => resolve(this.catalogDirectory()));
    const userDirectoryDepth = configuredDirectory ? 0 : 1;
    const entriesByID = new Map<string, CatalogAcquisitionEntry>();
    let retainedBytes = 0;
    for (const session of sessions) {
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
          || directoryDepth > userDirectoryDepth,
      };
      retainedBytes += Buffer.byteLength(JSON.stringify(entry));
      if (retainedBytes > limits.maximumAcquisitionBytes) this.catalogCapacityExceeded();
      entriesByID.set(entry.id, entry);
    }
    for (const id of ambiguousIDs) {
      retainedBytes += Buffer.byteLength(id);
      if (retainedBytes > limits.maximumAcquisitionBytes) this.catalogCapacityExceeded();
    }
    return { entriesByID, ambiguousIDs, structureDigest };
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
  ): Promise<SessionSummary[]> {
    const pathToId = new Map(sessions.map((session) => [resolve(session.path), session.id]));
    const configuredDirectory = this.configuredSessionDirectory();
    const catalogDirectory = await realpath(this.catalogDirectory()).catch(() => resolve(this.catalogDirectory()));
    const userDirectoryDepth = configuredDirectory ? 0 : 1;
    const nestedOwners = this.nestedOwners(sessions);

    return sessions.flatMap((session) => {
      const sessionPath = resolve(session.path);
      const nestedOwnerId = nestedOwners.get(sessionPath);
      // Pi's default catalog groups user sessions one directory per cwd; an
      // explicit sessionDir stores them directly. Anything deeper is extension-
      // owned child state, even if its parent file was later removed.
      const directoryFromCatalog = relative(catalogDirectory, dirname(sessionPath));
      const directoryDepth = directoryFromCatalog === "" ? 0 : directoryFromCatalog.split(sep).length;
      const namedSubagent = session.name?.startsWith("subagent-") === true;
      const kind: SessionSummary["kind"] = nestedOwnerId || namedSubagent || directoryDepth > userDirectoryDepth ? "subagent" : "user";
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
      }];
    }).sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
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
    this.assertSlotAdmissionOpen();
    const trust = await this.options.trust.requireResolved(cwdInput);
    return this.mutex.run(async () => {
      this.assertSlotAdmissionOpen();
      if (this.trustReloadProjects.has(trust.cwd)) {
        throw new GatewayError("busy", "Project trust is being reconfigured", true);
      }
      this.requireLiveSlotCapacity();
      const manager = SessionManager.create(trust.cwd, this.sessionDirectoryFor(trust.cwd));
      const id = manager.getSessionId();
      const slot = await RuntimeSlot.create(manager, this.dependencies(), this.hooks(), false);
      this.slots.set(id, slot);
      this.invalidateCatalogAcquisition();
      this.revision += 1;
      this.options.sessionListChanged();
      return slot;
    });
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
    const acquisition = await this.catalogAcquisition();
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
    return this.mutex.run(async () => {
      this.assertSlotAdmissionOpen();
      let raced = this.slots.get(sessionId);
      if (raced?.isDisposed) {
        if (this.slots.get(sessionId) === raced) this.slots.delete(sessionId);
        raced = undefined;
      }
      if (raced && !this.ambiguousSessionIds.has(sessionId)) {
        const eviction = this.idleEvictions.get(sessionId);
        if (eviction?.slot === raced && eviction.committed && eviction.completion) {
          await eviction.completion;
          return this.acquire(sessionId);
        }
        this.cancelIdleEviction(sessionId, raced);
        raced.touch();
        return raced;
      }
      if (raced) {
        const current = await this.catalogAcquisition();
        this.requireUnambiguousSessionId(sessionId, current.ambiguousIDs);
        if (current.entriesByID.get(sessionId)?.structuralSubagent) {
          throw new GatewayError("conflict", "Subagent sessions are informational and remain owned by their originating runtime");
        }
        this.cancelIdleEviction(sessionId, raced);
        raced.touch();
        return raced;
      }
      this.requireLiveSlotCapacity();
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
      if (acquisition.fallbackIdentityFingerprint !== undefined) {
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
      const slot = await RuntimeSlot.create(manager, this.dependencies(), this.hooks(), this.interrupted.has(sessionId));
      this.slots.set(sessionId, slot);
      return slot;
    });
  }

  async importFromJsonl(path: string, cwdInput: string): Promise<RuntimeSlot> {
    this.assertSlotAdmissionOpen();
    const trust = await this.options.trust.requireResolved(cwdInput);
    return this.mutex.run(async () => {
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
      if (!info) throw new GatewayError("not_found", "Tron session was removed before it could be deleted");
      this.cancelIdleEviction(sessionId, slot);
      if (slot) await slot.dispose();
      this.slots.delete(sessionId);
      this.subscribers.delete(sessionId);
      this.summaryRevisions.delete(sessionId);
      this.latestSummaries.delete(sessionId);
      this.interrupted.delete(sessionId);
      await this.markers.clear(sessionId);
      await rm(info.path, { force: true });
      this.invalidateCatalogAcquisition();
      this.revision += 1;
      this.options.sessionListChanged();
    });
  }

  private requireLiveSlotCapacity(): void {
    const maximum = this.options.maximumLiveRuntimes;
    if (maximum !== undefined && this.slots.size >= maximum) {
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
        const disposal = slot.disposeIf(() => {
          if (this.idleEvictions.get(id) !== eviction || !this.isIdleEvictionEligible(id, slot, cutoff)) return false;
          eviction.committed = true;
          return true;
        });
        eviction.completion = disposal;
        const disposed = await disposal;
        if (disposed && this.slots.get(id) === slot && this.idleEvictions.get(id) === eviction) {
          this.slots.delete(id);
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

  async waitUntilIdle(timeoutMs = 60_000): Promise<void> {
    const slots = [...this.slots.values()];
    let preparationSettled = false;
    let preparationError: unknown;
    void Promise.all(slots.map((slot) => slot.prepareForAdministrativeDrain())).then(
      () => { preparationSettled = true; },
      (error) => { preparationError = error; preparationSettled = true; },
    );
    const deadline = Date.now() + timeoutMs;
    while (!preparationSettled || slots.some((slot) => slot.isDrainBusy)) {
      if (Date.now() >= deadline) {
        throw new GatewayError("busy", "Gateway restart drain timed out; remaining extension work will be interrupted", true);
      }
      await new Promise((resolve) => setTimeout(resolve, Math.min(100, Math.max(1, deadline - Date.now()))));
    }
    if (preparationError !== undefined) throw preparationError;
  }

  async dispose(): Promise<void> {
    if (this.shutdownState === "disposed") return;
    if (this.disposalPromise) return this.disposalPromise;

    // Close admission synchronously before waiting for any in-flight critical
    // section. The mutex snapshot then includes every slot whose insertion had
    // already begun and excludes every later create/acquire/import attempt.
    this.shutdownState = "shuttingDown";
    if (this.evictionTimer) clearInterval(this.evictionTimer);
    const operation = this.performDispose();
    this.disposalPromise = operation;
    return operation;
  }

  private async performDispose(): Promise<void> {
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

  private assertSlotAdmissionOpen(): void {
    if (this.shutdownState !== "active") {
      throw new GatewayError("conflict", "Session runtime registry is shutting down", true);
    }
  }

  acquireBlob(id: string) {
    return this.blobs.acquire(id);
  }
}
