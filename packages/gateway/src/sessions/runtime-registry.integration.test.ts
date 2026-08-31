import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { appendFile, copyFile, mkdtemp, mkdir, readFile, realpath, rename, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { getExamplesPath, ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import type { NotificationService } from "../notifications/notification-service.js";
import type { ExtensionRunActivity, ExtensionToolOrigin, SessionProcessActivity, SessionSummaryUpdate } from "../protocol/types.js";
import { GatewayWorkRegistry } from "./gateway-work-registry.js";
import { CatalogMetadataIndex } from "./catalog-metadata-index.js";
import { INVOCATION_RECEIPT_TYPE } from "./invocation-receipts.js";
import { RuntimeRegistry } from "./runtime-registry.js";
import { RunMarkerCompletionConflictError } from "./run-markers.js";

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
    phaseObserver?: (phase: "catalog-warming" | "attention-recovery") => void;
    sessionListChanged?: () => void;
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
    const summaries: SessionSummaryUpdate[] = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      maximumLiveRuntimes: options.maximumLiveRuntimes,
      workRegistry: options.workRegistry,
      modelRuntimeFactory: runtimeFactory,
      trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => events.push({ topic, payload }),
      sessionSummaryChanged: (summary) => summaries.push(summary),
      sessionListChanged: options.sessionListChanged ?? (() => {}),
    });
    registries.push(registry);
    const startupEvidence = options.phaseObserver
      ? vi.spyOn(registry as any, "catalogStructureEvidence")
      : undefined;
    await registry.initialize(options.phaseObserver);
    return {
      root,
      agentDir,
      cwd,
      manager,
      registry,
      runtimeFactory,
      events,
      summaries,
      sessionFile: manager.getSessionFile()!,
      startupEvidence,
    };
  }

  afterEach(async () => {
    await Promise.all(registries.splice(0).map((registry) => registry.dispose()));
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
  });

  it("orders startup phases and acquires one structural evidence cut", async () => {
    const phases: string[] = [];
    const fixture = await coldFixture("startup-phases", {
      phaseObserver: (phase) => phases.push(phase),
    });
    expect(phases).toEqual(["catalog-warming", "attention-recovery"]);
    // A later page source may validate a different cut, but startup itself has
    // exactly one bounded structural evidence acquisition for reconciliation.
    expect(fixture.startupEvidence).toHaveBeenCalledTimes(1);
  });

  it("admits a page source after in-flight live summary churn", async () => {
    const fixture = await coldFixture("page-source-summary-churn");
    const internals = fixture.registry as unknown as {
      materializeCatalogSnapshot: () => Promise<unknown>;
      publishRevisionedSummary: (summary: SessionSummaryUpdate) => void;
    };
    const original = internals.materializeCatalogSnapshot.bind(fixture.registry);
    let entered!: () => void;
    let release!: () => void;
    const captured = new Promise<void>((resolve) => { entered = resolve; });
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const materialize = vi.spyOn(internals, "materializeCatalogSnapshot").mockImplementation(async () => {
      const result = await original();
      entered();
      await gate;
      return result;
    });
    try {
      const listing = fixture.registry.pageSource("user");
      await captured;
      internals.publishRevisionedSummary({
        sessionId: fixture.manager.getSessionId(),
        summaryRevision: 1,
        phase: "running",
        updatedAt: new Date().toISOString(),
        messageCount: 1,
        firstMessage: "cold acquisition page-source-summary-churn",
        completionRevision: 0,
        attentionRevision: 0,
        isUnread: false,
      });
      release();
      const source = await listing;
      await expect(source.page(0, 1)).resolves.toMatchObject([
        expect.objectContaining({ id: fixture.manager.getSessionId(), phase: "running" }),
      ]);
    } finally {
      release();
      materialize.mockRestore();
    }
  });

  it("builds page sources without full catalog projection and captures overlays per generation", async () => {
    const fixture = await coldFixture("page-source");
    const catalog = vi.spyOn(fixture.registry, "catalog");
    const firstSource = await fixture.registry.pageSource("user");
    const firstPage = await firstSource.page(0, 25_000);
    expect(catalog).not.toHaveBeenCalled();
    expect(firstPage).toHaveLength(1);
    expect(firstPage[0]).toMatchObject({ id: fixture.manager.getSessionId(), kind: "user", cwd: fixture.cwd });
    expect(firstPage[0]!.isUnread).toBe(false);
    await fixture.registry.setAttention(fixture.manager.getSessionId(), true);
    const secondSource = await fixture.registry.pageSource("user");
    expect(secondSource.generation).not.toBe(firstSource.generation);
    expect((await secondSource.page(0, 1))[0]!.isUnread).toBe(true);
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

  it("latches foreground-open and foreground-close completion dispositions at canonical admission", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-agent-observed-completion-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    let releaseHiddenCompletion!: () => void;
    const hiddenCompletionBarrier = new Promise<void>((resolve) => { releaseHiddenCompletion = resolve; });
    const faux = fauxProvider({ provider: "tron-agent-observed-completion", tokensPerSecond: 10_000 });
    faux.setResponses([
      fauxAssistantMessage("observed response"),
      async () => {
        await hiddenCompletionBarrier;
        return fauxAssistantMessage("hidden response");
      },
    ]);
    runtime.registerNativeProvider(faux.provider);
    const enqueue = vi.fn(async () => "queued" as const);
    const suppressAutomaticCompletion = vi.fn(async () => "suppressed" as const);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      machineId: "machine-observed-test",
      notifications: { enqueue, suppressAutomaticCompletion, askPresented: vi.fn() } as unknown as NotificationService,
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    registry.subscribe("visible-phone", slot.id);
    registry.setPresentationVisibility({
      clientId: "visible-phone",
      sessionId: slot.id,
      subscriptionToken: "visible-subscription",
      revision: 1,
      visible: true,
    });

    await slot.prompt("finish while visible");
    await waitUntil(() => !slot.isBusy);
    await waitUntil(() => registry.attentionProjection(slot.id).completionRevision === 1);
    expect(registry.attentionProjection(slot.id)).toMatchObject({ completionRevision: 1, isUnread: false });
    await waitUntil(() => suppressAutomaticCompletion.mock.calls.length > 0);
    expect(enqueue).not.toHaveBeenCalled();
    expect(suppressAutomaticCompletion).toHaveBeenCalledWith({
      sessionId: slot.id,
      sourceId: expect.any(String),
    });

    enqueue.mockClear();
    suppressAutomaticCompletion.mockClear();
    await slot.prompt("finish after presentation closes");
    await waitUntil(() => slot.isBusy);
    registry.setPresentationVisibility({
      clientId: "visible-phone",
      sessionId: slot.id,
      subscriptionToken: "visible-subscription",
      revision: 2,
      visible: false,
    });
    releaseHiddenCompletion();
    await waitUntil(() => !slot.isBusy);
    await waitUntil(() => registry.attentionProjection(slot.id).completionRevision === 2);
    expect(registry.attentionProjection(slot.id)).toMatchObject({ completionRevision: 2, isUnread: true });
    await waitUntil(() => enqueue.mock.calls.length > 0);
    expect(enqueue).toHaveBeenCalledWith(expect.objectContaining({
      sessionId: slot.id,
      kind: "agent_finished",
      sourceId: expect.any(String),
    }));
    expect(suppressAutomaticCompletion).not.toHaveBeenCalled();
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

  it("resolves attention membership without materializing the full catalog", async () => {
    const fixture = await coldFixture("attention-scoped-resolution");
    const catalog = vi.spyOn(fixture.registry, "catalog");
    const projection = await fixture.registry.setAttention(fixture.manager.getSessionId(), true);
    expect(projection.isUnread).toBe(true);
    expect(catalog).not.toHaveBeenCalled();
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
    await Promise.all(infos.map((info) => writeFile(info.path, `${JSON.stringify({
      type: "session", version: 3, id: info.id, timestamp: now.toISOString(), cwd: root,
    })}\n`)));
    const encodedBytes = infos.reduce((total, { allMessagesText: _unused, ...info }) => (
      total + Buffer.byteLength(JSON.stringify({
        ...info, created: now, modified: now, firstMessage: "(no messages)",
      }))
    ), 0);
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

    await expect(makeRegistry(1, encodedBytes).catalog("all")).rejects.toMatchObject({ code: "busy" });
    await expect(makeRegistry(2, encodedBytes).catalog("all")).rejects.toMatchObject({ code: "busy" });
    await expect(makeRegistry(2, encodedBytes + 1_024).catalog("all")).resolves.toMatchObject({
      sessions: [{ id: "first" }, { id: "second" }],
    });
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
    await Promise.all(infos.map((info) => writeFile(info.path, `${JSON.stringify({
      type: "session", version: 3, id: info.id, timestamp: now.toISOString(), cwd: root,
    })}\n`)));
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
    }
  });

  it("reuses one stable catalog acquisition without a second transcript-wide materialization", async () => {
    const fixture = await coldFixture("reuse");
    const internals = fixture.registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const materialize = vi.spyOn(internals, "sessionInfos");

    const catalog = await fixture.registry.catalog("user");
    expect(catalog.sessions.map((session) => session.id)).toContain(fixture.manager.getSessionId());
    // The first cut builds the durable metadata index; subsequent operations
    // reuse it without another transcript-wide SDK catalog helper.
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

  it("reuses an on-disk catalog across a second registry without a body scan and advances one appended row", async () => {
    const fixture = await coldFixture("restart-index");
    const secondDirectory = join(fixture.agentDir, "sessions", "second");
    await mkdir(secondDirectory, { recursive: true });
    const secondManager = SessionManager.create(fixture.cwd, secondDirectory);
    secondManager.appendMessage(fauxAssistantMessage("unchanged canonical body"));
    fixture.manager.appendMessage(fauxAssistantMessage("initial canonical body"));
    await fixture.registry.catalog("all");
    const indexPath = join(fixture.root, "tron", "gateway", "catalog-metadata-v1.json");
    await waitUntil(() => existsSync(indexPath));
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
    const internals = restarted as unknown as { sessionInfos: () => Promise<unknown[]> };
    const scanner = vi.spyOn(internals, "sessionInfos");
    const append = vi.spyOn(CatalogMetadataIndex.prototype, "append");
    const reconcile = vi.spyOn(CatalogMetadataIndex.prototype, "reconcile");
    try {
      const unchanged = await restarted.catalog("all");
      expect(scanner).not.toHaveBeenCalled();
      expect(unchanged.sessions.find((session) => session.id === fixture.manager.getSessionId())?.messageCount).toBe(2);
      expect(unchanged.sessions.find((session) => session.id === secondManager.getSessionId())?.messageCount).toBe(1);
      await new Promise((resolve) => setTimeout(resolve, 50));
      fixture.manager.appendMessage(fauxAssistantMessage("external append after restart"));
      const updated = await restarted.catalog("all");
      expect(scanner).not.toHaveBeenCalled();
      expect(append).toHaveBeenCalledTimes(1);
      expect(updated.sessions.find((session) => session.id === fixture.manager.getSessionId())?.messageCount).toBe(3);
      expect(updated.sessions.find((session) => session.id === secondManager.getSessionId())?.messageCount).toBe(1);
    } finally {
      scanner.mockRestore();
      append.mockRestore();
      reconcile.mockRestore();
    }
  });

  it("retires a durable load invalidated before publication and falls back to a fresh canonical cut", async () => {
    const fixture = await coldFixture("restart-index-publication-race");
    fixture.manager.appendMessage(fauxAssistantMessage("indexed canonical body"));
    await fixture.registry.catalog("all");
    const indexPath = join(fixture.root, "tron", "gateway", "catalog-metadata-v1.json");
    await waitUntil(() => existsSync(indexPath));
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
    const internals = restarted as unknown as {
      catalogMetadataIndex: CatalogMetadataIndex;
      sessionInfos: () => Promise<unknown[]>;
      invalidateCatalogAcquisition: () => void;
      catalogStructuralIndex?: { structuralGeneration: number };
      catalogStructuralGeneration: number;
    };
    const original = internals.catalogMetadataIndex.reconcile.bind(internals.catalogMetadataIndex);
    let entered!: () => void;
    let release!: () => void;
    const suspended = new Promise<void>((resolve) => { entered = resolve; });
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const reconcile = vi.spyOn(internals.catalogMetadataIndex, "reconcile").mockImplementation(async (...arguments_) => {
      entered();
      await gate;
      return original(...arguments_);
    });
    const scanner = vi.spyOn(internals, "sessionInfos");
    try {
      const listing = restarted.catalog("all");
      await suspended;
      internals.invalidateCatalogAcquisition();
      release();
      await expect(listing).resolves.toMatchObject({
        sessions: expect.arrayContaining([expect.objectContaining({ id: fixture.manager.getSessionId() })]),
      });
      expect(scanner).toHaveBeenCalledTimes(1);
      expect(internals.catalogStructuralIndex?.structuralGeneration).toBe(internals.catalogStructuralGeneration);
    } finally {
      release();
      reconcile.mockRestore();
      scanner.mockRestore();
    }
  });

  it("admits a complete append only for the matching live-owned session identity", async () => {
    const fixture = await coldFixture("live-append");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internals = fixture.registry as unknown as {
      isLiveRuntimeOwnedPath: (path: string, sessionID: string) => boolean;
    };
    const ownedPath = slot.persistedSessionFile ?? fixture.sessionFile;
    expect(internals.isLiveRuntimeOwnedPath(ownedPath, slot.id)).toBe(true);
    expect(internals.isLiveRuntimeOwnedPath(ownedPath, "unrelated-session")).toBe(false);
    await fixture.registry.catalog("all");
    fixture.manager.appendMessage(fauxAssistantMessage("live append"));
    await expect(fixture.registry.catalog("all")).resolves.toMatchObject({
      sessions: expect.arrayContaining([expect.objectContaining({ id: fixture.manager.getSessionId() })]),
    });
  });

  it("fails closed with retryable busy when an unowned canonical file ends in a partial line", async () => {
    const fixture = await coldFixture("partial-final-line");
    await fixture.registry.catalog("all");
    await appendFile(fixture.sessionFile, "{\"type\":\"message\"");
    await expect(fixture.registry.catalog("all")).rejects.toMatchObject({ code: "busy", retryable: true });
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

  it("invalidates connected catalogs when cold attention has no live summary", async () => {
    const listChanged = vi.fn();
    const fixture = await coldFixture("cold-attention", { sessionListChanged: listChanged });
    const before = listChanged.mock.calls.length;
    const unread = await fixture.registry.setAttention(fixture.manager.getSessionId(), true);
    expect(unread.isUnread).toBe(true);
    expect(listChanged.mock.calls.length).toBe(before + 1);
  });

  it("converges empty create/list/delete while live summaries churn", async () => {
    const fixture = await coldFixture("create-list-delete-churn");
    const live = await fixture.registry.create(fixture.cwd);
    const internals = fixture.registry as unknown as {
      publishRevisionedSummary: (summary: SessionSummaryUpdate) => void;
    };
    for (let revision = 1; revision <= 8; revision += 1) {
      internals.publishRevisionedSummary({
        sessionId: live.id,
        summaryRevision: revision,
        phase: "running",
        updatedAt: new Date().toISOString(),
        messageCount: revision,
        firstMessage: "created live session",
        completionRevision: 0,
        attentionRevision: 0,
        isUnread: false,
      });
    }
    expect((await fixture.registry.catalog("user")).sessions.map((session) => session.id)).toContain(live.id);
    await fixture.registry.delete(live.id);
    expect((await fixture.registry.catalog("user")).sessions.map((session) => session.id)).not.toContain(live.id);
  });

  it("admits unread and read attention for an empty live-only session", async () => {
    const fixture = await coldFixture("live-only-attention");
    const live = await fixture.registry.create(fixture.cwd);
    const unread = await fixture.registry.setAttention(live.id, true);
    expect(unread.isUnread).toBe(true);
    const read = await fixture.registry.setAttention(live.id, false, unread.completionRevision);
    expect(read.isUnread).toBe(false);
  });

  it("quarantines a disk claimant that collides with an empty live-only session", async () => {
    const fixture = await coldFixture("live-only-attention-collision");
    const live = await fixture.registry.create(fixture.cwd);
    const collisionDirectory = join(fixture.agentDir, "sessions", "collision");
    await mkdir(collisionDirectory, { recursive: true });
    const collision = SessionManager.create(fixture.cwd, collisionDirectory, { id: live.id });
    collision.appendMessage(fauxAssistantMessage("collision"));
    await expect(fixture.registry.setAttention(live.id, true)).rejects.toMatchObject({ code: "conflict" });
  });

  it("rechecks a live-only attention target when a disk claimant appears at the commit boundary", async () => {
    const fixture = await coldFixture("live-only-attention-race");
    const live = await fixture.registry.create(fixture.cwd);
    const internals = fixture.registry as unknown as {
      attentionLiveOnlyStillAdmitted: (sessionId: string) => Promise<boolean>;
    };
    const original = internals.attentionLiveOnlyStillAdmitted.bind(fixture.registry);
    let entered!: () => void;
    let release!: () => void;
    const reachedCommitBoundary = new Promise<void>((resolve) => { entered = resolve; });
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const finalAdmission = vi.spyOn(internals, "attentionLiveOnlyStillAdmitted")
      .mockImplementation(async (sessionId) => {
        entered();
        await gate;
        return original(sessionId);
      });

    try {
      const update = fixture.registry.setAttention(live.id, true);
      await reachedCommitBoundary;
      const collisionDirectory = join(fixture.agentDir, "sessions", "late-collision");
      await mkdir(collisionDirectory, { recursive: true });
      const collision = SessionManager.create(fixture.cwd, collisionDirectory, { id: live.id });
      collision.appendMessage(fauxAssistantMessage("late collision"));
      release();
      await expect(update).rejects.toMatchObject({ code: "conflict" });
      expect(fixture.registry.attentionProjection(live.id).isUnread).toBe(false);
    } finally {
      release();
      finalAdmission.mockRestore();
    }
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
      // Generic acquisition-budget incompleteness may use the stable full
      // metadata fallback, but it is never certified as a reusable index.
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

  it("ignores malformed non-session subagent artifacts without poisoning the catalog index", async () => {
    const fixture = await coldFixture("ignored-artifacts");
    const artifactDirectory = join(fixture.agentDir, "sessions", "workspace", "subagent-artifacts");
    await mkdir(artifactDirectory, { recursive: true });
    await writeFile(join(artifactDirectory, "worker.jsonl"), `${JSON.stringify({ recordType: "message", text: "diagnostic" })}\\n`);
    const internals = fixture.registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const materialize = vi.spyOn(internals, "sessionInfos");

    const first = await fixture.registry.catalog("all");
    expect(first.sessions.map((session) => session.id)).toContain(fixture.manager.getSessionId());
    expect(materialize).toHaveBeenCalledTimes(1);
    const second = await fixture.registry.catalog("all");
    expect(second.sessions.map((session) => session.id)).toContain(fixture.manager.getSessionId());
    expect(materialize).toHaveBeenCalledTimes(1);
  });

  it("coalesces concurrent fallback acquisition scans for one catalog generation", async () => {
    const fixture = await coldFixture("coalesced-fallback");
    await writeFile(join(fixture.agentDir, "sessions", "workspace", "malformed.jsonl"), `${"x".repeat(70_000)}\\n`);
    const internals = fixture.registry as unknown as { sessionInfos: () => Promise<unknown[]> };
    const original = internals.sessionInfos.bind(fixture.registry);
    let entered!: () => void;
    let release!: () => void;
    const enteredScan = new Promise<void>((resolve) => { entered = resolve; });
    const scanBarrier = new Promise<void>((resolve) => { release = resolve; });
    let calls = 0;
    const materialize = vi.spyOn(internals, "sessionInfos").mockImplementation(async () => {
      calls += 1;
      if (calls === 1) {
        entered();
        await scanBarrier;
      }
      return original();
    });
    const acquire = (fixture.registry as unknown as { catalogAcquisition: () => Promise<unknown> }).catalogAcquisition
      .bind(fixture.registry);
    const first = acquire();
    await enteredScan;
    const second = acquire();
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(calls).toBe(1);
    release();
    await Promise.all([first, second]);
    expect(materialize).toHaveBeenCalledTimes(2);
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

  it("recognizes only the exact delegated-session producer topology", async () => {
    const fixture = await coldFixture("topology-helper");
    const internals = fixture.registry as unknown as {
      delegatedSessionTopologies: (sessions: Array<{
        id: string; path: string; parentSessionPath?: string;
      }>) => ReadonlyMap<string, { parentSessionId?: string; contradictoryHeader: boolean }>;
      catalogDirectory: () => string;
    };
    const root = join(await realpath(internals.catalogDirectory()), "topology");
    const parent = join(root, "parent.jsonl");
    const fork = join(root, "parent", "forks", "fork.jsonl");
    const fresh = join(root, "parent", "worker", "run-0", "session.jsonl");
    const interrupted = join(root, "parent", "reviewer", "run-1", "session.jsonl");
    const contradictory = join(root, "parent", "worker", "run-2", "session.jsonl");
    const extraDepthRun = join(root, "parent", "worker", "run-3", "extra", "session.jsonl");
    const extraDepthFork = join(root, "parent", "forks", "extra", "fork.jsonl");
    const wrongRunBasename = join(root, "parent", "worker", "run-4", "child.jsonl");
    const arbitraryDeep = join(root, "parent", "arbitrary", "deep", "session.jsonl");
    const topLevelParented = join(root, "ordinary-fork.jsonl");

    expect([...internals.delegatedSessionTopologies([
      { id: "parent", path: parent },
      { id: "fork", path: fork, parentSessionPath: parent },
      { id: "fresh", path: fresh },
      { id: "interrupted", path: interrupted },
      { id: "contradictory", path: contradictory, parentSessionPath: topLevelParented },
      { id: "extra-run", path: extraDepthRun },
      { id: "extra-fork", path: extraDepthFork, parentSessionPath: parent },
      { id: "wrong-basename", path: wrongRunBasename },
      { id: "deep", path: arbitraryDeep },
      { id: "ordinary", path: topLevelParented, parentSessionPath: parent },
    ])]).toEqual([
      [resolve(fork), { parentSessionId: "parent", contradictoryHeader: false }],
      [resolve(fresh), { contradictoryHeader: false }],
      [resolve(interrupted), { contradictoryHeader: false }],
      [resolve(contradictory), { contradictoryHeader: true }],
    ]);
  });

  it("does not infer delegated identity from names, titles, or generic depth", async () => {
    const nestedFixture = await coldFixture("nested-user", { nested: true });
    expect((await nestedFixture.registry.catalog("all")).sessions.find(
      (session) => session.id === nestedFixture.manager.getSessionId(),
    )?.kind).toBe("user");
    expect((await nestedFixture.registry.acquire(nestedFixture.manager.getSessionId())).id)
      .toBe(nestedFixture.manager.getSessionId());

    const namedFixture = await coldFixture("named-user", { name: "subagent-catalog-child" });
    expect((await namedFixture.registry.acquire(namedFixture.manager.getSessionId())).id)
      .toBe(namedFixture.manager.getSessionId());

    const renamedFixture = await coldFixture("renamed-user");
    const beforeRename = await renamedFixture.registry.catalog("all");
    renamedFixture.manager.appendSessionInfo("subagent-renamed-after-catalog");
    expect((await renamedFixture.registry.catalog("all")).listRevision).toBe(beforeRename.listRevision);
    expect((await renamedFixture.registry.acquire(renamedFixture.manager.getSessionId())).id)
      .toBe(renamedFixture.manager.getSessionId());
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

  it("does not follow a session path replaced by a symlink during delete", async () => {
    const fixture = await coldFixture("delete-symlink-race");
    await fixture.registry.catalog("all");
    const moved = `${fixture.sessionFile}.moved`;
    const external = join(fixture.root, "external.jsonl");
    const externalContent = `${JSON.stringify({
      type: "session", version: 3, id: fixture.manager.getSessionId(),
      timestamp: new Date().toISOString(), cwd: fixture.cwd,
    })}\n`;
    await writeFile(external, externalContent);
    const internals = fixture.registry as unknown as {
      catalogStructureEvidence: () => Promise<unknown>;
    };
    const original = internals.catalogStructureEvidence.bind(fixture.registry);
    let replaced = false;
    vi.spyOn(internals, "catalogStructureEvidence").mockImplementation(async () => {
      const evidence = await original();
      if (!replaced) {
        replaced = true;
        await rename(fixture.sessionFile, moved);
        await symlink(external, fixture.sessionFile);
      }
      return evidence;
    });

    await expect(fixture.registry.delete(fixture.manager.getSessionId())).rejects.toMatchObject({
      code: "busy", retryable: true,
    });
    expect(await readFile(external, "utf8")).toBe(externalContent);
    expect(existsSync(moved)).toBe(true);
  });

  it("revalidates parent creation, duplicate identity, and topology changes in the delete gap", async () => {
    for (const mutation of ["parent", "duplicate", "topology"] as const) {
      const fixture = await coldFixture(`delete-catalog-gap-${mutation}`);
      await fixture.registry.catalog("all");
      const mutationDirectory = join(fixture.agentDir, "sessions", `delete-gap-${mutation}`);
      const movedFile = join(mutationDirectory, "owner", "worker", "run-0", "session.jsonl");
      const internals = fixture.registry as unknown as {
        removeCanonicalCatalogFile: (...arguments_: any[]) => Promise<void>;
      };
      const original = internals.removeCanonicalCatalogFile.bind(fixture.registry);
      vi.spyOn(internals, "removeCanonicalCatalogFile").mockImplementation(async (...arguments_) => {
        await mkdir(mutationDirectory, { recursive: true });
        if (mutation === "parent") {
          await writeFile(join(mutationDirectory, "new-parent.jsonl"), `${JSON.stringify({
            type: "session", version: 3, id: "new-parent", timestamp: new Date().toISOString(), cwd: fixture.cwd,
          })}\n`);
        } else if (mutation === "duplicate") {
          await copyFile(fixture.sessionFile, join(mutationDirectory, "duplicate.jsonl"));
        } else {
          await mkdir(dirname(movedFile), { recursive: true });
          await rename(fixture.sessionFile, movedFile);
        }
        return original(...arguments_);
      });

      await expect(fixture.registry.delete(fixture.manager.getSessionId())).rejects.toMatchObject({
        code: "busy", retryable: true,
      });
      expect(existsSync(mutation === "topology" ? movedFile : fixture.sessionFile)).toBe(true);
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

  it("keeps a child mutation-protected when its parent ID is duplicated", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-duplicate-parent-"));
    const agentDir = join(root, "agent");
    const directory = join(agentDir, "sessions", "workspace");
    const duplicateDirectory = join(agentDir, "sessions", "duplicate-workspace");
    const cwd = join(root, "workspace");
    await Promise.all([
      mkdir(directory, { recursive: true }),
      mkdir(duplicateDirectory, { recursive: true }),
      mkdir(cwd),
    ]);
    const timestamp = new Date().toISOString();
    const parentId = "ambiguous-parent";
    const parentFile = join(directory, `${parentId}.jsonl`);
    const header = `${JSON.stringify({ type: "session", version: 3, id: parentId, timestamp, cwd })}\n`;
    await Promise.all([
      writeFile(parentFile, header),
      writeFile(join(duplicateDirectory, "duplicate.jsonl"), header),
    ]);
    const childDirectory = join(directory, parentId, "worker", "run-0");
    await mkdir(childDirectory, { recursive: true });
    const childId = "child-of-ambiguous-parent";
    await writeFile(join(childDirectory, "session.jsonl"), `${JSON.stringify({
      type: "session", version: 3, id: childId, timestamp, cwd,
    })}\n`);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);

    const all = await registry.catalog("all");
    expect(all.sessions.map((session) => session.id)).not.toContain(parentId);
    expect(all.sessions.find((session) => session.id === childId)).toMatchObject({ kind: "subagent" });
    await expect(registry.acquire(childId)).rejects.toMatchObject({ code: "conflict" });
    await expect(registry.delete(childId)).rejects.toMatchObject({ code: "conflict" });
  });

  it("omits a reserved child with a contradictory parent header without making it mutable", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-contradictory-header-"));
    const agentDir = join(root, "agent");
    const directory = join(agentDir, "sessions", "workspace");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(directory, { recursive: true }), mkdir(cwd)]);
    const timestamp = new Date().toISOString();
    const parentId = "expected-parent";
    const parentFile = join(directory, `${parentId}.jsonl`);
    const otherParentFile = join(directory, "other-parent.jsonl");
    await Promise.all([
      writeFile(parentFile, `${JSON.stringify({ type: "session", version: 3, id: parentId, timestamp, cwd })}\n`),
      writeFile(otherParentFile, `${JSON.stringify({
        type: "session", version: 3, id: "other-parent", timestamp, cwd,
      })}\n`),
    ]);
    const childDirectory = join(directory, parentId, "worker", "run-0");
    await mkdir(childDirectory, { recursive: true });
    const childId = "contradictory-child";
    const childFile = join(childDirectory, "session.jsonl");
    await writeFile(childFile, `${JSON.stringify({
      type: "session", version: 3, id: childId, timestamp, cwd, parentSession: otherParentFile,
    })}\n`);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);

    expect((await registry.catalog("all")).sessions.map((session) => session.id)).not.toContain(childId);
    const acquisition = await (registry as unknown as {
      catalogAcquisition: () => Promise<{
        entriesByID: ReadonlyMap<string, { structuralSubagent: boolean }>;
      }>;
    }).catalogAcquisition();
    expect(acquisition.entriesByID.get(childId)?.structuralSubagent).toBe(true);
    await expect(registry.acquire(childId)).rejects.toMatchObject({ code: "conflict" });
    await expect(registry.delete(childId)).rejects.toMatchObject({ code: "conflict" });
    expect(existsSync(childFile)).toBe(true);
  });

  it("keeps a reserved child delegated after its parent is deleted and ignores later title metadata", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-parent-deleted-"));
    const agentDir = join(root, "agent");
    const directory = join(agentDir, "sessions", "workspace");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(directory, { recursive: true }), mkdir(cwd)]);
    const timestamp = new Date().toISOString();
    const parentId = "deleted-parent";
    const parentFile = join(directory, `${parentId}.jsonl`);
    await writeFile(parentFile, `${JSON.stringify({
      type: "session", version: 3, id: parentId, timestamp, cwd,
    })}\n`);
    const childDirectory = join(directory, parentId, "worker", "run-0");
    await mkdir(childDirectory, { recursive: true });
    const childId = "interrupted-before-title";
    const childFile = join(childDirectory, "session.jsonl");
    await writeFile(childFile, `${JSON.stringify({
      type: "session", version: 3, id: childId, timestamp, cwd,
    })}\n`);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);

    expect((await registry.catalog("all")).sessions.find((session) => session.id === childId)?.kind)
      .toBe("subagent");
    await rm(parentFile);
    const withoutParent = await registry.catalog("all");
    expect(withoutParent.sessions.find((session) => session.id === childId)?.kind).toBe("subagent");
    await writeFile(childFile, `${await readFile(childFile, "utf8")}${JSON.stringify({
      type: "session_info", id: "late-title", parentId: null, timestamp,
      name: "ordinary title",
    })}\n`);
    const afterTitle = await registry.catalog("all");
    expect(afterTitle.listRevision).toBe(withoutParent.listRevision);
    expect(afterTitle.sessions.find((session) => session.id === childId)?.kind).toBe("subagent");
    await expect(registry.acquire(childId)).rejects.toMatchObject({ code: "conflict" });
    await expect(registry.delete(childId)).rejects.toMatchObject({ code: "conflict" });
  });

  it("classifies a 1,541-file catalog using positive topology only", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-topology-scale-"));
    const agentDir = join(root, "agent");
    const directory = join(agentDir, "sessions", "workspace");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(directory, { recursive: true }), mkdir(cwd)]);
    const timestamp = new Date().toISOString();
    const parentId = "scale-parent";
    const parentFile = join(directory, `${parentId}.jsonl`);
    const incidentId = "incident-top-level-parented";
    await Promise.all([
      writeFile(parentFile, `${JSON.stringify({ type: "session", version: 3, id: parentId, timestamp, cwd })}\n`),
      writeFile(join(directory, `${incidentId}.jsonl`), `${JSON.stringify({
        type: "session", version: 3, id: incidentId, timestamp, cwd, parentSession: parentFile,
      })}\n`),
      ...Array.from({ length: 1_538 }, (_, index) => writeFile(
        join(directory, `ordinary-${String(index).padStart(4, "0")}.jsonl`),
        `${JSON.stringify({ type: "session", version: 3, id: `ordinary-${index}`, timestamp, cwd })}\n`,
      )),
    ]);
    const childDirectory = join(directory, parentId, "worker", "run-0");
    await mkdir(childDirectory, { recursive: true });
    const childId = "scale-interrupted-child";
    await writeFile(join(childDirectory, "session.jsonl"), `${JSON.stringify({
      type: "session", version: 3, id: childId, timestamp, cwd,
    })}\n`);
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);

    const all = await registry.catalog("all");
    expect(all.sessions).toHaveLength(1_541);
    expect(all.sessions.find((session) => session.id === childId)?.kind).toBe("subagent");
    expect(all.sessions.find((session) => session.id === incidentId)?.kind).toBe("user");
    expect((await registry.list("user")).map((session) => session.id)).not.toContain(childId);
  }, 30_000);

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

  it("orders history by parsed recency while active heartbeats keep stable positions", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-catalog-time-precision-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const sessionDirectory = join(agentDir, "sessions", "workspace");
    await Promise.all([mkdir(sessionDirectory, { recursive: true }), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const whole = SessionManager.create(cwd, sessionDirectory);
    whole.appendMessage(fauxAssistantMessage("whole"));
    const fraction = SessionManager.create(cwd, sessionDirectory);
    fraction.appendMessage(fauxAssistantMessage("fraction"));
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const internals = registry as unknown as {
      latestSummaries: Map<string, SessionSummaryUpdate>;
      publishRevisionedSummary: (summary: SessionSummaryUpdate) => void;
    };
    const summary = (sessionId: string, updatedAt: string): SessionSummaryUpdate => ({
      sessionId,
      summaryRevision: 1,
      phase: "idle",
      updatedAt,
      messageCount: 1,
      firstMessage: "",
      completionRevision: 0,
      attentionRevision: 0,
      isUnread: false,
    });
    internals.latestSummaries.set(whole.getSessionId(), summary(whole.getSessionId(), "2026-01-01T00:00:00Z"));
    internals.latestSummaries.set(fraction.getSessionId(), summary(fraction.getSessionId(), "2026-01-01T00:00:00.900Z"));

    const catalog = await registry.catalog("user");
    expect(catalog.sessions.map((session) => session.id).slice(0, 2)).toEqual([
      fraction.getSessionId(),
      whole.getSessionId(),
    ]);

    internals.publishRevisionedSummary({
      ...summary(whole.getSessionId(), "2026-01-01T00:10:00Z"),
      phase: "running",
      activeSince: "2026-01-01T00:02:00Z",
    });
    internals.publishRevisionedSummary({
      ...summary(fraction.getSessionId(), "2026-01-01T00:20:00Z"),
      phase: "running",
      activeSince: "2026-01-01T00:01:00Z",
    });
    const activeCatalog = await registry.catalog("user");
    expect(activeCatalog.sessions.map((session) => session.id).slice(0, 2)).toEqual([
      whole.getSessionId(),
      fraction.getSessionId(),
    ]);

    internals.publishRevisionedSummary({
      ...summary(fraction.getSessionId(), "2026-01-01T00:30:00Z"),
      phase: "running",
      activeSince: "2026-01-01T00:01:00Z",
    });
    const heartbeatCatalog = await registry.catalog("user");
    expect(heartbeatCatalog.sessions.map((session) => session.id).slice(0, 2)).toEqual([
      whole.getSessionId(),
      fraction.getSessionId(),
    ]);
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
      path: join(agentDir, "sessions", "duplicate", `${slot.id}.jsonl`),
    };
    await mkdir(dirname(duplicate.path), { recursive: true });
    await copyFile(slot.persistedSessionFile!, duplicate.path);
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
    // Both runtime acquisition and deletion fail closed against the current
    // canonical duplicate rather than trusting a stale projected row.
    await expect(registry.acquire(slot.id)).rejects.toMatchObject({ code: "conflict" });
    await expect(registry.delete(slot.id)).rejects.toMatchObject({ code: "conflict" });
    await rm(duplicate.path);

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
    const summaryUpdates: SessionSummaryUpdate[] = [];
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
    const beforeHeartbeat = summaryUpdates.findLast((update) => update.sessionId === first.id)!;
    expect(beforeHeartbeat.activeSince).toBeDefined();
    await new Promise((resolve) => setTimeout(resolve, 2));
    (first as unknown as { publishActivityHeartbeat: () => void }).publishActivityHeartbeat();
    const afterHeartbeat = summaryUpdates.findLast((update) => update.sessionId === first.id)!;
    expect(Date.parse(afterHeartbeat.updatedAt)).toBeGreaterThan(Date.parse(beforeHeartbeat.updatedAt));
    expect(afterHeartbeat.activeSince).toBe(beforeHeartbeat.activeSince);

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
    expect(summaryUpdates.filter((update) => update.phase === "idle").every(
      (update) => update.activeSince === undefined,
    )).toBe(true);
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

  it("publishes detached extension work as current dashboard activity", async () => {
    const fixture = await coldFixture("detached-dashboard-activity");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const beforeActivity = await fixture.registry.catalog("user");
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      upsertExtensionActivity: (activity: ExtensionRunActivity) => unknown;
      publishExtensionActivity: (activity: ExtensionRunActivity) => void;
      publishActivityHeartbeat: () => void;
    };
    const startedAt = new Date(Date.now() - 2_000).toISOString();
    const running: ExtensionRunActivity = {
      id: "async-tool",
      activityId: "async-activity",
      runId: "async-run",
      toolCallId: "async-tool",
      source: { source: "pi-subagents" },
      title: "Pi Subagents",
      mode: "asynchronous",
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
    };
    internal.extensionActivities.set(running.toolCallId, running);
    internal.upsertExtensionActivity(running);
    internal.publishExtensionActivity(running);

    const active = fixture.summaries.at(-1)!;
    expect(active).toMatchObject({ sessionId: slot.id, phase: "running" });
    expect(active.activeSince).toBeDefined();
    expect(Date.parse(active.updatedAt)).toBeGreaterThan(Date.parse(startedAt));
    await new Promise((resolve) => setTimeout(resolve, 2));
    internal.publishActivityHeartbeat();
    const heartbeat = fixture.summaries.at(-1)!;
    expect(Date.parse(heartbeat.updatedAt)).toBeGreaterThan(Date.parse(active.updatedAt));
    expect(heartbeat.activeSince).toBe(active.activeSince);
    const activeCatalog = await fixture.registry.catalog("user");
    expect(activeCatalog.listRevision).toBe(beforeActivity.listRevision);
    expect(activeCatalog.sessions[0]).toMatchObject({
      id: slot.id,
      phase: "running",
      updatedAt: heartbeat.updatedAt,
      activeSince: active.activeSince,
    });

    const terminalAt = new Date().toISOString();
    const completed: ExtensionRunActivity = {
      ...running,
      status: "completed",
      updatedAt: terminalAt,
      completedAt: terminalAt,
      lifecycle: {
        version: 1,
        state: "completed",
        attention: "none",
        sequence: 2,
        observedAt: terminalAt,
        terminalAt,
        recentUntil: new Date(Date.parse(terminalAt) + 900_000).toISOString(),
      },
    };
    internal.extensionActivities.set(completed.toolCallId, completed);
    internal.upsertExtensionActivity(completed);
    internal.publishExtensionActivity(completed);
    expect(fixture.summaries.at(-1)).toMatchObject({ sessionId: slot.id, phase: "idle" });
    expect(fixture.summaries.at(-1)!.activeSince).toBeUndefined();
    expect(Date.parse(fixture.summaries.at(-1)!.updatedAt))
      .toBeGreaterThanOrEqual(Date.parse(heartbeat.updatedAt));
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

  it("admits exact pi-subagents foreground progress beside asynchronous work and settles it independently", async () => {
    const fixture = await coldFixture("foreground-subagent-progress");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const owner = { id: "extension:pi-subagents", title: "Subagents", source: "project" };
    const origin: ExtensionToolOrigin = { source: "project", owner };
    const internal = slot as unknown as {
      subagentExtensionOrigin: () => ExtensionToolOrigin;
      updateExtensionActivity: (
        toolCallId: string, toolName: string, origin: ExtensionToolOrigin,
        status: "running" | "completed" | "failed", startedAt: string,
        updatedAt: string, value: unknown, completedAt?: string, durationMs?: number,
      ) => ExtensionRunActivity | undefined;
      syncSubagentProcesses: (activity: ExtensionRunActivity) => void;
    };
    vi.spyOn(internal, "subagentExtensionOrigin").mockReturnValue(origin);
    const startedAt = new Date(Date.now() - 1_000).toISOString();
    const runningAt = new Date().toISOString();
    const progress = {
      details: {
        mode: "single",
        results: [{
          index: 0, agent: "reviewer", task: "Review",
          progress: { index: 0, agent: "reviewer", status: "running", currentTool: "read", toolCount: 2, durationMs: 1_000 },
        }],
        progress: [{ index: 0, agent: "reviewer", status: "running", currentTool: "read", toolCount: 2, durationMs: 1_000 }],
      },
    };

    expect(internal.updateExtensionActivity(
      "sync-tool", "subagent", origin, "running", startedAt, runningAt, progress, undefined, 1_000,
    )).toMatchObject({ toolCallId: "sync-tool", status: "running" });
    expect(slot.snapshot().processActivities).toEqual([expect.objectContaining({
      executionMode: "synchronous",
      title: "reviewer",
      visibility: "active",
      currentTool: "read",
      lifecycle: expect.objectContaining({ state: "running" }),
    })]);

    internal.syncSubagentProcesses({
      id: "async-tool", activityId: "async-activity", runId: "async-root", toolCallId: "async-tool",
      source: origin, title: "Subagent", mode: "asynchronous", status: "running", startedAt, updatedAt: runningAt,
      children: [{
        id: "async-child", producerId: "async-child", label: "worker",
        status: "running", lifecycle: "running", currentTool: "bash",
      }],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: runningAt },
    });
    expect(slot.snapshot().processActivities).toEqual(expect.arrayContaining([
      expect.objectContaining({ executionMode: "synchronous", title: "reviewer", visibility: "active" }),
      expect.objectContaining({ executionMode: "asynchronous", title: "worker", visibility: "active" }),
    ]));

    const unrelatedOwner: ExtensionToolOrigin = {
      source: "project",
      owner: { id: "extension:other", title: "Other", source: "project" },
    };
    expect(internal.updateExtensionActivity(
      "other-tool", "subagent", unrelatedOwner, "running", startedAt, runningAt, progress,
    )).toBeUndefined();

    const completedAt = new Date().toISOString();
    const terminal = {
      details: {
        mode: "single",
        runId: "sync-root",
        results: [{
          index: 0, agent: "reviewer", task: "Review", exitCode: 0, finalOutput: "Complete",
          progress: { index: 0, agent: "reviewer", status: "completed", toolCount: 3, durationMs: 1_200 },
        }],
      },
    };
    expect(internal.updateExtensionActivity(
      "sync-tool", "subagent", origin, "completed", startedAt, completedAt, terminal, completedAt, 1_200,
    )).toMatchObject({ toolCallId: "sync-tool", status: "completed", runId: "sync-root" });
    expect(slot.snapshot().processActivities).toEqual(expect.arrayContaining([
      expect.objectContaining({
        executionMode: "synchronous", title: "reviewer", visibility: "recent",
        lifecycle: expect.objectContaining({ state: "completed" }),
      }),
      expect.objectContaining({
        executionMode: "asynchronous", title: "worker", visibility: "active",
        lifecycle: expect.objectContaining({ state: "running" }),
      }),
    ]));
  });

  it("keeps process overview active while an async workflow child awaits producer identity", async () => {
    const fixture = await coldFixture("async-workflow-root-visibility");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      syncSubagentProcesses: (activity: ExtensionRunActivity) => void;
      publishProcessesForToolCall: (toolCallId: string) => void;
    };
    const startedAt = new Date(Date.now() - 1_000).toISOString();
    const runningAt = new Date().toISOString();
    const base = {
      id: "async-tool", activityId: "async-activity", runId: "workflow-run", toolCallId: "async-tool",
      source: { source: "pi-subagents" }, title: "Pi Subagents", mode: "asynchronous",
      startedAt, updatedAt: runningAt,
    } satisfies Partial<ExtensionRunActivity>;
    internal.syncSubagentProcesses({
      ...base,
      status: "running",
      children: [{ id: "single-async", label: "worker", status: "running", lifecycle: "running" }],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: runningAt },
    } as ExtensionRunActivity);
    internal.publishProcessesForToolCall("async-tool");
    expect(slot.snapshot()).toMatchObject({
      processOverview: { visibility: "active", activeCount: 1, recentCount: 0 },
      processActivities: [expect.objectContaining({
        title: "Subagent", runId: "workflow-run", visibility: "active", childCount: 1,
      })],
    });

    fixture.events.splice(0);
    const completedAt = new Date().toISOString();
    const terminalLifecycle = {
      version: 1 as const, state: "completed" as const, attention: "none" as const, sequence: 2,
      observedAt: completedAt, terminalAt: completedAt,
      recentUntil: new Date(Date.parse(completedAt) + 900_000).toISOString(),
    };
    internal.syncSubagentProcesses({
      ...base,
      status: "completed",
      completedAt,
      children: [{ id: "single-async", label: "worker", status: "completed", lifecycle: "completed" }],
      lifecycle: terminalLifecycle,
    } as ExtensionRunActivity);
    internal.publishProcessesForToolCall("async-tool");
    const terminalRoot = slot.snapshot().processActivities?.[0];
    expect(slot.snapshot()).toMatchObject({
      processOverview: { visibility: "recent", activeCount: 0, recentCount: 1 },
      processActivities: [expect.objectContaining({ title: "Subagent", visibility: "recent" })],
    });
    expect(fixture.events.find((event) => event.topic === "session.processActivity")?.payload.data)
      .not.toHaveProperty("removedProcessIds");

    // A later terminal enrichment with exact child identity replaces the root
    // atomically rather than retaining a duplicate recent workflow row.
    fixture.events.splice(0);
    internal.syncSubagentProcesses({
      ...base,
      status: "completed",
      completedAt,
      children: [{
        id: "child-run", producerId: "child-run", label: "worker",
        status: "completed", lifecycle: "completed", childSessionRef: "child-session",
      }],
      lifecycle: { ...terminalLifecycle, sequence: 3 },
    } as ExtensionRunActivity);
    internal.publishProcessesForToolCall("async-tool");
    expect(slot.snapshot()).toMatchObject({
      processOverview: { visibility: "recent", activeCount: 0, recentCount: 1 },
      processActivities: [expect.objectContaining({ title: "worker", visibility: "recent" })],
    });
    expect(slot.snapshot().processActivities?.[0]?.processId).not.toBe(terminalRoot?.processId);
    expect(fixture.events.find((event) => event.topic === "session.processActivity")?.payload.data)
      .toMatchObject({ removedProcessIds: [terminalRoot?.processId] });
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
      // The artifact itself is authoritative running evidence even before a
      // workflow publishes its first child step.
      steps: [],
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
      runId,
      executionMode: "asynchronous",
      visibility: "active",
    });
    expect(slot.snapshot().processOverview).toMatchObject({ visibility: "active", activeCount: 1 });
  });

  it("retries a live child binding when the canonical session appears after status publication", async () => {
    const fixture = await coldFixture("delayed-live-child-session");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const rootRunId = "delayed-workflow-root";
    const childRunId = "delayed-workflow-child";
    const toolCallId = "delayed-workflow-tool";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", rootRunId);
    const parentFile = slot.sessionFile!;
    const childDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), childRunId, "run-0");
    const childFile = join(childDirectory, "session.jsonl");
    await Promise.all([mkdir(asyncDir, { recursive: true }), mkdir(childDirectory, { recursive: true })]);
    const started = Date.now() - 1_000;
    const startedAt = new Date(started).toISOString();
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3,
      runId: rootRunId,
      state: "running",
      startedAt: started,
      lastUpdate: started + 500,
      mode: "workflow",
      steps: [{
        workflowKey: "delayed-child",
        runId: childRunId,
        agent: "worker",
        status: "running",
        sessionFile: childFile,
      }],
    }));
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
      startExtensionActivityWatcher: (toolCallId: string, asyncDir: string) => void;
    };
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId, activityId: "delayed-workflow-activity", runId: rootRunId, toolCallId,
      source: { source: "pi-subagents" }, title: "Subagents", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    internal.extensionRunOwnership.set(rootRunId, { toolCallId, asyncDir, terminal: false });
    internal.startExtensionActivityWatcher(toolCallId, asyncDir);
    await waitUntil(() => slot.snapshot().processActivities?.some((activity) =>
      activity.kind === "subagent" && activity.childSessionRef === undefined) === true);

    const childManager = SessionManager.create(fixture.cwd, childDirectory, { id: "delayed-child-session" });
    childManager.appendMessage(fauxAssistantMessage("published after artifact status"));
    await rename(childManager.getSessionFile()!, childFile);

    await waitUntil(() => slot.snapshot().processActivities?.some((activity) =>
      activity.kind === "subagent" && activity.childSessionRef === "delayed-child-session") === true);
    const process = slot.snapshot().processActivities?.find((activity) => activity.kind === "subagent");
    expect(process).toMatchObject({ childSessionRef: "delayed-child-session", visibility: "active" });
    expect(slot.processChildSessionBinding(process!.processId)).toMatchObject({
      ref: "delayed-child-session",
      producerId: "delayed-child",
      sessionOwnerId: childRunId,
      runId: rootRunId,
    });
  });

  it("admits the exact fresh child path for read-only process viewing", async () => {
    const fixture = await coldFixture("validated-child-session");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = "validated-child-run";
    const toolCallId = "validated-child-tool";
    const activityId = "validated-child-activity";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    const parentFile = slot.sessionFile!;
    const childProducerId = "step:0";
    const childDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), runId, "run-0");
    await Promise.all([mkdir(asyncDir, { recursive: true }), mkdir(childDirectory, { recursive: true })]);
    // Match the current producer: the root run reserves the fresh session
    // directory while the stable artifact step owns the child process row.
    const childManager = SessionManager.create(fixture.cwd, childDirectory, {
      id: "validated-child-session",
    });
    childManager.appendMessage(fauxAssistantMessage("child transcript"));
    const generatedChildFile = childManager.getSessionFile()!;
    const childFile = join(childDirectory, "session.jsonl");
    await rename(generatedChildFile, childFile);
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

    // Ownership reads only the immutable session header, so an in-progress
    // canonical append cannot transiently become an identity change. Page
    // projection still waits for that JSONL entry's terminating newline.
    const existingLines = (await readFile(childFile, "utf8")).trimEnd().split("\n");
    const parentId = (JSON.parse(existingLines.at(-1)!) as { id: string }).id;
    const appendedEntry = JSON.stringify({
      type: "message",
      id: "live-child-append",
      parentId,
      timestamp: new Date().toISOString(),
      message: fauxAssistantMessage("live appended transcript"),
    });
    await appendFile(childFile, appendedEntry);
    await expect(fixture.registry.resolveReadOnlySubagentPath(
      "validated-child-session", admission.path, slot.id, process!.processId, runId,
    )).resolves.toMatchObject({ path: admission.path, fileIdentity: admission.fileIdentity });
    await expect(fixture.registry.readOnlySubagentTranscriptPage(
      "validated-child-session", admission.path, slot.id, process!.processId, runId,
      undefined, undefined, admission.fileIdentity,
    )).rejects.toMatchObject({ code: "busy", retryable: true });
    await appendFile(childFile, "\n");
    await expect(fixture.registry.readOnlySubagentTranscriptPage(
      "validated-child-session", admission.path, slot.id, process!.processId, runId,
      undefined, undefined, admission.fileIdentity,
    )).resolves.toMatchObject({ fileIdentity: admission.fileIdentity });

    await expect(fixture.registry.resolveReadOnlySubagentPath(
      "validated-child-session", admission.path, slot.id, "wrong-process", runId,
    )).rejects.toMatchObject({ code: "not_found" });
    await waitUntil(() => slot.processHistory(undefined, 25, { kind: "subagent" }).activities.length === 1);
    expect(slot.processHistory(undefined, 25, { kind: "subagent" }).activities[0])
      .toMatchObject({ childSessionRef: "validated-child-session" });
    // Historical opening must derive its exact binding from the canonical
    // receipt rather than an unbounded runtime cache.
    (slot as unknown as { childSessionBindings: Map<string, unknown> }).childSessionBindings.clear();
    expect(slot.processChildSessionBinding(process!.processId)).toMatchObject({
      ref: "validated-child-session", producerId: childProducerId, sessionOwnerId: runId, runId,
    });

    const replacement = `${childFile}.replacement`;
    await writeFile(replacement, await readFile(childFile));
    await rm(childFile);
    await rename(replacement, childFile);
    await expect(fixture.registry.readOnlySubagentTranscriptPage(
      "validated-child-session", admission.path, slot.id, process!.processId, runId,
      undefined, undefined, admission.fileIdentity,
    )).rejects.toMatchObject({ code: "conflict", retryable: true });
  });

  it("binds a live async single child through its exact recovery root owner", async () => {
    const fixture = await coldFixture("validated-async-single-recovery-owner");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const parentFile = slot.sessionFile!;
    const asyncRunId = "async-single-run";
    const rootRunId = "parent-root-run";
    const toolCallId = "async-single-tool";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", asyncRunId);
    const childDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), rootRunId, "run-0");
    await Promise.all([mkdir(asyncDir, { recursive: true }), mkdir(childDirectory, { recursive: true })]);
    const childManager = SessionManager.create(fixture.cwd, childDirectory, { id: "async-single-child-session" });
    childManager.appendMessage(fauxAssistantMessage("live async single transcript"));
    const childFile = join(childDirectory, "session.jsonl");
    await rename(childManager.getSessionFile()!, childFile);
    const started = Date.now() - 1_000;
    const startedAt = new Date(started).toISOString();
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
      refreshExtensionActivityFromArtifact: (toolCallId: string, asyncDir: string) => Promise<void>;
    };
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId, activityId: "async-single-activity", runId: asyncRunId, toolCallId,
      source: { source: "pi-subagents" }, title: "Subagents", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    internal.extensionRunOwnership.set(asyncRunId, { toolCallId, asyncDir, terminal: false });
    const statusPath = join(asyncDir, "status.json");
    const descriptorPath = join(asyncDir, "recovery-descriptor.json");
    await writeFile(statusPath, JSON.stringify({
      lifecycleArtifactVersion: 3,
      runId: asyncRunId,
      state: "running",
      startedAt: started,
      lastUpdate: started + 500,
      mode: "single",
      // A raw status field cannot nominate the fresh path owner; only the
      // matching private descriptor may produce Gateway-attested evidence.
      steps: [{ agent: "worker", status: "running", sessionFile: childFile, sessionOwnerId: rootRunId }],
    }));
    await writeFile(descriptorPath, JSON.stringify({
      version: 1,
      sourceRunId: "foreign-async-run",
      sessionFile: childFile,
      runFanoutBudget: { version: 1, rootRunId, directory: "/private/opaque", limit: 64 },
    }));

    await internal.refreshExtensionActivityFromArtifact(toolCallId, asyncDir);
    const unbound = slot.snapshot().processActivities?.find((activity) => activity.kind === "subagent");
    expect(unbound).toMatchObject({ source: "delegatedAgent", visibility: "active" });
    expect(unbound).not.toHaveProperty("childSessionRef");
    expect(slot.processChildSessionBinding(unbound!.processId)).toBeUndefined();

    // The descriptor is private producer evidence: its exact source run,
    // session file, and fan-out root must agree before the path owner is used.
    await writeFile(descriptorPath, JSON.stringify({
      version: 1,
      sourceRunId: asyncRunId,
      sessionFile: childFile,
      runFanoutBudget: { version: 1, rootRunId, directory: "/private/opaque", limit: 64 },
    }));
    await writeFile(statusPath, JSON.stringify({
      lifecycleArtifactVersion: 3,
      runId: asyncRunId,
      state: "running",
      startedAt: started,
      lastUpdate: started + 700,
      mode: "single",
      steps: [{ agent: "worker", status: "running", sessionFile: childFile }],
    }));
    await internal.refreshExtensionActivityFromArtifact(toolCallId, asyncDir);

    const bound = slot.snapshot().processActivities?.find((activity) => activity.kind === "subagent");
    expect(bound).toMatchObject({
      processId: unbound!.processId,
      childSessionRef: "async-single-child-session",
      visibility: "active",
    });
    expect(slot.processChildSessionBinding(bound!.processId)).toMatchObject({
      ref: "async-single-child-session",
      producerId: "step:0",
      sessionOwnerId: rootRunId,
      runId: asyncRunId,
    });
    expect((await fixture.registry.readOnlySubagentTranscriptPage(
      "async-single-child-session", await realpath(childFile), slot.id, bound!.processId, asyncRunId,
    )).total).toBeGreaterThan(0);
  });

  it("separates a workflow producer identity from its fresh child-run path owner", async () => {
    const fixture = await coldFixture("validated-workflow-child-owner");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const parentFile = slot.sessionFile!;
    const rootRunId = "workflow-root";
    const childRunId = "workflow-child-run";
    const producerId = "workflow-key";
    const childDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), childRunId, "run-0");
    await mkdir(childDirectory, { recursive: true });
    const childManager = SessionManager.create(fixture.cwd, childDirectory, { id: "workflow-child-session" });
    childManager.appendMessage(fauxAssistantMessage("workflow child transcript"));
    const childFile = join(childDirectory, "session.jsonl");
    await rename(childManager.getSessionFile()!, childFile);
    const startedAt = new Date(Date.now() - 1_000).toISOString();
    const activity: ExtensionRunActivity = {
      id: "workflow-tool", activityId: "workflow-activity", runId: rootRunId, toolCallId: "workflow-tool",
      source: { source: "pi-subagents" }, title: "Subagents", mode: "workflow", status: "running",
      startedAt, updatedAt: startedAt,
      children: [{ id: producerId, producerId, label: "worker", status: "running", lifecycle: "running" }],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    };
    const internal = slot as unknown as {
      attachChildSessionReferences: (activity: ExtensionRunActivity, value: unknown, strategy: "piArtifact") => ExtensionRunActivity;
      syncSubagentProcesses: (activity: ExtensionRunActivity) => void;
    };
    const attached = internal.attachChildSessionReferences(activity, {
      runId: rootRunId,
      steps: [{ workflowKey: producerId, runId: childRunId, agent: "worker", status: "running", sessionFile: childFile }],
    }, "piArtifact");
    internal.syncSubagentProcesses(attached);
    const process = slot.snapshot().processActivities?.find((candidate) => candidate.kind === "subagent");
    expect(process).toMatchObject({ childSessionRef: "workflow-child-session" });
    expect(slot.processChildSessionBinding(process!.processId)).toMatchObject({
      ref: "workflow-child-session", producerId, sessionOwnerId: childRunId, runId: rootRunId,
    });
    expect((await fixture.registry.readOnlySubagentTranscriptPage(
      "workflow-child-session", await realpath(childFile), slot.id, process!.processId, rootRunId,
    )).total).toBeGreaterThan(0);
  });

  it("fails closed when one child session ref has conflicting process producers", async () => {
    const fixture = await coldFixture("ambiguous-child-producers");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const startedAt = new Date(Date.now() - 1_000).toISOString();
    const activity: ExtensionRunActivity = {
      id: "ambiguous-tool", activityId: "ambiguous-activity", runId: "ambiguous-run", toolCallId: "ambiguous-tool",
      source: { source: "pi-subagents" }, title: "Subagents", mode: "workflow", status: "running",
      startedAt, updatedAt: startedAt,
      children: ["first", "second"].map((producerId) => ({
        id: producerId, producerId, label: producerId, status: "running" as const,
        lifecycle: "running" as const, childSessionRef: "same-child-session",
      })),
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    };
    const internal = slot as unknown as { syncSubagentProcesses: (activity: ExtensionRunActivity) => void };
    internal.syncSubagentProcesses(activity);
    const processes = slot.snapshot().processActivities?.filter((candidate) => candidate.kind === "subagent") ?? [];
    expect(processes).toHaveLength(2);
    expect(processes.every((process) => slot.processChildSessionBinding(process.processId) === undefined)).toBe(true);
  });

  it("admits a fork-context transcript only from its artifact child identity and mounted parent", async () => {
    const fixture = await coldFixture("validated-fork-context");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const parentFile = slot.sessionFile!;
    const forksDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "forks");
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", "fork-run");
    await Promise.all([mkdir(forksDirectory, { recursive: true }), mkdir(asyncDir, { recursive: true })]);
    const fork = SessionManager.forkFrom(parentFile, fixture.cwd, forksDirectory);
    fork.appendMessage(fauxAssistantMessage("fork transcript"));
    const forkFile = fork.getSessionFile()!;
    const artifactChildId = "artifact-fork-child";
    const startedAt = new Date(Date.now() - 1_000).toISOString();
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
      refreshExtensionActivityFromArtifact: (toolCallId: string, asyncDir: string) => Promise<void>;
    };
    internal.extensionActivities.set("fork-tool", {
      id: "fork-tool", activityId: "fork-activity", runId: "fork-run", toolCallId: "fork-tool",
      source: { source: "pi-subagents" }, title: "Subagents", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    internal.extensionRunOwnership.set("fork-run", { toolCallId: "fork-tool", asyncDir, terminal: false });
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      runId: "fork-run", state: "running", startedAt: Date.parse(startedAt), lastUpdate: Date.now(),
      mode: "workflow",
      steps: [{ runId: artifactChildId, agent: "filename-must-not-bind", status: "running", sessionFile: forkFile }],
    }));

    await internal.refreshExtensionActivityFromArtifact("fork-tool", asyncDir);
    const process = slot.snapshot().processActivities?.find((activity) => activity.kind === "subagent");
    expect(process).toMatchObject({ childSessionRef: fork.getSessionId() });
    expect(slot.processChildSessionPath(process!.processId)).toEqual({
      ref: fork.getSessionId(), producerId: artifactChildId, runId: "fork-run", path: await realpath(forkFile),
    });
    const admission = await fixture.registry.resolveReadOnlySubagentPath(
      fork.getSessionId(), await realpath(forkFile), slot.id, process!.processId, "fork-run",
    );
    expect((await fixture.registry.readOnlySubagentTranscriptPage(
      fork.getSessionId(), admission.path, slot.id, process!.processId, "fork-run",
    )).total).toBeGreaterThan(0);
  });

  it("binds the canonical single-run fork step before and after terminal persistence", async () => {
    const fixture = await coldFixture("validated-single-fork-context");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const parentFile = slot.sessionFile!;
    const forksDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "forks");
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", "single-run");
    await Promise.all([mkdir(forksDirectory, { recursive: true }), mkdir(asyncDir, { recursive: true })]);
    const fork = SessionManager.forkFrom(parentFile, fixture.cwd, forksDirectory);
    fork.appendMessage(fauxAssistantMessage("single fork transcript"));
    const forkFile = fork.getSessionFile()!;
    const started = Date.now() - 1_000;
    const startedAt = new Date(started).toISOString();
    const internal = slot as unknown as {
      extensionActivities: Map<string, ExtensionRunActivity>;
      extensionRunOwnership: Map<string, { toolCallId: string; asyncDir?: string; terminal: boolean }>;
      refreshExtensionActivityFromArtifact: (toolCallId: string, asyncDir: string) => Promise<void>;
    };
    internal.extensionActivities.set("single-tool", {
      id: "single-tool", activityId: "single-activity", runId: "single-run", toolCallId: "single-tool",
      source: { source: "pi-subagents" }, title: "Subagents", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    internal.extensionRunOwnership.set("single-run", { toolCallId: "single-tool", asyncDir, terminal: false });
    const statusPath = join(asyncDir, "status.json");
    await writeFile(statusPath, JSON.stringify({
      runId: "single-run", state: "running", startedAt: started, lastUpdate: started + 500,
      mode: "single",
      steps: [{ agent: "worker", status: "running", sessionFile: forkFile }],
    }));

    await internal.refreshExtensionActivityFromArtifact("single-tool", asyncDir);
    const active = slot.snapshot().processActivities?.find((activity) => activity.kind === "subagent");
    expect(active).toMatchObject({ source: "delegatedAgent", childSessionRef: fork.getSessionId(), visibility: "active" });
    expect(slot.processChildSessionPath(active!.processId)).toEqual({
      ref: fork.getSessionId(), producerId: "step:0", runId: "single-run", path: await realpath(forkFile),
    });

    await writeFile(statusPath, JSON.stringify({
      runId: "single-run", state: "complete", startedAt: started, endedAt: started + 700, lastUpdate: started + 800,
      mode: "single",
      steps: [{ agent: "worker", status: "complete", sessionFile: forkFile }],
    }));
    await internal.refreshExtensionActivityFromArtifact("single-tool", asyncDir);
    const recent = slot.snapshot().processActivities?.find((activity) => activity.kind === "subagent");
    expect(recent).toMatchObject({
      processId: active!.processId,
      source: "delegatedAgent",
      childSessionRef: fork.getSessionId(),
      visibility: "recent",
      lifecycle: { state: "completed" },
    });
    expect((await fixture.registry.readOnlySubagentTranscriptPage(
      fork.getSessionId(), (await realpath(forkFile)), slot.id, recent!.processId, "single-run",
    )).total).toBeGreaterThan(0);
  });

  it("rejects wrong-parent, unbound, and extra-depth fork or fresh child paths", async () => {
    const fixture = await coldFixture("rejected-child-shapes");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const parentFile = slot.sessionFile!;
    const childRoot = join(dirname(parentFile), basename(parentFile, ".jsonl"));
    const forksDirectory = join(childRoot, "forks");
    const otherParent = SessionManager.create(fixture.cwd, dirname(parentFile), { id: "other-fork-parent" });
    otherParent.appendMessage(fauxAssistantMessage("other parent"));
    await mkdir(forksDirectory, { recursive: true });
    const wrongParentFork = SessionManager.forkFrom(otherParent.getSessionFile()!, fixture.cwd, forksDirectory);
    wrongParentFork.appendMessage(fauxAssistantMessage("wrong parent fork"));
    const validParentFork = SessionManager.forkFrom(parentFile, fixture.cwd, forksDirectory);
    validParentFork.appendMessage(fauxAssistantMessage("unbound fork"));
    const extraForkDirectory = join(forksDirectory, "extra");
    await mkdir(extraForkDirectory, { recursive: true });
    const extraDepthFork = SessionManager.forkFrom(parentFile, fixture.cwd, extraForkDirectory);
    extraDepthFork.appendMessage(fauxAssistantMessage("extra fork"));
    const extraRunDirectory = join(childRoot, "fresh-child", "run-0", "extra");
    await mkdir(extraRunDirectory, { recursive: true });
    const extraDepthRun = SessionManager.create(fixture.cwd, extraRunDirectory, {
      id: "extra-depth-run", parentSession: parentFile,
    });
    extraDepthRun.appendMessage(fauxAssistantMessage("extra run"));
    const extraDepthRunFile = join(extraRunDirectory, "session.jsonl");
    await rename(extraDepthRun.getSessionFile()!, extraDepthRunFile);
    const startedAt = new Date().toISOString();
    const activity: ExtensionRunActivity = {
      id: "tool", activityId: "activity", runId: "expected-run", toolCallId: "tool",
      source: { source: "pi-subagents" }, title: "Subagents", status: "running",
      startedAt, updatedAt: startedAt,
      children: [{ id: "artifact-child", label: "worker", status: "running" }],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    };
    const attach = (slot as unknown as {
      attachChildSessionReferences: (activity: ExtensionRunActivity, value: unknown) => ExtensionRunActivity;
    }).attachChildSessionReferences.bind(slot);
    const child = (sessionFile: string, producerId = "artifact-child", includeProducer = true) => attach({
      ...activity, children: [{ id: producerId, label: "worker", status: "running" }],
    }, {
      runId: "expected-run",
      results: [{ ...(includeProducer ? { runId: producerId } : {}), agent: producerId, sessionFile }],
    }).children[0]?.childSessionRef;

    expect(child(wrongParentFork.getSessionFile()!)).toBeUndefined();
    expect(child(validParentFork.getSessionFile()!, "artifact-child", false)).toBeUndefined();
    expect(child(extraDepthFork.getSessionFile()!)).toBeUndefined();
    expect(child(extraDepthRunFile, "fresh-child")).toBeUndefined();
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

  it("admits multiline plain prompts without duplicating their body into invocation receipts", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-multiline-prompt-receipt-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-multiline-prompt", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("complete")]);
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

    const prompt = "first line\nsecond line";
    await expect(slot.prompt(prompt)).resolves.toEqual({ operationId: expect.any(String) });
    await waitUntil(() => !slot.isBusy);

    const entries = (await readFile(slot.sessionFile!, "utf8"))
      .trimEnd().split("\n").map(line => JSON.parse(line) as any);
    const startReceipt = entries.find(entry => entry.type === "custom"
      && entry.customType === INVOCATION_RECEIPT_TYPE
      && entry.data?.receiptKind === "start");
    expect(startReceipt?.data).toMatchObject({ source: "plain", lifecycle: "staged" });
    expect(startReceipt?.data).not.toHaveProperty("arguments");
    expect(entries.some(entry => entry.type === "message" && entry.message?.role === "user"
      && entry.message.content?.some((part: any) => part.type === "text" && part.text === prompt))).toBe(true);
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

  it("keeps the Gateway alive when extension timers emit oversized or JSON-dense widgets", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-rpc-oversized-widget-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await mkdir(extensionDir, { recursive: true });
    await writeFile(join(extensionDir, "oversized-widget.ts"), `export default function (pi) {
      pi.on("session_start", (_event, ctx) => {
        setImmediate(() => {
          ctx.ui.setWidget("async-status", ["PI_SUBAGENT_ASYNC_JSON:" + "x".repeat(1_024)]);
          ctx.ui.setWidget("async-status", ["PI_SUBAGENT_ASYNC_JSON:" + '\"x\",'.repeat(115)]);
          ctx.ui.setStatus("oversized-widget-callback", "completed");
        });
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
    await waitUntil(() => slot.snapshot().extensionPresentation.semanticState.statuses["oversized-widget-callback"] === "completed");
    expect(slot.snapshot().extensionPresentation.semanticState.widgets).toEqual([]);
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
    expect(() => oldContext.setStatus("late", "old callback")).not.toThrow();
    expect(slot.snapshot().extensionPresentation.semanticState.statuses.late).toBeUndefined();

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

  it("serializes chained extension continuation ownership through a transient attention failure", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-settlement-overlap-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([
      mkdir(agentDir),
      mkdir(join(cwd, ".pi", "extensions"), { recursive: true }),
    ]);
    await writeFile(join(cwd, ".pi", "extensions", "continuation.ts"), `
let remaining = 3;
export default function (pi) {
  pi.on("agent_settled", () => {
    if (remaining === 0) return;
    const sequence = 4 - remaining;
    remaining -= 1;
    pi.sendMessage({ customType: "test-continuation", content: \`continue-\${sequence}\`, display: false }, { triggerTurn: true });
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
        return fauxAssistantMessage("continuation one complete");
      },
      fauxAssistantMessage("continuation two complete"),
      async () => {
        await new Promise((resolve) => setTimeout(resolve, 250));
        return fauxAssistantMessage("continuation three complete");
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
    const internals = registry as unknown as {
      attention: { complete: (sessionId: string, completionId: string) => Promise<unknown> };
      markers: {
        reassertAssistantCompletion: (
          sessionId: string, operationId: string, completionId: string, completedAt: string,
        ) => Promise<void>;
      };
    };
    const attention = internals.attention;
    const completionStamps = vi.spyOn(internals.markers, "reassertAssistantCompletion");
    const originalComplete = attention.complete.bind(attention);
    const complete = vi.spyOn(attention, "complete")
      .mockRejectedValueOnce(new Error("injected overlapping attention failure"))
      .mockImplementation(originalComplete);
    await slot.prompt("start");

    await waitUntil(() => faux.state.callCount === 4);
    expect(slot.snapshot()).toMatchObject({ phase: "running", operation: { kind: "prompt" } });
    const continuationSnapshotIndex = snapshots.length;
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(snapshots.slice(continuationSnapshotIndex).every((snapshot) => snapshot.phase === "running" && snapshot.operation)).toBe(true);
    await waitUntil(() => !slot.isBusy);
    const settled = slot.snapshot();
    expect(settled).toMatchObject({ phase: "idle" });
    // Producer-hidden continuation context is model input but not ordinary
    // transcript UI. Its canonical receipt remains available in the branch.
    expect(settled.transcript.find((item) => item.kind === "customMessage")).toBeUndefined();
    expect(settled.transcript.some((item) =>
      item.role === "user"
        && item.semantic?.invocationId !== undefined
        && item.semantic.lifecycle === "completed")).toBe(true);
    expect(registry.attentionProjection(slot.id).completionRevision).toBe(4);
    const completionIds = complete.mock.calls.map(([, completionId]) => completionId);
    expect(completionIds).toHaveLength(5);
    expect(completionIds[0]).toBe(completionIds[1]);
    expect(new Set(completionIds.slice(1)).size).toBe(4);
    const stampedOperationIds = completionStamps.mock.calls.map(([, operationId]) => operationId);
    expect(stampedOperationIds).toHaveLength(4);
    expect(new Set(stampedOperationIds).size).toBe(4);
    expect(snapshots.some((snapshot) => snapshot.phase === "running" && snapshot.operation)).toBe(true);
  });

  it("does not retry permanent marker completion conflicts", async () => {
    const fixture = await coldFixture("permanent-marker-invariant");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const retry = (slot as unknown as {
      retryDurableWrite: (key: string, operation: () => Promise<void>) => Promise<void>;
    }).retryDurableWrite.bind(slot);
    const operation = vi.fn(async () => {
      throw new RunMarkerCompletionConflictError("injected permanent ownership conflict");
    });

    await expect(retry("marker:test", operation)).rejects.toThrow("injected permanent ownership conflict");
    expect(operation).toHaveBeenCalledOnce();
    expect(fixture.events.filter((event) => event.topic === "session.operationFailed")).toEqual([]);
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
        reassertAssistantCompletion: (
          sessionId: string, operationId: string, completionId: string, completedAt: string,
        ) => Promise<void>;
      };
    };
    vi.spyOn(internals.attention, "complete").mockRejectedValue(new Error("injected persistent attention failure"));
    const originalStamp = internals.markers.reassertAssistantCompletion.bind(internals.markers);
    let secondStampEntered!: () => void;
    let releaseSecondStamp!: () => void;
    const secondStampEntry = new Promise<void>((resolve) => { secondStampEntered = resolve; });
    const secondStampBarrier = new Promise<void>((resolve) => { releaseSecondStamp = resolve; });
    let stampCount = 0;
    vi.spyOn(internals.markers, "reassertAssistantCompletion").mockImplementation(async (...arguments_) => {
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
    expect(finalSnapshot.streaming).toBeUndefined();
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
      expect(finalSnapshot.streaming).toBeUndefined();
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

  it("rejects a stale stop receipt before it can abort a newer operation", async () => {
    const fixture = await coldFixture("stale-operation-abort");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      operation?: { id: string; kind: "prompt"; startedAt: string };
    };
    internal.operation = {
      id: "newer-operation", kind: "prompt", startedAt: new Date().toISOString(),
    };

    await expect(slot.abort("agent", "older-operation")).rejects.toMatchObject({
      code: "conflict",
      retryable: true,
    });
    expect(internal.operation?.id).toBe("newer-operation");
  });

  it("holds steering behind compaction even while Pi reports broad streaming", async () => {
    const fixture = await coldFixture("compaction-steer-admission");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      phase: "compacting" | "running";
      operation?: { id?: string; kind: "compaction"; startedAt: string };
      publishSnapshot: () => void;
      runtime: { session: {
        readonly isStreaming: boolean;
        prompt: (text: string, options?: {
          streamingBehavior?: "steer" | "followUp";
          preflightResult?: (accepted: boolean) => void;
        }) => Promise<void>;
        getSteeringMessages: () => readonly string[];
      } };
    };
    internal.phase = "compacting";
    internal.operation = {
      id: "compaction-operation", kind: "compaction", startedAt: new Date().toISOString(),
    };
    vi.spyOn(internal.runtime.session, "isStreaming", "get").mockReturnValue(true);
    let queued = false;
    vi.spyOn(internal.runtime.session, "getSteeringMessages")
      .mockImplementation(() => queued ? ["after compaction"] : []);
    let invoked = false;
    vi.spyOn(internal.runtime.session, "prompt").mockImplementationOnce(async (_text, options) => {
      invoked = true;
      expect(options?.streamingBehavior).toBe("steer");
      queued = true;
      options?.preflightResult?.(true);
    });

    const prompting = slot.prompt("after compaction", [], "steer");
    await Promise.resolve();
    expect(invoked).toBe(false);
    internal.phase = "running";
    internal.operation = undefined;
    internal.publishSnapshot();

    await expect(prompting).resolves.toMatchObject({ operationId: expect.any(String) });
    expect(invoked).toBe(true);
    expect(slot.snapshot().queuedItems).toEqual([
      expect.objectContaining({ id: expect.any(String), behavior: "steer", text: "after compaction" }),
    ]);
  });

  it("keeps ordinary prompt admission behind the Gateway settlement transition", async () => {
    const fixture = await coldFixture("prompt-settlement-admission");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      phase: "running" | "idle";
      activeOperationId?: string;
      operation?: { id?: string; kind: "prompt"; startedAt: string };
      publishSnapshot: () => void;
      runtime: { session: { prompt: (
        text: string,
        options?: { preflightResult?: (accepted: boolean) => void },
      ) => Promise<void> } };
    };
    internal.phase = "running";
    internal.activeOperationId = "settling-operation";
    internal.operation = {
      id: "settling-operation", kind: "prompt", startedAt: new Date().toISOString(),
    };
    let invoked = false;
    vi.spyOn(internal.runtime.session, "prompt").mockImplementationOnce(async (_text, options) => {
      invoked = true;
      options?.preflightResult?.(true);
    });

    const prompting = slot.prompt("after settlement");
    await Promise.resolve();
    expect(invoked).toBe(false);
    internal.phase = "idle";
    internal.activeOperationId = undefined;
    internal.operation = undefined;
    internal.publishSnapshot();

    await expect(prompting).resolves.toMatchObject({ operationId: expect.any(String) });
    expect(invoked).toBe(true);
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

  it("exports a committed JSONL cut while the live session phase is running", async () => {
    const fixture = await coldFixture("active-jsonl-export");
    await fixture.registry.initializeBlobStorage();
    fixture.manager.appendMessage({ role: "user", content: "committed before export", timestamp: Date.now() });
    fixture.manager.appendMessage(fauxAssistantMessage("committed response"));
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as { phase: "running" | "idle" };
    internal.phase = "running";
    try {
      const artifact = await slot.export("jsonl");
      expect(artifact.size).toBeGreaterThan(0);
      const lease = await fixture.registry.acquireBlob(artifact.blobId);
      let exported = "";
      try {
        for await (const chunk of lease.stream) exported += Buffer.from(chunk).toString("utf8");
      } finally {
        await lease.release();
      }
      expect(exported).toContain("committed before export");
      expect(exported).toContain("committed response");
      expect(exported.endsWith("\n")).toBe(true);
    } finally {
      internal.phase = "idle";
    }
  });

  it("fails closed instead of projecting over an existing empty canonical file", async () => {
    const fixture = await coldFixture("empty-canonical-export");
    await fixture.registry.initializeBlobStorage();
    const source = fixture.manager.getSessionFile();
    expect(source).toBeDefined();
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    await writeFile(source!, "");
    await expect(slot.export("jsonl")).rejects.toMatchObject({
      code: "conflict",
      message: expect.stringContaining("empty"),
    });
  });

  it("renders HTML from an immutable cut without requiring the live session to become idle", async () => {
    const fixture = await coldFixture("active-html-export");
    await fixture.registry.initializeBlobStorage();
    const branchRoot = fixture.manager.getEntries().at(-1)!;
    fixture.manager.appendMessage(fauxAssistantMessage("abandoned html branch"));
    fixture.manager.branch(branchRoot.id);
    fixture.manager.appendMessage({ role: "user", content: "html snapshot marker", timestamp: Date.now() });
    fixture.manager.appendMessage(fauxAssistantMessage("html snapshot response"));
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as { phase: "running" | "idle" };
    internal.phase = "running";
    try {
      const artifact = await slot.export("html");
      expect(artifact.mimeType).toContain("text/html");
      const lease = await fixture.registry.acquireBlob(artifact.blobId);
      let exported = "";
      try {
        for await (const chunk of lease.stream) exported += Buffer.from(chunk).toString("utf8");
      } finally {
        await lease.release();
      }
      expect(exported).toContain("<!DOCTYPE html>");
      expect(Buffer.byteLength(exported)).toBe(artifact.size);
      const encoded = exported.match(/<script id="session-data" type="application\/json">([^<]+)<\/script>/)?.[1];
      expect(encoded).toBeDefined();
      const sessionData = Buffer.from(encoded!, "base64").toString("utf8");
      expect(sessionData).toContain("html snapshot marker");
      expect(sessionData).toContain("html snapshot response");
      expect(sessionData).not.toContain("abandoned html branch");
    } finally {
      internal.phase = "idle";
    }
  }, 30_000);

  it("keeps session exports independent from the 25 MiB transient media item limit", async () => {
    const fixture = await coldFixture("large-jsonl-export");
    await fixture.registry.initializeBlobStorage();
    fixture.manager.appendCustomEntry("large-export-fixture", {
      payload: "x".repeat(26 * 1_024 * 1_024),
    });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const artifact = await slot.export("jsonl");
    expect(artifact.size).toBeGreaterThan(25 * 1_024 * 1_024);
    const lease = await fixture.registry.acquireBlob(artifact.blobId);
    let bytes = 0;
    try {
      for await (const chunk of lease.stream) bytes += Buffer.byteLength(chunk);
    } finally {
      await lease.release();
    }
    expect(bytes).toBe(artifact.size);
  }, 30_000);

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

  it("persists fast foreground skill and prompt bindings without operation failures", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-skill-binding-receipt-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([
      mkdir(join(agentDir, "skills", "review"), { recursive: true }),
      mkdir(join(agentDir, "prompts"), { recursive: true }),
      mkdir(cwd),
    ]);
    await Promise.all([
      writeFile(join(agentDir, "skills", "review", "SKILL.md"),
        "---\nname: review\ndescription: Review carefully\n---\nReview the requested change.\n"),
      writeFile(join(agentDir, "prompts", "summarize.md"),
        "---\ndescription: Summarize carefully\n---\nSummarize $ARGUMENTS\n"),
    ]);
    const failures: unknown[] = [];
    const snapshots: any[] = [];
    const faux = fauxProvider({ provider: "tron-skill-binding", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("skill complete"), fauxAssistantMessage("prompt complete")]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime, trust: new TrustService(agentDir),
      broadcast: (_sessionId, topic, payload) => {
        if (topic === "session.operationFailed") failures.push(payload);
        if (topic === "session.snapshot") snapshots.push(payload);
      },
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await expect(slot.prompt("/skill:review configurations", [], undefined, {
      text: "configurations",
      resourceInvocation: { source: "skill", name: "review", arguments: "configurations" },
      attachmentEnvelope: "", attachmentCount: 0,
    })).resolves.toEqual({ operationId: expect.any(String) });
    await waitUntil(() => !slot.isBusy);
    const entries = (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n").map(line => JSON.parse(line) as any);
    let receipts = entries.filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE).map(entry => entry.data);
    expect(receipts.map(receipt => receipt.receiptKind)).toEqual(["start", "transition", "binding", "terminal"]);
    expect(receipts.find(receipt => receipt.receiptKind === "binding")).not.toHaveProperty("name");
    expect(snapshots.some(snapshot => snapshot.pendingPrompt?.resourceInvocation?.name === "review")).toBe(true);
    expect(slot.snapshot().transcript.some(item => item.semantic?.resourceInvocation?.name === "review")).toBe(true);

    await expect(slot.prompt("/summarize configurations", [], undefined, {
      text: "configurations",
      resourceInvocation: { source: "prompt", name: "summarize", arguments: "configurations" },
      attachmentEnvelope: "", attachmentCount: 0,
    })).resolves.toEqual({ operationId: expect.any(String) });
    await waitUntil(() => !slot.isBusy);
    const allEntries = (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n").map(line => JSON.parse(line) as any);
    receipts = allEntries.filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE).map(entry => entry.data);
    const promptReceipts = receipts.filter(receipt => receipt.source === "prompt");
    expect(promptReceipts.map(receipt => receipt.receiptKind)).toEqual(["start", "transition", "binding", "terminal"]);
    expect(promptReceipts.find(receipt => receipt.receiptKind === "binding")).not.toHaveProperty("name");
    expect(slot.snapshot().transcript.some(item => item.semantic?.resourceInvocation?.name === "summarize")).toBe(true);
    expect(failures).toEqual([]);
  });

  it("records interruption intent before fast SDK settlement", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-abort-invocation-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let release!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { release = resolve; });
    const faux = fauxProvider({ provider: "tron-abort-invocation", tokensPerSecond: 10_000 });
    faux.setResponses([async () => { await responseBarrier; return fauxAssistantMessage("should not complete"); }]);
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
    const prompt = slot.prompt("interrupt me");
    await waitUntil(() => slot.isBusy);
    const aborting = slot.abort("agent");
    release();
    await aborting;
    await expect(prompt).resolves.toEqual({ operationId: expect.any(String) });
    await waitUntil(() => !slot.isBusy);
    const entries = (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n").map(line => JSON.parse(line) as any);
    const terminal = entries.find(entry => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data?.receiptKind === "terminal");
    expect(terminal?.data).toMatchObject({ lifecycle: "interrupted" });
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
      resourceInvocation: { source: "skill", name: "review", arguments: "queued skill" },
      attachmentEnvelope: "",
      attachmentCount: 0,
    });
    const queued = slot.snapshot();
    expect(queued.queuedItems).toHaveLength(4);
    expect(queued.queuedItems.map((item) => item.behavior)).toEqual(["steer", "steer", "steer", "followUp"]);
    expect(queued.queuedItems.map((item) => item.text)).toEqual([
      "first steer", "first steer", "queued skill", "later follow-up",
    ]);
    expect(new Set(queued.queuedItems.map((item) => item.id)).size).toBe(4);
    expect(queued.queuedItems[0]?.attachments).toEqual([attachment]);

    const [first, duplicate, skill, followUp] = queued.queuedItems;
    const replaced = await slot.replaceQueue(queued.queueRevision, [
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
    expect(replaced.items[3]?.resourceInvocation).toEqual({
      source: "skill", name: "review", arguments: "edited skill",
    });
    const afterEditEntries = (slot as any).runtime.session.sessionManager.getEntries() as any[];
    const skillInvocationReceipts = afterEditEntries.filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE
      && entry.data?.operationId === skill!.id).map(entry => entry.data);
    expect(skillInvocationReceipts.filter(receipt => receipt.receiptKind === "start")
      .map(receipt => receipt.arguments)).toEqual(["queued skill", "edited skill"]);
    expect(skillInvocationReceipts.some(receipt => receipt.receiptKind === "terminal"
      && receipt.lifecycle === "interrupted" && receipt.errorCode === "queue-edited")).toBe(true);
    const queuedRuntime = (slot as unknown as {
      runtime: { session: { getFollowUpMessages(): readonly string[] } };
    }).runtime.session.getFollowUpMessages();
    expect(queuedRuntime.some(
      (text) => text.startsWith('<skill name="review"') && text.endsWith("edited skill"),
    )).toBe(true);
    await expect(slot.replaceQueue(queued.queueRevision, [])).rejects.toMatchObject({ code: "conflict" });

    const removed = await slot.replaceQueue(replaced.queueRevision, [replaced.items[1]!]);
    expect(removed.items).toHaveLength(1);
    expect(removed.items[0]?.id).toBe(followUp!.id);
    const afterReplaceEntries = (slot as any).runtime.session.sessionManager.getEntries() as any[];
    expect(afterReplaceEntries.some(entry => entry.customType === INVOCATION_RECEIPT_TYPE
      && entry.data?.operationId === skill!.id
      && entry.data?.receiptKind === "terminal"
      && entry.data?.lifecycle === "interrupted")).toBe(true);

    await slot.clearQueue();
    expect(slot.snapshot().queuedItems).toEqual([]);
    const afterClearEntries = (slot as any).runtime.session.sessionManager.getEntries() as any[];
    expect(afterClearEntries.some(entry => entry.customType === INVOCATION_RECEIPT_TYPE
      && entry.data?.operationId === followUp!.id
      && entry.data?.receiptKind === "terminal"
      && entry.data?.lifecycle === "interrupted"
      && entry.data?.errorCode === "queue-cleared")).toBe(true);
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

  it("reasserts exact marker ownership when cleanup races terminal completion stamping", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-terminal-marker-race-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-terminal-marker-race", tokensPerSecond: 10_000 });
    faux.setResponses([
      async () => { await responseBarrier; return fauxAssistantMessage("first completion"); },
      fauxAssistantMessage("next completion"),
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

    const first = await slot.prompt("first");
    await waitUntil(() => slot.snapshot().phase === "running");
    const markers = (slot as unknown as {
      dependencies: {
        markers: {
          clear: (sessionId: string, operationId?: string) => Promise<void>;
          evidenceFor: (sessionId: string) => Promise<Array<{ operationId: string }>>;
        };
      };
    }).dependencies.markers;
    await markers.clear(slot.id, first.operationId);
    expect(await markers.evidenceFor(slot.id)).toEqual([]);

    releaseResponse();
    await waitUntil(() => registry.attentionProjection(slot.id).completionRevision === 1);
    await waitUntil(() => slot.snapshot().phase === "idle");
    await expect(slot.reconcileAttention()).resolves.toBeUndefined();
    expect(await markers.evidenceFor(slot.id)).toEqual([]);

    await expect(slot.prompt("next", [], "steer")).resolves.toEqual({
      operationId: expect.any(String),
    });
    const drain = registry.waitUntilIdle();
    await waitUntil(() => registry.attentionProjection(slot.id).completionRevision === 2);
    await drain;
    expect(slot.snapshot().phase).toBe("idle");
    expect(registry.administrativeDrainSnapshot()).toMatchObject({ phase: "complete", blockerCount: 0 });
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

  it("omits a terminal runtime overlay when its canonical result is outside the bounded tail", async () => {
    const fixture = await coldFixture("canonical-tool-ownership-backstop");
    fixture.manager.appendMessage({
      role: "toolResult",
      toolCallId: "canonical-old",
      toolName: "read",
      content: [{ type: "text", text: "canonical result" }],
      isError: true,
      timestamp: Date.now(),
    });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      toolExecutions: Map<string, unknown>;
      toolMetadata: Map<string, unknown>;
      onEvent: (event: unknown) => void;
      runtime: { session: { readonly isStreaming: boolean } };
    };
    internal.toolExecutions.set("canonical-old", {
      toolCallId: "canonical-old", toolName: "read", order: 0, status: "failed",
      arguments: null, isError: true, startedAt: new Date(0).toISOString(),
      updatedAt: new Date(0).toISOString(), lastProgressAt: new Date(0).toISOString(),
      progressSequence: 1,
    });
    const metadata = { startedAt: new Date(0).toISOString(), lastProgressAt: new Date(0).toISOString(), progressSequence: 3 };
    internal.toolMetadata.set("canonical-old", metadata);
    // The full-branch backstop removes the live row even before the lifecycle
    // handoff reaches this slot; ownership does not depend on the bounded
    // transcript page containing the result.
    expect(slot.snapshot().toolExecutions).toEqual([]);
    const streaming = vi.spyOn(internal.runtime.session, "isStreaming", "get").mockReturnValue(true);
    // The handoff removes the live row immediately while preserving the
    // metadata map for canonical enrichment. A later terminal callback cannot
    // re-admit the exact ID.
    internal.onEvent({
      type: "message_end",
      message: {
        role: "toolResult", toolCallId: "canonical-old", toolName: "read",
        content: [{ type: "text", text: "canonical result" }], isError: true,
        timestamp: Date.now(),
      },
    });
    await Promise.resolve();
    expect(internal.toolExecutions.has("canonical-old")).toBe(false);
    expect(internal.toolMetadata.get("canonical-old")).toEqual(metadata);
    internal.onEvent({
      type: "tool_execution_end", toolCallId: "canonical-old", toolName: "read",
      result: { content: [{ type: "text", text: "late terminal" }] }, isError: true,
    });
    expect(internal.toolExecutions.has("canonical-old")).toBe(false);
    expect(internal.toolMetadata.get("canonical-old")).toMatchObject({
      startedAt: expect.any(String), completedAt: expect.any(String), progressSequence: expect.any(Number),
    });
    expect(slot.snapshot().toolExecutions).toEqual([]);

    const notPersisted = {
      toolCallId: "not-persisted", toolName: "read", order: 1, status: "completed",
      arguments: null, isError: false, startedAt: new Date(0).toISOString(),
      updatedAt: new Date(0).toISOString(), lastProgressAt: new Date(0).toISOString(),
      progressSequence: 1,
    };
    internal.toolExecutions.set("not-persisted", notPersisted);
    internal.onEvent({
      type: "message_end",
      message: {
        role: "toolResult", toolCallId: "not-persisted", toolName: "read",
        content: [{ type: "text", text: "append failed" }], isError: false,
        timestamp: Date.now(),
      },
    });
    await Promise.resolve();
    expect(internal.toolExecutions.get("not-persisted")).toEqual(notPersisted);
    internal.toolExecutions.delete("not-persisted");
    streaming.mockRestore();
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
        toolSegmentId?: string;
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
    expect(new Set(grouped.map((event) => event.toolSegmentId)).size).toBe(1);
    expect(grouped.every((event) => event.toolSegmentId?.startsWith("tool-segment:") === true)).toBe(true);
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
    const activeSnapshots = events
      .filter((event) => event.topic === "session.snapshot")
      .map((event) => (event.payload?.data ?? event.payload) as {
        phase?: string;
        transcript?: Array<{ kind?: string; role?: string; toolCallId?: string }>;
        toolExecutions?: Array<{ toolCallId: string }>;
      })
      .filter((snapshot) => snapshot.phase === "running");
    // A sibling remains authoritative while one call transfers from terminal
    // runtime evidence to its canonical toolResult. There must be no active
    // snapshot in which the settled call is absent from both sources.
    expect(activeSnapshots.some((snapshot) => {
      const runtimeRead = snapshot.toolExecutions?.some((tool) => tool.toolCallId === "call-read");
      const runtimeBash = snapshot.toolExecutions?.some((tool) => tool.toolCallId === "call-bash");
      return runtimeRead === true && runtimeBash === true;
    })).toBe(true);
    expect(activeSnapshots.some((snapshot) => {
      const canonicalRead = snapshot.transcript?.some((item) =>
        item.kind === "message" && item.role === "toolResult" && item.toolCallId === "call-read");
      const canonicalBash = snapshot.transcript?.some((item) =>
        item.kind === "message" && item.role === "toolResult" && item.toolCallId === "call-bash");
      return canonicalRead === true && canonicalBash === true;
    })).toBe(true);
    const snapshotsAfterAdmission = activeSnapshots.filter((snapshot) => {
      const canonicalRead = snapshot.transcript?.some((item) =>
        item.kind === "message" && item.role === "toolResult" && item.toolCallId === "call-read");
      const runtimeRead = snapshot.toolExecutions?.some((tool) => tool.toolCallId === "call-read");
      return canonicalRead === true || runtimeRead === true;
    });
    expect(snapshotsAfterAdmission.length).toBeGreaterThan(0);
    expect(snapshotsAfterAdmission.every((snapshot) => {
      const canonicalRead = snapshot.transcript?.some((item) =>
        item.kind === "message" && item.role === "toolResult" && item.toolCallId === "call-read");
      const runtimeRead = snapshot.toolExecutions?.some((tool) => tool.toolCallId === "call-read");
      return canonicalRead === true || runtimeRead === true;
    })).toBe(true);
    expect(activeSnapshots.every((snapshot) => {
      const canonicalIDs = new Set((snapshot.transcript ?? [])
        .filter((item) => item.kind === "message" && item.role === "toolResult")
        .map((item) => item.toolCallId)
        .filter((id): id is string => typeof id === "string"));
      return !(snapshot.toolExecutions ?? []).some((tool) => canonicalIDs.has(tool.toolCallId));
    })).toBe(true);
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
    const canonicalSegmentIDs = new Set(canonicalCalls.flatMap((part) =>
      part.type === "toolCall" ? [part.toolSegmentId] : []
    ));
    expect(canonicalSegmentIDs.size).toBe(1);
    expect(canonicalSegmentIDs).toEqual(new Set(grouped.map((event) => event.toolSegmentId)));
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

  it("retires a command-triggered foreground owner when the turn has no successful assistant completion", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-failed-command-turn-drain-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "failed-turn.ts"), `export default function (pi) {
      pi.registerCommand("start-failed-turn", { handler: async (_args, ctx) => {
        pi.sendMessage({ customType: "failed-turn", content: "continue", display: false }, { triggerTurn: true });
      }});
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const faux = fauxProvider({ provider: "tron-failed-command-turn", tokensPerSecond: 10_000 });
    faux.setResponses([{
      ...fauxAssistantMessage("provider failed"),
      stopReason: "error",
      errorMessage: "injected provider failure",
    }]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const workRegistry = new GatewayWorkRegistry("failed-command-turn-epoch");
    const derivedAdmissions = vi.spyOn(workRegistry, "beginDerived");
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust, workRegistry,
      modelRuntimeFactory: async () => runtime,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    await slot.prompt("/start-failed-turn").catch(() => {});
    await waitUntil(() => slot.catalogPhase === "idle" || slot.catalogPhase === "interrupted");
    await waitUntil(() => workRegistry.size === 0);
    expect(faux.state.callCount).toBeGreaterThan(0);
    expect(derivedAdmissions.mock.calls.some(([admission]) =>
      admission.kind === "foreground-agent-operation"
    )).toBe(true);
    const markerPath = join(root, "tron", "gateway", "runtime-markers", `${slot.id}.json`);
    if (existsSync(markerPath)) {
      const marker = JSON.parse(await readFile(markerPath, "utf8")) as { operations: unknown[] };
      expect(marker.operations).toEqual([]);
    }
    await registry.waitUntilIdle();
    expect(registry.administrativeDrainSnapshot()).toMatchObject({
      phase: "complete", blockerCount: 0, suspectProjectionCount: 0,
    });
  });

  it("classifies and reconciles an unrepresented foreground token during drain", async () => {
    const fixture = await coldFixture("orphaned-foreground-drain");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      pendingPrompt?: { id: string; createdAt: string; text: string; attachmentCount: number };
      beginDerivedOperationWork: (operationId: string, kind: "foreground-agent-operation") => unknown;
      runtime: { session: { readonly isStreaming: boolean } };
      dependencies: { markers: { mark: (sessionId: string, operationId: string) => Promise<void> } };
    };
    internal.beginDerivedOperationWork("orphaned-operation", "foreground-agent-operation");
    internal.pendingPrompt = {
      id: "orphaned-operation",
      createdAt: new Date().toISOString(),
      text: "stale provisional prompt",
      attachmentCount: 0,
    };
    await internal.dependencies.markers.mark(slot.id, "orphaned-operation");
    const streaming = vi.spyOn(internal.runtime.session, "isStreaming", "get").mockReturnValue(true);

    const admitted = fixture.registry.beginAdministrativeDrain();
    expect(admitted).toMatchObject({
      blockerCount: 1,
      suspectProjectionCount: 0,
      blockers: [expect.objectContaining({
        category: "foreground-agent-operation", state: "active",
      })],
    });
    streaming.mockRestore();
    expect(fixture.registry.administrativeDrainSnapshot()).toMatchObject({
      blockerCount: 1,
      suspectProjectionCount: 1,
      blockers: [expect.objectContaining({
        category: "foreground-agent-operation", state: "suspect",
      })],
    });
    await fixture.registry.waitUntilIdle();
    expect(fixture.registry.administrativeDrainSnapshot()).toMatchObject({
      phase: "complete", blockerCount: 0, suspectProjectionCount: 0,
    });
    expect(slot.snapshot().pendingPrompt).toBeUndefined();
    const markerPath = join(fixture.root, "tron", "gateway", "runtime-markers", `${slot.id}.json`);
    if (existsSync(markerPath)) {
      const marker = JSON.parse(await readFile(markerPath, "utf8")) as { operations: unknown[] };
      expect(marker.operations).toEqual([]);
    }
  });

  it("reasserts ownership restored while orphan marker cleanup yields", async () => {
    const fixture = await coldFixture("orphan-marker-race");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      phase: "idle" | "running";
      activeOperationId?: string;
      operation?: { id?: string; kind: "prompt"; startedAt: string };
      beginDerivedOperationWork: (operationId: string, kind: "foreground-agent-operation") => unknown;
      dependencies: { markers: {
        mark: (sessionId: string, operationId: string) => Promise<void>;
        clear: (sessionId: string, operationId?: string) => Promise<void>;
        evidenceFor: (sessionId: string) => Promise<Array<{ operationId: string }>>;
      } };
    };
    internal.beginDerivedOperationWork("racing-operation", "foreground-agent-operation");
    await internal.dependencies.markers.mark(slot.id, "racing-operation");
    const mark = vi.spyOn(internal.dependencies.markers, "mark");
    const originalClear = internal.dependencies.markers.clear.bind(internal.dependencies.markers);
    let releaseClear!: () => void;
    const clearBarrier = new Promise<void>((resolve) => { releaseClear = resolve; });
    const clear = vi.spyOn(internal.dependencies.markers, "clear")
      .mockImplementationOnce(async () => clearBarrier)
      .mockImplementation(originalClear);

    const drain = fixture.registry.waitUntilIdle();
    await waitUntil(() => clear.mock.calls.length === 1);
    internal.phase = "running";
    internal.activeOperationId = "racing-operation";
    internal.operation = {
      id: "racing-operation", kind: "prompt", startedAt: new Date().toISOString(),
    };
    releaseClear();
    await waitUntil(() => mark.mock.calls.length === 1);
    await expect(internal.dependencies.markers.evidenceFor(slot.id)).resolves.toEqual([
      expect.objectContaining({ operationId: "racing-operation" }),
    ]);

    internal.phase = "idle";
    internal.activeOperationId = undefined;
    internal.operation = undefined;
    await drain;
    expect(clear.mock.calls.length).toBeGreaterThanOrEqual(2);
    await expect(internal.dependencies.markers.evidenceFor(slot.id)).resolves.toEqual([]);
  });

  it("fails a drain instead of waiting forever on foreground work without a captured slot", async () => {
    const workRegistry = new GatewayWorkRegistry("missing-slot-drain-epoch");
    const fixture = await coldFixture("missing-slot-drain", { workRegistry });
    const stranded = workRegistry.begin({
      kind: "foreground-agent-operation",
      sessionId: "missing-slot",
      hostEpoch: "missing-slot-drain-epoch",
    });

    await expect(fixture.registry.waitUntilIdle()).rejects.toThrow(
      /foreground ownership without a captured runtime slot/u,
    );
    expect(fixture.registry.administrativeDrainSnapshot()).toMatchObject({
      phase: "failed", blockerCount: 1, suspectProjectionCount: 1,
    });
    stranded.settle();
  });

  it("does not treat an ownerless late agent settlement as all-marker authority", async () => {
    const fixture = await coldFixture("ownerless-late-settlement");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      pendingExtensionCommand?: { id: string; kind: "command"; startedAt: string };
      onEvent: (event: { type: "agent_settled" }) => void;
      dependencies: { markers: {
        mark: (sessionId: string, operationId: string) => Promise<void>;
        evidenceFor: (sessionId: string) => Promise<Array<{ operationId: string }>>;
      } };
    };
    internal.pendingExtensionCommand = {
      id: "command-owner", kind: "command", startedAt: new Date().toISOString(),
    };
    await internal.dependencies.markers.mark(slot.id, "other-owner-one");
    await internal.dependencies.markers.mark(slot.id, "other-owner-two");

    internal.onEvent({ type: "agent_settled" });

    await expect(internal.dependencies.markers.evidenceFor(slot.id)).resolves.toEqual([
      expect.objectContaining({ operationId: "other-owner-one" }),
      expect.objectContaining({ operationId: "other-owner-two" }),
    ]);
  });

  it("retires an exact provisional prompt projection even after its work token already settled", async () => {
    const fixture = await coldFixture("settled-provisional-prompt");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      pendingPrompt?: {
        id: string; createdAt: string; text: string; attachmentCount: number;
      };
      settleOperationWork: (operationId: string) => void;
    };
    internal.pendingPrompt = {
      id: "settled-operation",
      createdAt: new Date().toISOString(),
      text: "settled prompt",
      attachmentCount: 0,
    };

    internal.settleOperationWork("settled-operation");

    expect(slot.snapshot().pendingPrompt).toBeUndefined();
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
    await waitUntil(() => (slot as any).pendingExtensionCommand === undefined);
    expect(failedMarker.mock.calls.length).toBeGreaterThanOrEqual(2);
    failedMarker.mockRestore();

    let resolveAdmission!: (result: { operationId: string }) => void;
    const admission = new Promise<{ operationId: string }>((resolve) => { resolveAdmission = resolve; });
    const command = slot.prompt(
      "/during-stream",
      [],
      undefined,
      undefined,
      resolveAdmission,
    );
    await expect(admission).resolves.toEqual({ operationId: expect.any(String) });
    await waitUntil(() => slot.snapshot().extensionPresentation.pendingInteractions.length === 1);
    const pending = slot.snapshot().extensionPresentation.pendingInteractions[0]!;
    const during = slot.snapshot();
    expect(during.phase).toBe("running");
    expect(during.operation?.kind).toBe("prompt");
    expect((slot as any).pendingExtensionCommand?.kind).toBe("command");
    const marker = JSON.parse(await readFile(join(root, "tron", "gateway", "runtime-markers", `${slot.id}.json`), "utf8")) as {
      operations: Array<{ operationId: string }>;
    };
    expect(marker.operations.map((operation) => operation.operationId)).toContain((slot as any).pendingExtensionCommand?.id);
    let drainSettled = false;
    const drain = registry.waitUntilIdle().then(() => { drainSettled = true; });
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(drainSettled).toBe(false);
    slot.respondToInteraction(pending.id, pending.hostEpoch, pending.presentationRevision, true, false);
    await expect(command).resolves.toEqual({ operationId: expect.any(String) });
    await waitUntil(() => (slot as any).pendingExtensionCommand === undefined);
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

  it("persists extension notifications as centered non-context rows with exact command provenance", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-extension-command-notification-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "notify-command.ts"), `export default function (pi) {
      pi.registerCommand("notify-command", {
        handler: async (_args, ctx) => {
          ctx.ui.notify("Goal created.", "info");
          pi.sendMessage({
            customType: "goal-event",
            content: "Goal created.",
            display: true,
            details: { goal: { objective: "count to 20", status: "active" } },
          });
          pi.sendMessage({
            customType: "goal-audit",
            content: "Goal receipt stored.",
            display: true,
          });
        },
      });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
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
    const slot = await registry.create(cwd);

    await expect(slot.prompt("/notify-command count to 20")).resolves.toEqual({ operationId: expect.any(String) });
    await waitUntil(() => slot.snapshot().transcript.some(item =>
      item.kind === "customEntry" && item.semantic?.kind === "status"));
    await waitUntil(() => slot.snapshot().transcript.filter(item =>
      item.kind === "customMessage" && item.semantic?.origin.kind === "extension").length === 2);
    const snapshot = slot.snapshot();
    const command = snapshot.transcript.find(item => item.semantic?.kind === "command");
    const commandOwnerID = command?.semantic?.origin.ownerId;
    expect(command).toMatchObject({
      semantic: {
        direction: "ambientStatus",
        contextEffect: "none",
        lifecycle: "completed",
        origin: { kind: "extension", ownerId: expect.any(String) },
      },
    });
    expect(snapshot.transcript.find(item =>
      item.kind === "customEntry" && item.semantic?.kind === "status")).toMatchObject({
      kind: "customEntry",
      data: expect.objectContaining({ message: "Goal created.", tone: "info" }),
      semantic: {
        direction: "ambientStatus",
        contextEffect: "none",
        origin: expect.objectContaining({ kind: "extension", ownerId: commandOwnerID }),
      },
    });
    const customMessages = snapshot.transcript.filter(item => item.kind === "customMessage");
    expect(customMessages).toHaveLength(2);
    expect(customMessages[0]).toMatchObject({
      details: { goal: { objective: "count to 20", status: "active" } },
      semantic: {
        direction: "inboundContext",
        contextEffect: "modelInput",
        origin: expect.objectContaining({ kind: "extension", ownerId: commandOwnerID }),
      },
    });
    expect(customMessages[1]).toMatchObject({
      semantic: {
        direction: "inboundContext",
        contextEffect: "modelInput",
        origin: expect.objectContaining({ kind: "extension", ownerId: commandOwnerID }),
      },
    });
  });

  it("records a caught extension-command handler error as a failed canonical invocation", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-extension-command-failure-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await Promise.all([mkdir(agentDir), mkdir(extensionDir, { recursive: true })]);
    await writeFile(join(extensionDir, "failing-command.ts"), `export default function (pi) {
      pi.registerCommand("fail-command", {
        description: "Fail deterministically",
        handler: async () => { throw new Error("expected command failure"); },
      });
    }\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
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
    const slot = await registry.create(cwd);

    await expect(slot.prompt("/fail-command")).resolves.toEqual({ operationId: expect.any(String) });
    await waitUntil(() => (slot as any).pendingExtensionCommand === undefined);
    const command = slot.snapshot().transcript.find(item => item.semantic?.kind === "command");
    expect(command).toMatchObject({
      semantic: {
        lifecycle: "failed",
        resourceInvocation: { source: "extension", name: "fail-command" },
      },
    });
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
        ctx.ui.notify("Shutdown complete.", "info");
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
    const reopened = await registry.acquire(persistedID);
    expect(reopened.snapshot().transcript.find(item =>
      item.kind === "customEntry" && item.semantic?.kind === "status"
        && item.data !== undefined && !Array.isArray(item.data)
        && typeof item.data === "object" && item.data !== null
        && item.data.message === "Shutdown complete.")).toMatchObject({
      data: expect.objectContaining({ message: "Shutdown complete." }),
      semantic: { direction: "ambientStatus", contextEffect: "none" },
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
      expect.objectContaining({
        name: "project_echo", label: "Project echo",
        description: "Echo project text", scope: "project",
      }),
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

  it("classifies exact producer topology and keeps top-level parented sessions user-visible", async () => {
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
    const generatedNestedFile = await writeSession(nestedDirectory, nestedId, "nested fresh child");
    await rename(generatedNestedFile, join(nestedDirectory, "session.jsonl"));

    const forksDirectory = join(parentFile.replace(/\.jsonl$/, ""), "forks");
    await mkdir(forksDirectory, { recursive: true });
    const nestedFork = SessionManager.forkFrom(parentFile, cwd, forksDirectory);
    const fork = SessionManager.forkFrom(parentFile, cwd, piSessionDirectory);
    fork.appendSessionInfo("ordinary fork");
    const directSubagent = SessionManager.forkFrom(parentFile, cwd, piSessionDirectory);
    directSubagent.appendSessionInfo("subagent-worker-fixture-1");
    const crossProjectDirectory = join(agentDir, "sessions", "--other-workspace--");
    await mkdir(crossProjectDirectory, { recursive: true });
    const crossProjectFork = SessionManager.forkFrom(
      parentFile, join(root, "other-workspace"), crossProjectDirectory
    );

    // Reproduce the incident shape without using text or timestamps: a
    // top-level parented snapshot interrupted before child naming remains a
    // user session because it does not satisfy delegated producer topology.
    const interruptedId = randomUUID();
    const interruptedFile = join(piSessionDirectory, `${interruptedId}.jsonl`);
    await writeFile(interruptedFile, [
      JSON.stringify({
        type: "session", version: 3, id: interruptedId,
        timestamp, cwd, parentSession: parentFile,
      }),
      JSON.stringify({
        type: "message", id: randomUUID().slice(0, 8), parentId: null,
        timestamp, message: { role: "user", content: "inherited", timestamp: Date.now() - 1_000 },
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
      parentId, fork.getSessionId(), directSubagent.getSessionId(),
      crossProjectFork.getSessionId(), interruptedId,
    ]));
    expect(defaultCatalog.map((session) => session.id)).not.toContain(nestedId);
    expect(defaultCatalog.map((session) => session.id)).not.toContain(nestedFork.getSessionId());
    expect(defaultCatalog.map((session) => session.id)).not.toContain(externalId);
    expect(completeCatalog.map((session) => session.id)).not.toContain(externalId);
    expect(completeCatalog.find((session) => session.id === parentId)).toMatchObject({ kind: "user" });
    expect(completeCatalog.find((session) => session.id === fork.getSessionId())).toMatchObject({ kind: "user", parentSessionId: parentId });
    expect(completeCatalog.find((session) => session.id === crossProjectFork.getSessionId())).toMatchObject({
      kind: "user", parentSessionId: parentId,
    });
    expect(completeCatalog.find((session) => session.id === directSubagent.getSessionId())).toMatchObject({
      kind: "user",
      parentSessionId: parentId,
    });
    expect(completeCatalog.find((session) => session.id === interruptedId)).toMatchObject({
      kind: "user",
      parentSessionId: parentId,
    });
    expect(completeCatalog.find((session) => session.id === nestedFork.getSessionId())).toMatchObject({
      kind: "subagent",
      parentSessionId: parentId,
    });
    expect(completeCatalog.find((session) => session.id === nestedId)).toMatchObject({
      kind: "subagent",
    });
    const acquisition = await (registry as unknown as {
      catalogAcquisition: () => Promise<{ entriesByID: ReadonlyMap<string, { structuralSubagent: boolean; path: string }> }>;
    }).catalogAcquisition();
    expect(acquisition.entriesByID.get(nestedId)?.structuralSubagent).toBe(true);
    expect(acquisition.entriesByID.get(nestedFork.getSessionId())?.structuralSubagent).toBe(true);
    await expect(registry.acquire(nestedId)).rejects.toMatchObject({ code: "conflict" });
    await expect(registry.acquire(nestedFork.getSessionId())).rejects.toMatchObject({ code: "conflict" });
    await expect(registry.delete(nestedId)).rejects.toMatchObject({ code: "conflict" });

    await registry.delete(parentId);
    expect((await registry.list("all")).find((session) => session.id === nestedId)).toMatchObject({ kind: "subagent" });
    expect((await registry.list("all")).find((session) => session.id === nestedFork.getSessionId()))
      .toMatchObject({ kind: "subagent" });
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
    const internal = slot as unknown as {
      runtime: { session: { executeBash: (...arguments_: unknown[]) => Promise<unknown> } };
      activityHeartbeat?: NodeJS.Timeout;
    };
    const session = internal.runtime.session;
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
    expect(internal.activityHeartbeat).toBeDefined();
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
    expect(internal.activityHeartbeat).toBeUndefined();
    expect(slot.snapshot()).toMatchObject({ phase: "idle" });
    expect(slot.snapshot().processActivities ?? []).toEqual([]);
  });

  it("does not commit idle eviction while canonical receipt persistence is unsettled", async () => {
    const { manager, registry } = await coldFixture("idle-eviction-receipt-barrier");
    const sessionId = manager.getSessionId();
    const slot = await registry.acquire(sessionId);
    vi.spyOn(slot, "touchedAt", "get").mockReturnValue(0);

    let settleReceipt!: () => void;
    const receipt = new Promise<void>((resolve) => { settleReceipt = resolve; });
    const internals = slot as unknown as { pendingReceiptWrites: Set<Promise<void>> };
    internals.pendingReceiptWrites.add(receipt);

    const eviction = (registry as unknown as { evictIdle: () => Promise<void> }).evictIdle();
    const outcome = await Promise.race([
      eviction.then(() => "settled" as const),
      new Promise<"blocked">((resolve) => setTimeout(() => resolve("blocked"), 100)),
    ]);
    settleReceipt();
    internals.pendingReceiptWrites.delete(receipt);
    await eviction;

    expect(outcome).toBe("settled");
    expect(await registry.acquire(sessionId)).toBe(slot);
    expect(slot.isDisposed).toBe(false);
  });

  it("force-invalidates an extension runtime whose idle-eviction shutdown never settles", async () => {
    const { manager, registry } = await coldFixture("idle-eviction-shutdown-timeout");
    const sessionId = manager.getSessionId();
    const slot = await registry.acquire(sessionId);
    vi.spyOn(slot, "touchedAt", "get").mockReturnValue(0);

    const internals = slot as unknown as {
      runtime: { dispose: () => Promise<void>; session: { dispose: () => void } };
      dependencies: { runtimeDisposalTimedOut?: (graceMs: number) => void };
    };
    const timedOut = vi.fn(() => { throw new Error("instrumentation failed"); });
    internals.dependencies.runtimeDisposalTimedOut = timedOut;
    const gracefulDispose = vi.spyOn(internals.runtime, "dispose")
      .mockImplementation(() => new Promise<void>(() => {}));
    const forceDispose = vi.spyOn(internals.runtime.session, "dispose");

    const eviction = (registry as unknown as { evictIdle: () => Promise<void> }).evictIdle();
    await waitUntil(() => gracefulDispose.mock.calls.length === 1);
    let acquisitionSettled = false;
    const acquisition = registry.acquire(sessionId).finally(() => { acquisitionSettled = true; });
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(acquisitionSettled).toBe(false);

    await eviction;
    const reopened = await acquisition;
    expect(timedOut).toHaveBeenCalledWith(5_000);
    expect(forceDispose).toHaveBeenCalledOnce();
    expect(slot.isDisposed).toBe(true);
    expect(reopened).not.toBe(slot);
    expect(reopened.id).toBe(sessionId);
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
