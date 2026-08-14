import { readdir, realpath, rm } from "node:fs/promises";
import { dirname, join, relative, resolve, sep } from "node:path";
import { ModelRuntime, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import type { SessionSummary, SessionSummaryUpdate } from "../protocol/types.js";
import { AsyncMutex } from "../util/async-mutex.js";
import type { TrustService } from "../admin/trust-service.js";
import { BlobStore } from "./blob-store.js";
import { RunMarkerStore } from "./run-markers.js";
import { RuntimeSlot, type SessionBroadcast } from "./runtime-slot.js";

export class RuntimeRegistry {
  private readonly slots = new Map<string, RuntimeSlot>();
  private readonly mutex = new AsyncMutex();
  private readonly catalogMutex = new AsyncMutex();
  private readonly blobs = new BlobStore();
  private readonly markers: RunMarkerStore;
  private interrupted = new Set<string>();
  private readonly subscribers = new Map<string, Set<string>>();
  private readonly summaryRevisions = new Map<string, number>();
  private revision = 0;
  private catalogFingerprint: string | undefined;
  private evictionTimer?: NodeJS.Timeout;

  constructor(
    private readonly options: {
      agentDir: string;
      tronHome: string;
      idleRuntimeMs: number;
      modelRuntimeFactory?: () => Promise<ModelRuntime>;
      trust: TrustService;
      broadcast: SessionBroadcast;
      sessionSummaryChanged: (summary: SessionSummaryUpdate) => void;
      sessionListChanged: () => void;
    },
  ) {
    this.markers = new RunMarkerStore(options.tronHome);
  }

  get listRevision(): number {
    return this.revision;
  }

  async initialize(): Promise<void> {
    this.interrupted = await this.markers.interruptedSessionIds();
    this.evictionTimer = setInterval(() => void this.evictIdle(), 60_000);
    this.evictionTimer.unref();
  }

  private hooks() {
    return {
      broadcast: this.options.broadcast,
      summaryChanged: (summary: SessionSummaryUpdate) => {
        const summaryRevision = (this.summaryRevisions.get(summary.sessionId) ?? 0) + 1;
        this.summaryRevisions.set(summary.sessionId, summaryRevision);
        this.revision += 1;
        this.options.sessionSummaryChanged({ ...summary, summaryRevision });
      },
      changed: () => {
        this.revision += 1;
        this.options.sessionListChanged();
      },
      settled: (sessionId: string) => { this.interrupted.delete(sessionId); },
      rekey: (previousId: string, nextId: string, slot: RuntimeSlot) => {
        const existing = this.slots.get(nextId);
        if (existing && existing !== slot) throw new GatewayError("conflict", "Replacement session is already active");
        if (this.slots.get(previousId) === slot) this.slots.delete(previousId);
        this.slots.set(nextId, slot);
        const previousSummaryRevision = this.summaryRevisions.get(previousId);
        this.summaryRevisions.delete(previousId);
        if (previousSummaryRevision !== undefined) this.summaryRevisions.set(nextId, previousSummaryRevision);
        if (this.interrupted.delete(previousId)) this.interrupted.add(nextId);
        const subscribers = this.subscribers.get(previousId);
        if (subscribers) {
          this.subscribers.delete(previousId);
          this.subscribers.set(nextId, subscribers);
        }
        this.revision += 1;
        this.options.sessionListChanged();
      },
    };
  }

  private dependencies() {
    return {
      agentDir: this.options.agentDir,
      createModelRuntime: this.options.modelRuntimeFactory ?? (() => ModelRuntime.create({
        authPath: join(this.options.agentDir, "auth.json"),
        modelsPath: join(this.options.agentDir, "models.json"),
        modelsStorePath: join(this.options.agentDir, "models-store.json"),
        refreshOnCreate: true,
        allowModelNetwork: false,
      })),
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

  private async sessionInfos() {
    const pending = [resolve(this.catalogDirectory())];
    const seen = new Set<string>();
    const sessions = [];
    while (pending.length > 0) {
      const candidate = pending.pop()!;
      let directory: string;
      try { directory = await realpath(candidate); }
      catch { continue; }
      if (!seen.add(directory)) continue;
      sessions.push(...await SessionManager.listAll(directory));
      let entries;
      try { entries = await readdir(directory, { withFileTypes: true }); }
      catch { continue; }
      for (const entry of entries) {
        if (entry.isDirectory()) pending.push(join(directory, entry.name));
      }
    }
    return Promise.all(sessions.map(async (session) => ({
      ...session,
      path: await realpath(session.path).catch(() => resolve(session.path)),
      ...(session.parentSessionPath
        ? { parentSessionPath: await realpath(session.parentSessionPath).catch(() => resolve(session.parentSessionPath!)) }
        : {}),
    })));
  }

  async list(scope: "user" | "all" = "user"): Promise<SessionSummary[]> {
    return (await this.catalog(scope)).sessions;
  }

  async catalog(scope: "user" | "all" = "user"): Promise<{ sessions: SessionSummary[]; listRevision: number }> {
    return this.catalogMutex.run(async () => {
      const sessions = await this.sessionInfos();
      const fingerprint = JSON.stringify(sessions
        .map((session) => [session.id, session.path, session.parentSessionPath, session.modified.toISOString(), session.messageCount, session.name])
        .sort((left, right) => String(left[0]).localeCompare(String(right[0]))));
      if (this.catalogFingerprint === undefined) this.catalogFingerprint = fingerprint;
      else if (this.catalogFingerprint !== fingerprint) {
        this.catalogFingerprint = fingerprint;
        this.revision += 1;
      }
      return { sessions: await this.projectSessions(sessions, scope), listRevision: this.revision };
    });
  }

  private async projectSessions(
    sessions: Awaited<ReturnType<RuntimeRegistry["sessionInfos"]>>,
    scope: "user" | "all",
  ): Promise<SessionSummary[]> {
    const pathToId = new Map(sessions.map((session) => [resolve(session.path), session.id]));
    const configuredDirectory = this.configuredSessionDirectory();
    const catalogDirectory = await realpath(this.catalogDirectory()).catch(() => resolve(this.catalogDirectory()));
    const userDirectoryDepth = configuredDirectory ? 0 : 1;
    const catalogRoots = sessions
      .map((session) => ({ id: session.id, root: resolve(session.path).replace(/\.jsonl$/i, "") }))
      .sort((left, right) => right.root.length - left.root.length);

    return sessions.flatMap((session) => {
      const sessionPath = resolve(session.path);
      const nestedOwner = catalogRoots.find((candidate) => {
        if (candidate.id === session.id) return false;
        const pathFromRoot = relative(candidate.root, sessionPath);
        return pathFromRoot !== "" && pathFromRoot !== ".." && !pathFromRoot.startsWith(`..${sep}`) && !pathFromRoot.startsWith(sep);
      });
      // Pi's default catalog groups user sessions one directory per cwd; an
      // explicit sessionDir stores them directly. Anything deeper is extension-
      // owned child state, even if its parent file was later removed.
      const directoryFromCatalog = relative(catalogDirectory, dirname(sessionPath));
      const directoryDepth = directoryFromCatalog === "" ? 0 : directoryFromCatalog.split(sep).length;
      const namedSubagent = session.name?.startsWith("subagent-") === true;
      const kind: SessionSummary["kind"] = nestedOwner || namedSubagent || directoryDepth > userDirectoryDepth ? "subagent" : "user";
      if (scope === "user" && kind === "subagent") return [];
      const headerParentSessionId = session.parentSessionPath ? pathToId.get(resolve(session.parentSessionPath)) : undefined;
      const parentSessionId = nestedOwner?.id ?? headerParentSessionId;
      const slot = this.slots.get(session.id);
      return [{
        id: session.id,
        ...(session.name ? { name: session.name } : {}),
        cwd: session.cwd,
        kind,
        ...(parentSessionId ? { parentSessionId } : {}),
        createdAt: session.created.toISOString(),
        updatedAt: session.modified.toISOString(),
        messageCount: session.messageCount,
        firstMessage: session.firstMessage,
        phase: slot ? slot.snapshot().phase : this.interrupted.has(session.id) ? "interrupted" : "idle",
        summaryRevision: this.summaryRevisions.get(session.id) ?? 0,
      }];
    }).sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
  }

  async create(cwdInput: string): Promise<RuntimeSlot> {
    const trust = await this.options.trust.requireResolved(cwdInput);
    return this.mutex.run(async () => {
      const manager = SessionManager.create(trust.cwd, this.sessionDirectoryFor(trust.cwd));
      const id = manager.getSessionId();
      const slot = await RuntimeSlot.create(manager, this.dependencies(), this.hooks(), false);
      this.slots.set(id, slot);
      this.revision += 1;
      this.options.sessionListChanged();
      return slot;
    });
  }

  async acquire(sessionId: string): Promise<RuntimeSlot> {
    const existing = this.slots.get(sessionId);
    if (existing) {
      existing.touch();
      return existing;
    }
    return this.mutex.run(async () => {
      const raced = this.slots.get(sessionId);
      if (raced) return raced;
      const summary = (await this.list("all")).find((session) => session.id === sessionId);
      if (!summary) throw new GatewayError("not_found", "Tron session was not found");
      if (summary.kind === "subagent") {
        throw new GatewayError("conflict", "Subagent sessions are informational and remain owned by their originating runtime");
      }
      const info = (await this.sessionInfos()).find((session) => session.id === sessionId);
      if (!info) throw new GatewayError("not_found", "Tron session was removed before it could be opened");
      const manager = SessionManager.open(info.path, this.sessionDirectoryFor(info.cwd));
      const slot = await RuntimeSlot.create(manager, this.dependencies(), this.hooks(), this.interrupted.has(sessionId));
      this.slots.set(sessionId, slot);
      return slot;
    });
  }

  async importFromJsonl(path: string, cwdInput: string): Promise<RuntimeSlot> {
    const trust = await this.options.trust.requireResolved(cwdInput);
    return this.mutex.run(async () => {
      const manager = SessionManager.inMemory(trust.cwd);
      const slot = await RuntimeSlot.create(manager, this.dependencies(), this.hooks(), false);
      this.slots.set(slot.id, slot);
      try {
        await slot.importFromJsonl(path, trust.cwd);
        this.slots.set(slot.id, slot);
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

  async reloadProject(cwdInput: string): Promise<void> {
    const cwd = await this.options.trust.canonicalDirectory(cwdInput);
    const slots = [...this.slots.values()].filter((slot) => slot.cwd === cwd);
    await Promise.all(slots.map(async (slot) => {
      if (slot.isBusy) throw new GatewayError("busy", "Stop active sessions before changing project trust", true);
      await slot.reload();
    }));
  }

  async delete(sessionId: string): Promise<void> {
    await this.mutex.run(async () => {
      const slot = this.slots.get(sessionId);
      if (slot?.isBusy) throw new GatewayError("busy", "Stop the active session before deleting it");
      const summary = (await this.list("all")).find((session) => session.id === sessionId);
      if (!summary) throw new GatewayError("not_found", "Tron session was not found");
      if (summary.kind === "subagent") {
        throw new GatewayError("conflict", "Delete the originating user session instead of mutating its runtime-owned subagent session");
      }
      const info = (await this.sessionInfos()).find((candidate) => candidate.id === sessionId);
      if (!info) throw new GatewayError("not_found", "Tron session was removed before it could be deleted");
      if (slot) await slot.dispose();
      this.slots.delete(sessionId);
      this.subscribers.delete(sessionId);
      this.summaryRevisions.delete(sessionId);
      this.interrupted.delete(sessionId);
      await this.markers.clear(sessionId);
      await rm(info.path, { force: true });
      this.revision += 1;
      this.options.sessionListChanged();
    });
  }

  subscribe(clientId: string, sessionId: string): void {
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

  private async evictIdle(): Promise<void> {
    const cutoff = Date.now() - this.options.idleRuntimeMs;
    for (const [id, slot] of this.slots) {
      if (slot.isBusy || slot.touchedAt >= cutoff || (this.subscribers.get(id)?.size ?? 0) > 0) continue;
      try {
        await slot.dispose();
        this.slots.delete(id);
      } catch {
        // A slot may have become busy after the eligibility check; retain it.
      }
    }
    this.blobs.prune();
  }

  activeSessionIds(): string[] {
    return [...this.slots.values()].filter((slot) => slot.isBusy).map((slot) => slot.id);
  }

  async waitUntilIdle(): Promise<void> {
    while (this.activeSessionIds().length > 0) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }

  async dispose(): Promise<void> {
    if (this.evictionTimer) clearInterval(this.evictionTimer);
    const busy = [...this.slots.values()].filter((slot) => slot.isBusy);
    await Promise.allSettled(busy.map((slot) => slot.abort()));
    await Promise.allSettled([...this.slots.values()].map(async (slot) => {
      if (!slot.isBusy) await slot.dispose();
    }));
    this.slots.clear();
  }

  getBlob(id: string): { data: Buffer; mimeType: string } {
    return this.blobs.get(id);
  }
}
