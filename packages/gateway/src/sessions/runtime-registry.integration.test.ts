import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { copyFile, mkdtemp, mkdir, readFile, realpath, rename, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { getExamplesPath, ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import type { NotificationService } from "../notifications/notification-service.js";
import type { ExtensionRunActivity, ExtensionToolOrigin, SessionProcessActivity, SessionSummaryUpdate } from "../protocol/types.js";
import { GatewayWorkRegistry } from "./gateway-work-registry.js";
import { RuntimeRegistry } from "./runtime-registry.js";

async function waitUntil(predicate: () => boolean, timeoutMs = 5_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("condition timed out");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

describe.sequential("RuntimeRegistry with the pinned agent runtime", () => {
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  const registries: RuntimeRegistry[] = [];

  async function coldFixture(label: string, options: {
    nested?: boolean;
    name?: string;
    maximumLiveRuntimes?: number;
    workRegistry?: GatewayWorkRegistry;
  } = {}) {
    const root = await mkdtemp(join(tmpdir(), `tron-cold-acquire-${label}-`));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const sessionDirectory = options.nested
      ? join(agentDir, "sessions", "workspace", "child")
      : join(agentDir, "sessions", "workspace");
    await Promise.all([mkdir(sessionDirectory, { recursive: true }), mkdir(cwd, { recursive: true })]);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const manager = SessionManager.create(cwd, sessionDirectory);
    manager.appendMessage(fauxAssistantMessage(`cold acquisition ${label}`));
    if (options.name) manager.appendSessionInfo(options.name);
    const runtimeFactory = vi.fn(async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }));
    const events: Array<{ topic: string; payload: any }> = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      maximumLiveRuntimes: options.maximumLiveRuntimes,
      workRegistry: options.workRegistry,
      modelRuntimeFactory: runtimeFactory,
      trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => events.push({ topic, payload }),
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    return {
      root,
      agentDir,
      cwd,
      manager,
      registry,
      runtimeFactory,
      events,
      sessionFile: manager.getSessionFile()!,
    };
  }

  afterEach(async () => {
    await Promise.all(registries.splice(0).map((registry) => registry.dispose()));
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
  });

  it("rejects read-only child access without an exact live parent process owner", async () => {
    const fixture = await coldFixture("readonly-unowned", { nested: true, name: "subagent-worker" });
    const sessionId = fixture.manager.getSessionId();
    await expect(fixture.registry.resolveReadOnlySubagentPath(
      sessionId,
      await realpath(fixture.sessionFile),
      "missing-parent",
      "missing-process",
      "missing-run",
    )).rejects.toMatchObject({ code: "not_found" });
    expect(fixture.runtimeFactory).not.toHaveBeenCalled();
  });

  it("announces a final successful Pi settlement through the inline notification hook", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-agent-finished-notification-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const faux = fauxProvider({ provider: "tron-agent-finished-notification", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("notification ready")]);
    runtime.registerNativeProvider(faux.provider);
    const enqueue = vi.fn(async () => "queued" as const);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      machineId: "machine-notification-test",
      notifications: { enqueue, askPresented: vi.fn() } as unknown as NotificationService,
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("finish and notify");
    await waitUntil(() => !slot.isBusy);
    await waitUntil(() => enqueue.mock.calls.length > 0);
    expect(enqueue).toHaveBeenCalledWith(expect.objectContaining({
      sessionId: slot.id,
      kind: "agent_finished",
      title: "finish and notify",
      message: "The agent finished responding.",
      route: { sessionId: slot.id, machineId: "machine-notification-test" },
    }));
  });

  it("recovers a canonical successful completion missed before restart", async () => {
    const fixture = await coldFixture("attention-restart");
    expect(fixture.registry.attentionProjection(fixture.manager.getSessionId()).isUnread).toBe(false);
    // Simulate the crash window: accepted work retained its marker and Pi's
    // successful terminal leaf committed after the persisted reconciliation
    // cursor, but attention admission/marker cleanup did not.
    const markerStore = (fixture.registry as unknown as {
      markers: {
        mark: (sessionId: string, operationId: string) => Promise<void>;
        markAssistantCompletion: (
          sessionId: string,
          operationId: string,
          completionId: string,
          completedAt: string,
        ) => Promise<void>;
      };
    }).markers;
    const sessionId = fixture.manager.getSessionId();
    await markerStore.mark(sessionId, "crashed-operation");
    fixture.manager.appendMessage(fauxAssistantMessage("completed immediately before crash"));
    const completion = fixture.manager.getLeafEntry()!;
    await markerStore.markAssistantCompletion(
      sessionId,
      "crashed-operation",
      completion.id,
      completion.timestamp,
    );
    await fixture.registry.dispose();

    const restarted = new RuntimeRegistry({
      agentDir: fixture.agentDir,
      tronHome: join(fixture.root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(fixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(restarted);
    await restarted.initialize();
    expect(restarted.attentionProjection(fixture.manager.getSessionId()))
      .toMatchObject({ completionRevision: 1, isUnread: true });
    expect((await restarted.catalog("all")).sessions.find((row) => row.id === fixture.manager.getSessionId()))
      .toMatchObject({ phase: "idle", isUnread: true });
  });

  it("does not infer a completion from an unstamped accepted marker after restart", async () => {
    const fixture = await coldFixture("attention-unstamped-marker");
    const sessionId = fixture.manager.getSessionId();
    const markerStore = (fixture.registry as unknown as {
      markers: { mark: (sessionId: string, operationId: string) => Promise<void> };
    }).markers;
    await markerStore.mark(sessionId, "accepted-without-stamp");
    fixture.manager.appendMessage(fauxAssistantMessage("unowned successful leaf"));
    await fixture.registry.dispose();

    const restarted = new RuntimeRegistry({
      agentDir: fixture.agentDir,
      tronHome: join(fixture.root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(fixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(restarted);
    await restarted.initialize();
    expect(restarted.attentionProjection(sessionId)).toEqual({
      completionRevision: 0,
      attentionRevision: 0,
      isUnread: false,
    });
  });

  it("recovers the exact stamped completion off-leaf and never infers later markerless completions", async () => {
    const fixture = await coldFixture("attention-exact-marker");
    const sessionId = fixture.manager.getSessionId();
    const markerStore = (fixture.registry as unknown as {
      markers: {
        mark: (sessionId: string, operationId: string) => Promise<void>;
        markAssistantCompletion: (
          sessionId: string,
          operationId: string,
          completionId: string,
          completedAt: string,
        ) => Promise<void>;
      };
    }).markers;
    await markerStore.mark(sessionId, "stamped-operation");
    fixture.manager.appendMessage(fauxAssistantMessage("owned completion"));
    const owned = fixture.manager.getLeafEntry()!;
    await markerStore.markAssistantCompletion(sessionId, "stamped-operation", owned.id, owned.timestamp);
    fixture.manager.appendMessage(fauxAssistantMessage("newer markerless completion"));
    await fixture.registry.dispose();

    const restarted = new RuntimeRegistry({
      agentDir: fixture.agentDir,
      tronHome: join(fixture.root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(fixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(restarted);
    await restarted.initialize();
    expect(restarted.attentionProjection(sessionId)).toMatchObject({ completionRevision: 1, isUnread: true });

    await restarted.dispose();
    fixture.manager.appendMessage(fauxAssistantMessage("still markerless"));
    const secondRestart = new RuntimeRegistry({
      agentDir: fixture.agentDir,
      tronHome: join(fixture.root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(fixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(secondRestart);
    await secondRestart.initialize();
    expect(secondRestart.attentionProjection(sessionId).completionRevision).toBe(1);
  });

  it("merges a suspended attention write into latest summary facts and cannot race deletion", async () => {
    const fixture = await coldFixture("attention-races");
    const sessionId = fixture.manager.getSessionId();
    const internals = fixture.registry as unknown as {
      attention: { set: (id: string, unread: boolean, through?: number) => Promise<unknown> };
      latestSummaries: Map<string, SessionSummaryUpdate>;
    };
    const originalSet = internals.attention.set.bind(internals.attention);
    let entered!: () => void;
    let release!: () => void;
    const enteredBarrier = new Promise<void>((resolve) => { entered = resolve; });
    const writeBarrier = new Promise<void>((resolve) => { release = resolve; });
    vi.spyOn(internals.attention, "set").mockImplementation(async (id, unread, through) => {
      entered();
      await writeBarrier;
      return originalSet(id, unread, through);
    });

    const setting = fixture.registry.setAttention(sessionId, true, 0);
    await enteredBarrier;
    const catalogSummary = (await fixture.registry.catalog("all")).sessions.find((row) => row.id === sessionId)!;
    internals.latestSummaries.set(sessionId, {
      sessionId,
      phase: "running",
      updatedAt: catalogSummary.updatedAt,
      messageCount: 99,
      firstMessage: catalogSummary.firstMessage,
      summaryRevision: 41,
    });
    expect(internals.latestSummaries.get(sessionId)).toMatchObject({ phase: "running", messageCount: 99 });
    const deleting = fixture.registry.delete(sessionId);
    release();
    await setting;
    expect(internals.latestSummaries.get(sessionId)).toMatchObject({ phase: "running", messageCount: 99, isUnread: true });
    await deleting;
    expect(fixture.registry.attentionProjection(sessionId)).toEqual({
      completionRevision: 0,
      attentionRevision: 0,
      isUnread: false,
    });
    expect((await fixture.registry.catalog("all")).sessions.find((row) => row.id === sessionId)).toBeUndefined();
  });

  it("never holds the attention lane while deletion waits for the slot lane", async () => {
    const fixture = await coldFixture("attention-delete-rekey-order");
    const sessionId = fixture.manager.getSessionId();
    const slot = await fixture.registry.acquire(sessionId);
    const originalDispose = slot.dispose.bind(slot);
    let enteredDispose!: () => void;
    let releaseDispose!: () => void;
    const disposeEntered = new Promise<void>((resolve) => { enteredDispose = resolve; });
    const disposeBarrier = new Promise<void>((resolve) => { releaseDispose = resolve; });
    vi.spyOn(slot, "dispose").mockImplementation(async () => {
      enteredDispose();
      await disposeBarrier;
      return originalDispose();
    });

    const deleting = fixture.registry.delete(sessionId);
    await disposeEntered;
    const hooks = (fixture.registry as unknown as { hooks: () => {
      rekey: (
        previousId: string,
        nextId: string,
        slot: typeof slot,
        disposition: "preserve",
        commit: () => void,
      ) => Promise<void>;
    } }).hooks();
    await expect(hooks.rekey(sessionId, "replacement", slot, "preserve", () => {}))
      .rejects.toMatchObject({ code: "busy" });
    releaseDispose();
    await deleting;
  });

  it("projects empty live sessions until deletion, persistence, eviction, or restart", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-live-empty-catalog-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let listChanges = 0;
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 1,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => { listChanges += 1; },
    });
    registries.push(registry);
    await registry.initialize();
    const initial = await registry.catalog("user");

    const deletedSlot = await registry.create(cwd);
    const afterCreate = await registry.catalog("user");
    expect(afterCreate.listRevision).toBe(initial.listRevision + 1);
    expect(listChanges).toBe(1);
    expect(afterCreate.sessions).toEqual([expect.objectContaining({
      id: deletedSlot.id,
      cwd: deletedSlot.cwd,
      kind: "user",
      messageCount: 0,
      firstMessage: "",
      phase: "idle",
    })]);
    expect(afterCreate.sessions[0]?.createdAt).toBe(deletedSlot.catalogCreatedAt);
    expect((await registry.catalog("user")).sessions[0]?.createdAt)
      .toBe(afterCreate.sessions[0]?.createdAt);
    expect(await registry.acquire(deletedSlot.id)).toBe(deletedSlot);

    await registry.delete(deletedSlot.id);
    expect((await registry.catalog("user")).sessions).toEqual([]);
    expect(listChanges).toBe(2);

    const persistedSlot = await registry.create(cwd);
    const persistedManager = (persistedSlot as unknown as { sessionManager: SessionManager }).sessionManager;
    persistedManager.appendMessage(fauxAssistantMessage("persisted catalog row"));
    expect(persistedSlot.persistedSessionFile).toBeDefined();
    const afterPersistence = await registry.catalog("user");
    expect(afterPersistence.sessions.filter((session) => session.id === persistedSlot.id)).toHaveLength(1);
    const ownership = registry as unknown as {
      summaryRevisions: Map<string, number>;
      latestSummaries: Map<string, SessionSummaryUpdate>;
      evictIdle: () => Promise<void>;
    };
    expect(ownership.summaryRevisions.has(persistedSlot.id)).toBe(true);
    expect(ownership.latestSummaries.has(persistedSlot.id)).toBe(true);
    const persistedRevision = ownership.summaryRevisions.get(persistedSlot.id);
    const persistedChanges = listChanges;
    (persistedSlot as unknown as { lastTouchedAt: number }).lastTouchedAt = 0;
    await ownership.evictIdle();
    expect(listChanges).toBe(persistedChanges);
    expect(ownership.summaryRevisions.get(persistedSlot.id)).toBe(persistedRevision);
    expect(ownership.latestSummaries.has(persistedSlot.id)).toBe(true);
    expect((await registry.catalog("user")).sessions.map((session) => session.id)).toContain(persistedSlot.id);

    const evictedSlot = await registry.create(cwd);
    const beforeEviction = await registry.catalog("user");
    const changesBeforeEviction = listChanges;
    expect(ownership.summaryRevisions.has(evictedSlot.id)).toBe(true);
    expect(ownership.latestSummaries.has(evictedSlot.id)).toBe(true);
    (evictedSlot as unknown as { lastTouchedAt: number }).lastTouchedAt = 0;
    await ownership.evictIdle();
    const afterEviction = await registry.catalog("user");
    expect(afterEviction.sessions.map((session) => session.id)).not.toContain(evictedSlot.id);
    expect(afterEviction.listRevision).toBeGreaterThan(beforeEviction.listRevision);
    expect(listChanges).toBe(changesBeforeEviction + 1);
    expect(ownership.summaryRevisions.has(evictedSlot.id)).toBe(false);
    expect(ownership.latestSummaries.has(evictedSlot.id)).toBe(false);

    const fresh = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "fresh-tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(fresh);
    await fresh.initialize();
    const freshIDs = (await fresh.catalog("user")).sessions.map((session) => session.id);
    expect(freshIDs).toContain(persistedSlot.id);
    expect(freshIDs).not.toContain(evictedSlot.id);
  });

  it("fails closed when a canonical file collides with a live-only slot", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-live-empty-collision-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const baseline = await registry.catalog("all");
    const slot = await registry.create(cwd);
    const beforeCollision = await registry.catalog("all");
    expect(beforeCollision.listRevision).toBe(baseline.listRevision + 1);
    expect(beforeCollision.sessions.map((session) => session.id)).toContain(slot.id);
    expect(slot.persistedSessionFile).toBeUndefined();

    const collisionDirectory = join(agentDir, "sessions", "collision");
    await mkdir(collisionDirectory, { recursive: true });
    const timestamp = new Date().toISOString();
    await writeFile(join(collisionDirectory, "claim.jsonl"), [
      JSON.stringify({ type: "session", version: 3, id: slot.id, timestamp, cwd }),
      JSON.stringify({
        type: "message",
        id: randomUUID().slice(0, 8),
        parentId: null,
        timestamp,
        message: { role: "user", content: "colliding canonical claimant", timestamp: Date.now() },
      }),
    ].join("\n") + "\n");

    const afterCollision = await registry.catalog("all");
    expect(afterCollision.sessions.map((session) => session.id)).not.toContain(slot.id);
    expect(afterCollision.listRevision).toBeGreaterThan(beforeCollision.listRevision);
    await expect(registry.acquire(slot.id)).rejects.toMatchObject({ code: "conflict" });
  });

  it("keeps row-summary revisions separate and lists phase without transcript snapshots", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-summary-revision-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const faux = fauxProvider({ provider: "tron-catalog-boundary", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("catalog ready")]);
    runtime.registerNativeProvider(faux.provider);
    const summaries: SessionSummaryUpdate[] = [];
    let listChanges = 0;
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: (summary) => summaries.push(summary),
      sessionListChanged: () => { listChanges += 1; },
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt(`catalog boundary ${"x".repeat(5_000)}`);
    await waitUntil(() => !slot.isBusy);
    await slot.rename(`catalog-${"n".repeat(5_000)}`);
    const before = await registry.catalog("user");
    const snapshot = vi.spyOn(slot, "snapshot");
    const structuralChangesBeforeSummary = listChanges;

    slot.publishSnapshot();
    snapshot.mockClear();
    const after = await registry.catalog("user");

    expect(summaries.at(-1)?.summaryRevision).toBeGreaterThan(0);
    expect(Buffer.byteLength(summaries.at(-1)?.firstMessage ?? "")).toBeLessThanOrEqual(1_024);
    expect(Buffer.byteLength(summaries.at(-1)?.name ?? "")).toBeLessThanOrEqual(1_024);
    expect(after.listRevision).toBe(before.listRevision);
    expect(listChanges).toBe(structuralChangesBeforeSummary);
    expect(after.sessions[0]?.phase).toBe(slot.catalogPhase);
    // Runtime-owned deferred publication may legitimately call snapshot(sequence)
    // here; catalog listing must never call the former zero-argument full snapshot.
    expect(snapshot.mock.calls.filter((arguments_) => arguments_.length === 0)).toHaveLength(0);
  });

  it("bounds recursive catalog directories and streamed entries before materialization", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-discovery-bounds-"));
    const agentDir = join(root, "agent");
    const catalog = join(agentDir, "sessions");
    await Promise.all([
      mkdir(join(catalog, "first"), { recursive: true }),
      mkdir(join(catalog, "second"), { recursive: true }),
    ]);
    const makeRegistry = (
      maximumDirectories: number,
      maximumEntries: number,
      maximumTraversalBytes = 8 * 1_024 * 1_024,
    ) => {
      const registry = new RuntimeRegistry({
        agentDir,
        tronHome: join(root, `tron-${maximumDirectories}-${maximumEntries}-${maximumTraversalBytes}`),
        idleRuntimeMs: 60_000,
        trust: new TrustService(agentDir),
        broadcast: () => {},
        sessionSummaryChanged: () => {},
        sessionListChanged: () => {},
        catalogDiscoveryLimits: { maximumDirectories, maximumEntries, maximumTraversalBytes },
      });
      registries.push(registry);
      return registry;
    };

    await expect(makeRegistry(2, 2).catalog("all")).rejects.toMatchObject({
      code: "busy",
      retryable: true,
    });
    await expect(makeRegistry(3, 1).catalog("all")).rejects.toMatchObject({
      code: "busy",
      retryable: true,
    });
    await expect(makeRegistry(3, 2, 1).catalog("all")).rejects.toMatchObject({ code: "busy" });
    await expect(makeRegistry(3, 2).catalog("all")).resolves.toMatchObject({ sessions: [] });
  });

  it("owns recursion without overlapping SDK directory materializations", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-direct-sdk-listing-"));
    const agentDir = join(root, "agent");
    const catalog = join(agentDir, "sessions");
    const child = join(catalog, "child");
    await Promise.all([mkdir(catalog, { recursive: true }), mkdir(child, { recursive: true })]);
    const directSession = SessionManager.create(root, catalog);
    const childSession = SessionManager.create(root, child);
    directSession.appendMessage(fauxAssistantMessage("direct catalog fixture"));
    childSession.appendMessage(fauxAssistantMessage("child catalog fixture"));

    expect((await SessionManager.listAll(catalog)).map((session) => session.id)).toEqual([
      directSession.getSessionId(),
    ]);
    expect((await SessionManager.listAll(child)).map((session) => session.id)).toEqual([
      childSession.getSessionId(),
    ]);

    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      catalogDiscoveryLimits: { maximumDirectories: 2, maximumSessions: 2 },
    });
    registries.push(registry);
    expect((await registry.catalog("all")).sessions.map((session) => session.id).sort()).toEqual([
      childSession.getSessionId(), directSession.getSessionId(),
    ].sort());
  });

  it("bounds discovered session count and bytes before normalization", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-materialization-bounds-"));
    const agentDir = join(root, "agent");
    await mkdir(join(agentDir, "sessions"), { recursive: true });
    const now = new Date("2026-01-01T00:00:00Z");
    const infos = ["first", "second"].map((id) => ({
      id,
      path: join(agentDir, "sessions", `${id}.jsonl`),
      cwd: root,
      created: now,
      modified: now,
      messageCount: 0,
      firstMessage: id,
      allMessagesText: "unused picker search text ".repeat(20_000),
    }));
    const encodedBytes = infos.reduce((total, { allMessagesText: _discarded, ...info }) => (
      total + Buffer.byteLength(JSON.stringify(info))
    ), 0);
    const listAll = vi.spyOn(SessionManager, "listAll").mockResolvedValue(infos as never);
    const makeRegistry = (maximumSessions: number, maximumRetainedBytes: number) => {
      const registry = new RuntimeRegistry({
        agentDir,
        tronHome: join(root, `tron-${maximumSessions}-${maximumRetainedBytes}`),
        idleRuntimeMs: 60_000,
        trust: new TrustService(agentDir),
        broadcast: () => {},
        sessionSummaryChanged: () => {},
        sessionListChanged: () => {},
        catalogDiscoveryLimits: { maximumSessions, maximumRetainedBytes, normalizationConcurrency: 1 },
      });
      registries.push(registry);
      return registry;
    };

    try {
      await expect(makeRegistry(1, encodedBytes).catalog("all")).rejects.toMatchObject({ code: "busy" });
      await expect(makeRegistry(2, encodedBytes - 1).catalog("all")).rejects.toMatchObject({ code: "busy" });
      await expect(makeRegistry(2, encodedBytes).catalog("all")).resolves.toMatchObject({
        sessions: [{ id: "first" }, { id: "second" }],
      });
    } finally {
      listAll.mockRestore();
    }
  });

  it("caps canonical session path normalization concurrency", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-normalization-concurrency-"));
    const agentDir = join(root, "agent");
    await mkdir(join(agentDir, "sessions"), { recursive: true });
    const now = new Date("2026-01-01T00:00:00Z");
    const infos = Array.from({ length: 6 }, (_, index) => ({
      id: `session-${index}`,
      path: join(agentDir, "sessions", `session-${index}.jsonl`),
      cwd: root,
      created: now,
      modified: now,
      messageCount: 0,
      firstMessage: `session ${index}`,
    }));
    const listAll = vi.spyOn(SessionManager, "listAll").mockResolvedValue(infos as never);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      catalogDiscoveryLimits: { normalizationConcurrency: 2 },
    });
    registries.push(registry);
    const internals = registry as unknown as {
      canonicalSessionPath: (path: string) => Promise<string>;
    };
    let active = 0;
    let maximumActive = 0;
    let release!: () => void;
    let reachedCapacity!: () => void;
    const capacity = new Promise<void>((resolve) => { reachedCapacity = resolve; });
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const canonicalize = vi.spyOn(internals, "canonicalSessionPath").mockImplementation(async (path) => {
      active += 1;
      maximumActive = Math.max(maximumActive, active);
      if (active === 2) reachedCapacity();
      await gate;
      active -= 1;
      return resolve(path);
    });

    try {
      const loading = registry.catalog("all");
      await capacity;
      expect(maximumActive).toBe(2);
      release();
      await loading;
      expect(maximumActive).toBe(2);
    } finally {
      canonicalize.mockRestore();
      listAll.mockRestore();
    }
  });

  it("reuses one stable catalog acquisition without a second transcript-wide materialization", async () => {
    const fixture = await coldFixture("reuse");
    const internals = fixture.registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const materialize = vi.spyOn(internals, "sessionInfos");

    const catalog = await fixture.registry.catalog("user");
    expect(catalog.sessions.map((session) => session.id)).toContain(fixture.manager.getSessionId());
    expect(materialize).toHaveBeenCalledTimes(1);
    fixture.manager.appendMessage(fauxAssistantMessage("ordinary append after catalog"));

    expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id).toBe(fixture.manager.getSessionId());
    expect(materialize).toHaveBeenCalledTimes(1);
    expect(fixture.runtimeFactory).toHaveBeenCalledTimes(1);

    // A hot slot not marked ambiguous by the latest full catalog bypasses
    // both transcript materialization and global header validation.
    const evidence = vi.spyOn(fixture.registry as any, "catalogStructureEvidence");
    expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id).toBe(fixture.manager.getSessionId());
    expect(materialize).toHaveBeenCalledTimes(1);
    expect(evidence).not.toHaveBeenCalled();
  });

  it("keeps a warmed disk index across live-only create and delete", async () => {
    const fixture = await coldFixture("warm-live-membership");
    const internals = fixture.registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const materialize = vi.spyOn(internals, "sessionInfos");

    await fixture.registry.catalog("user");
    expect(materialize).toHaveBeenCalledTimes(1);
    const live = await fixture.registry.create(fixture.cwd);
    expect((await fixture.registry.catalog("user")).sessions.map((session) => session.id)).toContain(live.id);
    expect(materialize).toHaveBeenCalledTimes(1);
    await fixture.registry.delete(live.id);
    expect((await fixture.registry.catalog("user")).sessions.map((session) => session.id)).not.toContain(live.id);
    expect(materialize).toHaveBeenCalledTimes(1);
  });

  it("does not certify a cached index when traversal evidence is incomplete", async () => {
    const fixture = await coldFixture("incomplete-index-evidence");
    const internals = fixture.registry as unknown as {
      sessionInfos: () => Promise<unknown[]>;
      catalogStructureEvidence: () => Promise<{ digest: string; identitiesByPath: ReadonlyMap<string, unknown>; complete: boolean }>;
    };
    const materialize = vi.spyOn(internals, "sessionInfos");
    await fixture.registry.catalog("all");
    expect(materialize).toHaveBeenCalledTimes(1);
    const evidence = await internals.catalogStructureEvidence();
    const evidenceSpy = vi.spyOn(internals, "catalogStructureEvidence")
      .mockResolvedValue({ ...evidence, complete: false });
    try {
      await fixture.registry.catalog("all");
      expect(materialize).toHaveBeenCalledTimes(2);
    } finally {
      evidenceSpy.mockRestore();
    }
  });

  it("deduplicates same-session starts and starts distinct sessions concurrently", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-concurrent-cold-starts-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const sessionDirectory = join(agentDir, "sessions", "workspace");
    await Promise.all([mkdir(sessionDirectory, { recursive: true }), mkdir(cwd, { recursive: true })]);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const firstManager = SessionManager.create(cwd, sessionDirectory);
    firstManager.appendMessage(fauxAssistantMessage("first cold start"));
    const secondManager = SessionManager.create(cwd, sessionDirectory);
    secondManager.appendMessage(fauxAssistantMessage("second cold start"));
    let entered = 0;
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const runtimeFactory = vi.fn(async () => {
      entered += 1;
      await gate;
      return ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    });
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      maximumLiveRuntimes: 2,
      modelRuntimeFactory: runtimeFactory,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    await registry.catalog("all");

    const first = registry.acquire(firstManager.getSessionId());
    const duplicate = registry.acquire(firstManager.getSessionId());
    const second = registry.acquire(secondManager.getSessionId());
    await waitUntil(() => entered === 2);
    expect(runtimeFactory).toHaveBeenCalledTimes(2);
    await expect(registry.create(cwd)).rejects.toMatchObject({ code: "busy", retryable: true });
    expect(runtimeFactory).toHaveBeenCalledTimes(2);
    release();
    const [firstSlot, duplicateSlot, secondSlot] = await Promise.all([first, duplicate, second]);
    expect(duplicateSlot).toBe(firstSlot);
    expect(secondSlot.id).toBe(secondManager.getSessionId());
  });

  it("uses only bounded header evidence when cold acquisition has no reusable admission", async () => {
    const fixture = await coldFixture("uncached");
    const internals = fixture.registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const materialize = vi.spyOn(internals, "sessionInfos");

    expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id).toBe(fixture.manager.getSessionId());
    expect(materialize).not.toHaveBeenCalled();
    expect(fixture.runtimeFactory).toHaveBeenCalledTimes(1);
  });

  it("ignores jsonl-named directories during lightweight acquisition", async () => {
    const fixture = await coldFixture("jsonl-directory");
    await mkdir(join(fixture.agentDir, "sessions", "unrelated.jsonl"));
    const internals = fixture.registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const materialize = vi.spyOn(internals, "sessionInfos");

    expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id)
      .toBe(fixture.manager.getSessionId());
    expect(materialize).not.toHaveBeenCalled();
  });

  it("falls back to stable SDK discovery for an unrelated malformed header", async () => {
    const fixture = await coldFixture("malformed-fallback");
    const unrelated = join(fixture.agentDir, "sessions", "unrelated");
    await mkdir(unrelated, { recursive: true });
    await writeFile(join(unrelated, "malformed.jsonl"), `${"x".repeat(70_000)}\n`);
    const internals = fixture.registry as unknown as {
      sessionInfos: () => Promise<unknown[]>;
      catalogAcquisitionAdmission?: unknown;
    };
    const materialize = vi.spyOn(internals, "sessionInfos");

    expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id)
      .toBe(fixture.manager.getSessionId());
    expect(materialize).toHaveBeenCalledTimes(3);
    expect(internals.catalogAcquisitionAdmission).toBeUndefined();
  });

  it("revalidates oversized SDK identities after fallback resolution", async () => {
    const fixture = await coldFixture("oversized-fallback-identity");
    const unrelatedDirectory = join(fixture.agentDir, "sessions", "unrelated-oversized");
    const unrelatedFile = join(unrelatedDirectory, "unrelated.jsonl");
    await mkdir(unrelatedDirectory, { recursive: true });
    const originalLines = (await readFile(fixture.sessionFile, "utf8")).split("\n");
    const originalHeader = JSON.parse(originalLines[0]!) as Record<string, unknown>;
    originalLines[0] = JSON.stringify({
      ...originalHeader,
      id: "unrelated-oversized-session",
      padding: "x".repeat(70_000),
    });
    await writeFile(unrelatedFile, originalLines.join("\n"));
    const internals = fixture.registry as unknown as {
      fallbackCatalogAcquisition: () => Promise<unknown>;
      sessionInfos: () => Promise<unknown[]>;
    };
    const originalFallback = internals.fallbackCatalogAcquisition.bind(fixture.registry);
    const fallback = vi.spyOn(internals, "fallbackCatalogAcquisition").mockImplementation(async () => {
      const resolution = await originalFallback();
      const mutatedLines = (await readFile(unrelatedFile, "utf8")).split("\n");
      const mutatedHeader = JSON.parse(mutatedLines[0]!) as Record<string, unknown>;
      mutatedLines[0] = JSON.stringify({ ...mutatedHeader, id: fixture.manager.getSessionId() });
      await writeFile(unrelatedFile, mutatedLines.join("\n"));
      return resolution;
    });
    const materialize = vi.spyOn(internals, "sessionInfos");

    await expect(fixture.registry.acquire(fixture.manager.getSessionId()))
      .rejects.toMatchObject({ code: "busy", retryable: true });
    expect(fallback).toHaveBeenCalledTimes(1);
    expect(materialize).toHaveBeenCalledTimes(3);
    expect(fixture.runtimeFactory).not.toHaveBeenCalled();
  });

  it("invalidates reusable acquisition when a duplicate or removal changes canonical membership", async () => {
    const duplicateFixture = await coldFixture("duplicate-membership");
    const duplicateInternals = duplicateFixture.registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const duplicateMaterialize = vi.spyOn(duplicateInternals, "sessionInfos");
    await duplicateFixture.registry.catalog("all");
    const duplicateDirectory = join(duplicateFixture.agentDir, "sessions", "duplicate");
    await mkdir(duplicateDirectory, { recursive: true });
    await copyFile(
      duplicateFixture.sessionFile,
      join(duplicateDirectory, "duplicate.jsonl"),
    );

    await expect(duplicateFixture.registry.acquire(duplicateFixture.manager.getSessionId())).rejects.toMatchObject({
      code: "conflict",
    });
    expect(duplicateMaterialize).toHaveBeenCalledTimes(1);
    expect(duplicateFixture.runtimeFactory).not.toHaveBeenCalled();
    await rm(join(duplicateDirectory, "duplicate.jsonl"));
    expect((await duplicateFixture.registry.acquire(duplicateFixture.manager.getSessionId())).id)
      .toBe(duplicateFixture.manager.getSessionId());
    expect(duplicateMaterialize).toHaveBeenCalledTimes(1);
    const duplicateAgain = join(duplicateDirectory, "duplicate-again.jsonl");
    await copyFile(duplicateFixture.sessionFile, duplicateAgain);
    await duplicateFixture.registry.catalog("all");
    await expect(duplicateFixture.registry.acquire(duplicateFixture.manager.getSessionId())).rejects.toMatchObject({
      code: "conflict",
    });
    await rm(duplicateAgain);
    expect((await duplicateFixture.registry.acquire(duplicateFixture.manager.getSessionId())).id)
      .toBe(duplicateFixture.manager.getSessionId());

    const removedFixture = await coldFixture("removed-membership");
    const removedInternals = removedFixture.registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const removedMaterialize = vi.spyOn(removedInternals, "sessionInfos");
    await removedFixture.registry.catalog("all");
    await rm(removedFixture.sessionFile);

    await expect(removedFixture.registry.acquire(removedFixture.manager.getSessionId())).rejects.toMatchObject({
      code: "not_found",
    });
    expect(removedMaterialize).toHaveBeenCalledTimes(1);
    expect(removedFixture.runtimeFactory).not.toHaveBeenCalled();
  });

  it("resolves deepest nested topology owners without scanning every root", async () => {
    const fixture = await coldFixture("topology-helper");
    const internals = fixture.registry as unknown as {
      nestedOwners: (sessions: Array<{ id: string; path: string }>) => ReadonlyMap<string, string>;
    };
    const root = join(fixture.root, "topology");
    const parent = join(root, "parent.jsonl");
    const child = join(root, "parent", "child.jsonl");
    const grandchild = join(root, "parent", "child", "run", "grandchild.jsonl");
    const unrelated = join(root, "unrelated.jsonl");

    expect([...internals.nestedOwners([
      { id: "parent", path: parent },
      { id: "child", path: child },
      { id: "grandchild", path: grandchild },
      { id: "unrelated", path: unrelated },
    ])]).toEqual([
      [resolve(child), "parent"],
      [resolve(grandchild), "child"],
    ]);
  });

  it("keeps structural and exact current named subagent sessions non-openable", async () => {
    const nestedFixture = await coldFixture("nested-subagent", { nested: true });
    const nestedInternals = nestedFixture.registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const nestedMaterialize = vi.spyOn(nestedInternals, "sessionInfos");
    const nestedCatalog = await nestedFixture.registry.catalog("all");
    expect(nestedCatalog.sessions.find((session) => session.id === nestedFixture.manager.getSessionId())?.kind)
      .toBe("subagent");
    await expect(nestedFixture.registry.acquire(nestedFixture.manager.getSessionId())).rejects.toMatchObject({
      code: "conflict",
    });
    expect(nestedMaterialize).toHaveBeenCalledTimes(1);
    expect(nestedFixture.runtimeFactory).not.toHaveBeenCalled();

    const namedFixture = await coldFixture("named-subagent", { name: "subagent-catalog-child" });
    const namedInternals = namedFixture.registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const namedMaterialize = vi.spyOn(namedInternals, "sessionInfos");
    await expect(namedFixture.registry.acquire(namedFixture.manager.getSessionId())).rejects.toMatchObject({
      code: "conflict",
    });
    expect(namedMaterialize).not.toHaveBeenCalled();
    expect(namedFixture.runtimeFactory).not.toHaveBeenCalled();

    const renamedFixture = await coldFixture("renamed-subagent");
    const renamedInternals = renamedFixture.registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const renamedMaterialize = vi.spyOn(renamedInternals, "sessionInfos");
    await renamedFixture.registry.catalog("all");
    renamedFixture.manager.appendSessionInfo("subagent-renamed-after-catalog");
    await expect(renamedFixture.registry.acquire(renamedFixture.manager.getSessionId())).rejects.toMatchObject({
      code: "conflict",
    });
    expect(renamedMaterialize).toHaveBeenCalledTimes(1);
    expect(renamedFixture.runtimeFactory).not.toHaveBeenCalled();
  });

  it("rejects identity, cwd, or duplicate mutation before runtime creation", async () => {
    for (const field of ["id", "cwd", "duplicate"] as const) {
      const fixture = await coldFixture(`${field}-race`);
      await fixture.registry.catalog("all");
      const replacementCwd = join(fixture.root, "replacement-workspace");
      await mkdir(replacementCwd);
      const internals = fixture.registry as unknown as {
        catalogAcquisition: () => Promise<unknown>;
      };
      const original = internals.catalogAcquisition.bind(fixture.registry);
      const admission = vi.spyOn(internals, "catalogAcquisition").mockImplementation(async () => {
        const acquired = await original();
        if (field === "duplicate") {
          const duplicateDirectory = join(fixture.agentDir, "sessions", "duplicate-gap");
          await mkdir(duplicateDirectory, { recursive: true });
          await copyFile(fixture.sessionFile, join(duplicateDirectory, "duplicate.jsonl"));
        } else {
          const lines = (await readFile(fixture.sessionFile, "utf8")).split("\n");
          const header = JSON.parse(lines[0]!) as Record<string, unknown>;
          lines[0] = JSON.stringify({
            ...header,
            [field]: field === "id" ? "replacement-session-id" : replacementCwd,
          });
          await writeFile(fixture.sessionFile, lines.join("\n"));
        }
        return acquired;
      });

      try {
        await expect(fixture.registry.acquire(fixture.manager.getSessionId())).rejects.toMatchObject({
          code: field === "duplicate" ? "busy" : "conflict",
        });
        expect(fixture.runtimeFactory).not.toHaveBeenCalled();
      } finally {
        admission.mockRestore();
      }
    }
  });

  it("retries lightweight acquisition without stamping invalidated evidence current", async () => {
    const fixture = await coldFixture("lightweight-generation-race");
    const internals = fixture.registry as unknown as {
      buildCatalogAcquisition: (...arguments_: any[]) => Promise<unknown>;
      catalogAcquisition: () => Promise<unknown>;
      invalidateCatalogAcquisition: () => void;
      catalogAcquisitionInvalidationGeneration: number;
      catalogAcquisitionAdmission?: { invalidationGeneration: number };
    };
    const original = internals.buildCatalogAcquisition.bind(fixture.registry);
    let calls = 0;
    const build = vi.spyOn(internals, "buildCatalogAcquisition").mockImplementation(async (...arguments_) => {
      const resolution = await original(...arguments_);
      calls += 1;
      if (calls === 1) internals.invalidateCatalogAcquisition();
      return resolution;
    });

    await internals.catalogAcquisition();
    expect(build).toHaveBeenCalledTimes(2);
    expect(internals.catalogAcquisitionAdmission?.invalidationGeneration)
      .toBe(internals.catalogAcquisitionInvalidationGeneration);
  });

  it("fails busy after a second lightweight acquisition invalidation", async () => {
    const fixture = await coldFixture("repeated-lightweight-generation-race");
    const internals = fixture.registry as unknown as {
      catalogStructureEvidence: () => Promise<unknown>;
      catalogAcquisition: () => Promise<unknown>;
      invalidateCatalogAcquisition: () => void;
      catalogAcquisitionAdmission?: unknown;
    };
    const original = internals.catalogStructureEvidence.bind(fixture.registry);
    const evidence = vi.spyOn(internals, "catalogStructureEvidence").mockImplementation(async () => {
      const captured = await original();
      internals.invalidateCatalogAcquisition();
      return captured;
    });

    await expect(internals.catalogAcquisition()).rejects.toMatchObject({ code: "busy", retryable: true });
    expect(evidence).toHaveBeenCalledTimes(2);
    expect(internals.catalogAcquisitionAdmission).toBeUndefined();
  });

  it("cannot republish an acquisition invalidated during full materialization", async () => {
    const fixture = await coldFixture("invalidation-race");
    const internals = fixture.registry as unknown as {
      sessionInfos: () => Promise<unknown[]>;
      invalidateCatalogAcquisition: () => void;
    };
    const original = internals.sessionInfos.bind(fixture.registry);
    let calls = 0;
    const materialize = vi.spyOn(internals, "sessionInfos").mockImplementation(async () => {
      const infos = await original();
      calls += 1;
      if (calls === 1) internals.invalidateCatalogAcquisition();
      return infos;
    });

    await fixture.registry.catalog("all");
    expect(materialize).toHaveBeenCalledTimes(2);
    await fixture.registry.acquire(fixture.manager.getSessionId());
    expect(materialize).toHaveBeenCalledTimes(2);
  });

  it("rejects a mutation in the final full-catalog publication gap", async () => {
    const fixture = await coldFixture("final-publication-gap");
    const internals = fixture.registry as unknown as {
      publishCatalogAcquisition: (...arguments_: unknown[]) => Promise<boolean>;
      invalidateCatalogAcquisition: () => void;
      updateCatalogIdentity: (...arguments_: unknown[]) => void;
      catalogAcquisitionAdmission?: unknown;
    };
    const original = internals.publishCatalogAcquisition.bind(fixture.registry);
    const publication = vi.spyOn(internals, "publishCatalogAcquisition").mockImplementation(async (...arguments_) => {
      const admitted = await original(...arguments_);
      internals.invalidateCatalogAcquisition();
      return admitted;
    });
    const identity = vi.spyOn(internals, "updateCatalogIdentity");

    await expect(fixture.registry.catalog("all")).rejects.toMatchObject({ code: "busy", retryable: true });
    expect(publication).toHaveBeenCalledTimes(1);
    expect(identity).not.toHaveBeenCalled();
    expect(internals.catalogAcquisitionAdmission).toBeUndefined();
  });

  it("fails busy without publishing after a second unstable full materialization", async () => {
    const fixture = await coldFixture("repeated-instability");
    const internals = fixture.registry as unknown as {
      catalogStructureEvidence: () => Promise<{ digest: string; identitiesByPath: ReadonlyMap<string, unknown>; complete: boolean }>;
      catalogAcquisition: () => Promise<unknown>;
      sessionInfos: () => Promise<unknown[]>;
      updateCatalogIdentity: (...arguments_: unknown[]) => void;
      catalogAcquisitionAdmission?: unknown;
    };
    await internals.catalogAcquisition();
    expect(internals.catalogAcquisitionAdmission).toBeDefined();
    const originalEvidence = internals.catalogStructureEvidence.bind(fixture.registry);
    let evidenceCall = 0;
    const evidence = vi.spyOn(internals, "catalogStructureEvidence").mockImplementation(async () => {
      const current = await originalEvidence();
      evidenceCall += 1;
      return { ...current, digest: `${current.digest}-${evidenceCall}` };
    });
    const materialize = vi.spyOn(internals, "sessionInfos");
    const publishIdentity = vi.spyOn(internals, "updateCatalogIdentity");

    try {
      await expect(fixture.registry.catalog("all")).rejects.toMatchObject({ code: "busy", retryable: true });
      expect(materialize).toHaveBeenCalledTimes(2);
      expect(publishIdentity).not.toHaveBeenCalled();
      expect(internals.catalogAcquisitionAdmission).toBeUndefined();
    } finally {
      evidence.mockRestore();
    }
  });

  it("bounds validation reads and retained acquisition evidence before publication", async () => {
    const headerFixture = await coldFixture("header-bound");
    const headerRegistry = new RuntimeRegistry({
      agentDir: headerFixture.agentDir,
      tronHome: join(headerFixture.root, "tron-header-bound"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(headerFixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      catalogDiscoveryLimits: { maximumHeaderBytes: 1 },
    });
    registries.push(headerRegistry);
    await expect(headerRegistry.catalog("all")).resolves.toMatchObject({
      sessions: expect.arrayContaining([expect.objectContaining({ id: headerFixture.manager.getSessionId() })]),
    });

    const admissionRegistry = new RuntimeRegistry({
      agentDir: headerFixture.agentDir,
      tronHome: join(headerFixture.root, "tron-admission-bound"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(headerFixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      catalogDiscoveryLimits: { maximumAcquisitionBytes: 1 },
    });
    registries.push(admissionRegistry);
    await expect(admissionRegistry.catalog("all")).resolves.toMatchObject({
      sessions: expect.arrayContaining([expect.objectContaining({ id: headerFixture.manager.getSessionId() })]),
    });
    await expect(admissionRegistry.acquire(headerFixture.manager.getSessionId()))
      .rejects.toMatchObject({ code: "busy", retryable: true });
  });

  it("admits scaled short headers within the aggregate validation budget", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-short-header-budget-"));
    const agentDir = join(root, "agent");
    const directory = join(agentDir, "sessions", "workspace");
    const cwd = join(root, "workspace");
    const count = 64;
    await Promise.all([mkdir(directory, { recursive: true }), mkdir(cwd)]);
    await Promise.all(Array.from({ length: count }, (_, index) => writeFile(
      join(directory, `session-${index}.jsonl`),
      `${JSON.stringify({
        type: "session",
        version: 3,
        id: `session-${index}`,
        timestamp: "2026-01-01T00:00:00.000Z",
        cwd,
      })}\n${"x".repeat(4_096)}\n`,
    )));
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      catalogDiscoveryLimits: {
        maximumSessions: count,
        maximumHeaderBytes: count * 512,
        normalizationConcurrency: 4,
      },
    });
    registries.push(registry);
    const internals = registry as unknown as {
      catalogAcquisition: () => Promise<{ entriesByID: ReadonlyMap<string, unknown> }>;
      readCatalogHeader: (...arguments_: any[]) => Promise<unknown>;
    };
    const original = internals.readCatalogHeader.bind(registry);
    let active = 0;
    let maximumActive = 0;
    let releaseResolve!: () => void;
    let capacityResolve!: () => void;
    const release = new Promise<void>((resolve) => { releaseResolve = resolve; });
    const capacity = new Promise<void>((resolve) => { capacityResolve = resolve; });
    const headers = vi.spyOn(internals, "readCatalogHeader").mockImplementation(async (...arguments_) => {
      active += 1;
      maximumActive = Math.max(maximumActive, active);
      if (maximumActive === 4) capacityResolve();
      await release;
      try { return await original(...arguments_); }
      finally { active -= 1; }
    });

    const acquiring = internals.catalogAcquisition();
    await capacity;
    expect(maximumActive).toBe(4);
    releaseResolve();
    expect((await acquiring).entriesByID.size).toBe(count);
    expect(headers).toHaveBeenCalledTimes(count);
  });

  it("reserves a deterministic aggregate header-read budget across concurrent readers", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-strict-header-budget-"));
    const agentDir = join(root, "agent");
    const directory = join(agentDir, "sessions", "workspace");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(directory, { recursive: true }), mkdir(cwd)]);
    await Promise.all(Array.from({ length: 8 }, (_, index) => writeFile(
      join(directory, `session-${index}.jsonl`),
      `${JSON.stringify({
        type: "session",
        id: `session-${index}`,
        cwd: index < 4 ? "/x" : "x".repeat(200),
      })}\n${"x".repeat(4_096)}\n`,
    )));
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      catalogDiscoveryLimits: {
        maximumHeaderBytes: 2 * 512,
        normalizationConcurrency: 4,
      },
    });
    registries.push(registry);
    const internals = registry as unknown as {
      catalogStructureEvidence: () => Promise<{
        complete: boolean;
        digest: string;
        identitiesByPath: ReadonlyMap<string, unknown>;
      }>;
    };

    const first = await internals.catalogStructureEvidence();
    const second = await internals.catalogStructureEvidence();
    expect(first.complete).toBe(false);
    expect(first.identitiesByPath.size).toBe(4);
    expect([...first.identitiesByPath.keys()]).toEqual([...second.identitiesByPath.keys()]);
    expect(first.digest).toBe(second.digest);
  });

  it("acquires from header evidence while a full catalog materialization is suspended", async () => {
    const fixture = await coldFixture("concurrent-list");
    const internals = fixture.registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const original = internals.sessionInfos.bind(fixture.registry);
    let suspendedResolve!: () => void;
    let releaseResolve!: () => void;
    const suspended = new Promise<void>((resolve) => { suspendedResolve = resolve; });
    const release = new Promise<void>((resolve) => { releaseResolve = resolve; });
    const materialize = vi.spyOn(internals, "sessionInfos").mockImplementation(async () => {
      suspendedResolve();
      await release;
      return original();
    });

    const listing = fixture.registry.catalog("all");
    await suspended;
    try {
      expect((await fixture.registry.acquire(fixture.manager.getSessionId())).id)
        .toBe(fixture.manager.getSessionId());
      expect(materialize).toHaveBeenCalledTimes(1);
    } finally {
      releaseResolve();
    }
    await expect(listing).resolves.toMatchObject({
      sessions: expect.arrayContaining([expect.objectContaining({ id: fixture.manager.getSessionId() })]),
    });
  });

  it("never stamps captured stale catalog fields with a newer summary revision", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-summary-race-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const faux = fauxProvider({ provider: "tron-catalog-race", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("catalog ready")]);
    runtime.registerNativeProvider(faux.provider);
    const summaries: SessionSummaryUpdate[] = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: (summary) => summaries.push(summary),
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("catalog race baseline");
    await waitUntil(() => !slot.isBusy);
    await waitUntil(() => registry.attentionProjection(slot.id).isUnread);
    expect(registry.attentionProjection(slot.id)).toMatchObject({ completionRevision: 1, isUnread: true });

    const internals = registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const originalSessionInfos = internals.sessionInfos.bind(registry);
    let capturedResolve!: () => void;
    let releaseResolve!: () => void;
    const captured = new Promise<void>((resolve) => { capturedResolve = resolve; });
    const release = new Promise<void>((resolve) => { releaseResolve = resolve; });
    vi.spyOn(internals, "sessionInfos").mockImplementation(async () => {
      const infos = await originalSessionInfos();
      capturedResolve();
      await release;
      return infos;
    });

    const loading = registry.catalog("user");
    await captured;
    await slot.rename("new authoritative name");
    const latest = summaries.at(-1)!;
    releaseResolve();
    const catalog = await loading;

    expect(catalog.sessions[0]?.name).toBe(latest.name);
    expect(catalog.sessions[0]?.phase).toBe(latest.phase);
    expect(catalog.sessions[0]?.messageCount).toBe(latest.messageCount);
    expect(catalog.sessions[0]?.summaryRevision).toBe(latest.summaryRevision);
  });

  it("fails closed when multiple canonical files claim one session ID", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-duplicate-id-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const faux = fauxProvider({ provider: "tron-duplicate-session-id", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("persisted")]);
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("persist duplicate ownership fixture");
    await waitUntil(() => !slot.isBusy);
    const internals = registry as unknown as {
      sessionInfos: () => Promise<Array<Record<string, unknown>>>;
    };
    const originalSessionInfos = internals.sessionInfos.bind(registry);
    const existing = (await originalSessionInfos()).find((session) => session.id === slot.id)!;
    const duplicate = {
      ...existing,
      path: join(root, "duplicate", `${slot.id}.jsonl`),
    };
    let reverseDiscoveryOrder = false;
    const discovery = vi.spyOn(internals, "sessionInfos").mockImplementation(async () => (
      reverseDiscoveryOrder ? [duplicate, existing] : [existing, duplicate]
    ));

    const conflicted = await registry.catalog("all");
    expect(conflicted.sessions.find((session) => session.id === slot.id)).toBeUndefined();
    reverseDiscoveryOrder = true;
    const reordered = await registry.catalog("all");
    expect(reordered.listRevision).toBe(conflicted.listRevision);
    expect(reordered.sessions.find((session) => session.id === slot.id)).toBeUndefined();
    // Open admission uses current canonical headers rather than the stale global
    // ambiguity last projected by a mocked full catalog.
    expect((await registry.acquire(slot.id)).id).toBe(slot.id);
    await expect(registry.delete(slot.id)).rejects.toMatchObject({ code: "conflict" });

    discovery.mockRestore();
    const repaired = await registry.catalog("all");
    expect(repaired.sessions.filter((session) => session.id === slot.id)).toHaveLength(1);
    expect((await registry.acquire(slot.id)).id).toBe(slot.id);
  });

  it("runs distinct sessions concurrently and keeps a run alive after its client disconnects", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-runtime-integration-"));
    const agentDir = join(root, "agent");
    const tronHome = join(root, "tron");
    const firstCwd = join(root, "first");
    const secondCwd = join(root, "second");
    await Promise.all([mkdir(agentDir), mkdir(tronHome), mkdir(firstCwd), mkdir(secondCwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;

    const faux = fauxProvider({ provider: "tron-test", tokensPerSecond: 10_000 });
    const runtimes: ModelRuntime[] = [];
    const summaryUpdates: Array<{ sessionId: string; phase: string }> = [];
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      runtimes.push(runtime);
      return runtime;
    };
    faux.setResponses([
      async () => { await new Promise((resolve) => setTimeout(resolve, 150)); return fauxAssistantMessage("first complete"); },
      async () => { await new Promise((resolve) => setTimeout(resolve, 150)); return fauxAssistantMessage("second complete"); },
    ]);

    const registry = new RuntimeRegistry({
      agentDir,
      tronHome,
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: (summary) => summaryUpdates.push(summary),
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();

    const [first, second] = await Promise.all([registry.create(firstCwd), registry.create(secondCwd)]);
    expect(first.modelRuntime).not.toBe(second.modelRuntime);
    expect(runtimes).toHaveLength(2);
    const model = faux.getModel();
    await Promise.all([first.setModel(model.provider, model.id), second.setModel(model.provider, model.id)]);
    registry.subscribe("phone", first.id);
    registry.subscribe("phone", second.id);

    await Promise.all([first.prompt("one"), second.prompt("two")]);
    await waitUntil(() => first.isBusy && second.isBusy);
    expect(faux.state.callCount).toBe(2);
    expect(summaryUpdates).toEqual(expect.arrayContaining([
      expect.objectContaining({ sessionId: first.id, phase: "running" }),
      expect.objectContaining({ sessionId: second.id, phase: "running" }),
    ]));

    registry.unsubscribeClient("phone");
    expect(first.isBusy).toBe(true);
    expect(second.isBusy).toBe(true);
    let drainCompleted = false;
    const drain = registry.waitUntilIdle().then(() => { drainCompleted = true; });
    await new Promise((resolve) => setTimeout(resolve, 30));
    expect(drainCompleted).toBe(false);

    await waitUntil(() => !first.isBusy && !second.isBusy);
    await drain;
    expect(drainCompleted).toBe(true);
    const hasCompletion = (slot: typeof first) => slot.snapshot().transcript.some(
      (item) => item.kind === "message" && item.role === "assistant" && item.content.some(
        (part) => part.type === "text" && part.text.includes("complete"),
      ),
    );
    expect(hasCompletion(first)).toBe(true);
    expect(hasCompletion(second)).toBe(true);
    expect(summaryUpdates.filter((update) => update.phase === "idle").map((update) => update.sessionId)).toEqual(
      expect.arrayContaining([first.id, second.id]),
    );
  });

  it("lets accepted follow-up queue work execute naturally during administrative drain", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-restart-queue-drain-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseFirst!: () => void;
    const firstBarrier = new Promise<void>((resolve) => { releaseFirst = resolve; });
    const faux = fauxProvider({ provider: "tron-queue-drain", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => { await firstBarrier; return fauxAssistantMessage("first"); },
      fauxAssistantMessage("queued complete"),
    ]);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir), broadcast: () => {},
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("first");
    await waitUntil(() => slot.isBusy);
    const queued = await slot.prompt("accepted follow up", [], "followUp");
    expect(slot.snapshot().queuedItems).toMatchObject([{ id: queued.operationId, behavior: "followUp" }]);
    let drained = false;
    const drain = registry.waitUntilIdle().then(() => { drained = true; });
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(drained).toBe(false);
    expect(slot.snapshot().queuedItems).toHaveLength(1);
    releaseFirst();
    await waitUntil(() => faux.state.callCount === 2);
    await drain;
    expect(drained).toBe(true);
    expect(slot.snapshot().queuedItems).toEqual([]);
    expect(slot.snapshot().transcript.some((item) => item.kind === "message" && item.role === "assistant"
      && item.content.some((part) => part.type === "text" && part.text.includes("queued complete")))).toBe(true);
  });

  it("settles foreground completion without a second derived token", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-completion-capacity-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-completion-capacity", tokensPerSecond: 10_000 });
    faux.setResponses([async () => { await responseBarrier; return fauxAssistantMessage("complete"); }]);
    const workRegistry = new GatewayWorkRegistry("epoch", 4);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, workRegistry,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir), broadcast: () => {},
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("finish while derived capacity is full");
    await waitUntil(() => slot.catalogPhase === "running");
    const derived = [0, 1].map(() => workRegistry.beginDerived({
      kind: "administrative-provider-package-operation",
      hostEpoch: workRegistry.runtimeEpoch,
    }));

    releaseResponse();
    await waitUntil(() => slot.catalogPhase === "idle");
    expect(workRegistry.facts().filter((fact) => fact.sessionId === slot.id)).toEqual([]);
    for (const owner of derived) owner.settle();
  });

  it("includes runtime creation admitted before administrative drain", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-restart-create-drain-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);

    const trust = new TrustService(agentDir);
    const resolveTrust = trust.requireResolved.bind(trust);
    let markTrustEntered!: () => void;
    const trustEntered = new Promise<void>((resolve) => { markTrustEntered = resolve; });
    let releaseTrust!: () => void;
    const trustBarrier = new Promise<void>((resolve) => { releaseTrust = resolve; });
    vi.spyOn(trust, "requireResolved").mockImplementation(async (input) => {
      markTrustEntered();
      await trustBarrier;
      return resolveTrust(input);
    });
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust,
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();

    const creating = registry.create(cwd);
    await trustEntered;
    expect(registry.drainBusySessionCount()).toBe(1);
    const initialDrain = registry.beginAdministrativeDrain();
    expect(initialDrain).toMatchObject({
      phase: "preparing",
      blockerCount: 1,
      blockerCounts: { "slot-admission": 1 },
      omittedCount: 0,
      suspectProjectionCount: 0,
    });
    expect(initialDrain.blockers).toHaveLength(1);
    expect(initialDrain.blockers[0]?.id).toMatch(/^blocker-[0-9a-f]{20}$/u);
    expect(JSON.stringify(initialDrain)).not.toContain(cwd);
    const repeatedDrain = registry.beginAdministrativeDrain();
    expect(repeatedDrain.drainId).toBe(initialDrain.drainId);
    expect(repeatedDrain.revision).toBeGreaterThanOrEqual(initialDrain.revision);
    let drainSettled = false;
    const drain = registry.waitUntilIdle().then(() => { drainSettled = true; });
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(drainSettled).toBe(false);
    expect(registry.drainBusySessionCount()).toBe(1);
    await expect(registry.create(cwd)).rejects.toMatchObject({ code: "busy", retryable: true });

    releaseTrust();
    const slot = await creating;
    await drain;
    expect(drainSettled).toBe(true);
    expect(slot.isDrainBusy).toBe(false);
    await expect(slot.prompt("post-cutoff prompt")).rejects.toMatchObject({ code: "busy" });
    expect(slot.snapshot().queuedItems).toEqual([]);
    expect(registry.administrativeDrainSnapshot()).toMatchObject({ phase: "complete", blockerCount: 0 });
  });

  it.each(["complete", "failed"] as const)("reconciles an exact-owned historical %s artifact during administrative drain", async (terminalState) => {
    const fixture = await coldFixture("historical-terminal-drain");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = "historical-terminal-run";
    const toolCallId = "historical-terminal-tool";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    const startedAt = new Date(Date.now() - 5_000).toISOString();
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
    };
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId,
      activityId: "historical-terminal-activity",
      runId,
      toolCallId,
      source: { source: "pi-subagents" },
      title: "Pi Subagents",
      status: "running",
      startedAt,
      updatedAt: startedAt,
      children: [],
      lifecycle: {
        version: 1,
        state: "running",
        attention: "none",
        sequence: 1,
        observedAt: startedAt,
      },
    });
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    const registryInternal = fixture.registry as unknown as { artifactDiscoveryTimer?: NodeJS.Timeout };
    if (registryInternal.artifactDiscoveryTimer) clearInterval(registryInternal.artifactDiscoveryTimer);
    registryInternal.artifactDiscoveryTimer = undefined;
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      runId,
      state: "running",
      startedAt: Date.parse(startedAt),
      lastUpdate: Date.now(),
    }));

    const receiptManager = (slot as unknown as {
      runtime: { session: { sessionManager: SessionManager } };
    }).runtime.session.sessionManager;
    const receiptAppend = terminalState === "complete"
      ? vi.spyOn(receiptManager, "appendCustomEntry").mockImplementationOnce(() => {
          throw new Error("injected receipt persistence failure");
        })
      : undefined;
    expect(slot.isDrainBusy).toBe(true);
    let drainSettled = false;
    const drain = fixture.registry.waitUntilIdle().then(() => { drainSettled = true; });
    await new Promise((resolve) => setTimeout(resolve, 25));
    (slot as unknown as { stopExtensionActivityWatcher: (id: string) => void })
      .stopExtensionActivityWatcher(toolCallId);
    expect(drainSettled).toBe(false);

    const endedAt = Date.now();
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      // Deployed sessions may outlive the producer version that launched them.
      // pi-subagents persists after recording completion, so lastUpdate normally
      // follows endedAt. A later direct drain pass must reconcile this evidence
      // without watcher delivery or ambient discovery.
      runId,
      state: terminalState,
      startedAt: Date.parse(startedAt),
      endedAt,
      lastUpdate: endedAt + 1,
    }));

    await drain;
    expect(slot.isDrainBusy).toBe(false);
    expect(slot.snapshot().extensionActivities).toMatchObject([{
      toolCallId,
      status: terminalState === "failed" ? "failed" : "completed",
      lifecycle: { state: terminalState === "failed" ? "failed" : "completed" },
    }]);
    if (receiptAppend) expect(receiptAppend.mock.calls.length).toBeGreaterThanOrEqual(2);
  });

  it("does not retain unwatched async launcher acknowledgements as running work", async () => {
    const fixture = await coldFixture("unwatched-async-launcher");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const update = (slot as unknown as {
      updateExtensionActivity: (
        toolCallId: string, toolName: string, origin: ExtensionToolOrigin,
        status: "running" | "completed" | "failed", startedAt: string,
        updatedAt: string, value: unknown, completedAt?: string, durationMs?: number,
      ) => ExtensionRunActivity | undefined;
      extensionActivityWatchers: Map<string, unknown>;
    });
    const now = new Date().toISOString();
    const origin: ExtensionToolOrigin = { source: "project" };

    const idOnly = update.updateExtensionActivity(
      "id-only-tool", "subagent", origin, "completed", now, now,
      { details: { asyncId: "id-only-run", mode: "async" } }, now, 44,
    );
    expect(idOnly?.status).toBe("completed");
    expect(update.extensionActivityWatchers.has("id-only-tool")).toBe(false);

    const rejectedDirectory = update.updateExtensionActivity(
      "rejected-dir-tool", "subagent", origin, "completed", now, now,
      { details: { asyncId: "rejected-dir-run", mode: "async", asyncDir: "/tmp/not-owned-by-this-session" } }, now, 44,
    );
    expect(rejectedDirectory?.status).toBe("completed");
    expect(update.extensionActivityWatchers.has("rejected-dir-tool")).toBe(false);

    await fixture.registry.waitUntilIdle();
    expect(slot.isDrainBusy).toBe(false);
    expect(slot.snapshot().processActivities ?? []).toEqual([]);
  });

  it("emits exact removals when process producer identity is replaced", async () => {
    const fixture = await coldFixture("process-removal-delta");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      replaceProcessesForToolCall: (toolCallId: string, activities: SessionProcessActivity[]) => void;
      publishProcessesForToolCall: (toolCallId: string) => void;
    };
    const now = new Date().toISOString();
    const process = (processId: string, sequence: number): SessionProcessActivity => ({
      version: 1, processId, kind: "subagent", executionMode: "asynchronous",
      source: "delegatedAgent", visibility: "active", title: "worker", outputTruncated: false,
      lifecycle: { version: 1, state: "running", attention: "none", sequence, observedAt: now },
      toolCallId: "tool-1", runId: "run-1",
    });
    internal.replaceProcessesForToolCall("tool-1", [process("process-old", 1)]);
    internal.publishProcessesForToolCall("tool-1");
    fixture.events.splice(0);

    internal.replaceProcessesForToolCall("tool-1", [process("process-new", 2)]);
    internal.publishProcessesForToolCall("tool-1");
    const delta = fixture.events.find((event) => event.topic === "session.processActivity")?.payload.data;
    expect(delta).toMatchObject({
      activity: { processId: "process-new" },
      removedProcessIds: ["process-old"],
      overview: { visibility: "active", activeCount: 1 },
    });
  });

  it("claims receipt ownership before watcher-driven terminal projection", async () => {
    const fixture = await coldFixture("watcher-terminal-receipt");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = "watcher-terminal-run";
    const toolCallId = "watcher-terminal-tool";
    const activityId = "watcher-terminal-activity";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    const startedAt = new Date(Date.now() - 1_000).toISOString();
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
      refreshExtensionActivityFromArtifact: (toolCallId: string, asyncDir: string) => Promise<void>;
      runtime: { session: { sessionManager: SessionManager } };
    };
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId, activityId, runId, toolCallId,
      source: { source: "pi-subagents" }, title: "Pi Subagents", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    const receiptAppend = vi.spyOn(internal.runtime.session.sessionManager, "appendCustomEntry")
      .mockImplementationOnce(() => { throw new Error("injected receipt persistence failure"); });
    const endedAt = Date.now();
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      runId, state: "complete", startedAt: Date.parse(startedAt), endedAt, lastUpdate: endedAt + 1,
    }));

    await internal.refreshExtensionActivityFromArtifact(toolCallId, asyncDir);
    expect(slot.snapshot().extensionActivities).toMatchObject([{ toolCallId, status: "completed" }]);
    await fixture.registry.waitUntilIdle();
    expect(receiptAppend.mock.calls.length).toBeGreaterThanOrEqual(2);
  });

  it("retries an initial atomic async status replacement before projecting activity", async () => {
    const fixture = await coldFixture("async-status-initial-retry");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = "retry-run";
    const toolCallId = "retry-tool";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    const startedAt = new Date(Date.now() - 1_000).toISOString();
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      runId,
      state: "running",
      startedAt: Date.parse(startedAt),
      lastUpdate: Date.now(),
      mode: "workflow",
      steps: [{ runId: "retry-child", agent: "worker", status: "running", currentTool: "bash" }],
    }));
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
      readExtensionStatusArtifact: (asyncDir: string) => Promise<Record<string, unknown> | undefined>;
      startExtensionActivityWatcher: (toolCallId: string, asyncDir: string) => void;
    };
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId, activityId: "retry-activity", runId, toolCallId,
      source: { source: "pi-subagents" }, title: "Subagents", mode: "asynchronous", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    const originalRead = internal.readExtensionStatusArtifact.bind(slot);
    let reads = 0;
    internal.readExtensionStatusArtifact = async (directory) => {
      reads += 1;
      return reads === 1 ? undefined : originalRead(directory);
    };
    internal.startExtensionActivityWatcher(toolCallId, asyncDir);
    await waitUntil(() => reads >= 2 && (slot.snapshot().processActivities?.length ?? 0) === 1);
    expect(slot.snapshot().processActivities?.[0]).toMatchObject({
      kind: "subagent",
      executionMode: "asynchronous",
      visibility: "active",
      currentTool: "bash",
    });
  });

  it("persists only a validated opaque child-session reference for process viewing", async () => {
    const fixture = await coldFixture("validated-child-session");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = "validated-child-run";
    const toolCallId = "validated-child-tool";
    const activityId = "validated-child-activity";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    const parentFile = slot.sessionFile!;
    const childProducerId = "child-run";
    const childDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), childProducerId, "run-0");
    await Promise.all([mkdir(asyncDir, { recursive: true }), mkdir(childDirectory, { recursive: true })]);
    // Match the deployed pi-subagents producer: the canonical child path and
    // structural name carry the child run while the header omits parentSession.
    const childManager = SessionManager.create(fixture.cwd, childDirectory, {
      id: "validated-child-session",
    });
    childManager.appendSessionInfo(`subagent-worker-${childProducerId}-1`);
    childManager.appendMessage(fauxAssistantMessage("child transcript"));
    const childFile = childManager.getSessionFile()!;
    const startedAt = new Date(Date.now() - 1_000).toISOString();
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
      refreshExtensionActivityFromArtifact: (toolCallId: string, asyncDir: string) => Promise<void>;
    };
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId, activityId, runId, toolCallId,
      source: { source: "pi-subagents" }, title: "Subagents", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      runId,
      state: "running",
      startedAt: Date.parse(startedAt),
      lastUpdate: Date.now(),
      mode: "workflow",
      steps: [{ agent: "worker", status: "running", sessionFile: childFile }],
    }));
    await internal.refreshExtensionActivityFromArtifact(toolCallId, asyncDir);
    const activeSnapshot = slot.snapshot();
    const activeProcess = activeSnapshot.processActivities?.find((activity) => activity.kind === "subagent");
    expect(activeSnapshot.extensionActivities?.[0]?.lifecycle).toMatchObject({
      state: "running",
      visibility: "current",
    });
    expect(activeSnapshot.extensionActivities?.[0]?.lifecycle).not.toHaveProperty("remainingMs");
    expect(activeProcess).toMatchObject({
      title: "worker",
      childSessionRef: "validated-child-session",
      executionMode: "asynchronous",
      visibility: "active",
      lifecycle: { state: "running" },
    });

    const endedAt = Date.now();
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      runId,
      state: "complete",
      startedAt: Date.parse(startedAt),
      endedAt,
      lastUpdate: endedAt + 1,
      mode: "workflow",
      steps: [{ agent: "worker", status: "completed", sessionFile: childFile }],
    }));

    await internal.refreshExtensionActivityFromArtifact(toolCallId, asyncDir);
    const process = slot.snapshot().processActivities?.find((activity) => activity.kind === "subagent");
    expect(process).toMatchObject({
      title: "worker",
      childSessionRef: "validated-child-session",
      executionMode: "asynchronous",
    });
    expect(JSON.stringify(process)).not.toContain(childFile);
    expect(slot.processChildSessionPath(process!.processId)).toEqual({
      ref: "validated-child-session",
      producerId: childProducerId,
      runId,
      path: await realpath(childFile),
    });
    const admission = await fixture.registry.resolveReadOnlySubagentPath(
      "validated-child-session", await realpath(childFile), slot.id, process!.processId, runId,
    );
    const page = await fixture.registry.readOnlySubagentTranscriptPage(
      "validated-child-session", admission.path, slot.id, process!.processId, runId,
      undefined, undefined, admission.fileIdentity,
    );
    expect(page.total).toBeGreaterThan(0);
    expect(page.revision).toMatch(/^[a-f0-9]{32}$/u);
    expect(fixture.runtimeFactory).toHaveBeenCalledTimes(1);
    await expect(fixture.registry.resolveReadOnlySubagentPath(
      "validated-child-session", admission.path, slot.id, "wrong-process", runId,
    )).rejects.toMatchObject({ code: "not_found" });
    await waitUntil(() => slot.processHistory(undefined, 25, { kind: "subagent" }).activities.length === 1);
    expect(slot.processHistory(undefined, 25, { kind: "subagent" }).activities[0])
      .toMatchObject({ childSessionRef: "validated-child-session" });

    const replacement = `${childFile}.replacement`;
    await writeFile(replacement, await readFile(childFile));
    await rm(childFile);
    await rename(replacement, childFile);
    await expect(fixture.registry.readOnlySubagentTranscriptPage(
      "validated-child-session", admission.path, slot.id, process!.processId, runId,
      undefined, undefined, admission.fileIdentity,
    )).rejects.toMatchObject({ code: "conflict", retryable: true });
  });

  it("fails closed for foreign or wrong-run child-session evidence", async () => {
    const fixture = await coldFixture("rejected-child-session");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const unrelatedDirectory = join(fixture.agentDir, "sessions", "workspace", "unrelated");
    await mkdir(unrelatedDirectory, { recursive: true });
    const unrelated = SessionManager.create(fixture.cwd, unrelatedDirectory, { id: "unrelated-child" });
    unrelated.appendMessage(fauxAssistantMessage("not this run"));
    const startedAt = new Date().toISOString();
    const activity: ExtensionRunActivity = {
      id: "tool", activityId: "activity", runId: "expected-run", toolCallId: "tool",
      source: { source: "pi-subagents" }, title: "Subagents", status: "running",
      startedAt, updatedAt: startedAt,
      children: [{ id: "child-run", label: "worker", status: "running" }],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    };
    const attach = (slot as unknown as {
      attachChildSessionReferences: (activity: ExtensionRunActivity, value: unknown) => ExtensionRunActivity;
    }).attachChildSessionReferences.bind(slot);
    const foreign = attach(activity, {
      runId: "expected-run",
      results: [{ runId: "child-run", sessionFile: unrelated.getSessionFile() }],
    });
    expect(foreign.children[0]?.childSessionRef).toBeUndefined();
    const wrongRun = attach(activity, {
      runId: "forged-run",
      results: [{ runId: "child-run", sessionFile: unrelated.getSessionFile() }],
    });
    expect(wrongRun.children[0]?.childSessionRef).toBeUndefined();

    const parentFile = slot.sessionFile!;
    const oversizedDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "expected-run", "run-0");
    await mkdir(oversizedDirectory, { recursive: true });
    const oversizedFile = join(oversizedDirectory, "session.jsonl");
    await writeFile(oversizedFile, `${JSON.stringify({ type: "session", version: 3, id: "oversized-child", timestamp: startedAt, cwd: fixture.cwd })}${" ".repeat(70 * 1_024)}\n`);
    const oversized = attach(activity, {
      runId: "expected-run",
      results: [{ runId: "child-run", sessionFile: oversizedFile }],
    });
    expect(oversized.children[0]?.childSessionRef).toBeUndefined();

    const missingParentDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "child-run", "run-missing-parent");
    await mkdir(missingParentDirectory, { recursive: true });
    const missingParent = SessionManager.create(fixture.cwd, missingParentDirectory, { id: "missing-parent-child" });
    missingParent.appendSessionInfo("subagent-worker");
    const missingParentResult = attach(activity, {
      runId: "expected-run",
      results: [{ runId: "child-run", sessionFile: missingParent.getSessionFile() }],
    });
    expect(missingParentResult.children[0]?.childSessionRef).toBeUndefined();

    const ordinaryDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "expected-run", "run-ordinary");
    await mkdir(ordinaryDirectory, { recursive: true });
    const ordinary = SessionManager.create(fixture.cwd, ordinaryDirectory, {
      id: "ordinary-child",
      parentSession: parentFile,
    });
    ordinary.appendSessionInfo("ordinary-worker");
    const ordinaryResult = attach(activity, {
      runId: "expected-run",
      results: [{ runId: "child-run", sessionFile: ordinary.getSessionFile() }],
    });
    expect(ordinaryResult.children[0]?.childSessionRef).toBeUndefined();
  });

  it("rejects canonical artifact paths outside the exact project run root", async () => {
    const fixture = await coldFixture("artifact-path-containment");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const parent = join(fixture.cwd, ".pi", "subagents");
    const sibling = join(parent, "sibling");
    await mkdir(sibling, { recursive: true });
    const allowed = (slot as unknown as { extensionArtifactPathAllowed: (path: string) => boolean })
      .extensionArtifactPathAllowed.bind(slot);
    expect(allowed(parent)).toBe(false);
    expect(allowed(sibling)).toBe(false);
  });

  it("retains nonterminal artifact authority until receipt capacity is available", async () => {
    const workRegistry = new GatewayWorkRegistry("epoch", 2);
    const fixture = await coldFixture("artifact-receipt-capacity", { workRegistry });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = "capacity-run";
    const toolCallId = "capacity-tool";
    const activityId = "capacity-activity";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    const startedAt = new Date(Date.now() - 1_000).toISOString();
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
    };
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId, activityId, runId, toolCallId,
      source: { source: "pi-subagents" }, title: "Pi Subagents", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    expect(workRegistry.facts().filter((fact) => fact.sessionId === slot.id)).toEqual([]);
    const capacityOwner = workRegistry.beginDerived({
      kind: "administrative-provider-package-operation",
      hostEpoch: workRegistry.runtimeEpoch,
    });
    const endedAt = Date.now();
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      runId, state: "complete", startedAt: Date.parse(startedAt), endedAt, lastUpdate: endedAt + 1,
    }));

    await slot.reconcileOwnedExtensionArtifactsForDrain();
    expect(slot.snapshot().extensionActivities).toMatchObject([{ lifecycle: { state: "running" } }]);
    expect(slot.administrativeDrainBlockers()).toHaveLength(1);

    capacityOwner.settle();
    await slot.reconcileOwnedExtensionArtifactsForDrain();
    await waitUntil(() => slot.snapshot().extensionActivities[0]?.lifecycle?.state === "completed");
    expect(slot.administrativeDrainBlockers()).toEqual([]);
    await waitUntil(() => workRegistry.size === 0);
  });

  it("does not treat terminal attention presentation as drain work", async () => {
    const fixture = await coldFixture("terminal-attention-presentation");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const observedAt = new Date().toISOString();
    const internal = slot as unknown as { extensionActivities: Map<string, ExtensionRunActivity> };
    internal.extensionActivities.set("terminal-tool", {
      id: "terminal-tool", activityId: "terminal-activity", runId: "terminal-run", toolCallId: "terminal-tool",
      source: { source: "pi-subagents" }, title: "Pi Subagents", status: "failed",
      startedAt: observedAt, updatedAt: observedAt, children: [],
      lifecycle: {
        version: 1, state: "failed", attention: "needsAttention", sequence: 1,
        observedAt, terminalAt: observedAt,
      },
    });

    expect(slot.administrativeDrainBlockers()).toEqual([]);
    expect(slot.isDrainBusy).toBe(false);
  });

  it("keeps genuinely running exact-owned artifact work blocking across clock advances", async () => {
    const fixture = await coldFixture("running-artifact-clock");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const startedAt = new Date().toISOString();
    const internal = slot as unknown as { extensionActivities: Map<string, ExtensionRunActivity> };
    internal.extensionActivities.set("running-tool", {
      id: "running-tool", activityId: "running-activity", runId: "running-run", toolCallId: "running-tool",
      source: { source: "pi-subagents" }, title: "Pi Subagents", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    vi.useFakeTimers();
    try {
      vi.setSystemTime(new Date(Date.now() + 365 * 24 * 60 * 60_000));
      await vi.advanceTimersByTimeAsync(365 * 24 * 60 * 60_000);
      expect(slot.isDrainBusy).toBe(true);
    } finally {
      vi.useRealTimers();
    }
  });

  it("rate-limits artifact rejection warnings behind opaque owner identities", async () => {
    const fixture = await coldFixture("artifact-warning-redaction");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const warnings: Array<{ reason: string; owner: string }> = [];
    const internal = slot as unknown as {
      dependencies: { extensionArtifactWarning?: (warning: { reason: string; owner: string }) => void };
      warnExtensionArtifact: (reason: "ownership-mismatch", owner: string) => void;
    };
    internal.dependencies.extensionArtifactWarning = (warning) => warnings.push(warning);
    internal.warnExtensionArtifact("ownership-mismatch", "/private/project/run-with-output");
    internal.warnExtensionArtifact("ownership-mismatch", "/private/project/run-with-output");
    expect(warnings).toEqual([{ reason: "ownership-mismatch", owner: expect.stringMatching(/^[0-9a-f]{24}$/u) }]);
    expect(JSON.stringify(warnings)).not.toContain("private");
    expect(JSON.stringify(warnings)).not.toContain("output");
  });

  it("reconciles an exact-owned oversized terminal artifact from bounded event evidence", async () => {
    const fixture = await coldFixture("oversized-terminal-drain");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = "oversized-terminal-run";
    const toolCallId = "oversized-terminal-tool";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    const started = Date.now() - 5_000;
    const ended = Date.now() - 1_000;
    const startedAt = new Date(started).toISOString();
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
    };
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId,
      activityId: "oversized-terminal-activity",
      runId,
      toolCallId,
      source: { source: "pi-subagents" },
      title: "Pi Subagents",
      status: "running",
      startedAt,
      updatedAt: startedAt,
      children: [],
      lifecycle: {
        version: 1,
        state: "running",
        attention: "none",
        sequence: 1,
        observedAt: startedAt,
      },
    });
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    const status = JSON.stringify({
      runId,
      state: "complete",
      startedAt: started,
      lastUpdate: ended + 1,
      steps: [{ output: "x".repeat(300 * 1_024) }],
      endedAt: ended,
    });
    const completedEvent = JSON.stringify({
      ts: ended + 2,
      runId,
      type: "subagent.workflow.completed",
      state: "complete",
    });
    const foreignDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", "foreign-oversized-run");
    await mkdir(foreignDir);
    await writeFile(join(foreignDir, "status.json"), status);
    await symlink(join(foreignDir, "status.json"), join(asyncDir, "status.json"));
    await writeFile(join(asyncDir, "events.jsonl"), `${completedEvent}\n`);

    await slot.discoverExtensionArtifact(asyncDir);
    expect(slot.isDrainBusy).toBe(true);

    await rm(join(asyncDir, "status.json"));
    await writeFile(join(asyncDir, "status.json"), status);
    await writeFile(join(foreignDir, "events.jsonl"), `${completedEvent}\n`);
    await rm(join(asyncDir, "events.jsonl"));
    await symlink(join(foreignDir, "events.jsonl"), join(asyncDir, "events.jsonl"));
    await slot.discoverExtensionArtifact(asyncDir);
    expect(slot.isDrainBusy).toBe(true);

    await rm(join(asyncDir, "events.jsonl"));
    await writeFile(join(asyncDir, "events.jsonl"), `${completedEvent}\n${JSON.stringify({
      ts: ended + 3,
      runId,
      type: "subagent.workflow.completed",
      state: "failed",
    })}\n`);
    await slot.discoverExtensionArtifact(asyncDir);
    expect(slot.isDrainBusy).toBe(true);

    await writeFile(join(asyncDir, "events.jsonl"), `${JSON.stringify({
      ts: ended + 4,
      runId,
      type: "subagent.workflow.completed",
      state: "complete",
    })}\n`);
    await fixture.registry.waitUntilIdle();
    expect(slot.isDrainBusy).toBe(false);
    expect(slot.snapshot().extensionActivities).toMatchObject([{
      toolCallId,
      status: "completed",
      lifecycle: { state: "completed" },
    }]);
  });

  it("reconciles an exact-owned active artifact before the bounded ambient scan", async () => {
    const fixture = await coldFixture("artifact-priority-scan");
    const runId = "late-active-run";
    const toolCallId = "late-active-tool";
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const projectRoot = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs");
    await mkdir(projectRoot, { recursive: true });
    fixture.manager.appendMessage({
      role: "toolResult",
      toolCallId,
      toolName: "subagent",
      content: [{ type: "text", text: "launched" }],
      details: { runId, asyncDir: join(projectRoot, runId), state: "running" },
      isError: false,
      timestamp: Date.now(),
    });
    await Promise.all(Array.from({ length: 1_025 }, (_, index) => mkdir(join(projectRoot, `early-${String(index).padStart(4, "0")}`))));
    const activeDir = join(projectRoot, runId);
    await mkdir(activeDir);
    const now = Date.now();
    await writeFile(join(activeDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3,
      runId,
      state: "running",
      startedAt: now - 1_000,
      lastUpdate: now,
    }));
    vi.spyOn(slot as unknown as { extensionToolOrigin: (name: string) => { source: string } | undefined }, "extensionToolOrigin")
      .mockReturnValue({ source: "pi-subagents" });

    const discovered = vi.spyOn(slot, "discoverExtensionArtifact");
    await (fixture.registry as unknown as { discoverExtensionArtifacts: () => Promise<void> }).discoverExtensionArtifacts();
    expect(discovered).toHaveBeenCalledTimes(1);
    expect(discovered.mock.calls[0]?.[0]).toMatch(/async-subagent-runs[\\/]late-active-run$/u);
  });

  it("fails closed on a stale running artifact after canonical completion", async () => {
    const fixture = await coldFixture("stale-subagent-artifact");
    fixture.manager.appendMessage({
      role: "toolResult",
      toolCallId: "stale-tool-call",
      toolName: "subagent",
      content: [{ type: "text", text: "acknowledged" }],
      details: { runId: "stale-run", state: "completed" },
      isError: false,
      timestamp: Date.now(),
    });
    fixture.manager.appendMessage({
      role: "toolResult",
      toolCallId: "unbound-historical-tool-call",
      toolName: "subagent",
      content: [{ type: "text", text: "launched" }],
      details: { runId: "unbound-historical-run", state: "running" },
      isError: false,
      timestamp: Date.now(),
    });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", "stale-run");
    await mkdir(asyncDir, { recursive: true });
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3,
      runId: "stale-run",
      cwd: fixture.cwd,
      sessionId: slot.id,
      state: "running",
      startedAt: Date.now() - 1_000,
      lastUpdate: Date.now(),
    }));
    const internal = slot as unknown as { refreshSubagentActivityFromArtifact: (path: string) => Promise<void> };
    await internal.refreshSubagentActivityFromArtifact(asyncDir);
    expect(slot.snapshot().extensionActivities ?? []).toEqual([]);

    const projectRoot = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs");
    const unboundHistoricalDir = join(projectRoot, "unbound-historical-run");
    await mkdir(unboundHistoricalDir, { recursive: true });
    await writeFile(join(unboundHistoricalDir, "status.json"), JSON.stringify({
      runId: "unbound-historical-run",
      state: "complete",
      startedAt: Date.now() - 1_000,
      lastUpdate: Date.now(),
      endedAt: Date.now(),
    }));
    await internal.refreshSubagentActivityFromArtifact(unboundHistoricalDir);
    expect(slot.snapshot().extensionActivities ?? []).toEqual([]);

    const pathPolicy = slot as unknown as { extensionArtifactPathAllowed: (path: string) => boolean };
    expect(pathPolicy.extensionArtifactPathAllowed(projectRoot)).toBe(false);
    expect(pathPolicy.extensionArtifactPathAllowed(`${projectRoot}/.`)).toBe(false);
    expect(pathPolicy.extensionArtifactPathAllowed(`${projectRoot}/../escape`)).toBe(false);

    // A non-extension tool result carrying an arbitrary runId is not ownership
    // evidence, even when the artifact claims this exact session and cwd.
    fixture.manager.appendMessage({
      role: "toolResult",
      toolCallId: "ordinary-tool-call",
      toolName: "read",
      content: [{ type: "text", text: "ordinary" }],
      details: { runId: "ordinary-run", state: "completed" },
      isError: false,
      timestamp: Date.now(),
    });
    const ordinaryDir = join(projectRoot, "ordinary-run");
    await mkdir(ordinaryDir, { recursive: true });
    await writeFile(join(ordinaryDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3,
      runId: "ordinary-run",
      cwd: fixture.cwd,
      sessionId: slot.id,
      state: "running",
      startedAt: Date.now() - 1_000,
      lastUpdate: Date.now(),
    }));
    await internal.refreshSubagentActivityFromArtifact(ordinaryDir);
    expect(slot.snapshot().extensionActivities ?? []).toEqual([]);
  });

  it("binds artifact refresh to the canonical run directory and keeps admission time authoritative", async () => {
    const fixture = await coldFixture("artifact-binding-integrity");
    for (const duplicateToolCallId of ["canonical-first", "canonical-second"]) {
      fixture.manager.appendMessage({
        role: "toolResult",
        toolCallId: duplicateToolCallId,
        toolName: "subagent",
        content: [{ type: "text", text: "duplicate" }],
        details: { runId: "duplicate-canonical-run", state: "running" },
        isError: false,
        timestamp: Date.now(),
      });
    }
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = "bound-run";
    const toolCallId = "real-tool-call";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    const activityStartedAt = new Date(Date.now() - 5_000).toISOString();
    const artifactCompletedAt = new Date(Date.now() - 1_000).toISOString();
    const activity: ExtensionRunActivity = {
      id: toolCallId,
      runId,
      toolCallId,
      source: { source: "pi-subagents" },
      title: "Pi Subagents",
      status: "running",
      startedAt: activityStartedAt,
      updatedAt: activityStartedAt,
      children: [],
    };
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
      refreshSubagentActivityFromArtifact: (path: string) => Promise<void>;
      refreshExtensionActivityFromArtifact: (toolCallId: string, path: string) => Promise<void>;
      bindExtensionRunOwnership: (runId: string, binding: { toolCallId: string; asyncDir?: string; terminal: boolean }) => boolean;
      canonicalExtensionRunFacts: () => Map<string, { toolCallId?: string; terminal: boolean; ambiguous: boolean }>;
    };
    internal.extensionActivities.set(toolCallId, activity);
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3,
      runId,
      state: "completed",
      startedAt: Date.parse(activity.startedAt),
      lastUpdate: Date.parse(artifactCompletedAt),
      endedAt: Date.parse(artifactCompletedAt),
    }));
    await internal.refreshSubagentActivityFromArtifact(asyncDir);
    const admitted = slot.snapshot().extensionActivities?.find((candidate) => candidate.toolCallId === toolCallId);
    expect(admitted).toMatchObject({
      toolCallId,
      status: "completed",
      completedAt: artifactCompletedAt,
    });
    expect(admitted?.lifecycle?.terminalAt).toBe(admitted?.lifecycle?.observedAt);

    const foreignDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", "foreign-run");
    await mkdir(foreignDir, { recursive: true });
    await writeFile(join(foreignDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3,
      runId,
      state: "running",
      startedAt: Date.parse(activity.startedAt),
      lastUpdate: Date.parse("2026-01-01T00:00:05.000Z"),
    }));
    await internal.refreshSubagentActivityFromArtifact(foreignDir);
    await internal.refreshExtensionActivityFromArtifact(toolCallId, foreignDir);
    expect(slot.snapshot().extensionActivities).toMatchObject([{
      toolCallId,
      status: "completed",
      completedAt: artifactCompletedAt,
    }]);
    const afterForeign = slot.snapshot().extensionActivities?.find((candidate) => candidate.toolCallId === toolCallId);
    expect(afterForeign?.lifecycle?.terminalAt).toBe(admitted?.lifecycle?.terminalAt);

    expect(internal.bindExtensionRunOwnership(runId, {
      toolCallId: "second-real-tool-call",
      asyncDir: foreignDir,
      terminal: false,
    })).toBe(false);
    expect(internal.extensionRunOwnership.get(runId)?.toolCallId).toBe(toolCallId);

    vi.spyOn(slot as unknown as { extensionToolOrigin: (name: string) => { source: string } | undefined }, "extensionToolOrigin")
      .mockReturnValue({ source: "pi-subagents" });
    const duplicateFact = internal.canonicalExtensionRunFacts().get("duplicate-canonical-run");
    expect(duplicateFact?.toolCallId).toBeUndefined();
    expect(duplicateFact?.ambiguous).toBe(true);
  });

  it("runs the unchanged official status and working-indicator examples with the baseline theme", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-official-semantic-examples-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    const examples = join(getExamplesPath(), "extensions");
    await Promise.all([
      copyFile(join(examples, "status-line.ts"), join(extensionDir, "status-line.ts")),
      copyFile(join(examples, "working-indicator.ts"), join(extensionDir, "working-indicator.ts")),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-official-examples", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("persisted")]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      modelRuntimeFactory: async () => runtime,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const presentation = slot.snapshot().extensionPresentation;
    expect(presentation.semanticState.statuses["status-demo"]).toBe("Ready");
    expect(presentation.semanticState.statuses["working-indicator"]).toBe("Indicator: custom spinner");
    expect(presentation.semanticState.working.indicator).toMatchObject({ kind: "animated", intervalMs: 80 });
    expect(presentation.semanticState.working.indicator.frames.every((frame) => !frame.includes("\u001b"))).toBe(true);
    expect(slot.isBusy).toBe(false);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("persist session");
    await waitUntil(() => !slot.isBusy);
    await registry.reloadProject(cwd, true);
    expect(slot.snapshot().extensionPresentation.hostEpoch).not.toBe(presentation.hostEpoch);
    await slot.rename("decorative-state-delete-fixture");
    const sessionID = slot.id;
    await registry.delete(sessionID);
    await expect(registry.acquire(sessionID)).rejects.toMatchObject({ code: "not_found" });
  });

  it("projects retained component widgets through the RPC-bound host without enabling TUI mode", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-rpc-factory-dormant-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await mkdir(extensionDir, { recursive: true });
    await writeFile(join(extensionDir, "rpc-factory.ts"), `export default function (pi) {
      let invoked = false;
      pi.on("session_start", async (_event, ctx) => {
        ctx.ui.setStatus("context-has-ui", ctx.hasUI ? "true" : "false");
        ctx.ui.setStatus("context-mode", ctx.mode);
        ctx.ui.setWidget("factory", () => ({
          render: () => ["must mount"], invalidate: () => {}
        }));
        try {
          await ctx.ui.custom(() => {
            invoked = true;
            return { render: () => ["must not invoke"], invalidate: () => {} };
          });
        } catch {
          ctx.ui.setStatus("custom-deferred", invoked ? "invoked" : "not-invoked");
        }
      });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const internal = slot as unknown as { extensionHost: { isTuiStarted: boolean; mountedComponentCount: number } };
    await waitUntil(() => internal.extensionHost.mountedComponentCount === 1);
    expect(internal.extensionHost.isTuiStarted).toBe(true);
    const snapshot = slot.snapshot();
    expect(snapshot.extensionPresentation.semanticState.statuses).toMatchObject({
      "context-has-ui": "true", "context-mode": "rpc", "custom-deferred": "not-invoked",
    });
    expect(snapshot.extensionPresentation.semanticState.widgets).toEqual([]);
    expect(snapshot.extensionPresentation.surfaces).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: "widget:ZmFjdG9yeQ", kind: "widget", placement: "aboveEditor", inputMode: "none" }),
    ]));
  });

  it("keeps ask-style semantic selection on the RPC interaction path", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-rpc-semantic-ask-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await mkdir(extensionDir, { recursive: true });
    await writeFile(join(extensionDir, "semantic-ask.ts"), `export default function (pi) {
      pi.registerCommand("semantic-ask", { handler: async (_args, ctx) => {
        const answer = await ctx.ui.select("Choose a path", ["Keep", "Change"]);
        ctx.ui.setStatus("answer", answer ?? "Cancelled");
      }});
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const command = slot.prompt("/semantic-ask");
    await waitUntil(() => slot.snapshot().extensionPresentation.pendingInteractions.length === 1);
    const pending = slot.snapshot().extensionPresentation.pendingInteractions[0]!;
    expect(pending.method).toBe("select");
    expect(pending.options).toEqual(["Keep", "Change"]);
    const internal = slot as unknown as { respondToInteraction: (id: string, epoch: string, revision: number, value: unknown, cancelled: boolean) => void };
    internal.respondToInteraction(pending.id, pending.hostEpoch, pending.presentationRevision, "Keep", false);
    await command;
    expect(slot.snapshot().extensionPresentation.semanticState.statuses.answer).toBe("Keep");
  });

  it("rotates and retires semantic epochs on direct, command, and trust reload paths", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-semantic-epoch-reload-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "reload.ts"), `export default function (pi) {
      pi.on("session_start", (_event, ctx) => ctx.ui.setStatus("epoch", "started"));
      pi.registerCommand("reload-host", { handler: async (_args, ctx) => ctx.reload() });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const internal = slot as unknown as { ui: { context(): { confirm(title: string, message: string): Promise<boolean>; setStatus(key: string, text: string): void } } };
    const oldContext = internal.ui.context();
    const firstEpoch = slot.snapshot().extensionPresentation.hostEpoch;

    await slot.reload();
    const secondEpoch = slot.snapshot().extensionPresentation.hostEpoch;
    expect(secondEpoch).not.toBe(firstEpoch);
    expect(() => oldContext.setStatus("late", "old callback")).toThrow(expect.objectContaining({ code: "conflict" }));

    const pending = internal.ui.context().confirm("Pending", "Retire me");
    // Attach rejection observation before the command retires the epoch.
    const retiredPending = expect(pending).rejects.toMatchObject({ code: "cancelled" });
    await slot.prompt("/reload-host");
    await retiredPending;
    const thirdEpoch = slot.snapshot().extensionPresentation.hostEpoch;
    expect(thirdEpoch).not.toBe(secondEpoch);
    await registry.reloadProject(cwd, true);
    expect(slot.snapshot().extensionPresentation.hostEpoch).not.toBe(thirdEpoch);
  });

  it("serializes extension continuation ownership through a transient attention failure", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-settlement-overlap-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([
      mkdir(agentDir),
      mkdir(join(cwd, ".pi", "extensions"), { recursive: true }),
    ]);
    await writeFile(join(cwd, ".pi", "extensions", "continuation.ts"), `
let triggered = false;
export default function (pi) {
  pi.on("agent_settled", () => {
    if (triggered) return;
    triggered = true;
    pi.sendMessage({ customType: "test-continuation", content: "continue", display: false }, { triggerTurn: true });
  });
}
`);

    const faux = fauxProvider({ provider: "tron-settlement-overlap", tokensPerSecond: 10_000 });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    faux.setResponses([
      fauxAssistantMessage("first complete"),
      async () => {
        await new Promise((resolve) => setTimeout(resolve, 250));
        return fauxAssistantMessage("continuation complete");
      },
    ]);
    const snapshots: Array<{ phase: string; operation?: unknown }> = [];
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust,
      broadcast: (_sessionId, topic, payload) => {
        if (topic === "session.snapshot") snapshots.push(payload as { phase: string; operation?: unknown });
      },
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    expect(slot.sessionFile?.startsWith(join(agentDir, "sessions"))).toBe(true);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const attention = (registry as unknown as {
      attention: { complete: (sessionId: string, completionId: string) => Promise<unknown> };
    }).attention;
    const originalComplete = attention.complete.bind(attention);
    const complete = vi.spyOn(attention, "complete")
      .mockRejectedValueOnce(new Error("injected overlapping attention failure"))
      .mockImplementation(originalComplete);
    await slot.prompt("start");

    await waitUntil(() => faux.state.callCount === 2);
    expect(slot.snapshot()).toMatchObject({ phase: "running", operation: { kind: "prompt" } });
    const continuationSnapshotIndex = snapshots.length;
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(snapshots.slice(continuationSnapshotIndex).every((snapshot) => snapshot.phase === "running" && snapshot.operation)).toBe(true);
    await waitUntil(() => !slot.isBusy);
    expect(slot.snapshot()).toMatchObject({ phase: "idle" });
    expect(registry.attentionProjection(slot.id).completionRevision).toBe(2);
    const completionIds = complete.mock.calls.map(([, completionId]) => completionId);
    expect(completionIds).toHaveLength(3);
    expect(completionIds[0]).toBe(completionIds[1]);
    expect(completionIds[2]).not.toBe(completionIds[1]);
    expect(snapshots.some((snapshot) => snapshot.phase === "running" && snapshot.operation)).toBe(true);
  });

  it("recovers ordered continuation completions after the attention head repeatedly fails and restart", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-settlement-crash-durable-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([
      mkdir(agentDir),
      mkdir(join(cwd, ".pi", "extensions"), { recursive: true }),
    ]);
    await writeFile(join(cwd, ".pi", "extensions", "continuation.ts"), `
let triggered = false;
export default function (pi) {
  pi.on("agent_settled", () => {
    if (triggered) return;
    triggered = true;
    pi.sendMessage({ customType: "test-continuation", content: "continue", display: false }, { triggerTurn: true });
  });
}
`);
    const faux = fauxProvider({ provider: "tron-settlement-crash-durable", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage("completion A"),
      fauxAssistantMessage("completion B"),
    ]);
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const tronHome = join(root, "tron");
    const registry = new RuntimeRegistry({
      agentDir, tronHome, idleRuntimeMs: 60_000, modelRuntimeFactory: createModels, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const internals = registry as unknown as {
      attention: { complete: (sessionId: string, completionId: string) => Promise<unknown> };
      markers: {
        evidenceFor: (sessionId: string) => Promise<Array<{ assistantCompletionId?: string }>>;
        markAssistantCompletion: (
          sessionId: string, operationId: string, completionId: string, completedAt: string,
        ) => Promise<void>;
      };
    };
    vi.spyOn(internals.attention, "complete").mockRejectedValue(new Error("injected persistent attention failure"));
    const originalStamp = internals.markers.markAssistantCompletion.bind(internals.markers);
    let secondStampEntered!: () => void;
    let releaseSecondStamp!: () => void;
    const secondStampEntry = new Promise<void>((resolve) => { secondStampEntered = resolve; });
    const secondStampBarrier = new Promise<void>((resolve) => { releaseSecondStamp = resolve; });
    let stampCount = 0;
    vi.spyOn(internals.markers, "markAssistantCompletion").mockImplementation(async (...arguments_) => {
      stampCount += 1;
      if (stampCount === 2) {
        secondStampEntered();
        await secondStampBarrier;
      }
      await originalStamp(...arguments_);
    });

    await slot.prompt("start");
    await secondStampEntry;
    await waitUntil(() => slot.snapshot().phase === "interrupted");
    const blockedQueue = (slot as unknown as { completionOwnershipQueue: unknown[] }).completionOwnershipQueue;
    expect(blockedQueue).toHaveLength(2);
    let disposalSettled = false;
    const disposal = registry.dispose().finally(() => { disposalSettled = true; });
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(disposalSettled).toBe(false);
    releaseSecondStamp();
    await disposal;

    const durableCompletionIds = (await internals.markers.evidenceFor(slot.id))
      .map((marker) => marker.assistantCompletionId)
      .filter((id): id is string => id !== undefined);
    expect(durableCompletionIds).toHaveLength(2);
    expect(new Set(durableCompletionIds).size).toBe(2);
    const restarted = new RuntimeRegistry({
      agentDir, tronHome, idleRuntimeMs: 60_000, modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(restarted);
    const restartedAttention = (restarted as unknown as {
      attention: { complete: (sessionId: string, completionId: string) => Promise<unknown> };
    }).attention;
    const recovered = vi.spyOn(restartedAttention, "complete");
    await restarted.initialize();

    expect(recovered.mock.calls.map(([, completionId]) => completionId)).toEqual(durableCompletionIds);
    expect(restarted.attentionProjection(slot.id)).toMatchObject({ completionRevision: 2, isUnread: true });
  });

  it("coalesces streaming progress frames while keeping the event stream contiguous and complete", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-streaming-coalesce-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;

    // Deterministic 4-character chunks at 100 tokens/second stream ~240 SDK
    // updates over ~2.4 seconds. Uncoalesced, every update would republish the
    // cumulative message to each subscriber.
    const text = "streaming chunk ".repeat(60);
    const faux = fauxProvider({ provider: "tron-streaming-coalesce", tokensPerSecond: 100, tokenSize: { min: 1, max: 1 } });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    faux.setResponses([fauxAssistantMessage(text)]);
    const events: Array<{ topic: string; payload: { eventSequence?: number; data?: any } }> = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => events.push({ topic, payload: payload as { eventSequence?: number; data?: any } }),
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const promptReceipt = await slot.prompt("stream");
    await waitUntil(() => !slot.isBusy);
    expect(slot.snapshot().pendingPrompt).toBeUndefined();
    const canonicalUser = slot.snapshot().transcript.find((item) => item.role === "user");
    expect(canonicalUser).toMatchObject({ presentationId: promptReceipt.operationId });

    const progress = events.filter((event) => event.topic === "session.progress");
    expect(progress.length).toBeGreaterThanOrEqual(2);
    expect(progress.length).toBeLessThanOrEqual(40);

    // Coalescing must never reorder or gap the sequenced event stream.
    const sequenced = events.filter((event) => typeof event.payload.eventSequence === "number");
    for (let index = 1; index < sequenced.length; index += 1) {
      expect(sequenced[index]!.payload.eventSequence).toBe(sequenced[index - 1]!.payload.eventSequence! + 1);
    }

    // The last live frame carries the complete cumulative message and the
    // settled canonical transcript keeps the full text.
    const progressMessages = progress.map((event) => event.payload.data?.message).filter(Boolean);
    const lastMessage = progressMessages.at(-1)!;
    const lastText = (lastMessage.content ?? []).filter((part: any) => part.type === "text").map((part: any) => part.text).join("");
    expect(lastText.trimEnd().endsWith("streaming chunk")).toBe(true);
    expect(new Set(progressMessages.map((message) => message.presentationId)).size).toBe(1);
    expect(new Set(progressMessages.map((message) => message.parentId)).size).toBe(1);
    expect(new Set(progressMessages.map((message) => message.timestamp)).size).toBe(1);
    expect(lastMessage.content.map((part: any) => part.ordinal)).toEqual([0]);
    const finalSnapshot = slot.snapshot();
    const assistant = finalSnapshot.transcript.find(
      (item) => item.kind === "message" && item.role === "assistant",
    );
    expect(assistant).toMatchObject({ presentationId: lastMessage.presentationId });
    const transcriptText = finalSnapshot.transcript
      .filter((item) => item.kind === "message")
      .flatMap((item) => item.kind === "message" ? item.content : [])
      .filter((part) => part.type === "text")
      .map((part) => part.type === "text" ? part.text : "")
      .join("");
    expect(transcriptText).toContain(text.trimEnd());
  });

  it.each(["message_start", "message_end"] as const)(
    "keeps one presentation identity through an async %s extension hook",
    async (hook) => {
      const root = await mkdtemp(join(tmpdir(), `tron-streaming-${hook}-`));
      const agentDir = join(root, "agent");
      const cwd = join(root, "workspace");
      const extensionDir = join(cwd, ".pi", "extensions");
      const entered = join(root, "entered");
      const release = join(root, "release");
      await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
      process.env.PI_CODING_AGENT_DIR = agentDir;
      await writeFile(join(extensionDir, "streaming-hook.ts"), `
        import { existsSync, writeFileSync } from "node:fs";
        export default function (pi) {
          pi.on(${JSON.stringify(hook)}, async (event) => {
            if (event.message?.role !== "assistant") return;
            writeFileSync(${JSON.stringify(entered)}, "entered");
            while (!existsSync(${JSON.stringify(release)})) {
              await new Promise((resolve) => setTimeout(resolve, 5));
            }
          });
        }
      `);
      const trust = new TrustService(agentDir);
      await trust.set(cwd, true);
      const faux = fauxProvider({ provider: `tron-streaming-${hook}`, tokensPerSecond: 20, tokenSize: { min: 1, max: 1 } });
      const createModels = async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      };
      faux.setResponses([fauxAssistantMessage("stable identity")]);
      const registry = new RuntimeRegistry({
        agentDir,
        tronHome: join(root, "tron"),
        idleRuntimeMs: 60_000,
        modelRuntimeFactory: createModels,
        trust,
        broadcast: () => {},
        sessionSummaryChanged: () => {},
        sessionListChanged: () => {},
      });
      registries.push(registry);
      await registry.initialize();
      const slot = await registry.create(cwd);
      const model = faux.getModel();
      await slot.setModel(model.provider, model.id);

      const prompt = slot.prompt("stream");
      await waitUntil(() => existsSync(entered));
      const during = slot.snapshot().streaming;
      expect(during).toMatchObject({ role: "assistant" });
      if (during?.kind !== "message") throw new Error("expected live assistant");
      await writeFile(release, "release");
      await prompt;
      await waitUntil(() => !slot.isBusy);

      const finalSnapshot = slot.snapshot();
      const canonical = finalSnapshot.transcript.find(
        (item) => item.kind === "message" && item.role === "assistant",
      );
      expect(canonical).toMatchObject({
        id: expect.not.stringMatching(/^streaming$/),
        presentationId: during.presentationId,
      });
      if (canonical?.kind !== "message") throw new Error("expected canonical assistant");
      expect(canonical.content.slice(0, during.content.length).map(
        (part) => ({ id: part.id, ordinal: part.ordinal }),
      )).toEqual(during.content.map((part) => ({ id: part.id, ordinal: part.ordinal })));
    },
    15_000,
  );

  it("keeps async input preflight alive and settles accepted handled input exactly once", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-input-handled-preflight-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "handled.ts"), `export default function (pi) {
      pi.on("input", async () => {
        await new Promise((resolve) => setTimeout(resolve, 200));
        return { action: "handled" };
      });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const prompting = slot.prompt("handled without agent");
    await waitUntil(() => slot.isBusy);
    await expect(slot.dispose()).rejects.toMatchObject({ code: "busy" });
    await expect(prompting).resolves.toMatchObject({ operationId: expect.any(String) });
    await waitUntil(() => !slot.isBusy);
    expect(slot.snapshot()).toMatchObject({ phase: "idle" });
    expect(slot.snapshot().operation).toBeUndefined();
    const markerStore = (registry as unknown as { markers: { interruptedSessionIds(): Promise<Set<string>> } }).markers;
    expect((await markerStore.interruptedSessionIds()).has(slot.id)).toBe(false);
  });

  it("permits the exact delayed prompt accepted before the drain cutoff", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-drain-delayed-preflight-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "delay.ts"), `export default function (pi) {
      pi.on("input", async () => { await new Promise((resolve) => setTimeout(resolve, 150)); });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-drain-delayed-preflight", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("accepted after delayed preflight")]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const failures: unknown[] = [];
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      modelRuntimeFactory: async () => runtime,
      broadcast: (_id, topic, payload) => { if (topic === "session.operationFailed") failures.push(payload); },
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const prompt = slot.prompt("accepted before cutoff");
    await waitUntil(() => slot.isBusy);
    const drain = registry.waitUntilIdle();
    await expect(prompt).resolves.toMatchObject({ operationId: expect.any(String) });
    await drain;
    expect(faux.state.callCount).toBe(1);
    expect(failures).toEqual([]);
    expect(slot.snapshot()).toMatchObject({ phase: "idle" });
  });

  it("cuts off extension auto-continuations during administrative drain", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-drain-continuation-cutoff-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "continue.ts"), `let sent = false;
      export default function (pi) {
        pi.on("agent_settled", () => {
          if (sent) return;
          sent = true;
          pi.sendMessage({ customType: "after-cutoff", content: "continue", display: false }, { triggerTurn: true });
        });
      }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-drain-cutoff", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => { await new Promise((resolve) => setTimeout(resolve, 150)); return fauxAssistantMessage("first"); },
      fauxAssistantMessage("must be aborted"),
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const failures: unknown[] = [];
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      modelRuntimeFactory: async () => runtime,
      broadcast: (_id, topic, payload) => { if (topic === "session.operationFailed") failures.push(payload); },
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("start");
    await waitUntil(() => slot.catalogPhase === "running");
    await registry.waitUntilIdle();
    expect(slot.isDrainBusy).toBe(false);
    expect(failures).not.toEqual([]);
  });

  it("uses runtime preflight as the sole prompt-admission outcome", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-prompt-preflight-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const session = (slot as unknown as {
      runtime: { session: { prompt: (
        text: string,
        options?: { preflightResult?: (accepted: boolean) => void },
      ) => Promise<void> } };
    }).runtime.session;
    let startedResolve!: () => void;
    const started = new Promise<void>((resolve) => { startedResolve = resolve; });
    vi.spyOn(session, "prompt").mockImplementationOnce(async (_text, options) => {
      startedResolve();
      await new Promise((resolve) => setTimeout(resolve, 6_000));
      options?.preflightResult?.(true);
    });

    vi.useFakeTimers();
    try {
      const attachment = {
        id: "upload:00000000-0000-4000-8000-000000000001",
        name: "notes.txt", mimeType: "text/plain", size: 4,
      };
      const prompting = slot.prompt("delayed preflight", [], undefined, {
        text: "delayed preflight",
        attachmentEnvelope: '<attachment name="notes.txt" />',
        attachmentCount: 1,
        photoCount: 0,
        fileAttachmentCount: 1,
        attachments: [attachment],
      });
      await started;
      expect(slot.snapshot().pendingPrompt).toMatchObject({
        id: expect.any(String),
        text: "delayed preflight",
        attachmentCount: 1,
        attachments: [attachment],
      });
      await vi.advanceTimersByTimeAsync(6_000);
      await expect(prompting).resolves.toMatchObject({ operationId: expect.any(String) });
    } finally {
      vi.useRealTimers();
    }
  });

  it("does not retire a newer pending prompt for an older user message callback", async () => {
    const fixture = await coldFixture("pending-prompt-object-ownership");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      pendingPrompt?: {
        id: string; createdAt: string; text: string; attachmentCount: number;
      };
      pendingPromptMessage?: unknown;
      onEvent: (event: unknown) => void;
    };
    const older = { role: "user", content: "same", timestamp: Date.now() };
    const newer = { role: "user", content: "same", timestamp: Date.now() + 1 };
    internal.pendingPrompt = {
      id: "older-operation", createdAt: new Date().toISOString(),
      text: "same", attachmentCount: 0,
    };
    internal.onEvent({ type: "message_start", message: older });
    internal.pendingPrompt = {
      id: "newer-operation", createdAt: new Date().toISOString(),
      text: "same", attachmentCount: 0,
    };
    internal.pendingPromptMessage = undefined;
    internal.onEvent({ type: "message_start", message: newer });
    internal.onEvent({ type: "message_end", message: older });
    expect(internal.pendingPrompt?.id).toBe("newer-operation");
    expect(internal.pendingPromptMessage).toBe(newer);
  });

  it("exports the complete canonical JSONL tree including abandoned branches", async () => {
    const fixture = await coldFixture("complete-jsonl-export");
    await fixture.registry.initializeBlobStorage();
    fixture.manager.appendMessage({ role: "user", content: "root prompt", timestamp: Date.now() });
    const rootEntry = fixture.manager.getEntries().at(-1)!;
    fixture.manager.appendMessage(fauxAssistantMessage("abandoned branch response"));
    const abandonedEntry = fixture.manager.getEntries().at(-1)!;
    fixture.manager.branch(rootEntry.id);
    fixture.manager.appendMessage(fauxAssistantMessage("active branch response"));
    const activeEntry = fixture.manager.getEntries().at(-1)!;

    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const artifact = await slot.export("jsonl");
    const lease = await fixture.registry.acquireBlob(artifact.blobId);
    let exported = "";
    try {
      for await (const chunk of lease.stream) exported += Buffer.from(chunk).toString("utf8");
    } finally {
      await lease.release();
    }

    const lines = exported.trimEnd().split("\n").map((line) => JSON.parse(line) as {
      id?: string;
      parentId?: string | null;
    });
    expect(lines.some((entry) => entry.id === abandonedEntry.id && entry.parentId === rootEntry.id)).toBe(true);
    expect(lines.some((entry) => entry.id === activeEntry.id && entry.parentId === rootEntry.id)).toBe(true);
    expect(exported).toContain("abandoned branch response");
    expect(exported).toContain("active branch response");
  });

  it("drains branch summarization through exact SDK settlement", async () => {
    const { manager, registry } = await coldFixture("branch-summary-drain");
    const slot = await registry.acquire(manager.getSessionId());
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => { release = resolve; });
    const session = (slot as unknown as {
      runtime: { session: { navigateTree: (...arguments_: unknown[]) => Promise<{ cancelled: boolean }> } };
    }).runtime.session;
    const navigate = vi.spyOn(session, "navigateTree").mockImplementation(async () => {
      await barrier;
      return { cancelled: false };
    });
    const navigating = slot.navigate("target", { summarize: true });
    await waitUntil(() => navigate.mock.calls.length === 1);
    let drained = false;
    const drain = registry.waitUntilIdle().then(() => { drained = true; });
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(drained).toBe(false);
    release();
    await navigating;
    await drain;
    expect(drained).toBe(true);
  });

  it("drains extension resource reload through exact loader settlement", async () => {
    const { manager, registry } = await coldFixture("resource-reload-drain");
    const slot = await registry.acquire(manager.getSessionId());
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => { release = resolve; });
    const loader = (slot as unknown as {
      runtime: { session: { resourceLoader: { reload: (...arguments_: unknown[]) => Promise<void> } } };
    }).runtime.session.resourceLoader;
    const reload = vi.spyOn(loader, "reload").mockImplementation(async () => { await barrier; });
    const reloading = slot.reload();
    await waitUntil(() => reload.mock.calls.length === 1);
    let drained = false;
    const drain = registry.waitUntilIdle().then(() => { drained = true; });
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(drained).toBe(false);
    release();
    await reloading;
    await drain;
    expect(drained).toBe(true);
  });

  it("clears branch-summary operation state when tree navigation rejects or is cancelled", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-navigation-cleanup-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const snapshots: Array<{ phase: string; operation?: { kind: string }; retry?: unknown }> = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => {
        if (topic === "session.snapshot") snapshots.push(payload as { phase: string; operation?: { kind: string }; retry?: unknown });
      },
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const session = (slot as unknown as {
      runtime: { session: { navigateTree: (targetId: string, options: unknown) => Promise<{ cancelled: boolean }> } };
    }).runtime.session;
    const navigate = vi.spyOn(session, "navigateTree");

    navigate.mockRejectedValueOnce(new Error("navigation failed"));
    await expect(slot.navigate("target", { summarize: true })).rejects.toThrow("navigation failed");
    expect(slot.snapshot()).toMatchObject({ phase: "idle" });
    expect(slot.snapshot().operation).toBeUndefined();
    expect(slot.snapshot().retry).toBeUndefined();

    navigate.mockResolvedValueOnce({ cancelled: true });
    await expect(slot.navigate("target", { summarize: true })).rejects.toMatchObject({ code: "cancelled" });
    expect(slot.snapshot().operation).toBeUndefined();
    expect(slot.snapshot().retry).toBeUndefined();
    expect(snapshots.at(-1)?.operation).toBeUndefined();
  });

  it("projects and atomically manages multiple queued messages by stable identity", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-queue-management-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const skillDir = join(agentDir, "skills", "review");
    await Promise.all([mkdir(skillDir, { recursive: true }), mkdir(cwd)]);
    await writeFile(
      join(skillDir, "SKILL.md"),
      "---\nname: review\ndescription: Review carefully\n---\nReview the requested change.\n",
    );

    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-queue-management", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => {
        await responseBarrier;
        return fauxAssistantMessage("initial complete");
      },
      fauxAssistantMessage("queued complete"),
      fauxAssistantMessage("follow-up complete"),
    ]);
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("start");
    await waitUntil(() => slot.isBusy);

    const oversizedDescriptors = Array.from({ length: 11 }, (_, index) => ({
      id: `upload-${index}`, name: `file-${index}.txt`, mimeType: "text/plain", size: 1,
    }));
    await expect(slot.prompt("invalid", [], "steer", {
      text: "invalid",
      attachmentEnvelope: "",
      attachmentCount: oversizedDescriptors.length,
      attachments: oversizedDescriptors,
    })).rejects.toMatchObject({ code: "invalid_request" });

    const attachment = {
      id: "upload:00000000-0000-4000-8000-000000000001",
      name: "notes.txt", mimeType: "text/plain", size: 4,
    };
    await slot.prompt("first steer", [], "steer", {
      text: "first steer",
      attachmentEnvelope: '<attachment name="notes.txt" />',
      attachmentCount: 1,
      photoCount: 0,
      fileAttachmentCount: 1,
      attachments: [attachment],
    });
    await slot.prompt("first steer", [], "steer", {
      text: "first steer",
      attachmentEnvelope: "",
      attachmentCount: 0,
    });
    await slot.prompt("later follow-up", [], "followUp", {
      text: "later follow-up",
      attachmentEnvelope: "",
      attachmentCount: 0,
    });
    await slot.prompt("/skill:review queued skill", [], "steer", {
      text: "queued skill",
      skillName: "review",
      attachmentEnvelope: "",
      attachmentCount: 0,
    });
    const queued = slot.snapshot();
    expect(queued.queuedItems).toHaveLength(4);
    expect(queued.queuedItems?.map((item) => item.behavior)).toEqual(["steer", "steer", "steer", "followUp"]);
    expect(queued.queuedItems?.map((item) => item.text)).toEqual([
      "first steer", "first steer", "queued skill", "later follow-up",
    ]);
    expect(new Set(queued.queuedItems?.map((item) => item.id)).size).toBe(4);
    expect(queued.queuedItems?.[0]?.attachments).toEqual([attachment]);

    const [first, duplicate, skill, followUp] = queued.queuedItems!;
    const replaced = await slot.replaceQueue(queued.queueRevision!, [
      { id: duplicate!.id, behavior: "steer", text: duplicate!.text },
      { id: followUp!.id, behavior: "steer", text: "edited and earlier" },
      { id: first!.id, behavior: "followUp", text: first!.text },
      { id: skill!.id, behavior: "followUp", text: "edited skill" },
    ]);
    expect(replaced.items.map(({ id, behavior, text }) => ({ id, behavior, text }))).toEqual([
      { id: duplicate!.id, behavior: "steer", text: "first steer" },
      { id: followUp!.id, behavior: "steer", text: "edited and earlier" },
      { id: first!.id, behavior: "followUp", text: "first steer" },
      { id: skill!.id, behavior: "followUp", text: "edited skill" },
    ]);
    expect(replaced.items[2]?.attachments).toEqual([attachment]);
    const queuedRuntime = (slot as unknown as {
      runtime: { session: { getFollowUpMessages(): readonly string[] } };
    }).runtime.session.getFollowUpMessages();
    expect(queuedRuntime.some(
      (text) => text.startsWith('<skill name="review"') && text.endsWith("edited skill"),
    )).toBe(true);
    await expect(slot.replaceQueue(queued.queueRevision!, [])).rejects.toMatchObject({ code: "conflict" });

    const removed = await slot.replaceQueue(replaced.queueRevision, [replaced.items[1]!]);
    expect(removed.items).toHaveLength(1);
    expect(removed.items[0]?.id).toBe(followUp!.id);

    const cleared = await slot.clearQueue();
    expect(cleared.steering).toEqual(["edited and earlier"]);
    expect(slot.snapshot().queuedItems).toEqual([]);
    await expect(slot.replaceQueue(removed.queueRevision, removed.items))
      .rejects.toMatchObject({ code: "conflict" });

    releaseResponse();
    await waitUntil(() => !slot.isBusy);
  });

  it("queues one manual compaction behind an active run and keeps its receipt pending", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-queued-compaction-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);

    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    let releaseCompaction!: () => void;
    const compactionBarrier = new Promise<void>((resolve) => { releaseCompaction = resolve; });
    const faux = fauxProvider({ provider: "tron-queued-compaction", tokensPerSecond: 10_000 });
    faux.setResponses([async () => {
      await responseBarrier;
      return fauxAssistantMessage("run complete");
    }]);
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    const compact = vi.spyOn(session, "compact").mockImplementation(async () => {
      await compactionBarrier;
      return {};
    });
    let releaseMarker!: () => void;
    const markerBarrier = new Promise<void>((resolve) => { releaseMarker = resolve; });
    const markerStore = (slot as unknown as {
      dependencies: { markers: { clear: (sessionId: string) => Promise<void> } };
    }).dependencies.markers;
    const clearMarker = vi.spyOn(markerStore, "clear").mockImplementation(async () => markerBarrier);

    await slot.prompt("start");
    await waitUntil(() => slot.isBusy);
    const queuedCompaction = slot.compact("Preserve exact decisions");
    await waitUntil(() => slot.snapshot().compactionQueued === true);

    expect(slot.snapshot()).toMatchObject({
      phase: "running",
      compactionQueued: true,
      automaticCompactionEnabled: true,
    });
    expect(registry.activeSessionIds()).toContain(slot.id);
    await expect(slot.compact()).rejects.toMatchObject({
      code: "busy",
      message: "A manual compaction is already pending for this session",
    });
    expect(compact).not.toHaveBeenCalled();

    releaseResponse();
    await waitUntil(() => compact.mock.calls.length === 1);
    expect(compact).toHaveBeenCalledWith("Preserve exact decisions");
    expect(slot.snapshot()).toMatchObject({ phase: "compacting", compactionQueued: false });
    expect(registry.activeSessionIds()).toContain(slot.id);

    let queuedSettled = false;
    void queuedCompaction.then(() => { queuedSettled = true; }, () => {});
    releaseCompaction();
    await waitUntil(() => clearMarker.mock.calls.length === 1);
    await Promise.resolve();
    expect(queuedSettled).toBe(false);
    expect(registry.activeSessionIds()).toContain(slot.id);
    releaseMarker();
    await expect(queuedCompaction).resolves.toEqual({ queued: true });
    await waitUntil(() => !slot.isBusy);
    expect(slot.snapshot()).toMatchObject({ phase: "idle", compactionQueued: false });
    expect(registry.activeSessionIds()).not.toContain(slot.id);
  });

  it("retains one exact completion intent across repeated persistence failure and rejects a second prompt", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-attention-settlement-failure-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const faux = fauxProvider({ provider: "tron-attention-failure", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage("first completion"),
      fauxAssistantMessage("must not be admitted"),
    ]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const attention = (registry as unknown as {
      attention: { complete: (sessionId: string, completionId: string) => Promise<unknown> };
    }).attention;
    const complete = vi.spyOn(attention, "complete").mockRejectedValue(new Error("attention persistence failed"));

    await slot.prompt("first");
    await waitUntil(() => slot.snapshot().phase === "interrupted");
    expect(complete).toHaveBeenCalledTimes(3);
    await expect(slot.prompt("second")).rejects.toMatchObject({ code: "busy", retryable: true });
    expect(complete.mock.calls.map(([, completionId]) => completionId))
      .toEqual(Array(3).fill(complete.mock.calls[0]![1]));

    complete.mockRestore();
    await slot.reconcileAttention();
    expect(registry.attentionProjection(slot.id)).toMatchObject({ completionRevision: 1, isUnread: true });
    expect(slot.snapshot().phase).toBe("idle");
  });

  it("cleans up queued manual compaction state when canonical compaction fails", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-queued-compaction-failure-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);

    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-queued-compaction-failure", tokensPerSecond: 10_000 });
    faux.setResponses([async () => {
      await responseBarrier;
      return fauxAssistantMessage("run complete");
    }]);
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    vi.spyOn(session, "compact").mockRejectedValue(new Error("manual compaction failed"));

    await slot.prompt("start");
    await waitUntil(() => slot.isBusy);
    const queuedCompaction = slot.compact();
    const failure = expect(queuedCompaction).rejects.toThrow("manual compaction failed");
    await waitUntil(() => slot.snapshot().compactionQueued === true);
    releaseResponse();
    await failure;
    await waitUntil(() => !slot.isBusy);
    expect(slot.snapshot()).toMatchObject({ phase: "idle", compactionQueued: false });
    expect(slot.snapshot().operation).toBeUndefined();
  });

  it("keeps queued compaction owned while transient marker removal retries", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-compaction-marker-failure-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-compaction-marker-failure", tokensPerSecond: 10_000 });
    faux.setResponses([async () => {
      await responseBarrier;
      return fauxAssistantMessage("run complete");
    }]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    vi.spyOn(session, "compact").mockResolvedValue({});
    const markerStore = (slot as unknown as {
      dependencies: { markers: { clear: (sessionId: string) => Promise<void> } };
    }).dependencies.markers;
    const clearMarker = vi.spyOn(markerStore, "clear")
      .mockRejectedValueOnce(new Error("marker removal failed"));

    await slot.prompt("start");
    await waitUntil(() => slot.isBusy);
    const queuedCompaction = slot.compact();
    await waitUntil(() => slot.snapshot().compactionQueued === true);
    releaseResponse();
    await expect(queuedCompaction).resolves.toEqual({ queued: true });
    expect(clearMarker).toHaveBeenCalledTimes(2);
    expect(slot.snapshot()).toMatchObject({ phase: "idle", compactionQueued: false });
    expect(slot.snapshot().operation).toBeUndefined();
    clearMarker.mockRestore();
  });

  it("admits only one direct manual compaction and retains the claim through completion", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-direct-compaction-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    let releaseCompaction!: () => void;
    const barrier = new Promise<void>((resolve) => { releaseCompaction = resolve; });
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    const compact = vi.spyOn(session, "compact").mockImplementation(async () => {
      await barrier;
      return {};
    });
    const markerStore = (slot as unknown as {
      dependencies: { markers: { clear: (sessionId: string, operationId?: string) => Promise<void> } };
    }).dependencies.markers;
    const clearMarker = vi.spyOn(markerStore, "clear").mockRejectedValueOnce(new Error("transient clear failure"));

    const first = slot.compact("Keep decisions");
    await waitUntil(() => slot.snapshot().phase === "compacting");
    expect(registry.activeSessionIds()).toContain(slot.id);
    await expect(slot.compact()).rejects.toMatchObject({
      code: "busy",
      message: "A manual compaction is already pending for this session",
    });
    expect(compact).toHaveBeenCalledTimes(1);
    const markerPath = join(root, "tron", "gateway", "runtime-markers", `${slot.id}.json`);
    expect(JSON.parse(await readFile(markerPath, "utf8")).operations).toHaveLength(1);

    releaseCompaction();
    await expect(first).resolves.toEqual({ queued: false });
    expect(clearMarker.mock.calls.length).toBeGreaterThanOrEqual(2);
    await waitUntil(() => !slot.isBusy);
    expect(slot.snapshot()).toMatchObject({ phase: "idle", compactionQueued: false });
  });

  it("publishes one authoritative compaction snapshot including a hook-appended suffix", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-compaction-delta-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const broadcasts: Array<{ sessionId: string; topic: string; payload: unknown }> = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: (sessionId, topic, payload) => broadcasts.push({ sessionId, topic, payload }),
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const runtime = (slot as unknown as {
      runtime: { session: { sessionManager: SessionManager } };
      onEvent: (event: unknown) => void;
    });
    const firstKeptEntryId = runtime.runtime.session.sessionManager.appendMessage(
      fauxAssistantMessage("canonical history")
    );
    const summary = "Preserved exact decisions";
    const tokensBefore = 12_345;
    const compactionId = runtime.runtime.session.sessionManager.appendCompaction(
      summary,
      firstKeptEntryId,
      tokensBefore
    );
    runtime.runtime.session.sessionManager.appendLabelChange(
      compactionId,
      "hook appended after compaction"
    );

    runtime.onEvent({
      type: "compaction_end",
      reason: "manual",
      result: { summary, firstKeptEntryId, tokensBefore },
      aborted: false,
      willRetry: true,
    });

    expect(broadcasts.some((event) => event.topic === "session.compaction")).toBe(false);
    const completion = broadcasts.filter((event) => event.topic === "session.snapshot").at(-1);
    const payload = completion?.payload as {
      eventSequence?: number;
      phase?: string;
      leafEntryId?: string;
      transcript?: Array<{ id: string; kind: string }>;
    } | undefined;
    expect(completion?.sessionId).toBe(slot.id);
    expect(payload).toMatchObject({
      eventSequence: expect.any(Number),
      phase: "idle",
      leafEntryId: expect.any(String),
    });
    expect(payload?.transcript).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: compactionId, kind: "compaction" }),
      expect.objectContaining({ id: payload?.leafEntryId, kind: "label" }),
    ]));
  });

  it("restores a pre-prompt operation in the authoritative compaction completion frame", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-preprompt-compaction-frame-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const broadcasts: Array<{ topic: string; payload: any }> = [];
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => broadcasts.push({ topic, payload }),
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const internal = slot as unknown as {
      runtime: { session: { sessionManager: SessionManager } };
      pendingPrompt: { id: string; createdAt: string; text: string; attachmentCount: number };
      phase: string;
      operation: unknown;
      onEvent: (event: unknown) => void;
    };
    const parent = internal.runtime.session.sessionManager.appendMessage(
      fauxAssistantMessage("history")
    );
    const compaction = internal.runtime.session.sessionManager.appendCompaction(
      "summary", parent, 4_096
    );
    internal.runtime.session.sessionManager.appendLabelChange(compaction, "hook suffix");
    internal.pendingPrompt = {
      id: "pending-operation", createdAt: "2026-01-01T00:00:00.000Z",
      text: "continue", attachmentCount: 0,
    };
    internal.phase = "compacting";
    internal.operation = { kind: "compaction" };
    internal.onEvent({
      type: "compaction_end", reason: "threshold",
      result: { summary: "summary", firstKeptEntryId: parent, tokensBefore: 4_096 },
      aborted: false, willRetry: false,
    });
    const completion = broadcasts.filter((event) => event.topic === "session.snapshot").at(-1)?.payload;
    expect(completion).toMatchObject({
      phase: "running",
      operation: { id: "pending-operation", kind: "prompt", startedAt: "2026-01-01T00:00:00.000Z" },
      pendingPrompt: { id: "pending-operation" },
    });
    expect(completion.leafEntryId).not.toBe(compaction);
  });

  it("cleans up a failed direct manual compaction claim", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-direct-compaction-failure-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    const compact = vi.spyOn(session, "compact")
      .mockRejectedValueOnce(new Error("direct compaction failed"))
      .mockResolvedValueOnce({});

    await expect(slot.compact()).rejects.toThrow("direct compaction failed");
    expect(slot.snapshot()).toMatchObject({ phase: "idle", compactionQueued: false });
    expect(slot.snapshot().operation).toBeUndefined();
    await expect(slot.compact()).resolves.toEqual({ queued: false });
    expect(compact).toHaveBeenCalledTimes(2);
  });

  it("defers queued compaction when a newer prompt enters preflight before handoff", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-compaction-handoff-race-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseFirst!: () => void;
    let releaseSecond!: () => void;
    const firstBarrier = new Promise<void>((resolve) => { releaseFirst = resolve; });
    const secondBarrier = new Promise<void>((resolve) => { releaseSecond = resolve; });
    const faux = fauxProvider({ provider: "tron-compaction-handoff-race", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => { await firstBarrier; return fauxAssistantMessage("first complete"); },
      async () => { await secondBarrier; return fauxAssistantMessage("second complete"); },
    ]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const runtimeSession = (slot as unknown as {
      runtime: { session: {
        compact: (instructions?: string) => Promise<unknown>;
        isStreaming: boolean;
      } };
    }).runtime.session;
    const compact = vi.spyOn(runtimeSession, "compact").mockResolvedValue({});
    const lane = (slot as unknown as {
      lane: { run<T>(operation: () => Promise<T> | T): Promise<T> };
    }).lane;

    await slot.prompt("first");
    await waitUntil(() => runtimeSession.isStreaming);
    const queuedCompaction = slot.compact();
    await waitUntil(() => slot.snapshot().compactionQueued === true);

    let releaseLane!: () => void;
    let laneEntered!: () => void;
    const laneWasEntered = new Promise<void>((resolve) => { laneEntered = resolve; });
    const laneBarrier = new Promise<void>((resolve) => { releaseLane = resolve; });
    const blocker = lane.run(async () => {
      laneEntered();
      await laneBarrier;
    });
    await laneWasEntered;
    const newerPrompt = slot.prompt("newer");
    releaseFirst();
    await waitUntil(() => !runtimeSession.isStreaming);
    releaseLane();
    await blocker;
    await newerPrompt;
    await waitUntil(() => runtimeSession.isStreaming);
    await lane.run(() => {});
    expect(compact).not.toHaveBeenCalled();
    expect(slot.snapshot().compactionQueued).toBe(true);

    releaseSecond();
    await waitUntil(() => compact.mock.calls.length === 1);
    await expect(queuedCompaction).resolves.toEqual({ queued: true });
    await waitUntil(() => !slot.isBusy);
  });

  it("cancels pending compaction and drains its runtime during registry shutdown", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-queued-compaction-shutdown-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-queued-compaction-shutdown", tokensPerSecond: 10_000 });
    faux.setResponses([async () => {
      await responseBarrier;
      return fauxAssistantMessage("run complete");
    }]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const session = (slot as unknown as {
      runtime: { session: { compact: (instructions?: string) => Promise<unknown> } };
    }).runtime.session;
    const compact = vi.spyOn(session, "compact").mockResolvedValue({});

    await slot.prompt("start");
    await waitUntil(() => slot.isBusy);
    const queuedCompaction = slot.compact();
    const queuedOutcome = queuedCompaction.then(
      () => ({ status: "fulfilled" as const }),
      (error: unknown) => ({ status: "rejected" as const, error }),
    );
    await waitUntil(() => slot.snapshot().compactionQueued === true);
    const shutdown = registry.dispose();
    releaseResponse();

    const outcome = await queuedOutcome;
    expect(outcome).toMatchObject({ status: "rejected", error: { code: "cancelled" } });
    await shutdown;
    expect(compact).not.toHaveBeenCalled();
    expect(registry.activeSessionIds()).toEqual([]);
    const index = registries.indexOf(registry);
    if (index >= 0) registries.splice(index, 1);
  });

  it("aborts and drains an in-flight direct compaction during registry shutdown", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-direct-compaction-shutdown-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    let releaseCompaction!: () => void;
    const compactionBarrier = new Promise<void>((resolve) => { releaseCompaction = resolve; });
    const session = (slot as unknown as {
      runtime: { session: {
        compact: (instructions?: string) => Promise<unknown>;
        abortCompaction: () => void;
      } };
    }).runtime.session;
    vi.spyOn(session, "compact").mockImplementation(async () => {
      await compactionBarrier;
      return {};
    });
    const originalAbort = session.abortCompaction.bind(session);
    const abortCompaction = vi.spyOn(session, "abortCompaction").mockImplementation(() => {
      originalAbort();
      releaseCompaction();
    });

    const compaction = slot.compact();
    await waitUntil(() => slot.snapshot().phase === "compacting");
    const shutdown = registry.dispose();
    await expect(compaction).resolves.toEqual({ queued: false });
    await shutdown;
    expect(abortCompaction).toHaveBeenCalled();
    expect(registry.activeSessionIds()).toEqual([]);
    const index = registries.indexOf(registry);
    if (index >= 0) registries.splice(index, 1);
  });

  it("closes global slot admission before draining an already-entered creation", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-registry-admission-shutdown-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let factoryEntered!: () => void;
    let releaseFactory!: () => void;
    const factoryWasEntered = new Promise<void>((resolve) => { factoryEntered = resolve; });
    const factoryBarrier = new Promise<void>((resolve) => { releaseFactory = resolve; });
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => {
        factoryEntered();
        await factoryBarrier;
        return ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      },
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();

    const creating = registry.create(cwd);
    await factoryWasEntered;
    let shutdownFinished = false;
    const shutdown = registry.dispose().then(() => { shutdownFinished = true; });
    await Promise.resolve();
    expect(shutdownFinished).toBe(false);
    await expect(registry.create(cwd)).rejects.toMatchObject({
      code: "conflict",
      message: "Session runtime registry is shutting down",
    });

    releaseFactory();
    const created = await creating;
    await shutdown;
    expect(shutdownFinished).toBe(true);
    expect(registry.activeSessionIds()).toEqual([]);
    expect((registry as unknown as { slots: Map<string, unknown> }).slots.size).toBe(0);
    await expect(registry.acquire(created.id)).rejects.toMatchObject({ code: "conflict" });
    const index = registries.indexOf(registry);
    if (index >= 0) registries.splice(index, 1);
  });

  it("preserves the admitted run marker when global shutdown forces interruption", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-forced-shutdown-marker-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const faux = fauxProvider({ provider: "tron-forced-marker", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => { await new Promise((resolve) => setTimeout(resolve, 250)); return fauxAssistantMessage("late"); },
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime, trust: new TrustService(agentDir),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("accepted work");
    await waitUntil(() => slot.catalogPhase === "running");
    const sessionID = slot.id;
    await slot.shutdown();
    const markerStore = (registry as unknown as { markers: { interruptedSessionIds(): Promise<Set<string>> } }).markers;
    expect((await markerStore.interruptedSessionIds()).has(sessionID)).toBe(true);
  });

  it("does not tear down blob ownership before every captured slot drains", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-registry-blob-drain-order-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);

    let shutdownEntered!: () => void;
    let releaseShutdown!: () => void;
    const shutdownWasEntered = new Promise<void>((resolve) => { shutdownEntered = resolve; });
    const shutdownBarrier = new Promise<void>((resolve) => { releaseShutdown = resolve; });
    const originalShutdown = slot.shutdown.bind(slot);
    let slotDrained = false;
    vi.spyOn(slot, "shutdown").mockImplementation(async () => {
      shutdownEntered();
      await shutdownBarrier;
      await originalShutdown();
      slotDrained = true;
    });
    const blobs = (registry as unknown as { blobs: { dispose: () => Promise<void> } }).blobs;
    const originalBlobDispose = blobs.dispose.bind(blobs);
    let blobDisposeStarted = false;
    vi.spyOn(blobs, "dispose").mockImplementation(async () => {
      blobDisposeStarted = true;
      expect(slotDrained).toBe(true);
      await originalBlobDispose();
    });

    const shutdown = registry.dispose();
    await shutdownWasEntered;
    expect(blobDisposeStarted).toBe(false);
    releaseShutdown();
    await shutdown;
    expect(slotDrained).toBe(true);
    expect(blobDisposeStarted).toBe(true);
    const index = registries.indexOf(registry);
    if (index >= 0) registries.splice(index, 1);
  });

  it("projects stable ordinals for parallel tools from start through completion", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-tool-order-integration-"));
    const agentDir = join(root, "agent");
    const sessionDir = join(root, "sessions");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(sessionDir), mkdir(cwd)]);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ sessionDir }));

    const faux = fauxProvider({ provider: "tron-tool-order", tokensPerSecond: 10_000 });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    faux.setResponses([
      fauxAssistantMessage([
        fauxToolCall("read", { path: join(cwd, "one.txt") }, { id: "call-read" }),
        fauxToolCall("bash", { command: "printf start; sleep 0.35; printf end" }, { id: "call-bash" }),
      ], { stopReason: "toolUse" }),
      fauxAssistantMessage("finished"),
    ]);
    await writeFile(join(cwd, "one.txt"), "one\n");
    const events: Array<{ topic: string; payload: any }> = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => events.push({ topic, payload }),
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("run tools");
    await waitUntil(() => !slot.isBusy);
    await waitUntil(() => registry.attentionProjection(slot.id).isUnread);
    expect(registry.attentionProjection(slot.id).completionRevision).toBe(1);

    const progress = events
      .filter((event) => event.topic === "session.toolProgress")
      .map((event) => event.payload.data as {
        toolCallId: string;
        order: number;
        status: string;
        output?: string;
        progressSequence: number;
        durationMs?: number;
        completedAt?: string;
        groupId?: string;
        groupIndex?: number;
        groupCount?: number;
        groupFinalized?: boolean;
      });
    const finalizedProgressIndex = events.findIndex((event) => {
      if (event.topic !== "session.progress") return false;
      const message = event.payload.data?.message;
      const calls = message?.content?.filter((part: any) => part.type === "toolCall") ?? [];
      return calls.length === 2 && calls.every((part: any) => part.groupFinalized === true);
    });
    const firstToolProgressIndex = events.findIndex((event) => event.topic === "session.toolProgress");
    expect(finalizedProgressIndex).toBeGreaterThanOrEqual(0);
    expect(firstToolProgressIndex).toBeGreaterThan(finalizedProgressIndex);

    const firstRunning = new Map<string, number>();
    for (const event of progress) {
      if (event.status === "running" && !firstRunning.has(event.toolCallId)) firstRunning.set(event.toolCallId, event.order);
    }
    expect(firstRunning).toEqual(new Map([["call-read", 0], ["call-bash", 1]]));
    const finalOrder = new Map(progress.map((event) => [event.toolCallId, event.order]));
    expect(finalOrder).toEqual(new Map([["call-read", 0], ["call-bash", 1]]));
    const grouped = progress.filter((event) => event.groupFinalized === true);
    expect(grouped.length).toBeGreaterThanOrEqual(2);
    expect(new Set(grouped.map((event) => event.groupId)).size).toBe(1);
    expect(new Set(grouped.map((event) => event.groupCount))).toEqual(new Set([2]));
    expect(new Map(grouped.map((event) => [event.toolCallId, event.groupIndex])))
      .toEqual(new Map([["call-read", 0], ["call-bash", 1]]));
    const bashProgress = progress.filter((event) => event.toolCallId === "call-bash");
    expect(bashProgress.some((event) => event.status === "running" && event.output?.includes("start"))).toBe(true);
    const runningDurations = bashProgress
      .filter((event) => event.status === "running")
      .map((event) => event.durationMs);
    expect(runningDurations.length).toBeGreaterThan(0);
    expect(runningDurations.every((duration) => typeof duration === "number" && duration >= 0)).toBe(true);
    expect(runningDurations).toEqual([...runningDurations].sort((left, right) => left! - right!));
    expect(bashProgress.at(-1)).toMatchObject({ status: "completed", output: "startend" });
    expect(bashProgress.at(-1)!.progressSequence).toBeGreaterThan(2);
    expect(bashProgress.at(-1)!.durationMs).toBeGreaterThanOrEqual(300);
    expect(bashProgress.at(-1)!.completedAt).toBeTypeOf("string");
    expect(events.filter((event) => event.topic === "session.processActivity")).toEqual([]);
    const settled = slot.snapshot();
    expect(settled.toolExecutions).toEqual([]);
    expect(settled.processOverview).toMatchObject({ visibility: "hidden", activeCount: 0, recentCount: 0 });
    expect(settled.processActivities ?? []).toEqual([]);
    expect(slot.processHistory(undefined, 25, { kind: "command" }).activities).toEqual([]);
    const canonicalAssistant = settled.transcript.find((item) => item.kind === "message" && item.role === "assistant");
    const canonicalCalls = canonicalAssistant?.kind === "message"
      ? canonicalAssistant.content.filter((part) => part.type === "toolCall")
      : [];
    expect(canonicalCalls).toHaveLength(2);
    expect(canonicalCalls.every((part) => part.type === "toolCall" && part.groupFinalized === true)).toBe(true);
    expect(new Set(canonicalCalls.flatMap((part) => part.type === "toolCall" ? [part.groupId] : [])).size).toBe(1);
    expect(settled.transcript.find((item) => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "call-bash"))
      .toMatchObject({ durationMs: expect.any(Number), startedAt: expect.any(String), completedAt: expect.any(String) });
    expect(slot.sessionFile?.startsWith(sessionDir)).toBe(true);
  });

  it("permits one delayed agent start owned by an accepted extension command during drain", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-drain-extension-command-start-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "command.ts"), `export default function (pi) {
      pi.registerCommand("start-after-confirm", { handler: async (_args, ctx) => {
        if (await ctx.ui.confirm("Start", "Continue?")) {
          pi.sendMessage({ customType: "confirmed", content: "continue", display: false }, { triggerTurn: true });
        }
      }});
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-drain-extension-command-start", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("command continuation complete")]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const failures: unknown[] = [];
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      modelRuntimeFactory: async () => runtime,
      broadcast: (_id, topic, payload) => { if (topic === "session.operationFailed") failures.push(payload); },
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const command = slot.prompt("/start-after-confirm");
    await waitUntil(() => slot.snapshot().extensionPresentation.pendingInteractions.length === 1);
    const pending = slot.snapshot().extensionPresentation.pendingInteractions[0]!;
    const drain = registry.waitUntilIdle();
    slot.respondToInteraction(pending.id, pending.hostEpoch, pending.presentationRevision, true, false);
    await command;
    await drain;
    expect(faux.state.callCount).toBe(1);
    expect(failures).toEqual([]);
    expect(slot.snapshot()).toMatchObject({ phase: "idle" });
  });

  it("admits exact extension commands while streaming without hiding the foreground run", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-streaming-extension-command-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "stream-command.ts"), `export default function (pi) {
      pi.registerCommand("during-stream", {
        description: "Wait for native confirmation",
        handler: async (_args, ctx) => {
          if (await ctx.ui.confirm("Streaming command", "Continue?")) ctx.ui.setStatus("stream-command", "accepted");
        },
      });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-stream-command", tokensPerSecond: 1 });
    faux.setResponses([fauxAssistantMessage("streaming ".repeat(100))]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      modelRuntimeFactory: async () => runtime,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("start foreground streaming");
    await waitUntil(() => slot.catalogPhase === "running");

    const markerDependencies = (slot as unknown as {
      dependencies: { markers: { mark: (sessionId: string, operationId: string) => Promise<void> } };
    }).dependencies.markers;
    const failedMarker = vi.spyOn(markerDependencies, "mark").mockRejectedValueOnce(new Error("injected marker failure"));
    const recoveredCommand = slot.prompt("/during-stream");
    await waitUntil(() => slot.snapshot().extensionPresentation.pendingInteractions.length === 1);
    const recoveredPending = slot.snapshot().extensionPresentation.pendingInteractions[0]!;
    slot.respondToInteraction(recoveredPending.id, recoveredPending.hostEpoch, recoveredPending.presentationRevision, false, true);
    await expect(recoveredCommand).resolves.toEqual({ operationId: expect.any(String) });
    await waitUntil(() => slot.snapshot().extensionCommand === undefined);
    expect(failedMarker.mock.calls.length).toBeGreaterThanOrEqual(2);
    failedMarker.mockRestore();

    const command = slot.prompt("/during-stream");
    await waitUntil(() => slot.snapshot().extensionPresentation.pendingInteractions.length === 1);
    const pending = slot.snapshot().extensionPresentation.pendingInteractions[0]!;
    const during = slot.snapshot();
    expect(during.phase).toBe("running");
    expect(during.operation?.kind).toBe("prompt");
    expect(during.extensionCommand?.kind).toBe("command");
    const marker = JSON.parse(await readFile(join(root, "tron", "gateway", "runtime-markers", `${slot.id}.json`), "utf8")) as {
      operations: Array<{ operationId: string }>;
    };
    expect(marker.operations.map((operation) => operation.operationId)).toContain(during.extensionCommand?.id);
    let drainSettled = false;
    const drain = registry.waitUntilIdle().then(() => { drainSettled = true; });
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(drainSettled).toBe(false);
    slot.respondToInteraction(pending.id, pending.hostEpoch, pending.presentationRevision, true, false);
    await expect(command).resolves.toEqual({ operationId: expect.any(String) });
    await waitUntil(() => slot.snapshot().extensionCommand === undefined);
    expect(slot.snapshot().extensionPresentation.semanticState.statuses["stream-command"]).toBe("accepted");
    let releaseMarkerClear!: () => void;
    const markerClearBarrier = new Promise<void>((resolve) => { releaseMarkerClear = resolve; });
    const markerStore = (slot as unknown as {
      dependencies: { markers: { clear: (sessionId: string, operationId?: string) => Promise<void> } };
    }).dependencies.markers;
    const originalClear = markerStore.clear.bind(markerStore);
    const markerClear = vi.spyOn(markerStore, "clear").mockImplementationOnce(async () => markerClearBarrier);
    const aborting = slot.abort();
    await waitUntil(() => markerClear.mock.calls.length === 1);
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(drainSettled).toBe(false);
    markerClear.mockImplementation(originalClear);
    releaseMarkerClear();
    await aborting;
    await waitUntil(() => slot.catalogPhase === "idle");
    await drain;
    expect(drainSettled).toBe(true);
  });

  it("keeps exact extension-shutdown ownership through a failed close retry", async () => {
    const fixture = await coldFixture("extension-shutdown-retry");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runtime = (slot as unknown as { runtime: { dispose: () => Promise<void> } }).runtime;
    const originalDispose = runtime.dispose.bind(runtime);
    const dispose = vi.spyOn(runtime, "dispose")
      .mockRejectedValueOnce(new Error("injected shutdown failure"))
      .mockImplementationOnce(originalDispose);

    (slot as unknown as { requestExtensionShutdown: () => void }).requestExtensionShutdown();
    await waitUntil(() => dispose.mock.calls.length === 1);
    expect(fixture.registry.administrativeWorkRegistry.facts()).toMatchObject([{
      kind: "extension-command-prompt-ui",
      sessionId: slot.id,
    }]);
    await waitUntil(() => dispose.mock.calls.length === 2, 3_000);
    await waitUntil(() => fixture.registry.administrativeWorkRegistry.size === 0);
    expect(slot.isDisposed).toBe(true);
  });

  it("scopes extension shutdown to the owning runtime slot", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-extension-scoped-shutdown-"));
    const agentDir = join(root, "agent");
    const closingCwd = join(root, "closing");
    const otherCwd = join(root, "other");
    const extensionDir = join(closingCwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true }), mkdir(otherCwd)]);
    await writeFile(join(extensionDir, "shutdown.ts"), `export default function (pi) {
      pi.on("session_shutdown", async (_event, ctx) => {
        await new Promise((resolve) => setTimeout(resolve, 50));
        ctx.ui.setStatus("shutdown", "complete");
      });
      pi.registerCommand("close-owning-session", { handler: async (_args, ctx) => ctx.shutdown() });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(closingCwd, true);
    const shutdownTopics: string[] = [];
    let listChanges = 0;
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: (_sessionID, topic) => shutdownTopics.push(topic),
      sessionSummaryChanged: () => {},
      sessionListChanged: () => { listChanges += 1; },
    });
    registries.push(registry);
    await registry.initialize();
    const closing = await registry.create(closingCwd);
    const other = await registry.create(otherCwd);
    const closingID = closing.id;
    const ownership = registry as unknown as {
      slots: Map<string, unknown>;
      summaryRevisions: Map<string, number>;
      latestSummaries: Map<string, SessionSummaryUpdate>;
    };
    expect(closing.persistedSessionFile).toBeUndefined();
    expect(ownership.summaryRevisions.has(closingID)).toBe(true);
    expect(ownership.latestSummaries.has(closingID)).toBe(true);

    await closing.prompt("/close-owning-session");
    await waitUntil(() => !ownership.slots.has(closingID));
    expect(() => other.context()).not.toThrow();
    expect(ownership.summaryRevisions.has(closingID)).toBe(false);
    expect(ownership.latestSummaries.has(closingID)).toBe(false);
    await expect(registry.acquire(closingID)).rejects.toMatchObject({ code: "not_found" });
    const shutdownStatusIndex = shutdownTopics.lastIndexOf("session.extensionPresentation");
    const closedIndex = shutdownTopics.lastIndexOf("session.closed");
    expect(shutdownStatusIndex).toBeGreaterThanOrEqual(0);
    expect(closedIndex).toBeGreaterThan(shutdownStatusIndex);

    const persisted = await registry.create(closingCwd);
    const persistedManager = (persisted as unknown as { sessionManager: SessionManager }).sessionManager;
    persistedManager.appendMessage(fauxAssistantMessage("persisted before extension close"));
    persisted.publishSnapshot();
    expect(persisted.persistedSessionFile).toBeDefined();
    const persistedID = persisted.id;
    const revisionBeforeClose = ownership.summaryRevisions.get(persistedID)!;
    const structuralChangesBeforeClose = listChanges;

    await persisted.prompt("/close-owning-session");
    await waitUntil(() => !ownership.slots.has(persistedID));
    expect(listChanges).toBe(structuralChangesBeforeClose);
    expect(ownership.summaryRevisions.get(persistedID)).toBeGreaterThanOrEqual(revisionBeforeClose);
    expect(ownership.latestSummaries.get(persistedID)).toMatchObject({
      sessionId: persistedID,
      phase: "idle",
      summaryRevision: ownership.summaryRevisions.get(persistedID),
    });
  });

  it("isolates same-named providers registered by concurrent project extensions", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-provider-isolation-"));
    const agentDir = join(root, "agent");
    const firstCwd = join(root, "first");
    const secondCwd = join(root, "second");
    await Promise.all([
      mkdir(agentDir),
      mkdir(join(firstCwd, ".pi", "extensions"), { recursive: true }),
      mkdir(join(secondCwd, ".pi", "extensions"), { recursive: true }),
    ]);
    const extension = (name: string) => `export default function (pi) { pi.registerProvider("project-provider", { baseUrl: "https://provider.invalid", apiKey: "fixture", api: "openai-completions", models: [{ id: "model", name: ${JSON.stringify(name)}, reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 4096, maxTokens: 1024 }] }); }\n`;
    await Promise.all([
      writeFile(join(firstCwd, ".pi", "extensions", "provider.ts"), extension("First Project Model")),
      writeFile(join(secondCwd, ".pi", "extensions", "provider.ts"), extension("Second Project Model")),
    ]);
    const trust = new TrustService(agentDir);
    await Promise.all([trust.set(firstCwd, true), trust.set(secondCwd, true)]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust,
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();

    const [first, second] = await Promise.all([registry.create(firstCwd), registry.create(secondCwd)]);
    expect(first.modelRuntime).not.toBe(second.modelRuntime);
    expect(first.modelRuntime.getModel("project-provider", "model")?.name).toBe("First Project Model");
    expect(second.modelRuntime.getModel("project-provider", "model")?.name).toBe("Second Project Model");
  });

  it("projects the canonical latest cache hit rate used by the terminal footer", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-cache-rate-integration-"));
    const agentDir = join(root, "agent");
    const sessionDir = join(root, "sessions");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(sessionDir), mkdir(cwd)]);
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ sessionDir }));
    const faux = fauxProvider({ provider: "tron-cache-rate", tokensPerSecond: 10_000 });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    faux.setResponses([fauxAssistantMessage("cached")]);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    expect(slot.sessionFile?.startsWith(sessionDir)).toBe(true);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("cache stats");
    await waitUntil(() => !slot.isBusy);

    const snapshot = slot.snapshot();
    const assistant = snapshot.transcript.find((item) => item.role === "assistant");
    const usage = (assistant as any)?.usage as { input?: number; cacheRead?: number; cacheWrite?: number } | undefined;
    const promptTokens = (usage?.input ?? 0) + (usage?.cacheRead ?? 0) + (usage?.cacheWrite ?? 0);
    const expected = promptTokens > 0 ? ((usage?.cacheRead ?? 0) / promptTokens) * 100 : undefined;
    expect(snapshot.stats.latestCacheHitRate).toBe(expected);
  });

  it("projects readable metadata for project resources", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-resources-integration-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const pi = join(cwd, ".pi");
    await Promise.all([
      mkdir(agentDir),
      mkdir(join(pi, "extensions"), { recursive: true }),
      mkdir(join(pi, "prompts"), { recursive: true }),
      mkdir(join(pi, "skills", "review"), { recursive: true }),
    ]);
    const cwdAlias = join(root, "workspace-alias");
    await symlink(cwd, cwdAlias);
    await Promise.all([
      writeFile(join(pi, "extensions", "tool.ts"), `export default function (pi) { pi.registerTool({ name: "project_echo", label: "Project echo", description: "Echo project text", parameters: { type: "object", properties: { text: { type: "string" } }, required: ["text"] }, execute: async (_id, params) => ({ content: [{ type: "text", text: params.text }], details: {} }) }); }\n`),
      writeFile(join(pi, "prompts", "review.md"), `---\ndescription: Review the current change\n---\nReview $ARGUMENTS\n`),
      writeFile(join(pi, "skills", "review", "SKILL.md"), `---\nname: review-skill\ndescription: Inspect a code change\n---\nReview carefully.\n`),
    ]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const resourceEvents: string[] = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust,
      broadcast: (_sessionId, topic) => { resourceEvents.push(topic); },
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();

    const slot = await registry.create(cwd);
    const resources = slot.resources() as any;
    expect(resources.extensions).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "tool.ts", scope: "project", tools: ["project_echo"] }),
    ]));
    expect(resources.prompts.prompts).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "review", description: "Review the current change", scope: "project" }),
    ]));
    expect(resources.skills.skills).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "review-skill", description: "Inspect a code change", scope: "project" }),
    ]));
    expect(resources.tools).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "project_echo", description: "Echo project text", scope: "project" }),
    ]));

    resourceEvents.length = 0;
    await registry.reloadProject(cwd, false, false);
    expect(() => slot.resources()).toThrow("Project trust is being reconfigured");
    expect(() => slot.modelRuntime).toThrow("Project trust is being reconfigured");
    expect(() => slot.sessionEnvironment()).toThrow("Project trust is being reconfigured");
    expect(() => slot.respondToInteraction("pending", "host", 0, null, true)).toThrow("Project trust is being reconfigured");
    await expect(registry.create(cwd)).rejects.toMatchObject({ code: "busy", retryable: true });
    await expect(registry.create(cwdAlias)).rejects.toMatchObject({ code: "busy", retryable: true });
    await expect(trust.inspect(cwd)).resolves.toMatchObject({ savedDecision: true });
    expect(resourceEvents).not.toContain("session.resourcesChanged");
    await trust.set(cwd, false);
    await registry.commitProjectReload(cwd);
    const untrusted = slot.resources() as any;
    expect(untrusted.tools).not.toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "project_echo" }),
    ]));
    expect(resourceEvents).toContain("session.resourcesChanged");
  });

  it("owns its catalog, infers nested subagents, and keeps ordinary forks user-visible", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-session-catalog-"));
    const agentDir = join(root, "agent");
    const tronHome = join(root, "tron");
    const cwd = join(root, "workspace");
    const externalDir = join(root, "external-sessions");
    await Promise.all([mkdir(agentDir), mkdir(tronHome), mkdir(cwd), mkdir(externalDir)]);

    const timestamp = new Date().toISOString();
    const writeSession = async (directory: string, id: string, message: string, parentSession?: string) => {
      const path = join(directory, `${id}.jsonl`);
      await writeFile(path, [
        JSON.stringify({ type: "session", version: 3, id, timestamp, cwd, ...(parentSession ? { parentSession } : {}) }),
        JSON.stringify({ type: "message", id: randomUUID().slice(0, 8), parentId: null, timestamp, message: { role: "user", content: message, timestamp: Date.now() } }),
      ].join("\n") + "\n");
      return path;
    };
    const externalId = randomUUID();
    await writeSession(externalDir, externalId, "external process");

    const piSessionDirectory = join(agentDir, "sessions", "--workspace--");
    await mkdir(piSessionDirectory, { recursive: true });
    const parentId = randomUUID();
    const parentFile = await writeSession(piSessionDirectory, parentId, "parent");

    const nestedDirectory = join(parentFile.replace(/\.jsonl$/, ""), "child", "run-0");
    await mkdir(nestedDirectory, { recursive: true });
    const nestedId = randomUUID();
    await writeSession(nestedDirectory, nestedId, "nested fresh child");

    const fork = SessionManager.forkFrom(parentFile, cwd, piSessionDirectory);
    fork.appendSessionInfo("ordinary fork");
    const directSubagent = SessionManager.forkFrom(parentFile, cwd, piSessionDirectory);
    directSubagent.appendSessionInfo("subagent-worker-fixture-1");
    const crossProjectDirectory = join(agentDir, "sessions", "--other-workspace--");
    await mkdir(crossProjectDirectory, { recursive: true });
    const crossProjectFork = SessionManager.forkFrom(
      parentFile, join(root, "other-workspace"), crossProjectDirectory
    );

    // A child context can be interrupted after Pi writes its inherited branch
    // but before any task/name provenance is appended. Its last entry predates
    // its own header and must not become a user dashboard clone.
    const frozenId = randomUUID();
    const frozenTimestamp = new Date(Date.now() + 1_000).toISOString();
    const frozenFile = join(piSessionDirectory, `${frozenId}.jsonl`);
    await writeFile(frozenFile, [
      JSON.stringify({
        type: "session", version: 3, id: frozenId,
        timestamp: frozenTimestamp, cwd, parentSession: parentFile,
      }),
      JSON.stringify({
        type: "message", id: randomUUID().slice(0, 8), parentId: null,
        timestamp, message: { role: "user", content: "inherited", timestamp: Date.now() - 1_000 },
      }),
    ].join("\n") + "\n");
    const markedForkId = randomUUID();
    const markedForkFile = join(piSessionDirectory, `${markedForkId}.jsonl`);
    await writeFile(markedForkFile, [
      JSON.stringify({
        type: "session", version: 3, id: markedForkId,
        timestamp: frozenTimestamp, cwd, parentSession: parentFile,
      }),
      JSON.stringify({
        type: "message", id: "marked-old", parentId: null,
        timestamp, message: { role: "user", content: "inherited", timestamp: Date.now() - 1_000 },
      }),
      JSON.stringify({
        type: "custom", id: "marked-provenance", parentId: "marked-old",
        // Positive provenance wins even if the wall clock moved backwards.
        timestamp, customType: "tron.gateway-user-fork", data: { version: 1 },
      }),
    ].join("\n") + "\n");

    const registry = new RuntimeRegistry({
      agentDir,
      tronHome,
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const defaultCatalog = await registry.list();
    const completeCatalog = await registry.list("all");
    expect(defaultCatalog.map((session) => session.id)).toEqual(expect.arrayContaining([
      parentId, fork.getSessionId(), crossProjectFork.getSessionId(), markedForkId,
    ]));
    expect(defaultCatalog.map((session) => session.id)).not.toContain(nestedId);
    expect(defaultCatalog.map((session) => session.id)).not.toContain(directSubagent.getSessionId());
    expect(defaultCatalog.map((session) => session.id)).not.toContain(frozenId);
    expect(defaultCatalog.map((session) => session.id)).not.toContain(externalId);
    expect(completeCatalog.map((session) => session.id)).not.toContain(externalId);
    expect(completeCatalog.find((session) => session.id === parentId)).toMatchObject({ kind: "user" });
    expect(completeCatalog.find((session) => session.id === fork.getSessionId())).toMatchObject({ kind: "user", parentSessionId: parentId });
    expect(completeCatalog.find((session) => session.id === crossProjectFork.getSessionId())).toMatchObject({
      kind: "user", parentSessionId: parentId,
    });
    expect(completeCatalog.find((session) => session.id === markedForkId)).toMatchObject({
      kind: "user", parentSessionId: parentId,
    });
    expect(completeCatalog.find((session) => session.id === directSubagent.getSessionId())).toMatchObject({
      kind: "subagent",
      parentSessionId: parentId,
    });
    expect(completeCatalog.find((session) => session.id === frozenId)).toMatchObject({
      kind: "subagent",
      parentSessionId: parentId,
    });
    expect(completeCatalog.find((session) => session.id === nestedId)).toMatchObject({
      kind: "subagent",
      parentSessionId: parentId,
    });
    await expect(registry.acquire(nestedId)).rejects.toMatchObject({ code: "conflict" });
    await expect(registry.acquire(frozenId)).rejects.toMatchObject({ code: "conflict" });
    await expect(registry.delete(nestedId)).rejects.toMatchObject({ code: "conflict" });

    await registry.delete(parentId);
    expect((await registry.list("all")).find((session) => session.id === nestedId)).toMatchObject({ kind: "subagent" });
  });

  it("rekeys the owning slot when a completed session is forked", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-runtime-fork-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;

    const faux = fauxProvider({ provider: "tron-fork", tokensPerSecond: 10_000 });
    const createModels = async () => {
      const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
      runtime.registerNativeProvider(faux.provider);
      return runtime;
    };
    faux.setResponses([fauxAssistantMessage("done")]);
    const rekeys: Array<[string, string]> = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: createModels,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      sessionRekeyed: (previousId, nextId) => {
        rekeys.push([previousId, nextId]);
        throw new Error("injected post-commit observer failure");
      },
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("fork this");
    await waitUntil(() => !slot.isBusy);
    const original = slot.id;
    expect(registry.attentionProjection(original).isUnread).toBe(true);
    const userEntry = slot.snapshot().transcript.find((item) => item.role === "user");
    expect(userEntry).toBeDefined();
    registry.subscribe("fork-subscriber", original);
    const internals = registry as unknown as {
      attention: { assertAbsent: (sessionId: string) => Promise<void> };
      slots: Map<string, typeof slot>;
      latestSummaries: Map<string, SessionSummaryUpdate>;
    };
    const assertAbsent = vi.spyOn(internals.attention, "assertAbsent")
      .mockRejectedValueOnce(new Error("injected attention prepare failure"));
    await expect(slot.fork(userEntry!.id, "at")).rejects.toThrow("injected attention prepare failure");
    expect(slot.id).toBe(original);
    expect(internals.slots.get(original)).toBe(slot);
    expect([...internals.slots.values()].filter((candidate) => candidate === slot)).toHaveLength(1);
    expect(registry.isSubscribed("fork-subscriber", original)).toBe(true);
    expect(internals.latestSummaries.get(original)?.sessionId).toBe(original);
    expect(registry.attentionProjection(original).isUnread).toBe(true);
    assertAbsent.mockRestore();

    const fork = await slot.fork(userEntry!.id, "at");
    expect(fork.sessionId).not.toBe(original);
    expect(rekeys).toEqual([[original, fork.sessionId]]);
    expect(registry.attentionProjection(original).isUnread).toBe(true);
    expect(registry.attentionProjection(fork.sessionId)).toEqual({
      completionRevision: 0,
      attentionRevision: 0,
      isUnread: false,
    });
    expect((await registry.acquire(fork.sessionId)).id).toBe(fork.sessionId);
    const forkEntries = (slot as unknown as {
      runtime: { session: { sessionManager: SessionManager } };
    }).runtime.session.sessionManager.getEntries();
    expect(forkEntries.at(-1)).toMatchObject({
      type: "custom",
      customType: "tron.gateway-user-fork",
      data: { version: 1 },
    });
  });

  it("rejects imports when live runtime capacity is full", async () => {
    const { root, cwd, registry } = await coldFixture("import-capacity", { maximumLiveRuntimes: 1 });
    await registry.create(cwd);

    await expect(registry.importFromJsonl(join(root, "import.jsonl"), cwd)).rejects.toMatchObject({
      code: "busy",
      retryable: true,
    });
  });

  it("admits direct Bash after proving idle without tripping on its own work token", async () => {
    const { manager, registry } = await coldFixture("bash-work-registry");
    const slot = await registry.acquire(manager.getSessionId());
    const session = (slot as unknown as {
      runtime: { session: { executeBash: (...arguments_: unknown[]) => Promise<unknown> } };
    }).runtime.session;
    let releaseBash!: () => void;
    const bashBarrier = new Promise<void>((resolve) => { releaseBash = resolve; });
    const execute = vi.spyOn(session, "executeBash").mockImplementation(async () => {
      await bashBarrier;
      return { output: "ok" };
    });
    const markerStore = (slot as unknown as {
      dependencies: { markers: { clear: (sessionId: string, operationId?: string) => Promise<void> } };
    }).dependencies.markers;
    const clearMarker = vi.spyOn(markerStore, "clear").mockRejectedValueOnce(new Error("transient clear failure"));

    const bash = slot.executeBash("printf ok", true);
    await waitUntil(() => execute.mock.calls.length === 1);
    expect(slot.snapshot().processActivities ?? []).toEqual([]);
    const markerPath = join((registry as unknown as { options: { tronHome: string } }).options.tronHome,
      "gateway", "runtime-markers", `${slot.id}.json`);
    expect(JSON.parse(await readFile(markerPath, "utf8")).operations).toHaveLength(1);
    let drained = false;
    const drain = registry.waitUntilIdle().then(() => { drained = true; });
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(drained).toBe(false);
    releaseBash();
    await expect(bash).resolves.toEqual({ output: "ok" });
    await drain;
    expect(clearMarker.mock.calls.length).toBeGreaterThanOrEqual(2);
    expect(execute).toHaveBeenCalledTimes(1);
    expect(registry.administrativeWorkRegistry.size).toBe(0);
    expect(slot.snapshot()).toMatchObject({ phase: "idle" });
    expect(slot.snapshot().processActivities ?? []).toEqual([]);
  });

  it("cancels an idle eviction when a selected slot is acquired or subscribed before disposal", async () => {
    const { manager, registry } = await coldFixture("idle-eviction-acquire-subscribe");
    const sessionId = manager.getSessionId();
    const slot = await registry.acquire(sessionId);
    vi.spyOn(slot, "touchedAt", "get").mockReturnValue(0);

    let releaseLane!: () => void;
    let laneEntered!: () => void;
    const laneHeld = new Promise<void>((resolve) => { releaseLane = resolve; });
    const laneEnteredPromise = new Promise<void>((resolve) => { laneEntered = resolve; });
    const lane = (slot as unknown as { lane: { run: (operation: () => Promise<void>) => Promise<void> } }).lane;
    const blockedLane = lane.run(async () => {
      laneEntered();
      await laneHeld;
    });
    await laneEnteredPromise;

    const eviction = (registry as unknown as { evictIdle: () => Promise<void> }).evictIdle();
    await waitUntil(() => (registry as unknown as { idleEvictions: Map<string, { slot: unknown }> }).idleEvictions.get(sessionId)?.slot === slot);

    const [acquired] = await Promise.all([
      registry.acquire(sessionId),
      Promise.resolve().then(() => registry.subscribe("race-client", sessionId)),
    ]);
    releaseLane();
    await Promise.all([blockedLane, eviction]);

    expect(acquired).toBe(slot);
    expect(await registry.acquire(sessionId)).toBe(slot);
    expect(registry.isSubscribed("race-client", sessionId)).toBe(true);
  });
});
