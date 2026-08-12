import { rm } from "node:fs/promises";
import { join } from "node:path";
import { ModelRuntime, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import type { SessionSummary } from "../protocol/types.js";
import { AsyncMutex } from "../util/async-mutex.js";
import type { TrustService } from "../admin/trust-service.js";
import { BlobStore } from "./blob-store.js";
import { RunMarkerStore } from "./run-markers.js";
import { RuntimeSlot, type SessionBroadcast } from "./runtime-slot.js";

export class RuntimeRegistry {
  private readonly slots = new Map<string, RuntimeSlot>();
  private readonly mutex = new AsyncMutex();
  private readonly blobs = new BlobStore();
  private readonly markers: RunMarkerStore;
  private interrupted = new Set<string>();
  private readonly subscribers = new Map<string, Set<string>>();
  private evictionTimer?: NodeJS.Timeout;

  constructor(
    private readonly options: {
      agentDir: string;
      tronHome: string;
      idleRuntimeMs: number;
      modelRuntimeFactory?: () => Promise<ModelRuntime>;
      trust: TrustService;
      broadcast: SessionBroadcast;
      sessionListChanged: () => void;
    },
  ) {
    this.markers = new RunMarkerStore(options.tronHome);
  }

  async initialize(): Promise<void> {
    this.interrupted = await this.markers.interruptedSessionIds();
    this.evictionTimer = setInterval(() => void this.evictIdle(), 60_000);
    this.evictionTimer.unref();
  }

  private hooks() {
    return {
      broadcast: this.options.broadcast,
      changed: () => this.options.sessionListChanged(),
      settled: (sessionId: string) => { this.interrupted.delete(sessionId); },
      rekey: (previousId: string, nextId: string, slot: RuntimeSlot) => {
        const existing = this.slots.get(nextId);
        if (existing && existing !== slot) throw new GatewayError("conflict", "Replacement session is already active");
        if (this.slots.get(previousId) === slot) this.slots.delete(previousId);
        this.slots.set(nextId, slot);
        if (this.interrupted.delete(previousId)) this.interrupted.add(nextId);
        const subscribers = this.subscribers.get(previousId);
        if (subscribers) {
          this.subscribers.delete(previousId);
          this.subscribers.set(nextId, subscribers);
        }
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

  private sessionDirectory(): string | undefined {
    return SettingsManager.create(process.cwd(), this.options.agentDir, { projectTrusted: false }).getSessionDir();
  }

  private async sessionInfos() {
    return SessionManager.listAll(this.sessionDirectory());
  }

  async list(): Promise<SessionSummary[]> {
    const sessions = await this.sessionInfos();
    const pathToId = new Map(sessions.map((session) => [session.path, session.id]));
    return sessions.map((session) => {
      const slot = this.slots.get(session.id);
      const parentSessionId = session.parentSessionPath ? pathToId.get(session.parentSessionPath) : undefined;
      return {
        id: session.id,
        ...(session.name ? { name: session.name } : {}),
        cwd: session.cwd,
        ...(parentSessionId ? { parentSessionId } : {}),
        createdAt: session.created.toISOString(),
        updatedAt: session.modified.toISOString(),
        messageCount: session.messageCount,
        firstMessage: session.firstMessage,
        phase: slot ? slot.snapshot().phase : this.interrupted.has(session.id) ? "interrupted" : "idle",
      };
    });
  }

  async create(cwdInput: string): Promise<RuntimeSlot> {
    const trust = await this.options.trust.requireResolved(cwdInput);
    return this.mutex.run(async () => {
      const manager = SessionManager.create(trust.cwd, this.sessionDirectory());
      const id = manager.getSessionId();
      const slot = await RuntimeSlot.create(manager, this.dependencies(), this.hooks(), false);
      this.slots.set(id, slot);
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
      const sessions = await this.sessionInfos();
      const info = sessions.find((session) => session.id === sessionId);
      if (!info) throw new GatewayError("not_found", "Tron session was not found");
      const manager = SessionManager.open(info.path, this.sessionDirectory());
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
        this.options.sessionListChanged();
        return slot;
      } catch (error) {
        this.slots.delete(slot.id);
        await slot.dispose().catch(() => {});
        throw error;
      }
    });
  }

  async delete(sessionId: string): Promise<void> {
    await this.mutex.run(async () => {
      const slot = this.slots.get(sessionId);
      if (slot?.isBusy) throw new GatewayError("busy", "Stop the active session before deleting it");
      const info = (await this.sessionInfos()).find((candidate) => candidate.id === sessionId);
      if (!info) throw new GatewayError("not_found", "Tron session was not found");
      if (slot) await slot.dispose();
      this.slots.delete(sessionId);
      this.subscribers.delete(sessionId);
      this.interrupted.delete(sessionId);
      await this.markers.clear(sessionId);
      await rm(info.path, { force: true });
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
