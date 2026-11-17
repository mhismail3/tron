import { createTestRegistry } from "../../../test-support/gateway-registry.js";
import { randomUUID } from "node:crypto";
import { performance as nodePerformance } from "node:perf_hooks";
import { existsSync } from "node:fs";
import { appendFile, mkdir, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../../kernel/resources/trust-service.js";
import type { NotificationService } from "../../notifications/notification-service.js";
import type { SessionSummaryUpdate } from "../../protocol/types.js";
import { GatewayWorkRegistry } from "../../kernel/run/gateway-work-registry.js";
import { RequestSpan, runInRequestSpan, stage } from "../../util/request-span.js";
import { CatalogDiscovery } from "../../sessions/catalog-discovery.js";
import { INVOCATION_RECEIPT_TYPE, makeInvocationReceipt } from "../../kernel/receipts/invocation-receipts.js";
import { EXTENSION_ACTIVITY_RECEIPT_TYPE, type ExtensionActivityReceipt } from "../../kernel/receipts/extension-activity-history.js";
import {
  RuntimeRegistry,
} from "../../kernel/session/runtime-registry.js";
import { waitFor } from "../../../test-support/wait-for.js";
import { catalogOwner, createColdRegistryFixture, initializeRegistry, settleCatalog, temporaryRoot } from "../../../test-support/runtime-registry-fixture.js";
function subscribeAudience(registry: RuntimeRegistry, sessionId: string): void {
  registry.subscribe("test-audience", sessionId);
}

function catalogWalks(): { count: () => number; restore: () => void } {
  const walk = vi.spyOn(CatalogDiscovery.prototype, "catalogStructureEvidence");
  return { count: () => walk.mock.calls.length, restore: () => walk.mockRestore() };
}

describe("RuntimeRegistry with the pinned agent runtime", { concurrent: false }, () => {
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  const registries: RuntimeRegistry[] = [];

  const coldFixture = createColdRegistryFixture.bind(undefined, registries);

  afterEach(async () => {
    await Promise.all(registries.splice(0).map((registry) => registry.dispose()));
    vi.restoreAllMocks();
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
  });
  it("rejects malformed or incomplete cold JSONL before branch projection", async () => {
    const fixture = await coldFixture("strict-search-jsonl");
    const admitted = await (fixture.registry as any).catalogSnapshot("user");
    await appendFile(fixture.sessionFile, "{}\\n");
    vi.spyOn(fixture.registry as any, "catalogSnapshot").mockResolvedValue(admitted);
    await expect(fixture.registry.readSearchCut(fixture.manager.getSessionId())).rejects.toMatchObject({ code: "invalid_request" });
    await appendFile(fixture.sessionFile, "{}");
    await expect(fixture.registry.readSearchCut(fixture.manager.getSessionId())).rejects.toMatchObject({ code: "invalid_request" });
  });

  it("fences canonical history reads to the exact live runtime", async () => {
    const fixture = await coldFixture("canonical-history");
    try {
      const entry = fixture.manager.appendMessage({ role: "user", content: "Full selected message", timestamp: 1 });
      const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
      const runtime = slot.snapshot().runtimeGeneration;
      expect(slot.history(runtime).nodes.find(node => node.id === entry)).toMatchObject({ role: "user", preview: "Full selected message" });
      expect(slot.historyDetail(runtime, entry, 0).text).toBe("Full selected message");
      expect(() => slot.history("retired-runtime")).toThrow(/runtime changed/);
      expect(() => slot.historyDetail("retired-runtime", entry, 0)).toThrow(/runtime changed/);
    } finally {
      await fixture.registry.dispose();
      registries.splice(registries.indexOf(fixture.registry), 1);
      await rm(fixture.root, { recursive: true, force: true });
    }
  });

  it("pages canonical subagent receipts through the live process history owner", async () => {
    const fixture = await coldFixture("process-history-pages");
    try {
      const sessionId = fixture.manager.getSessionId();
      const receipt: ExtensionActivityReceipt = {
        version: 1, activityId: "activity", sessionId, toolCallId: "tool", source: "extension", runId: "run", mode: "async", state: "completed",
        startedAt: "2026-01-01T00:00:00.000Z", terminalAt: "2026-01-01T00:00:01.000Z", observedAt: "2026-01-01T00:00:09.000Z", summary: { toolCount: 1 },
      };
      for (let index = 0; index < 5; index += 1) {
        const terminalAt = `2026-01-01T00:00:0${index + 1}.000Z`;
        fixture.manager.appendCustomEntry(EXTENSION_ACTIVITY_RECEIPT_TYPE, { ...receipt, activityId: `activity-${index}`, toolCallId: `tool-${index}`, runId: `run-${index}`, terminalAt });
      }
      const slot = await fixture.registry.acquire(sessionId);
      const terminals: string[] = [];
      const pages: number[] = [];
      let cursor: string | undefined;
      let revision: string | undefined;
      for (let pageIndex = 0; pageIndex < 5; pageIndex += 1) {
        const page = slot.processHistory(cursor, 2, { kind: "subagent" });
        expect(page.omissions).toBeUndefined();
        expect(page.activities.length).toBeGreaterThan(0);
        revision ??= page.historyRevision;
        expect(page.historyRevision).toBe(revision);
        pages.push(page.activities.length);
        for (const row of page.activities) {
          terminals.push(row.lifecycle.terminalAt!);
          expect(slot.processDetail(row.processId, page.historyRevision)).toEqual(row);
        }
        cursor = page.nextCursor;
        if (!cursor) break;
      }
      expect(cursor).toBeUndefined();
      expect(pages).toEqual([2, 2, 1]);
      expect(terminals).toEqual([5, 4, 3, 2, 1].map((second) => `2026-01-01T00:00:0${second}.000Z`));
      const first = slot.processHistory(undefined, 2, { kind: "subagent" });
      expect(() => slot.processHistory(first.nextCursor, 2, { kind: "command" })).toThrow(/cursor conflict/u);
      expect(() => slot.processDetail(first.activities[0]!.processId, "stale-revision")).toThrow(/generation changed/u);
    } finally {
      await fixture.registry.dispose();
      registries.splice(registries.indexOf(fixture.registry), 1);
      await rm(fixture.root, { recursive: true, force: true });
    }
  });

  it("publishes startup phases in catalog-before-attention order", async () => {
    const phases: string[] = [];
    await coldFixture("startup-phases", {
      phaseObserver: (phase) => phases.push(phase),
    });
    expect(phases).toEqual(["catalog-warming", "attention-recovery"]);
  });

  it("charges a queued request for the registry lane wait and keeps its admitted work on its own span", async () => {
    const fixture = await coldFixture("span-lane-contention");
    let now = 0;
    const clock = vi.spyOn(nodePerformance, "now").mockImplementation(() => now);
    try {
      const lane = (fixture.registry as unknown as {
        mutex: { run<T>(operation: () => Promise<T> | T): Promise<T> };
      }).mutex;
      const holder = new RequestSpan();
      const waiter = new RequestSpan();
      let entered!: () => void;
      const admitted = new Promise<void>((resolve) => { entered = resolve; });
      let release!: () => void;
      const held = new Promise<void>((resolve) => { release = resolve; });
      const holding = runInRequestSpan(holder, () => lane.run(async () => {
        entered();
        await held;
        await stage("holder.work", () => { now += 10; return Promise.resolve(); });
      }));
      await admitted;
      const waiting = runInRequestSpan(waiter, () => lane.run(async () => {
        await stage("waiter.work", () => { now += 5; return Promise.resolve(); });
      }));
      now += 40;
      release();
      await Promise.all([holding, waiting]);

      expect(holder.breakdown(50)!.stages).toBe("holder.work=10ms");
      const queued = waiter.breakdown(55)!;
      expect(queued.stages).toBe("registry.mutex=50ms;waiter.work=5ms");
      expect(queued.unaccountedMs).toBe(0);
    } finally {
      clock.mockRestore();
      await fixture.registry.dispose();
      registries.splice(registries.indexOf(fixture.registry), 1);
      await rm(fixture.root, { recursive: true, force: true });
    }
  });

  it("owns one exact live session for a workspace Automation operation", async () => {
    const changed = vi.fn();
    const fixture = await coldFixture("automation-exact-session", { sessionListChanged: changed, maximumLiveRuntimes: 1 });
    const sessionId = "20000000-0000-4000-8000-000000000010";
    const operationId = "automation:20000000-0000-4000-8000-000000000011";
    const automationId = "20000000-0000-4000-8000-000000000013";

    const first = await fixture.registry.createAutomationSession(
      fixture.cwd,
      sessionId,
      operationId,
      automationId,
    );
    expect(first.slot.id).toBe(sessionId);
    expect((await fixture.registry.list("user")).find((session) => session.id === sessionId))
      .toMatchObject({ creationOrigin: { kind: "automation", automationId } });
    (first.slot as unknown as { sessionManager: SessionManager }).sessionManager
      .appendMessage(fauxAssistantMessage("persisted automation"));
    first.release();
    const second = await fixture.registry.createAutomationSession(
      fixture.cwd,
      sessionId,
      operationId,
      automationId,
    );
    expect(second.slot === first.slot).toBe(true);
    await expect(fixture.registry.createAutomationSession(
      fixture.cwd,
      sessionId,
      "automation:20000000-0000-4000-8000-000000000012",
      automationId,
    )).rejects.toMatchObject({ code: "conflict" });

    second.release();
    expect(changed).toHaveBeenCalled();
  });

  it("recovers Automation session creation origin from the first canonical invocation binding", async () => {
    const fixture = await coldFixture("automation-cold-origin");
    const sessionId = "20000000-0000-4000-8000-000000000020";
    const automationId = "20000000-0000-4000-8000-000000000021";
    const invocationId = "20000000-0000-4000-8000-000000000022";
    const operationId = "automation:20000000-0000-4000-8000-000000000023";
    const generated = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile), { id: sessionId });
    generated.appendCustomEntry(INVOCATION_RECEIPT_TYPE, makeInvocationReceipt({
      version: 1, receiptId: `start:${invocationId}`, receiptKind: "start", invocationId,
      operationId, sessionId, source: "plain", lifecycle: "staged",
      origin: { kind: "gateway", ownerId: automationId, title: "Automation", confidence: "boundary" },
      sequence: 1, createdAt: "2026-01-01T00:00:00.000Z",
    }));
    generated.appendCustomEntry(INVOCATION_RECEIPT_TYPE, makeInvocationReceipt({
      version: 1, receiptId: `accepted:${invocationId}`, receiptKind: "transition", invocationId,
      operationId, sessionId, source: "plain", lifecycle: "accepted",
      sequence: 2, createdAt: "2026-01-01T00:00:00.100Z",
    }));
    const user = generated.appendMessage({ role: "user", content: "scheduled prompt", timestamp: 1 });
    generated.appendCustomEntry(INVOCATION_RECEIPT_TYPE, makeInvocationReceipt({
      version: 1, receiptId: `binding:${invocationId}`, receiptKind: "binding", invocationId,
      operationId, sessionId, source: "plain", canonicalEntryId: user,
      sequence: 3, createdAt: "2026-01-01T00:00:00.200Z",
    }));
    generated.appendMessage(fauxAssistantMessage("completed Automation response"));
    generated.appendCustomEntry(INVOCATION_RECEIPT_TYPE, makeInvocationReceipt({
      version: 1, receiptId: `terminal:${invocationId}`, receiptKind: "terminal", invocationId,
      operationId, sessionId, source: "plain", lifecycle: "completed",
      sequence: 4, createdAt: "2026-01-01T00:00:00.300Z",
    }));

    await fixture.registry.dispose();
    registries.splice(registries.indexOf(fixture.registry), 1);
    const cold = await createTestRegistry({
      agentDir: fixture.agentDir,
      tronHome: join(fixture.root, "tron-cold"),
      idleRuntimeMs: 60_000,
      workRegistry: new GatewayWorkRegistry(),
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(fixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(cold);
    await initializeRegistry(cold);

    expect((await cold.list("user")).find((session) => session.id === sessionId))
      .toMatchObject({ creationOrigin: { kind: "automation", automationId } });
    await cold.list("all");
    const indexPath = join(fixture.root, "tron-cold", "cache", "catalog-metadata-v3", "manifest.json");
    await settleCatalog(cold);
    expect(existsSync(indexPath)).toBe(true);
    await cold.dispose();
    registries.splice(registries.indexOf(cold), 1);

    const indexed = await createTestRegistry({
      agentDir: fixture.agentDir,
      tronHome: join(fixture.root, "tron-cold"),
      idleRuntimeMs: 60_000,
      workRegistry: new GatewayWorkRegistry(),
      modelRuntimeFactory: async () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false }),
      trust: new TrustService(fixture.agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(indexed);
    await initializeRegistry(indexed);
    await settleCatalog(indexed);
    const walks = catalogWalks();
    expect((await indexed.list("user")).find((session) => session.id === sessionId))
      .toMatchObject({ creationOrigin: { kind: "automation", automationId } });
    expect(walks.count()).toBe(0);
    walks.restore();
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

  it("latches foreground-open and foreground-close completion dispositions at canonical admission", async () => {
    const root = await temporaryRoot("tron-agent-observed-completion-");
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
    const suppressAutomatic = vi.fn(async () => "suppressed" as const);
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      machineId: "machine-observed-test",
      notifications: { enqueue, suppressAutomatic, markSessionInboxRead: vi.fn(async () => {}) } as unknown as NotificationService,
    });
    registries.push(registry);
    await initializeRegistry(registry);
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
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    await waitFor(() => registry.attentionProjection(slot.id).completionRevision === 1, "the first completion revision");
    expect(registry.attentionProjection(slot.id)).toMatchObject({ completionRevision: 1, isUnread: false });
    await waitFor(() => suppressAutomatic.mock.calls.length > 0, "the suppressed automatic title refresh");
    expect(enqueue).not.toHaveBeenCalled();
    expect(suppressAutomatic).toHaveBeenCalledWith({
      sessionId: slot.id,
      sourceId: expect.any(String),
      kind: "agent_finished",
    });

    enqueue.mockClear();
    suppressAutomatic.mockClear();
    await slot.prompt("finish after presentation closes");
    await waitFor(() => slot.isBusy, "the slot to take work");
    registry.setPresentationVisibility({
      clientId: "visible-phone",
      sessionId: slot.id,
      subscriptionToken: "visible-subscription",
      revision: 2,
      visible: false,
    });
    releaseHiddenCompletion();
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    await waitFor(() => registry.attentionProjection(slot.id).completionRevision === 2, "the second completion revision");
    expect(registry.attentionProjection(slot.id)).toMatchObject({ completionRevision: 2, isUnread: true });
    await waitFor(() => enqueue.mock.calls.length > 0, "the enqueued title refresh");
    expect(enqueue).toHaveBeenCalledWith(expect.objectContaining({
      sessionId: slot.id,
      kind: "agent_finished",
      sourceId: expect.any(String),
    }));
    expect(suppressAutomatic).not.toHaveBeenCalled();
  });

  it("recovers a canonical successful completion missed before restart", async () => {
    const fixture = await coldFixture("attention-restart");
    expect(fixture.registry.attentionProjection(fixture.manager.getSessionId()).isUnread).toBe(false);
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

    const restarted = await createTestRegistry({
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
    await initializeRegistry(restarted);
    await restarted.recoverCanonicalAttention();
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

    const restarted = await createTestRegistry({
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
    await initializeRegistry(restarted);
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

    const restarted = await createTestRegistry({
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
    await initializeRegistry(restarted);
    await restarted.recoverCanonicalAttention();
    expect(restarted.attentionProjection(sessionId)).toMatchObject({ completionRevision: 1, isUnread: true });

    await restarted.dispose();
    fixture.manager.appendMessage(fauxAssistantMessage("still markerless"));
    const secondRestart = await createTestRegistry({
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
    await initializeRegistry(secondRestart);
    expect(secondRestart.attentionProjection(sessionId).completionRevision).toBe(1);
  });

  it("resolves attention membership without materializing the full catalog", async () => {
    const fixture = await coldFixture("attention-scoped-resolution");
    const catalog = vi.spyOn(fixture.registry, "catalog");
    const projection = await fixture.registry.setAttention(fixture.manager.getSessionId(), true);
    expect(projection.isUnread).toBe(true);
    expect(catalog).not.toHaveBeenCalled();
  });

  it("excludes only the deleting RPC owner while preserving live child-work deletion safety", async () => {
    const fixture = await coldFixture("delete-own-rpc-work", { workRegistry: new GatewayWorkRegistry() });
    const session = await fixture.registry.create(fixture.cwd);
    const works = fixture.registry.administrativeWorkRegistry;
    const deleteRPC = works.begin({
      kind: "rpc-mutation", method: "session.delete", sessionId: session.id, hostEpoch: works.runtimeEpoch,
    });
    const child = works.begin({ kind: "foreground-agent-operation", sessionId: session.id, hostEpoch: works.runtimeEpoch });
    try {
      await expect(fixture.registry.delete(session.id, deleteRPC.token)).rejects.toMatchObject({ code: "busy", diagnosticReason: "session_operation_busy" });
    } finally { child.settle(); }
    await expect(fixture.registry.delete(session.id, deleteRPC.token)).resolves.toBeUndefined();
    deleteRPC.settle();
    expect((await fixture.registry.catalog("user")).sessions.some(entry => entry.id === session.id)).toBe(false);
  });

  it("acknowledges attention for a live persisted session without walking catalog headers", async () => {
    const fixture = await coldFixture("attention-live-owner");
    const sessionId = fixture.manager.getSessionId();
    const slot = await fixture.registry.acquire(sessionId);
    expect(slot.persistedSessionFile).toBeDefined();
    const evidence = vi.spyOn(fixture.registry as any, "catalogStructureEvidence");
    await expect(fixture.registry.setAttention(sessionId, true)).resolves.toMatchObject({ isUnread: true });
    await expect(fixture.registry.setAttention(sessionId, false, 0)).resolves.toMatchObject({ isUnread: false });
    expect(evidence).not.toHaveBeenCalled();

    await fixture.registry.delete(sessionId);
    await expect(fixture.registry.setAttention(sessionId, true)).rejects.toMatchObject({ code: "not_found" });
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
    const root = await temporaryRoot("tron-live-empty-catalog-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let listChanges = 0;
    const registry = await createTestRegistry({
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
    await initializeRegistry(registry);
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
    await catalogOwner(registry).refresh(persistedSlot.persistedSessionFile!);
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

    const fresh = await createTestRegistry({
      agentDir,
      tronHome: join(root, "fresh-tron"),
      idleRuntimeMs: 60_000,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(fresh);
    await initializeRegistry(fresh);
    const freshIDs = (await fresh.catalog("user")).sessions.map((session) => session.id);
    expect(freshIDs).toContain(persistedSlot.id);
    expect(freshIDs).not.toContain(evictedSlot.id);
  });

  it("fails closed when a canonical file collides with a live-only slot", async () => {
    const root = await temporaryRoot("tron-live-empty-collision-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const registry = await createTestRegistry({
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
    await initializeRegistry(registry);
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

    await settleCatalog(registry);
    const afterCollision = await registry.catalog("all");
    expect(afterCollision.sessions.map((session) => session.id)).not.toContain(slot.id);
    expect(afterCollision.listRevision).toBeGreaterThan(beforeCollision.listRevision);
    await expect(registry.acquire(slot.id)).rejects.toMatchObject({ code: "conflict" });
  });

  it("publishes the first prompt as the live session title before the agent settles", async () => {
    const root = await temporaryRoot("tron-live-session-title-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const faux = fauxProvider({ provider: "tron-live-session-title", tokensPerSecond: 10_000 });
    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    faux.setResponses([async () => {
      await responseBarrier;
      return fauxAssistantMessage("title published");
    }]);
    runtime.registerNativeProvider(faux.provider);
    const summaries: SessionSummaryUpdate[] = [];
    const registry = await createTestRegistry({
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
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    await slot.prompt("Update this title immediately");
    try {
      await waitFor(() => summaries.some((summary) => summary.firstMessage === "Update this title immediately"), "the immediate title summary");

      expect(slot.isBusy).toBe(true);
      expect(summaries.at(-1)).toMatchObject({
        phase: "running",
        messageCount: 1,
        firstMessage: "Update this title immediately",
      });
      expect((await registry.catalog("user")).sessions.find((summary) => summary.id === slot.id)).toMatchObject({
        messageCount: 1,
        firstMessage: "Update this title immediately",
      });
    } finally {
      releaseResponse();
    }
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(summaries.at(-1)).toMatchObject({
      phase: "idle",
      messageCount: 2,
      firstMessage: "Update this title immediately",
    });
  });

  it("folds summary facts from appended entries and rebuilds when the entry set is replaced", async () => {
    const fixture = await coldFixture("summary-fold");
    try {
      const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
      const manager = (slot as unknown as { sessionManager: SessionManager }).sessionManager;
      await waitFor(() => fixture.summaries.length > 0, "the first session summary");
      const before = fixture.summaries.at(-1)!;
      const beforeAt = Date.parse(before.updatedAt);

      manager.appendMessage({ role: "user", content: "folded prompt", timestamp: beforeAt + 1_000 });
      await slot.rename("fold one");
      await waitFor(() => fixture.summaries.at(-1)!.messageCount === before.messageCount + 1, "the summary after one message");
      expect(fixture.summaries.at(-1)).toMatchObject({
        firstMessage: "folded prompt",
        updatedAt: new Date(beforeAt + 1_000).toISOString(),
      });

      manager.appendMessage({ role: "user", content: "second prompt", timestamp: beforeAt + 2_000 });
      await slot.rename("fold two");
      await waitFor(() => fixture.summaries.at(-1)!.messageCount === before.messageCount + 2, "the summary after two messages");
      expect(fixture.summaries.at(-1)).toMatchObject({
        firstMessage: "folded prompt",
        updatedAt: new Date(beforeAt + 2_000).toISOString(),
      });

      const replacementDirectory = join(fixture.root, "replacement-sessions");
      await mkdir(replacementDirectory, { recursive: true });
      const replacement = SessionManager.create(fixture.cwd, replacementDirectory);
      replacement.appendMessage({ role: "user", content: "replacement prompt", timestamp: beforeAt + 5_000 });
      replacement.appendMessage(fauxAssistantMessage("replacement answer"));
      manager.setSessionFile(replacement.getSessionFile()!);
      await slot.rename("fold three");
      await waitFor(() => fixture.summaries.at(-1)!.firstMessage === "replacement prompt", "the summary of the replacement prompt");
      expect(fixture.summaries.at(-1)).toMatchObject({
        messageCount: 2,
        updatedAt: new Date(beforeAt + 5_000).toISOString(),
      });
    } finally {
      await fixture.registry.dispose();
      registries.splice(registries.indexOf(fixture.registry), 1);
      await rm(fixture.root, { recursive: true, force: true });
    }
  });

  it("never rebroadcasts a snapshot already covered by an immediate publication", async () => {
    const root = await temporaryRoot("tron-duplicate-snapshot-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const faux = fauxProvider({ provider: "tron-duplicate-snapshot", tokensPerSecond: 400 });
    faux.setResponses([fauxAssistantMessage("streamed reply ".repeat(12))]);
    runtime.registerNativeProvider(faux.provider);
    const snapshots: any[] = [];
    const configurationEvents: any[] = [];
    const registry = await createTestRegistry({
      agentDir,
      tronHome: join(root, "tron"),
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: (_id, topic, payload) => {
        if (topic === "session.snapshot") snapshots.push(payload);
        if (topic === "session.configuration") configurationEvents.push(payload);
      },
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
    });
    registries.push(registry);
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    subscribeAudience(registry, slot.id);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    const state = ({ eventSequence: _sequence, ...rest }: any) => JSON.stringify(rest);

    const before = snapshots.length;
    const receipt = await slot.prompt("duplicate snapshot owner");
    const midAdmission = slot.snapshot();
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    await new Promise((resolve) => setTimeout(resolve, 60));

    const published = snapshots.slice(before);
    for (let index = 1; index < published.length; index += 1) {
      expect(state(published[index]), `snapshot ${published[index].eventSequence} repeats its predecessor`)
        .not.toBe(state(published[index - 1]));
    }
    const final = slot.snapshot();
    expect(final.phase).toBe("idle");
    expect(final.pendingPrompt).toBeUndefined();
    expect(final.transcript.find((item: any) => item.role === "user")?.presentationId).toBe(receipt.operationId);
    const projected = (snapshot: any) => configurationEvents
      .filter(event => event.runtimeGeneration === snapshot.runtimeGeneration && event.eventSequence > snapshot.eventSequence)
      .reduce((current, event) => ({ ...current, configurationBlocker: event.data.configurationBlocker }), snapshot);
    expect(state(projected(published.at(-1)))).toBe(state(final));
    const lateSubscriberFrames = published.filter((snapshot) => snapshot.eventSequence > midAdmission.eventSequence);
    expect(lateSubscriberFrames.length).toBeGreaterThan(0);
    expect(state(projected(lateSubscriberFrames.at(-1)))).toBe(state(final));
  });

  it("keeps row-summary revisions separate and lists phase without transcript snapshots", async () => {
    const root = await temporaryRoot("tron-catalog-summary-revision-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const faux = fauxProvider({ provider: "tron-catalog-boundary", tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("catalog ready")]);
    runtime.registerNativeProvider(faux.provider);
    const summaries: SessionSummaryUpdate[] = [];
    let listChanges = 0;
    const registry = await createTestRegistry({
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
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt(`catalog boundary ${"x".repeat(5_000)}`);
    await waitFor(() => !slot.isBusy, "the slot to go idle");
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
    expect(snapshot.mock.calls.filter((arguments_) => arguments_.length === 0)).toHaveLength(0);
  });
});
