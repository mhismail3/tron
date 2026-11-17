import { upsertExtensionActivity, publishExtensionActivity, updateExtensionActivity, appendExtensionActivityReceipt, canonicalExtensionRunFacts, trimExtensionActivities } from "../../kernel/delegation/subagent-activity.js";
import { refreshExtensionActivityFromArtifact, refreshSubagentActivityFromArtifact } from "../../kernel/delegation/subagent-artifact-reconcile.js";
import { createTestRegistry } from "../../../test-support/gateway-registry.js";
import type { RunPersistence } from "../../kernel/run/run-persistence.js";
import { performance as nodePerformance } from "node:perf_hooks";
import * as fsPromises from "node:fs/promises";
import { mkdir, readFile, realpath, rename, rm, symlink, truncate, writeFile } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { AsyncLocalStorage } from "node:async_hooks";
import { fileURLToPath } from "node:url";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../../kernel/resources/trust-service.js";
import type { ExtensionRunActivity, ExtensionToolOrigin, SessionSummaryUpdate } from "../../protocol/types.js";
import { GatewayWorkRegistry } from "../../kernel/run/gateway-work-registry.js";
import { INVOCATION_RECEIPT_TYPE, makeInvocationReceipt } from "../../kernel/receipts/invocation-receipts.js";
import { EXTENSION_ACTIVITY_RECEIPT_TYPE } from "../../kernel/receipts/extension-activity-history.js";
import {
  RuntimeRegistry,
} from "../../kernel/session/runtime-registry.js";
import type { ExtensionArtifactDiscoveryCounts } from "../../sessions/extension-artifact-discovery.js";
import { awaitsWithin, waitFor } from "../../../test-support/wait-for.js";
import { createColdRegistryFixture, initializeRegistry, settleCatalog, temporaryRoot } from "../../../test-support/runtime-registry-fixture.js";
const statusJsonReplace = vi.hoisted(() => ({
  armed: false,
  replacements: 0,
  losses: 0,
  payload: "",
  statusPath: "",
  tempPath: "",
  insideRetryInvocation: (): boolean => false,
}));

const quarantineLock = vi.hoisted(() => ({ armed: false, directory: "" }));

vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...actual,
    rm: async (path: Parameters<typeof actual.rm>[0], ...rest: unknown[]) => {
      if (quarantineLock.armed && String(path).includes(".tron-delete-")) {
        quarantineLock.armed = false;
        quarantineLock.directory = dirname(String(path));
        await actual.chmod(quarantineLock.directory, 0o500);
      }
      return (actual.rm as unknown as (target: unknown, ...args: unknown[]) => Promise<void>)(path, ...rest);
    },
    open: async (path: Parameters<typeof actual.open>[0], ...rest: unknown[]) => {
      const handle = await (actual.open as unknown as (target: unknown, ...args: unknown[]) => Promise<unknown>)(path, ...rest);
      if (statusJsonReplace.armed && statusJsonReplace.losses === 0
        && statusJsonReplace.insideRetryInvocation() && String(path) === statusJsonReplace.statusPath) {
        statusJsonReplace.losses += 1;
        await actual.writeFile(statusJsonReplace.tempPath, statusJsonReplace.payload);
        await actual.rename(statusJsonReplace.tempPath, statusJsonReplace.statusPath);
        statusJsonReplace.replacements += 1;
      }
      return handle;
    },
  };
});

function projectedExtensionActivity(activities: ExtensionRunActivity[] | undefined, toolCallId: string): ExtensionRunActivity {
  const activity = activities?.find((candidate) => candidate.toolCallId === toolCallId);
  if (!activity) throw new Error(`no extension activity projected for ${toolCallId}`);
  return activity;
}

const DISCOVERY_PASS_LIMIT = 8;

async function discoverExtensionArtifactsUntil(
  registry: RuntimeRegistry,
  settled: () => boolean = () => true,
  passLimit = DISCOVERY_PASS_LIMIT,
): Promise<number> {
  const state = registry as unknown as { artifactDiscoveryInFlight: Promise<void> | undefined };
  let passes = 0;
  await waitFor(async () => {
    if (state.artifactDiscoveryInFlight) return false;
    await (registry as unknown as { discoverExtensionArtifacts: () => Promise<void> }).discoverExtensionArtifacts();
    passes += 1;
    return settled() || passes >= passLimit;
  }, "extension artifact discovery to settle");
  return passes;
}

describe("RuntimeRegistry with the pinned agent runtime", { concurrent: false }, () => {
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  const registries: RuntimeRegistry[] = [];
  const syntheticTranscriptSizes = new Map<string, number>();

  const coldFixture = createColdRegistryFixture.bind(undefined, registries);

  async function delegatedFixtureRoot(label: string): Promise<{ root: string; delegatedRoot: string }> {
    const root = await realpath(await temporaryRoot(`tron-delegated-${label}-`));
    const delegatedRoot = join(root, "delegated");
    await mkdir(delegatedRoot, { recursive: true, mode: 0o700 });
    return { root, delegatedRoot };
  }

  afterEach(async () => {
    try {
      const transcripts = [...syntheticTranscriptSizes];
      await Promise.all(transcripts.map(([path, size]) => truncate(path, size)));
      for (const [path, size] of transcripts) {
        expect((await fsPromises.stat(path)).size).toBe(size);
      }
      syntheticTranscriptSizes.clear();
    } finally {
      await Promise.all(registries.splice(0).map((registry) => registry.dispose()));
      vi.restoreAllMocks();
      if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
    }
  });
  it("runs distinct sessions concurrently and keeps a run alive after its client disconnects", async () => {
    const root = await temporaryRoot("tron-runtime-integration-");
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

    const registry = await createTestRegistry({
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
    await initializeRegistry(registry);

    const [first, second] = await Promise.all([registry.create(firstCwd), registry.create(secondCwd)]);
    expect(first.modelRuntime).not.toBe(second.modelRuntime);
    expect(runtimes).toHaveLength(2);
    const model = faux.getModel();
    await Promise.all([first.setModel(model.provider, model.id), second.setModel(model.provider, model.id)]);
    registry.subscribe("phone", first.id);
    registry.subscribe("phone", second.id);

    await Promise.all([first.prompt("one"), second.prompt("two")]);
    await waitFor(() => first.isBusy && second.isBusy && faux.state.callCount === 2, "both slots running their first turn");
    expect(faux.state.callCount).toBe(2);
    expect(summaryUpdates).toEqual(expect.arrayContaining([
      expect.objectContaining({
        sessionId: first.id, phase: "running", foregroundPhase: "running", hasActiveSubagents: false,
      }),
      expect.objectContaining({
        sessionId: second.id, phase: "running", foregroundPhase: "running", hasActiveSubagents: false,
      }),
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

    await waitFor(() => !first.isBusy && !second.isBusy, "both slots to go idle");
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
    const root = await temporaryRoot("tron-restart-queue-drain-");
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
    const registry = await createTestRegistry({
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
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("first");
    await waitFor(() => slot.isBusy, "the slot to take work");
    const queued = await slot.prompt("accepted follow up", [], "followUp");
    expect(slot.snapshot().queuedItems).toMatchObject([{ id: queued.operationId, behavior: "followUp" }]);
    let drained = false;
    const drain = registry.waitUntilIdle().then(() => { drained = true; });
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(drained).toBe(false);
    expect(slot.snapshot().queuedItems).toHaveLength(1);
    releaseFirst();
    await waitFor(() => faux.state.callCount === 2, "the second model call");
    await drain;
    expect(drained).toBe(true);
    expect(slot.snapshot().queuedItems).toEqual([]);
    expect(slot.snapshot().transcript.some((item) => item.kind === "message" && item.role === "assistant"
      && item.content.some((part) => part.type === "text" && part.text.includes("queued complete")))).toBe(true);
  });

  it("settles foreground completion without a second derived token", async () => {
    const root = await temporaryRoot("tron-completion-capacity-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    let releaseResponse!: () => void;
    const responseBarrier = new Promise<void>((resolve) => { releaseResponse = resolve; });
    const faux = fauxProvider({ provider: "tron-completion-capacity", tokensPerSecond: 10_000 });
    faux.setResponses([async () => { await responseBarrier; return fauxAssistantMessage("complete"); }]);
    const workRegistry = new GatewayWorkRegistry("epoch", 4);
    const registry = await createTestRegistry({
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
    await initializeRegistry(registry);
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);
    await slot.prompt("finish while derived capacity is full");
    await waitFor(() => slot.catalogPhase === "running", "the catalog phase to run");
    const derived = [0, 1].map(() => workRegistry.beginDerived({
      kind: "administrative-provider-package-operation",
      hostEpoch: workRegistry.runtimeEpoch,
    }));

    releaseResponse();
    await waitFor(() => slot.catalogPhase === "idle", "the catalog phase to go idle");
    expect(workRegistry.facts().filter((fact) => fact.sessionId === slot.id)).toEqual([]);
    for (const owner of derived) owner.settle();
  });

  it("includes runtime creation admitted before administrative drain", async () => {
    const root = await temporaryRoot("tron-restart-create-drain-");
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
    const registry = await createTestRegistry({
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
    await initializeRegistry(registry);

    const creating = registry.create(cwd);
    try {
      await trustEntered;
      expect(registry.administrativeDrainSnapshot().blockerCount).toBe(1);
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
      await expect(registry.create(cwd)).rejects.toMatchObject({ code: "busy", retryable: true });
      expect(drainSettled).toBe(false);
      expect(registry.administrativeDrainSnapshot().blockerCount).toBe(1);

      releaseTrust();
      const slot = await creating;
      await drain;
      expect(drainSettled).toBe(true);
      expect(slot.isDrainBusy).toBe(false);
      await expect(slot.prompt("post-cutoff prompt")).rejects.toMatchObject({ code: "busy" });
      expect(slot.snapshot().queuedItems).toEqual([]);
      expect(registry.administrativeDrainSnapshot()).toMatchObject({ phase: "complete", blockerCount: 0 });
    } finally { releaseTrust(); await creating.catch(() => {}); }
  });

  it("publishes detached extension work as current dashboard activity", async () => {
    const fixture = await coldFixture("detached-dashboard-activity");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const beforeActivity = await fixture.registry.catalog("user");
    const internal = slot.ownedTurns;
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
    slot.phase = "running";
    slot.publishSnapshot();
    expect(fixture.summaries.at(-1)).toMatchObject({
      sessionId: slot.id,
      phase: "running",
      foregroundPhase: "running",
      hasActiveSubagents: false,
    });

    internal.extensionActivities.set(running.toolCallId, running);
    upsertExtensionActivity(internal, running);
    publishExtensionActivity(internal, running);
    expect(fixture.summaries.at(-1)).toMatchObject({
      sessionId: slot.id,
      phase: "running",
      foregroundPhase: "running",
      hasActiveSubagents: true,
    });

    slot.phase = "idle";
    slot.publishSnapshot();
    const active = fixture.summaries.at(-1)!;
    expect(active).toMatchObject({
      sessionId: slot.id,
      phase: "running",
      foregroundPhase: "idle",
      hasActiveSubagents: true,
    });
    expect(active.activeSince).toBeDefined();
    expect(Date.parse(active.updatedAt)).toBeGreaterThan(Date.parse(startedAt));
    await new Promise((resolve) => setTimeout(resolve, 2));
    slot.publishActivityHeartbeat();
    const heartbeat = fixture.summaries.at(-1)!;
    expect(Date.parse(heartbeat.updatedAt)).toBeGreaterThan(Date.parse(active.updatedAt));
    expect(heartbeat.activeSince).toBe(active.activeSince);
    const activeCatalog = await fixture.registry.catalog("user");
    expect(activeCatalog.listRevision).toBe(beforeActivity.listRevision);
    expect(activeCatalog.sessions[0]).toMatchObject({
      id: slot.id,
      phase: "running",
      foregroundPhase: "idle",
      hasActiveSubagents: true,
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
    upsertExtensionActivity(internal, completed);
    publishExtensionActivity(internal, completed);
    expect(fixture.summaries.at(-1)).toMatchObject({
      sessionId: slot.id,
      phase: "idle",
      foregroundPhase: "idle",
      hasActiveSubagents: false,
    });
    expect(fixture.summaries.at(-1)!.activeSince).toBeUndefined();
    expect(Date.parse(fixture.summaries.at(-1)!.updatedAt))
      .toBeGreaterThanOrEqual(Date.parse(heartbeat.updatedAt));

    const settledRecency = fixture.summaries.at(-1)!.updatedAt;
    internal.extensionActivityAsOf = new Date(Date.parse(settledRecency) + 60_000).toISOString();
    const staleTerminal = {
      ...completed,
      updatedAt: startedAt,
      lifecycle: {
        ...completed.lifecycle!,
        observedAt: startedAt,
        terminalAt: startedAt,
        recentUntil: startedAt,
      },
    };
    publishExtensionActivity(internal, staleTerminal);
    expect(fixture.summaries.at(-1)!.updatedAt).toBe(settledRecency);
    slot.publishActivityHeartbeat();
    expect(fixture.summaries.at(-1)!.updatedAt).toBe(settledRecency);
  });

  it.each(["complete", "failed"] as const)("reconciles an exact-owned historical %s artifact during administrative drain", async (terminalState) => {
    const fixture = await coldFixture("historical-terminal-drain");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = "historical-terminal-run";
    const toolCallId = "historical-terminal-tool";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    const startedAt = new Date(Date.now() - 5_000).toISOString();
    const internal = slot.ownedTurns;
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
    slot.ownedTurns.stopExtensionActivityWatcher(toolCallId);
    expect(drainSettled).toBe(false);

    const endedAt = Date.now();
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
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

  it("drains an exact-owned paused workflow only after observed process-terminal proof", async () => {
    const fixture = await coldFixture("paused-process-terminal-drain");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = "paused-process-terminal-run";
    const toolCallId = "paused-process-terminal-tool";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    const started = Date.now() - 5_000;
    const internal = slot.ownedTurns;
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId,
      activityId: "paused-process-terminal-activity",
      runId,
      toolCallId,
      source: { source: "pi-subagents" },
      title: "Pi Subagents",
      status: "running",
      startedAt: new Date(started).toISOString(),
      updatedAt: new Date(started + 1_000).toISOString(),
      children: [],
      lifecycle: {
        version: 1,
        state: "paused",
        attention: "needsAttention",
        sequence: 1,
        observedAt: new Date(started + 1_000).toISOString(),
      },
    });
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    await Promise.all([
      writeFile(join(asyncDir, "status.json"), JSON.stringify({
        lifecycleProjection: {
          version: 1, runId, generatedAt: started + 1_001,
          caps: { maxRuns: 1, maxChildrenPerNode: 8, maxDepth: 3, maxStringLength: 160, maxSerializedBytes: 30_720 },
          omitted: { runs: 0, children: 0, byteLimitExceeded: false },
          root: { id: runId, kind: "workflow", label: "paused workflow", state: "paused", startedAt: started, updatedAt: started + 1_001, endedAt: started + 1_000 },
        },
        lifecycleArtifactVersion: 3, runId, state: "paused", startedAt: started, endedAt: started + 1_000, lastUpdate: started + 1_001,
      })),
      writeFile(join(asyncDir, "process-terminal.json"), JSON.stringify({
        version: 1,
        state: "pending",
        runId,
        runnerProcessInstanceId: "runner-instance",
      })),
    ]);

    const drain = fixture.registry.waitUntilIdle();
    let drained = false;
    void drain.then(() => { drained = true; });
    await new Promise((resolve) => setTimeout(resolve, 50));
    internal.stopExtensionActivityWatcher(toolCallId);
    expect(drained).toBe(false);
    expect(fixture.registry.administrativeDrainSnapshot()).toMatchObject({
      phase: "waiting",
      blockerCount: 1,
      blockerCounts: { "detached-extension-run": 1 },
    });

    await writeFile(join(asyncDir, "process-terminal.json"), JSON.stringify({
      version: 1,
      state: "observed",
      runId,
      runnerProcessInstanceId: "runner-instance",
      observedAt: started + 1_500,
      instances: [{
        kind: "runner",
        processInstanceId: "runner-instance",
        closeObservedAt: started + 1_500,
        exitCode: 0,
        signal: null,
      }],
      resumeDisposition: "resumable",
    }));
    await slot.ownedTurns.discoverExtensionArtifact(asyncDir);
    expect(internal.extensionRunOwnership.get(runId)?.pausedProcessQuiescentAt)
      .toBe(new Date(started + 1_500).toISOString());

    await drain;
    expect(slot.isDrainBusy).toBe(false);
    expect(fixture.registry.administrativeDrainSnapshot()).toMatchObject({
      phase: "complete", blockerCount: 0, suspectProjectionCount: 0,
    });
    expect(slot.snapshot().extensionActivities).toMatchObject([{
      toolCallId,
      status: "running",
      lifecycle: { state: "paused" },
    }]);
  });

  it.each(["recovered", "live-source", "foreign-owner", "unobserved-process"] as const)("admits exact auto-recovery handoff: %s", async (scenario) => {
    const fixture = await coldFixture("recovered-replacement-settlement");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const manager = (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } }).runtime.session.sessionManager;
    const sourceRunId = "recovered-source-run";
    const replacementRunId = "recovered-replacement-run";
    const sourceToolCallId = "recovered-source-tool";
    const recoveryToolCallId = "recovered-steering-tool";
    const sourceDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", sourceRunId);
    const replacementDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", replacementRunId);
    await mkdir(sourceDir, { recursive: true });
    await mkdir(replacementDir, { recursive: true });
    const providerOrigin = { source: "pi-subagents", owner: { id: "installed-provider" } };
    vi.spyOn(slot.ownedTurns, "subagentExtensionOrigin")
      .mockReturnValue(providerOrigin);
    vi.spyOn(slot as unknown as { extensionToolOrigin: (name: string) => typeof providerOrigin | undefined }, "extensionToolOrigin")
      .mockReturnValue(scenario === "foreign-owner" ? { ...providerOrigin, owner: { id: "project-impostor" } } : providerOrigin);
    manager.appendMessage({
      role: "toolResult", toolCallId: sourceToolCallId, toolName: "subagent",
      content: [{ type: "text", text: "launched" }],
      details: { runId: sourceRunId, asyncId: sourceRunId, asyncDir: sourceDir, mode: "single", results: [] },
      isError: false, timestamp: Date.now(),
    });
    manager.appendMessage({
      role: "toolResult", toolCallId: recoveryToolCallId, toolName: "subagent",
      content: [{ type: "text", text: "recovered" }],
      details: {
        mode: "management", results: [],
        steering: {
          state: "recovered", deliveryStatus: "delivered", sourceRunId, replacementRunId,
          targets: [{ index: 0, state: "recovered", replacementRunId }],
        },
      },
      isError: false, timestamp: Date.now(),
    });
    const internal = slot.ownedTurns;
    const started = Date.now() - 5_000;
    const recoveredAt = started + 3_000;
    internal.extensionActivities.set(sourceToolCallId, {
      id: sourceToolCallId, activityId: "recovered-source-activity", runId: sourceRunId, toolCallId: sourceToolCallId,
      source: { source: "pi-subagents" }, title: "Pi Subagents", status: "running",
      startedAt: new Date(started).toISOString(), updatedAt: new Date(started + 1_000).toISOString(), children: [],
      lifecycle: { version: 1, state: "paused", attention: "needsAttention", sequence: 1, observedAt: new Date(started + 1_000).toISOString() },
    });
    internal.extensionRunOwnership.set(sourceRunId, { toolCallId: sourceToolCallId, asyncDir: sourceDir, terminal: false });
    await writeFile(join(sourceDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3, runId: sourceRunId, state: scenario === "live-source" ? "running" : "paused", startedAt: started, endedAt: started + 1_000, lastUpdate: started + 2_000,
      steps: [{ index: 0, agent: "worker", status: "paused" }],
      steering: { recent: [{ targets: [{ state: "recovered", replacementRunId, recoveredAt }] }] },
    }));
    await writeFile(join(sourceDir, "process-terminal.json"), JSON.stringify({
      version: 1, state: scenario === "unobserved-process" ? "pending" : "observed", runId: sourceRunId, runnerProcessInstanceId: "source-runner", observedAt: started + 1_500,
      instances: [{ kind: "runner", processInstanceId: "source-runner", closeObservedAt: started + 1_500, exitCode: 0, signal: null }],
    }));
    await writeFile(join(replacementDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3, runId: replacementRunId, state: "running", startedAt: recoveredAt + 1, lastUpdate: recoveredAt + 2,
    }));

    await slot.ownedTurns.discoverExtensionArtifact(sourceDir);
    await slot.ownedTurns.discoverExtensionArtifact(replacementDir);
    if (scenario !== "recovered") {
      expect(slot.snapshot().extensionActivities.find((item) => item.runId === sourceRunId)?.status).toBe("running");
      if (scenario === "foreign-owner") {
        expect(slot.snapshot().extensionActivities.some((item) => item.runId === replacementRunId)).toBe(false);
      }
      return;
    }
    const drain = fixture.registry.waitUntilIdle();
    expect(slot.snapshot().extensionActivities).toEqual(expect.arrayContaining([
      expect.objectContaining({ toolCallId: sourceToolCallId, status: "completed", lifecycle: expect.objectContaining({ state: "stopped" }) }),
      expect.objectContaining({ runId: replacementRunId, status: "running", lifecycle: expect.objectContaining({ state: "running" }) }),
    ]));
    expect(slot.isDrainBusy).toBe(true);

    const finished = Date.now();
    await writeFile(join(replacementDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3, runId: replacementRunId, state: "complete", startedAt: recoveredAt + 1,
      lastUpdate: finished, endedAt: finished,
    }));
    await slot.ownedTurns.discoverExtensionArtifact(replacementDir);
    await drain;
    expect(slot.isDrainBusy).toBe(false);
    expect(slot.snapshot().extensionActivities).toEqual(expect.arrayContaining([
      expect.objectContaining({ toolCallId: sourceToolCallId, status: "completed", lifecycle: expect.objectContaining({ state: "stopped" }) }),
      expect.objectContaining({ runId: replacementRunId, status: "completed", lifecycle: expect.objectContaining({ state: "completed" }) }),
    ]));
    expect(slot.snapshot().processOverview.activeCount).toBe(0);
    await writeFile(join(sourceDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3, runId: sourceRunId, state: "running", startedAt: started, lastUpdate: Date.now(),
    }));
    await slot.ownedTurns.discoverExtensionArtifact(sourceDir);
    expect(slot.snapshot().extensionActivities.find((item) => item.runId === sourceRunId)?.lifecycle?.state).toBe("stopped");
    expect(slot.isDrainBusy).toBe(false);
  });

  it("does not retain unwatched async launcher acknowledgements as running work", async () => {
    const fixture = await coldFixture("unwatched-async-launcher");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const update = slot.ownedTurns;
    const now = new Date().toISOString();
    const origin: ExtensionToolOrigin = { source: "project" };

    const idOnly = updateExtensionActivity(update, "id-only-tool", "subagent", origin, "completed", now, now, { details: { asyncId: "id-only-run", mode: "async" } }, now, 44);
    expect(idOnly?.status).toBe("completed");
    expect(update.extensionActivityWatchers.has("id-only-tool")).toBe(false);

    const rejectedDirectory = updateExtensionActivity(update, "rejected-dir-tool", "subagent", origin, "completed", now, now, { details: { asyncId: "rejected-dir-run", mode: "async", asyncDir: "/tmp/not-owned-by-this-session" } }, now, 44);
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
    const internal = slot.ownedTurns;
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

    expect(updateExtensionActivity(internal, "sync-tool", "subagent", origin, "running", startedAt, runningAt, progress, undefined, 1_000)).toMatchObject({ toolCallId: "sync-tool", status: "running" });
    expect(slot.snapshot().processActivities).toEqual([expect.objectContaining({
      executionMode: "synchronous",
      title: "reviewer",
      visibility: "active",
      currentTool: "read",
      lifecycle: expect.objectContaining({ state: "running" }),
    })]);

    slot.syncSubagentProcesses({
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
    expect(updateExtensionActivity(internal, "other-tool", "subagent", unrelatedOwner, "running", startedAt, runningAt, progress)).toBeUndefined();

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
    expect(updateExtensionActivity(internal, "sync-tool", "subagent", origin, "completed", startedAt, completedAt, terminal, completedAt, 1_200)).toMatchObject({ toolCallId: "sync-tool", status: "completed", runId: "sync-root" });
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

  it("never reports a canonical receipt as durable when Pi only staged it in memory", async () => {
    const fixture = await coldFixture("canonical-receipt-staged-only");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      runtime: { session: { sessionManager: SessionManager; abort: () => Promise<void> } };
      persistCanonicalCustomEntry: (customType: string, data: unknown, identity: string) => Promise<void>;
      runPersistence: RunPersistence;
    };
    const manager = internal.runtime.session.sessionManager;
    const sessionFile = manager.getSessionFile()!;
    const receipt = makeInvocationReceipt({
      version: 1, receiptId: "staged-only-receipt", receiptKind: "start",
      invocationId: "staged-invocation", operationId: "staged-operation", sessionId: slot.id,
      source: "plain", lifecycle: "staged", origin: { kind: "user", confidence: "boundary" },
      sequence: 1, createdAt: "2026-01-01T00:00:00.000Z",
    });
    const staged = (): boolean => manager.getBranch().some((entry) =>
      entry.type === "custom" && (entry.data as { receiptId?: unknown })?.receiptId === "staged-only-receipt");

    const aside = `${sessionFile}.aside`;
    await rename(sessionFile, aside);
    await mkdir(sessionFile);
    try {
      await expect(internal.persistCanonicalCustomEntry(INVOCATION_RECEIPT_TYPE, receipt, "staged-only-receipt"))
        .rejects.toMatchObject({ details: { outcomeUnknown: true } });
      expect(staged()).toBe(false);
      await expect(internal.persistCanonicalCustomEntry(INVOCATION_RECEIPT_TYPE, receipt, "staged-only-receipt"))
        .rejects.toMatchObject({ details: { outcomeUnknown: true } });
    } finally {
      await rm(sessionFile, { recursive: true, force: true });
      await rename(aside, sessionFile);
    }
    expect(await readFile(sessionFile, "utf8")).not.toContain("staged-only-receipt");

    try {
      expect(slot.isBusy).toBe(true);
      expect(slot.isEvictionProtected).toBe(true);
      expect(slot.isDrainBusy).toBe(true);
      expect(slot.administrativeDrainBlockers()).toContainEqual(expect.objectContaining({ category: "terminal-receipt-persistence", state: "suspect" }));
      await expect(slot.prompt("must not execute")).rejects.toMatchObject({ details: { outcomeUnknown: true } });
      await expect(slot.dispose()).rejects.toMatchObject({ details: { outcomeUnknown: true } });
      const stop = vi.spyOn(internal.runtime.session, "abort");
      await slot.abort();
      expect(stop).toHaveBeenCalledOnce();
      expect(slot.isDrainBusy).toBe(true);
      stop.mockRestore();
      await expect(internal.persistCanonicalCustomEntry(INVOCATION_RECEIPT_TYPE, { receiptId: "healthy-receipt", version: 1 }, "healthy-receipt"))
        .rejects.toMatchObject({ details: { outcomeUnknown: true } });
      expect(await readFile(sessionFile, "utf8")).not.toContain("healthy-receipt");
    } finally {
      internal.runPersistence.durableWrites.clear();
    }
  });

  it("probes the bound session's file when a rebind lands between a failed receipt append and its retry", async () => {
    const fixture = await coldFixture("canonical-receipt-rebind-retry");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      sessionManager: SessionManager;
      persistCanonicalCustomEntry: (customType: string, data: unknown, identity: string) => Promise<void>;
    };
    const bound = internal.sessionManager;
    const replacementDirectory = join(fixture.root, "rebind-replacement");
    await mkdir(replacementDirectory, { recursive: true });
    const replacement = SessionManager.create(fixture.cwd, replacementDirectory);
    replacement.appendMessage({ role: "user", content: "replacement prompt", timestamp: Date.now() });
    replacement.appendMessage(fauxAssistantMessage("replacement answer"));
    const receipt = makeInvocationReceipt({
      version: 1, receiptId: "rebind-receipt", receiptKind: "start",
      invocationId: "rebind-invocation", operationId: "rebind-operation", sessionId: slot.id,
      source: "plain", lifecycle: "staged", origin: { kind: "user", confidence: "boundary" },
      sequence: 1, createdAt: "2026-01-01T00:00:00.000Z",
    });
    vi.spyOn(bound, "appendCustomEntry").mockImplementationOnce(() => {
      internal.sessionManager = replacement;
      throw new Error("append refused before any byte was written");
    });
    try {
      await internal.persistCanonicalCustomEntry(INVOCATION_RECEIPT_TYPE, receipt, "rebind-receipt");
    } finally {
      internal.sessionManager = bound;
    }
    expect(await readFile(bound.getSessionFile()!, "utf8")).toContain("rebind-receipt");
    expect(await readFile(replacement.getSessionFile()!, "utf8")).not.toContain("rebind-receipt");
  });

  it("retains the exact extension receipt owner when Pi stages its terminal receipt but disk append fails", async () => {
    const workRegistry = new GatewayWorkRegistry();
    const fixture = await coldFixture("extension-staged-receipt", { workRegistry });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot.ownedTurns;
    const activity: ExtensionRunActivity = {
      id: "staged-extension", activityId: "staged-extension", toolCallId: "tool-staged-extension",
      source: { source: "pi-subagents" }, title: "Fixture", status: "completed", children: [],
      startedAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:01.000Z",
      lifecycle: { version: 1, state: "completed", attention: "none", sequence: 1, observedAt: "2026-01-01T00:00:01.000Z" },
    };
    const owner = internal.claimExtensionReceiptOwnership(activity.id);
    const file = slot.runtime.session.sessionManager.getSessionFile()!;
    const aside = `${file}.aside`;
    await rename(file, aside);
    await mkdir(file);
    try {
      await expect(appendExtensionActivityReceipt(internal, activity)).rejects.toMatchObject({ details: { outcomeUnknown: true } });
      expect(workRegistry.facts().some(fact => fact.token === owner.token)).toBe(true);
      expect(slot.isEvictionProtected).toBe(true);
      expect(slot.isDrainBusy).toBe(true);
      await expect(slot.disposeIf(() => true)).rejects.toMatchObject({ details: { outcomeUnknown: true } });
      await expect(appendExtensionActivityReceipt(internal, activity)).rejects.toMatchObject({ details: { outcomeUnknown: true } });
      expect(await readFile(aside, "utf8")).not.toContain("staged-extension");
    } finally {
      await rm(file, { recursive: true, force: true });
      await rename(aside, file);
      slot.runPersistence.durableWrites.clear();
      internal.releaseExtensionReceiptOwnership(activity.id, owner);
    }
  });

  it.each(["rejecting", "stalled"])("bounds the %s persistence waiter without releasing its unresolved owner", async (failure) => {
    const fixture = await coldFixture(`ownership-write-${failure}`);
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const internal = slot as unknown as {
      runPersistence: RunPersistence;
    };
    let finish!: () => void;
    const stalled = new Promise<void>(resolve => { finish = resolve; });
    let attempts = 0;
    vi.useFakeTimers();
    const clock = vi.spyOn(nodePerformance, "now").mockImplementation(() => Date.now());
    try {
      const operation = async () => {
        attempts += 1;
        if (failure === "stalled") return stalled;
        throw new Error("synthetic storage failure");
      };
      const pending = internal.runPersistence.retryDurableWrite("test:storage-fault", operation);
      const rejected = expect(pending).rejects.toMatchObject({ details: { outcomeUnknown: true } });
      await vi.advanceTimersByTimeAsync(20_000);
      await rejected;
      if (failure === "stalled") expect(attempts).toBe(1);
      else expect(attempts).toBeGreaterThan(1);
      expect(slot.isEvictionProtected).toBe(true);
      expect(slot.isDrainBusy).toBe(true);
      await expect(slot.prompt("must remain fenced")).rejects.toMatchObject({ details: { outcomeUnknown: true } });
      await expect(slot.dispose()).rejects.toMatchObject({ details: { outcomeUnknown: true } });
      finish();
      await stalled;
      await vi.advanceTimersByTimeAsync(1_000);
      expect(slot.isDrainBusy).toBe(true);
      await expect(internal.runPersistence.retryDurableWrite("test:storage-fault", operation)).rejects.toMatchObject({ details: { outcomeUnknown: true } });
    } finally {
      finish();
      clock.mockRestore();
      vi.useRealTimers();
      internal.runPersistence.durableWrites.clear();
    }
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
    const internal = slot.ownedTurns;
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId, activityId, runId, toolCallId,
      source: { source: "pi-subagents" }, title: "Pi Subagents", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    const receiptAppend = vi.spyOn(slot.runtime.session.sessionManager, "appendCustomEntry")
      .mockImplementationOnce(() => { throw new Error("injected receipt persistence failure"); });
    const endedAt = Date.now();
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      runId, state: "complete", startedAt: Date.parse(startedAt), endedAt, lastUpdate: endedAt + 1,
    }));

    await refreshExtensionActivityFromArtifact(internal, toolCallId, asyncDir);
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
    const internal = slot.ownedTurns;
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId, activityId: "retry-activity", runId, toolCallId,
      source: { source: "project", owner: { id: "extension:pi-subagents", title: "Subagents", source: "project" } }, title: "Subagents", mode: "asynchronous", status: "running",
      startedAt, updatedAt: startedAt, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    });
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    const canonicalAsyncDir = await realpath(asyncDir);
    const originalRead = internal.artifacts.readExtensionStatusArtifact.bind(internal.artifacts);
    let missingReadCompleted = false;
    internal.artifacts.readExtensionStatusArtifact = async (directory) => {
      const status = await originalRead(directory);
      if (directory === canonicalAsyncDir && status === undefined) missingReadCompleted = true;
      return status;
    };
    internal.startExtensionActivityWatcher(toolCallId, asyncDir);
    try {
      await waitFor(() => missingReadCompleted, "the missing-artifact read");
      const pendingStatus = join(asyncDir, "status.json.pending");
      await writeFile(pendingStatus, JSON.stringify({
        lifecycleArtifactVersion: 3,
        runId,
        state: "running",
        startedAt: Date.parse(startedAt),
        lastUpdate: Date.now(),
        mode: "workflow",
        steps: [],
      }));
      await rename(pendingStatus, join(asyncDir, "status.json"));
      await waitFor(() => (slot.snapshot().processActivities?.length ?? 0) === 1, "the first process activity");
      expect(slot.snapshot().processActivities?.[0]).toMatchObject({
        kind: "subagent",
        runId,
        executionMode: "asynchronous",
        visibility: "active",
      });
      expect(slot.snapshot().processOverview).toMatchObject({ visibility: "active", activeCount: 1 });
    } finally {
      const endedAt = Date.now();
      const completedStatus = join(asyncDir, "status.json.pending");
      await writeFile(completedStatus, JSON.stringify({
        lifecycleArtifactVersion: 3,
        runId,
        state: "complete",
        startedAt: Date.parse(startedAt),
        lastUpdate: endedAt,
        endedAt,
        mode: "workflow",
        steps: [],
      }));
      await rename(completedStatus, join(asyncDir, "status.json"));
      await waitFor(() => slot.snapshot().extensionActivities?.some((activity) =>
        activity.toolCallId === toolCallId && activity.status === "completed") === true, "the completed extension activity");
      await fixture.registry.waitUntilIdle();
    }
  });

  it("retires a stale active process when its exact status artifact stays missing", async () => {
    const fixture = await coldFixture("async-status-permanently-missing");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = "missing-run";
    const toolCallId = "missing-tool";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    const startedAt = new Date(Date.now() - 60_000).toISOString();
    const activity: ExtensionRunActivity = {
      id: toolCallId, activityId: "missing-activity", runId, toolCallId,
      source: { source: "project", owner: { id: "extension:pi-subagents", title: "Subagents", source: "project" } }, title: "Subagents", mode: "asynchronous", status: "running",
      startedAt, updatedAt: startedAt,
      children: [{ id: "child", producerId: "child", label: "worker", status: "running", lifecycle: "running" }],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: startedAt },
    };
    const internal = slot.ownedTurns;
    internal.extensionActivities.set(toolCallId, activity);
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    internal.extensionArtifactMissingSince.set(toolCallId, Date.now() - 31_000);
    slot.syncSubagentProcesses(activity);
    expect(slot.snapshot().processOverview).toMatchObject({ visibility: "active", activeCount: 1 });
    expect(internal.ownedExtensionArtifactDirectories()).toContain(await realpath(asyncDir));

    internal.observeMissingExtensionArtifact(toolCallId);

    expect(slot.snapshot().processActivities ?? []).toEqual([]);
    expect(slot.snapshot().processOverview).toMatchObject({ visibility: "hidden", activeCount: 0 });
    expect(internal.extensionActivities.get(toolCallId)?.lifecycle?.state).toBe("unknown");
  });

  it("rejects canonical artifact paths outside the exact project run root", async () => {
    const fixture = await coldFixture("artifact-path-containment");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const parent = join(fixture.cwd, ".pi", "subagents");
    const sibling = join(parent, "sibling");
    await mkdir(sibling, { recursive: true });
    const allowed = slot.ownedTurns.extensionArtifactPathAllowed.bind(slot.ownedTurns);
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
    const internal = slot.ownedTurns;
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

    await slot.ownedTurns.reconcileOwnedExtensionArtifactsForDrain();
    expect(slot.snapshot().extensionActivities).toMatchObject([{ lifecycle: { state: "running" } }]);
    expect(slot.administrativeDrainBlockers()).toHaveLength(1);

    capacityOwner.settle();
    await slot.ownedTurns.reconcileOwnedExtensionArtifactsForDrain();
    await waitFor(() => slot.snapshot().extensionActivities[0]?.lifecycle?.state === "completed", "the first extension activity to complete");
    expect(slot.administrativeDrainBlockers()).toEqual([]);
    await waitFor(() => workRegistry.size === 0, "the work registry to drain");
  });

  it("does not treat terminal attention presentation as drain work", async () => {
    const fixture = await coldFixture("terminal-attention-presentation");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const observedAt = new Date().toISOString();
    const internal = slot.ownedTurns;
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
    const internal = slot.ownedTurns;
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
    const internal = slot.ownedTurns;
    slot.dependencies.extensionArtifactWarning = (warning) => warnings.push(warning);
    internal.warnExtensionArtifact("ownership-mismatch", "/private/project/run-with-output");
    internal.warnExtensionArtifact("ownership-mismatch", "/private/project/run-with-output");
    expect(warnings).toEqual([{ reason: "ownership-mismatch", owner: expect.stringMatching(/^[0-9a-f]{24}$/u) }]);
    expect(JSON.stringify(warnings)).not.toContain("private");
    expect(JSON.stringify(warnings)).not.toContain("output");
  });

  it.each(["missing directory", "malformed status", "foreign header", "watcher error", "temporary status absence"] as const)(
    "keeps root admission and observation independent of child %s", async (failure) => {
      const fixture = await coldFixture("optional-child-detail");
      try {
        const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
        const runId = "optional-root";
        const toolCallId = "optional-tool";
        const childRun = "optional-child";
        const artifactRoot = join(await realpath(fixture.cwd), ".pi", "subagents", "async-subagent-runs");
        const asyncDir = join(artifactRoot, runId);
        const childDir = join(artifactRoot, childRun);
        const childSessionDir = join(dirname(slot.sessionFile!), basename(slot.sessionFile!, ".jsonl"), childRun, "run-0");
        await mkdir(childSessionDir, { recursive: true });
        const manager = SessionManager.create(fixture.cwd, childSessionDir, { id: "optional-child-session" });
        manager.appendMessage(fauxAssistantMessage("Child transcript"));
        const childFile = join(childSessionDir, "session.jsonl");
        await rename(manager.getSessionFile()!, childFile);
        await mkdir(asyncDir, { recursive: true });
        const captured = JSON.parse(await readFile(join(dirname(fileURLToPath(import.meta.url)), "../../sessions/fixtures", "frozen-real-active.json"), "utf8"));
        const started = captured.startedAt as number;
        const edge = { agent: "worker", label: "Worker", status: "running", async: true, runId: childRun,
          workflowKey: "worker", sessionOwnerId: childRun, sessionFile: childFile };
        const document = (id: string, mode: string, steps: unknown[], update: number) => ({
          lifecycleProjection: { ...captured.lifecycleProjection, runId: id, toolCallId, sessionId: slot.sessionFile,
            generatedAt: update, omitted: { runs: 0, children: 0, byteLimitExceeded: false },
            root: { id, kind: mode === "workflow" ? "workflow" : "subagent", label: "Root", state: "running", startedAt: started, updatedAt: update, children: [] } },
          runId: id, toolCallId, sessionId: slot.sessionFile, mode, state: "running", startedAt: started, lastUpdate: update, steps,
        });
        const root = document(runId, "workflow", [edge], started + 5_000);
        const child = { ...document(childRun, "single", [{ agent: "worker", sessionFile: childFile, status: "running", model: "fixture/child", toolCount: 3 }], started + 5_000),
          parentWorkflowRunId: runId, workflowKey: "worker", sessionOwnerId: childRun };
        const replace = async (directory: string, value: unknown) => {
          await mkdir(directory, { recursive: true });
          const temp = join(directory, "replacement.json");
          await writeFile(temp, typeof value === "string" ? value : JSON.stringify(value));
          await rename(temp, join(directory, "status.json"));
        };
        const internal = slot.ownedTurns;
        try {
          internal.extensionActivities.set(toolCallId, { id: toolCallId, runId, toolCallId,
            source: { source: "pi-subagents" }, title: "Subagents", status: "running", children: [],
            startedAt: new Date(started).toISOString(), updatedAt: new Date(started).toISOString(),
            lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: new Date(started).toISOString() } });
          internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
          const runtimeManager = (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } }).runtime.session.sessionManager;
          runtimeManager.appendMessage({ role: "toolResult", toolName: "subagent", toolCallId, content: [{ type: "text", text: "Workflow started" }],
            details: { runId, asyncId: runId, asyncDir, mode: "workflow", state: "running" }, isError: false, timestamp: started });
          const activity = () => internal.extensionActivities.get(toolCallId);
          const partial = () => activity()?.lifecycleOmissions?.children;
          if (failure !== "missing directory") await replace(childDir, child);
          await replace(asyncDir, root);
          expect(await slot.ownedTurns.discoverExtensionArtifact(asyncDir), "root artifact admission").toBe("accepted");
          expect(activity(), "root admitted on its own evidence").toMatchObject({ runId, status: "running", updatedAt: new Date(started + 5_000).toISOString() });
          expect(internal.extensionActivityWatchers.has(toolCallId), "root watcher started").toBe(true);
          if (failure !== "missing directory") expect(activity()?.children[0], "reciprocal fixture detail").toMatchObject({ model: "fixture/child" });
          await waitFor(() => internal.extensionActivityWatchers.get(toolCallId)?.children.has(childDir) === true, "root edge owns subscription");
          if (failure === "missing directory") {
            expect(partial()).toBe(1);
          } else {
            await waitFor(() => activity()?.children[0]?.model === "fixture/child", "initial optional detail hydrated");
            if (failure === "malformed status") await replace(childDir, "{malformed");
            if (failure === "foreign header") await replace(childDir, { ...child,
              lifecycleProjection: { ...child.lifecycleProjection, sessionId: "/foreign/parent.jsonl" },
              steps: [{ ...child.steps[0], model: "FORGED_MODEL" }] });
            if (failure === "temporary status absence") await rm(join(childDir, "status.json"));
            if (failure === "watcher error") {
              const rootWatcher = internal.extensionActivityWatchers.get(toolCallId)!.watcher;
              internal.extensionActivityWatchers.get(toolCallId)!.children.get(childDir)!.emit("error", new Error("Injected child observation failure"));
              expect(internal.extensionActivityWatchers.get(toolCallId)?.watcher, "child error preserves the same root observer").toBe(rootWatcher);
            }
            const updated = { ...root, lastUpdate: started + 10_000,
              lifecycleProjection: { ...root.lifecycleProjection, generatedAt: started + 10_000, root: { ...root.lifecycleProjection.root, updatedAt: started + 10_000 } } };
            await replace(asyncDir, updated);
            await waitFor(() => activity()?.updatedAt === new Date(started + 10_000).toISOString(), "root watcher publishes despite child failure");
            expect(internal.extensionActivityWatchers.get(toolCallId)?.children.has(childDir), "unchanged edge stays subscribed").toBe(true);
            expect(await slot.ownedTurns.discoverExtensionArtifact(asyncDir), "optional detail never rejects discovery").toBe("accepted");
            if (failure !== "watcher error") expect(partial()).toBe(1);
            expect(JSON.stringify(activity())).not.toContain("FORGED_MODEL");
          }
          expect(internal.extensionActivityWatchers.has(toolCallId), "child failure cannot retire root").toBe(true);
          await replace(childDir, { ...child, steps: [{ ...child.steps[0], model: "fixture/recovered", toolCount: 4 }] });
          await waitFor(() => activity()?.children[0]?.model === "fixture/recovered", "child-only write hydrates detail");
          expect(partial() ?? 0).toBe(0);
          expect(slot.snapshot().processActivities).toEqual(expect.arrayContaining([expect.objectContaining({ model: "fixture/recovered", toolCount: 4 })]));
          await replace(asyncDir, { ...root, steps: [] });
          await waitFor(() => internal.extensionActivityWatchers.get(toolCallId)?.children.size === 0, "root edge removal retires observation");
        } finally {
          await replace(asyncDir, { ...root, state: "completed", endedAt: started + 20_000, lastUpdate: started + 20_000, steps: [],
            lifecycleProjection: { ...root.lifecycleProjection, root: { ...root.lifecycleProjection.root, state: "complete", endedAt: started + 20_000, updatedAt: started + 20_000 } } });
          await slot.ownedTurns.discoverExtensionArtifact(asyncDir);
        }
        expect(internal.extensionActivityWatchers.size).toBe(0);
      } finally {
        await fixture.registry.dispose().finally(() => rm(fixture.root, { recursive: true, force: true }));
      }
    }, 15_000,
  );

  async function workflowChildFixture(label: string) {
    const fixture = await coldFixture(label);
    const registryInternal = fixture.registry as unknown as { artifactDiscoveryTimer?: NodeJS.Timeout };
    if (registryInternal.artifactDiscoveryTimer) clearInterval(registryInternal.artifactDiscoveryTimer);
    registryInternal.artifactDiscoveryTimer = undefined;
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = `${label}-root`;
    const toolCallId = `${label}-tool`;
    const childRun = `${label}-child`;
    const artifactRoot = join(await realpath(fixture.cwd), ".pi", "subagents", "async-subagent-runs");
    const asyncDir = join(artifactRoot, runId);
    const childDir = join(artifactRoot, childRun);
    const childSessionDir = join(dirname(slot.sessionFile!), basename(slot.sessionFile!, ".jsonl"), childRun, "run-0");
    await mkdir(childSessionDir, { recursive: true });
    const manager = SessionManager.create(fixture.cwd, childSessionDir, { id: `${label}-child-session` });
    manager.appendMessage(fauxAssistantMessage("Child transcript"));
    const childFile = join(childSessionDir, "session.jsonl");
    await rename(manager.getSessionFile()!, childFile);
    const captured = JSON.parse(await readFile(join(dirname(fileURLToPath(import.meta.url)), "../../sessions/fixtures", "frozen-real-active.json"), "utf8"));
    const started = captured.startedAt as number;
    const edge = { agent: "worker", label: "Worker", status: "running", async: true, runId: childRun,
      workflowKey: "worker", sessionOwnerId: childRun, sessionFile: childFile };
    const document = (id: string, mode: string, steps: unknown[], update: number, state = "running") => ({
      lifecycleProjection: { ...captured.lifecycleProjection, runId: id, toolCallId, sessionId: slot.sessionFile,
        generatedAt: update, omitted: { runs: 0, children: 0, byteLimitExceeded: false },
        root: { id, kind: mode === "workflow" ? "workflow" : "subagent", label: "Root", state: state === "running" ? state : "complete", startedAt: started, updatedAt: update, children: [] } },
      runId: id, toolCallId, sessionId: slot.sessionFile, mode, state, startedAt: started, lastUpdate: update, steps,
      ...(state === "running" ? {} : { endedAt: update }),
    });
    const child = (detail: Record<string, unknown>) => ({
      ...document(childRun, "single", [{ agent: "worker", sessionFile: childFile, status: "running", ...detail }], started + 5_000),
      parentWorkflowRunId: runId, workflowKey: "worker", sessionOwnerId: childRun,
    });
    const replace = async (directory: string, value: unknown) => {
      await mkdir(directory, { recursive: true });
      const temp = join(directory, "replacement.json");
      await writeFile(temp, JSON.stringify(value));
      await rename(temp, join(directory, "status.json"));
    };
    const owner = slot.ownedTurns;
    owner.extensionActivities.set(toolCallId, { id: toolCallId, runId, toolCallId,
      source: { source: "pi-subagents" }, title: "Subagents", status: "running", children: [],
      startedAt: new Date(started).toISOString(), updatedAt: new Date(started).toISOString(),
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: new Date(started).toISOString() } });
    owner.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } }).runtime.session.sessionManager.appendMessage({
      role: "toolResult", toolName: "subagent", toolCallId, content: [{ type: "text", text: "Workflow started" }],
      details: { runId, asyncId: runId, asyncDir, mode: "workflow", state: "running" }, isError: false, timestamp: started });
    await replace(asyncDir, document(runId, "workflow", [edge], started + 5_000));
    return {
      slot, owner, toolCallId, asyncDir, childDir, child, replace,
      activity: () => owner.extensionActivities.get(toolCallId),
      evict: async (check: () => void | Promise<void>) => {
        const row = owner.extensionActivities.get(toolCallId)!;
        const fillers = Array.from({ length: 64 }, (_, index) => `${label}-filler-${index}`);
        for (const [index, id] of fillers.entries()) owner.extensionActivities.set(id, { ...row, id, toolCallId: id, runId: id,
          activityId: id, updatedAt: new Date(Date.parse(row.updatedAt) + 1_000 + index).toISOString() });
        try {
          trimExtensionActivities(owner);
          expect(owner.extensionActivities.get(toolCallId), "the oldest row is the one evicted").toBeUndefined();
          await check();
        } finally {
          for (const id of fillers) owner.extensionActivities.delete(id);
        }
      },
      dispose: async () => {
        try {
          await replace(asyncDir, document(runId, "workflow", [], started + 20_000, "completed"));
          await owner.discoverExtensionArtifact(asyncDir);
        } finally {
          await fixture.registry.dispose().finally(() => rm(fixture.root, { recursive: true, force: true }));
        }
      },
    };
  }

  it("disposes a runtime whose ownership write completed while the event loop was stalled past its deadline", async () => {
    const fixture = await coldFixture("ownership-write-stall");
    try {
      const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
      const write = slot.enqueueMarkerOwnership("stalled-ownership-operation");
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 21_000);
      await expect(write).resolves.toBeUndefined();
      expect(slot.runPersistence.hasBlockedOwnershipWrite).toBe(false);
      await slot.clearMarkerOwnership("stalled-ownership-operation");
    } finally {
      await fixture.registry.dispose();
      registries.splice(registries.indexOf(fixture.registry), 1);
      await rm(fixture.root, { recursive: true, force: true });
    }
  }, 60_000);

  it("keeps a workflow child's detail when its status read loses to the producer's atomic replacement", async () => {
    const f = await workflowChildFixture("child-replace");
    try {
      await f.replace(f.childDir, f.child({ model: "fixture/child", toolCount: 3 }));
      expect(await f.owner.discoverExtensionArtifact(f.asyncDir), "root artifact admission").toBe("accepted");
      expect(f.activity()?.children[0]).toMatchObject({ model: "fixture/child", toolCount: 3 });
      f.owner.stopExtensionActivityWatcher(f.toolCallId);
      const discovery = new AsyncLocalStorage<true>();
      statusJsonReplace.insideRetryInvocation = () => discovery.getStore() === true;
      statusJsonReplace.payload = JSON.stringify(f.child({ model: "fixture/child", toolCount: 4 }));
      statusJsonReplace.statusPath = join(f.childDir, "status.json");
      statusJsonReplace.tempPath = join(f.childDir, "status.tmp");
      statusJsonReplace.losses = 0;
      statusJsonReplace.replacements = 0;
      statusJsonReplace.armed = true;
      try {
        await discovery.run(true, () => f.owner.discoverExtensionArtifact(f.asyncDir));
      } finally {
        statusJsonReplace.armed = false;
        statusJsonReplace.insideRetryInvocation = () => false;
      }
      expect(statusJsonReplace.replacements, "one real rename between the child open and its verifying stat").toBe(1);
      expect(f.activity()?.lifecycleOmissions?.children ?? 0).toBe(0);
      expect(f.activity()?.children[0]).toMatchObject({ model: "fixture/child", toolCount: 4 });
      expect(f.slot.snapshot().processActivities).toEqual(expect.arrayContaining([expect.objectContaining({ model: "fixture/child", toolCount: 4 })]));
    } finally {
      await f.dispose();
    }
  });

  it("never publishes an older artifact read over a newer read's frame", async () => {
    const f = await workflowChildFixture("read-order");
    try {
      let observeHeld!: () => void;
      const held = new Promise<void>((resolve) => { observeHeld = resolve; });
      let release!: () => void;
      const gate = new Promise<void>((resolve) => { release = resolve; });
      const read = f.owner.artifacts.readExtensionStatusArtifactWithReplacementRetry.bind(f.owner.artifacts);
      let holdNextRootRead = true;
      vi.spyOn(f.owner.artifacts, "readExtensionStatusArtifactWithReplacementRetry").mockImplementation(async (...args) => {
        const hold = holdNextRootRead && args[0] === f.asyncDir;
        if (hold) holdNextRootRead = false;
        const value = await read(...args);
        if (hold) {
          observeHeld();
          await gate;
        }
        return value;
      });
      const older = f.owner.discoverExtensionArtifact(f.asyncDir);
      await awaitsWithin(held, "older read holds its real bytes before publication");
      await f.replace(f.childDir, f.child({ model: "fixture/child", toolCount: 0 }));
      expect(await f.owner.discoverExtensionArtifact(f.asyncDir), "newer read").toBe("accepted");
      expect(f.activity()?.children[0]).toMatchObject({ model: "fixture/child", toolCount: 0 });
      release();
      await older;
      expect(f.activity()?.lifecycleOmissions?.children ?? 0, "older bytes never replace a newer frame").toBe(0);
      expect(f.activity()?.children[0]).toMatchObject({ model: "fixture/child", toolCount: 0 });
      expect(f.slot.snapshot().processActivities).toEqual(expect.arrayContaining([expect.objectContaining({ model: "fixture/child", toolCount: 0 })]));
      expect(f.owner.extensionActivityPublishedReads.has(f.toolCallId)).toBe(true);
      await f.evict(() => {
        expect(f.owner.extensionActivityPublishedReads.has(f.toolCallId)).toBe(false);
        expect(f.owner.extensionActivityReadGenerations.has(f.toolCallId)).toBe(false);
      });
    } finally {
      await f.dispose();
    }
  });

  it("keeps an evicted row's read order until every older read has finished", async () => {
    const f = await workflowChildFixture("evicted-order");
    try {
      let observeHeld!: () => void;
      const held = new Promise<void>((resolve) => { observeHeld = resolve; });
      let release!: () => void;
      const gate = new Promise<void>((resolve) => { release = resolve; });
      const read = f.owner.artifacts.readExtensionStatusArtifactWithReplacementRetry.bind(f.owner.artifacts);
      let holdNextRootRead = true;
      vi.spyOn(f.owner.artifacts, "readExtensionStatusArtifactWithReplacementRetry").mockImplementation(async (...args) => {
        const hold = holdNextRootRead && args[0] === f.asyncDir;
        if (hold) holdNextRootRead = false;
        const value = await read(...args);
        if (hold) {
          observeHeld();
          await gate;
        }
        return value;
      });
      const older = f.owner.discoverExtensionArtifact(f.asyncDir);
      await awaitsWithin(held, "older read holds its real bytes before publication");
      await f.replace(f.childDir, f.child({ model: "fixture/child", toolCount: 0 }));
      expect(await f.owner.discoverExtensionArtifact(f.asyncDir), "newer read").toBe("accepted");
      await f.evict(async () => {
        expect(f.owner.extensionActivityPublishedReads.has(f.toolCallId), "older read still in flight").toBe(true);
        release();
        expect(await older, "older read cannot re-admit an evicted row").not.toBe("accepted");
        expect(f.activity()).toBeUndefined();
        expect(f.owner.extensionActivityPublishedReads.has(f.toolCallId), "retired once older reads finish").toBe(false);
      });
    } finally {
      await f.dispose();
    }
  });

  it("discovers real producer-serialized lifecycle headers without parsing oversized reports", async () => {
    const fixture = await coldFixture("embedded-lifecycle-header");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const runId = "frozen-real-run";
    const toolCallId = "frozen-real-tool";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    const parentFile = slot.sessionFile!;
    const childRoot = join(dirname(parentFile), basename(parentFile, ".jsonl"), runId);
    const makeChildSession = async (runName: string, id: string): Promise<string> => {
      const childDirectory = join(childRoot, runName);
      await mkdir(childDirectory, { recursive: true });
      const manager = SessionManager.create(fixture.cwd, childDirectory, { id });
      manager.appendMessage(fauxAssistantMessage(`${runName} transcript`));
      const generated = manager.getSessionFile()!;
      const childFile = join(childDirectory, "session.jsonl");
      await rename(generated, childFile);
      return childFile;
    };
    const childFile = await makeChildSession("run-0", "frozen-child-session");
    const nestedFile = await makeChildSession("run-1", "frozen-nested-session");
    await mkdir(asyncDir, { recursive: true });
    const fixturePath = (name: "active" | "terminal") => join(dirname(fileURLToPath(import.meta.url)), "../../sessions/fixtures", `frozen-real-${name}.json`);
    const loadFixture = async (name: "active" | "terminal"): Promise<string> => {
      const parsed = JSON.parse(await readFile(fixturePath(name), "utf8")) as {
        lifecycleProjection: { sessionId?: string };
      };
      parsed.lifecycleProjection.sessionId = slot.sessionFile;
      return JSON.stringify(parsed)
        .replaceAll("/tmp/frozen-real-child/session.jsonl", childFile)
        .replaceAll("/tmp/frozen-real-nested/session.jsonl", nestedFile);
    };
    const internal = slot.ownedTurns;
    const started = 1_700_000_000_000;
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId, activityId: "frozen-real-activity", runId, toolCallId,
      source: { source: "pi-subagents" }, title: "Pi Subagents", status: "running",
      startedAt: new Date(started).toISOString(), updatedAt: new Date(started).toISOString(), children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: new Date(started).toISOString() },
    });
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    await writeFile(join(asyncDir, "status.json"), await loadFixture("active"));
    await slot.ownedTurns.discoverExtensionArtifact(asyncDir);
    const active = projectedExtensionActivity(slot.snapshot().extensionActivities, toolCallId);
    expect(active).toMatchObject({ status: "running", lifecycle: { state: "running" } });
    expect(active.children).toEqual(expect.arrayContaining([
      expect.objectContaining({ currentTool: "bash", toolCount: 3, childSessionRef: "frozen-child-session", children: expect.arrayContaining([expect.objectContaining({ currentTool: "read", childSessionRef: "frozen-nested-session" })]) }),
      expect.objectContaining({ hostStep: expect.objectContaining({ provider: "github", role: "checks" }) }),
    ]));
    expect(active).not.toHaveProperty("output");
    expect(JSON.stringify(active)).not.toContain("x".repeat(1_024));
    expect(slot.snapshot().processActivities).toEqual(expect.arrayContaining([expect.objectContaining({ childSessionRef: "frozen-child-session", currentTool: "bash" })]));
    expect(slot.snapshot().processOverview.extensionChildOmissions).toMatchObject({ children: 34, byteLimitExceeded: true });

    const foreignDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "forged-owner", "run-0");
    await mkdir(foreignDirectory, { recursive: true });
    const foreignManager = SessionManager.create(fixture.cwd, foreignDirectory, { id: "forged-child-session" });
    foreignManager.appendMessage(fauxAssistantMessage("forged owner transcript"));
    const foreignFile = join(foreignDirectory, "session.jsonl");
    await rename(foreignManager.getSessionFile()!, foreignFile);
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3,
      lifecycleProjection: { presentationOnly: true },
      runId,
      state: "running",
      startedAt: started,
      lastUpdate: started + 6_000,
      mode: "workflow",
      steps: [{ runId: "forged-child", sessionOwnerId: "forged-owner", agent: "forged", status: "running", sessionFile: foreignFile }],
    }));
    await slot.ownedTurns.discoverExtensionArtifact(asyncDir);
    const forged = projectedExtensionActivity(slot.snapshot().extensionActivities, toolCallId);
    expect(forged.children[0]?.childSessionRef).toBeUndefined();
    expect(slot.snapshot().processActivities?.some((activity) => activity.childSessionRef === "forged-child-session")).toBe(false);

    await writeFile(join(asyncDir, "status.json"), await loadFixture("terminal"));
    await slot.ownedTurns.discoverExtensionArtifact(asyncDir);
    const terminal = projectedExtensionActivity(slot.snapshot().extensionActivities, toolCallId);
    expect(terminal).toMatchObject({ status: "completed", lifecycle: { state: "completed" }, completedAt: new Date(1_700_000_010_000).toISOString() });
  });

  it("rejects foreign producer session headers before live or reconstructed activity admission", async () => {
    const fixture = await coldFixture("foreign-producer-session-header");
    const runId = "packed-producer-owned-session-run";
    const toolCallId = "packed-producer-owned-session-tool";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const fixtureDirectory = join(dirname(fileURLToPath(import.meta.url)), "../../sessions/fixtures");
    const loadHeader = async (name: string): Promise<Record<string, unknown>> => {
      const parsed = JSON.parse(await readFile(join(fixtureDirectory, name), "utf8")) as { lifecycleProjection: Record<string, unknown> };
      return structuredClone(parsed.lifecycleProjection);
    };
    const ownedHeader = await loadHeader("packed-producer-owned-lifecycle-header.json");
    ownedHeader.sessionId = slot.sessionFile;
    const foreignHeader = await loadHeader("packed-producer-foreign-lifecycle-header.json");
    const foreignTerminalHeader = await loadHeader("packed-producer-foreign-terminal-lifecycle-header.json");
    expect(foreignHeader).toMatchObject({ runId, toolCallId, sessionId: "foreign-parent-session", root: { children: expect.arrayContaining([expect.objectContaining({ id: "step-a", state: "failed" })]) } });
    expect(foreignTerminalHeader).toMatchObject({ runId, toolCallId, sessionId: "foreign-parent-session", root: { state: "complete", endedAt: expect.any(Number) } });

    const writeHeader = async (projection: Record<string, unknown>) => {
      await writeFile(join(asyncDir, "status.json"), JSON.stringify({
        lifecycleProjection: projection,
        error: "oversized workflow report " + "x".repeat(300 * 1_024),
      }));
      expect((await readFile(join(asyncDir, "status.json"))).byteLength).toBeGreaterThan(256 * 1_024);
    };
    const runtimeManager = (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } }).runtime.session.sessionManager;
    runtimeManager.appendMessage({
      role: "toolResult", toolCallId, toolName: "subagent", content: [{ type: "text", text: "launched" }],
      details: { runId, asyncId: runId, asyncDir, mode: "workflow", state: "running" },
      isError: false, timestamp: Date.now(),
    });
    vi.spyOn(slot as unknown as { extensionToolOrigin: (name: string) => { source: string } | undefined }, "extensionToolOrigin")
      .mockReturnValue({ source: "pi-subagents" });

    const warnings: Array<{ reason: string; owner: string }> = [];
    (slot as unknown as { dependencies: { extensionArtifactWarning?: (warning: { reason: string; owner: string }) => void } })
      .dependencies.extensionArtifactWarning = (warning) => warnings.push(warning);
    await writeHeader(ownedHeader);
    await slot.ownedTurns.discoverExtensionArtifact(asyncDir);
    const admitted = projectedExtensionActivity(slot.snapshot().extensionActivities, toolCallId);
    expect(admitted).toMatchObject({ status: "running", children: expect.arrayContaining([
      expect.objectContaining({ id: "step-a", status: "completed" }),
      expect.objectContaining({ id: "step-c", status: "running" }),
    ]) });

    await writeHeader(foreignHeader);
    await slot.ownedTurns.discoverExtensionArtifact(asyncDir);
    const afterForeign = projectedExtensionActivity(slot.snapshot().extensionActivities, toolCallId);
    expect(afterForeign.children.find((child) => child.id === "step-a")?.status).toBe("completed");
    expect(warnings).toContainEqual(expect.objectContaining({ reason: "ownership-mismatch" }));
    await writeHeader(foreignTerminalHeader);
    await slot.ownedTurns.discoverExtensionArtifact(asyncDir);
    expect(slot.snapshot().extensionActivities?.find((activity) => activity.toolCallId === toolCallId)?.status).toBe("running");
    const receiptCount = async (sessionFile: string) => (await readFile(sessionFile, "utf8"))
      .trimEnd().split("\n").map((line) => JSON.parse(line) as Record<string, unknown>)
      .filter((entry) => entry.type === "custom" && entry.customType === EXTENSION_ACTIVITY_RECEIPT_TYPE).length;
    expect(await receiptCount(slot.sessionFile!)).toBe(0);

    await fixture.registry.dispose();
    const recoveredRegistry = await createTestRegistry({
      agentDir: fixture.agentDir, tronHome: join(fixture.root, "tron"), idleRuntimeMs: 60_000,
      trust: new TrustService(fixture.agentDir), broadcast: () => {},
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(recoveredRegistry);
    await initializeRegistry(recoveredRegistry);
    const recoveredSlot = await recoveredRegistry.acquire(slot.id);
    vi.spyOn(recoveredSlot as unknown as { extensionToolOrigin: (name: string) => { source: string } | undefined }, "extensionToolOrigin")
      .mockReturnValue({ source: "pi-subagents" });
    await discoverExtensionArtifactsUntil(recoveredRegistry);
    await recoveredSlot.ownedTurns.discoverExtensionArtifact(asyncDir);
    const coldForeign = recoveredSlot.snapshot().extensionActivities?.find((activity) => activity.runId === runId);
    expect(coldForeign?.status).not.toBe("completed");
    expect(coldForeign?.children.some((child) => child.id === "step-a" && child.status === "completed")).not.toBe(true);
    expect(await receiptCount(recoveredSlot.sessionFile!)).toBe(0);

    await writeHeader(ownedHeader);
    await discoverExtensionArtifactsUntil(recoveredRegistry);
    expect(recoveredSlot.snapshot().extensionActivities?.find((activity) => activity.toolCallId === toolCallId)).toMatchObject({
      status: "running", children: expect.arrayContaining([expect.objectContaining({ id: "step-a", status: "completed" })]),
    });
    expect(await receiptCount(recoveredSlot.sessionFile!)).toBe(0);
  });

  it("discovers oversized active lifecycle headers on the registered path and after runtime reconstruction", async () => {
    const fixture = await coldFixture("oversized-active-lifecycle-discovery");
    const runId = "oversized-active-workflow";
    const toolCallId = "oversized-active-tool";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const now = Date.now();
    const root = {
      id: runId, kind: "workflow", label: "large workflow", state: "running",
      startedAt: now - 10_000, updatedAt: now,
      children: [
        { id: "step-a", kind: "step", label: "A", state: "complete", startedAt: now - 9_000, updatedAt: now - 5_000, endedAt: now - 5_000 },
        { id: "step-b", kind: "step", label: "B", state: "complete", startedAt: now - 8_000, updatedAt: now - 4_000, endedAt: now - 4_000 },
        { id: "step-c", kind: "step", label: "C", state: "running", startedAt: now - 3_000, updatedAt: now },
      ],
    };
    const projection = () => ({
      version: 1, runId, toolCallId, sessionId: slot.sessionFile, generatedAt: root.updatedAt,
      caps: { maxRuns: 1, maxChildrenPerNode: 8, maxDepth: 3, maxStringLength: 160, maxSerializedBytes: 30_720 },
      omitted: { runs: 0, children: 0, byteLimitExceeded: false }, root: structuredClone(root),
    });
    const statusPath = join(asyncDir, "status.json");
    const writeModern = async () => writeFile(statusPath, JSON.stringify({
      lifecycleProjection: projection(), lifecycleArtifactVersion: 3, runId, state: root.state,
      startedAt: root.startedAt, lastUpdate: root.updatedAt,
      steps: [{ report: "x".repeat(300 * 1_024) }],
    }));
    const runtimeManager = (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } }).runtime.session.sessionManager;
    runtimeManager.appendMessage({
      role: "toolResult", toolCallId, toolName: "subagent", content: [{ type: "text", text: "launched" }],
      details: { runId, asyncId: runId, asyncDir, mode: "workflow", state: "running" },
      isError: false, timestamp: now,
    });
    vi.spyOn(slot as unknown as { extensionToolOrigin: (name: string) => { source: string } | undefined }, "extensionToolOrigin")
      .mockReturnValue({ source: "pi-subagents" });
    await writeModern();
    await discoverExtensionArtifactsUntil(fixture.registry, () => {
      const activity = (slot.snapshot().extensionActivities ?? []).find((candidate) => candidate.toolCallId === toolCallId);
      return activity?.status === "running"
        && activity.children.some((child) => child.id === "step-c" && child.status === "running");
    });
    expect((slot.snapshot().extensionActivities ?? []).find((activity) => activity.toolCallId === toolCallId)).toMatchObject({
      status: "running", children: expect.arrayContaining([
        expect.objectContaining({ id: "step-a", status: "completed" }),
        expect.objectContaining({ id: "step-b", status: "completed" }),
        expect.objectContaining({ id: "step-c", status: "running" }),
      ]),
    });
    expect(slot.snapshot().processOverview.extensionChildOmissions).toMatchObject({ byteLimitExceeded: true });
    expect((await readFile(statusPath)).byteLength).toBeGreaterThan(256 * 1_024);

    const foreignProjection = projection();
    foreignProjection.sessionId = "another-session";
    await writeFile(statusPath, JSON.stringify({ lifecycleProjection: foreignProjection, steps: [{ report: "x".repeat(300 * 1_024) }] }));
    await slot.ownedTurns.discoverExtensionArtifact(asyncDir);
    expect((slot.snapshot().extensionActivities ?? []).find((activity) => activity.toolCallId === toolCallId)?.status).toBe("running");
    await writeFile(statusPath, `{"lifecycleProjection":${"x".repeat(300 * 1_024)}`);
    await slot.ownedTurns.discoverExtensionArtifact(asyncDir);
    expect((slot.snapshot().extensionActivities ?? []).find((activity) => activity.toolCallId === toolCallId)?.status).toBe("running");
    await writeModern();

    const slotState = slot.ownedTurns;
    slotState.stopExtensionActivityWatcher(toolCallId);
    await writeFile(statusPath, JSON.stringify({
      runId, state: "running", startedAt: root.startedAt, lastUpdate: root.updatedAt,
      steps: [{ report: "x".repeat(300 * 1_024) }],
    }));
    const artifactWarnings: Array<{ reason: string; owner: string }> = [];
    slot.dependencies.extensionArtifactWarning = (warning) => artifactWarnings.push(warning);
    slotState.extensionArtifactMissingSince.set(toolCallId, Date.now() - 31_000);
    await slot.ownedTurns.discoverExtensionArtifact(asyncDir);
    expect(artifactWarnings).toMatchObject([{ reason: "oversized-artifact" }]);
    expect(artifactWarnings).not.toMatchObject([{ reason: "artifact-replacement-in-progress" }]);
    expect(slotState.extensionActivities.get(toolCallId)?.lifecycle?.state).toBe("unknown");
    expect((slot.snapshot().extensionActivities ?? []).some((activity) => activity.toolCallId === toolCallId)).toBe(false);

    await fixture.registry.dispose();
    await writeModern();
    const recoveredRegistry = await createTestRegistry({
      agentDir: fixture.agentDir, tronHome: join(fixture.root, "tron"), idleRuntimeMs: 60_000,
      trust: new TrustService(fixture.agentDir), broadcast: () => {},
      sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(recoveredRegistry);
    await initializeRegistry(recoveredRegistry);
    const recoveredSlot = await recoveredRegistry.acquire(slot.id);
    vi.spyOn(recoveredSlot as unknown as { extensionToolOrigin: (name: string) => { source: string } | undefined }, "extensionToolOrigin")
      .mockReturnValue({ source: "pi-subagents" });
    await discoverExtensionArtifactsUntil(recoveredRegistry, () => {
      const activity = (recoveredSlot.snapshot().extensionActivities ?? []).find((candidate) => candidate.toolCallId === toolCallId);
      return activity?.status === "running"
        && activity.children.some((child) => child.id === "step-c" && child.status === "running");
    });
    expect((recoveredSlot.snapshot().extensionActivities ?? []).find((activity) => activity.toolCallId === toolCallId)).toMatchObject({
      status: "running", children: expect.arrayContaining([
        expect.objectContaining({ id: "step-a", status: "completed" }),
        expect.objectContaining({ id: "step-b", status: "completed" }),
        expect.objectContaining({ id: "step-c", status: "running" }),
      ]),
    });

    root.state = "complete";
    root.updatedAt = Date.now();
    Object.assign(root, { endedAt: root.updatedAt });
    await writeFile(statusPath, JSON.stringify({
      lifecycleProjection: projection(), lifecycleArtifactVersion: 3, runId, state: "complete",
      startedAt: root.startedAt, endedAt: root.updatedAt, lastUpdate: root.updatedAt,
      steps: [{ report: "x".repeat(300 * 1_024) }],
    }));
    await recoveredSlot.ownedTurns.discoverExtensionArtifact(asyncDir);
    await recoveredRegistry.waitUntilIdle();
    expect((recoveredSlot.snapshot().extensionActivities ?? []).find((activity) => activity.toolCallId === toolCallId)?.status).toBe("completed");
    const canonical = (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n")
      .map((line) => JSON.parse(line) as Record<string, unknown>);
    expect(canonical.filter((entry) => entry.type === "custom" && entry.customType === EXTENSION_ACTIVITY_RECEIPT_TYPE)).toHaveLength(1);
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
    const internal = slot.ownedTurns;
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

    await slot.ownedTurns.discoverExtensionArtifact(asyncDir);
    expect(slot.isDrainBusy).toBe(true);

    await rm(join(asyncDir, "status.json"));
    await writeFile(join(asyncDir, "status.json"), status);
    await writeFile(join(foreignDir, "events.jsonl"), `${completedEvent}\n`);
    await rm(join(asyncDir, "events.jsonl"));
    await symlink(join(foreignDir, "events.jsonl"), join(asyncDir, "events.jsonl"));
    await slot.ownedTurns.discoverExtensionArtifact(asyncDir);
    expect(slot.isDrainBusy).toBe(true);

    await rm(join(asyncDir, "events.jsonl"));
    await writeFile(join(asyncDir, "events.jsonl"), `${completedEvent}\n${JSON.stringify({
      ts: ended + 3,
      runId,
      type: "subagent.workflow.completed",
      state: "failed",
    })}\n`);
    await slot.ownedTurns.discoverExtensionArtifact(asyncDir);
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
    const manager = (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } })
      .runtime.session.sessionManager;
    manager.appendMessage({
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

    const discovered = vi.spyOn(slot.ownedTurns, "discoverExtensionArtifact");
    await discoverExtensionArtifactsUntil(fixture.registry, () => discovered.mock.calls.length > 0);
    expect(discovered.mock.calls[0]?.[0]).toMatch(/async-subagent-runs[\\/]late-active-run$/u);
  });

  it("examines every ambient artifact within a bounded number of passes and reports a stopped pass", async () => {
    const stopped: ExtensionArtifactDiscoveryCounts[] = [];
    const delegated = await delegatedFixtureRoot("ambient-change-gate");
    const artifactCount = 1_100;
    const startedAt = Date.now();
    const runsRoot = join(delegated.delegatedRoot, "async-subagent-runs");
    const runDirectories = Array.from({ length: artifactCount }, (_unused, index) => ({
      asyncDir: join(runsRoot, `run-${String(index).padStart(4, "0")}`),
      runId: `run-${String(index).padStart(4, "0")}`,
    }));
    const writeStatus = async (run: { asyncDir: string; runId: string }, lastUpdate: number) => {
      await writeFile(join(run.asyncDir, "status.json"), JSON.stringify({
        lifecycleArtifactVersion: 3, runId: run.runId, state: "running", startedAt, lastUpdate,
      }));
    };
    await Promise.all(runDirectories.map(async (run) => {
      await mkdir(run.asyncDir, { recursive: true });
      await writeStatus(run, startedAt);
    }));
    const fixture = await coldFixture("ambient-change-gate", {
      delegatedRoot: delegated.delegatedRoot,
      artifactDiscoveryTruncated: (counts) => stopped.push(counts),
    });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const routed = vi.spyOn(slot.ownedTurns, "discoverExtensionArtifact");

    await discoverExtensionArtifactsUntil(fixture.registry);
    expect(stopped).toEqual([{ entries: 1_025, statusReads: 1_024, work: 0, dropped: 0 }]);
    expect(routed.mock.calls).toEqual([]);

    await discoverExtensionArtifactsUntil(fixture.registry);
    expect(stopped).toHaveLength(1);

    const second = SessionManager.create(fixture.cwd, dirname(fixture.sessionFile));
    second.appendMessage(fauxAssistantMessage("second ambient slot"));
    await settleCatalog(fixture.registry);
    await fixture.registry.acquire(second.getSessionId());
    vi.spyOn(slot as unknown as { extensionToolOrigin: (name: string) => { source: string } | undefined }, "extensionToolOrigin")
      .mockReturnValue({ source: "pi-subagents" });
    const late = runDirectories[artifactCount - 1]!;
    (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } }).runtime.session.sessionManager.appendMessage({
      role: "toolResult", toolCallId: `${late.runId}-tool`, toolName: "subagent",
      content: [{ type: "text", text: "launched" }],
      details: { runId: late.runId, asyncDir: late.asyncDir, state: "running" }, isError: false, timestamp: Date.now(),
    });
    const passes = await discoverExtensionArtifactsUntil(fixture.registry, () => routed.mock.calls.some(([asyncDir]) => asyncDir === late.asyncDir));
    expect(passes, "the pass that offers the newly attributed run").toBe(1);
    expect(new Set(routed.mock.calls.map(([asyncDir]) => asyncDir))).toEqual(new Set([late.asyncDir]));
    expect(stopped).toHaveLength(1);
    await rm(delegated.root, { recursive: true, force: true });
  });

  it("offers a run known only from the session log again after a claim the slot could not take", async () => {
    const delegated = await delegatedFixtureRoot("ambient-claim-retry");
    const completedAt = Date.now() - 1_000;
    const fixture = await coldFixture("ambient-claim-retry", { delegatedRoot: delegated.delegatedRoot });
    const runId = "claim-retry-run";
    const toolCallId = "claim-retry-tool";
    const asyncDir = join(delegated.delegatedRoot, "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3, runId, state: "complete",
      startedAt: completedAt - 60_000, lastUpdate: completedAt, endedAt: completedAt,
    }));
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    vi.spyOn(slot as unknown as { extensionToolOrigin: (name: string) => { source: string } | undefined }, "extensionToolOrigin")
      .mockReturnValue({ source: "pi-subagents" });
    (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } }).runtime.session.sessionManager.appendMessage({
      role: "toolResult", toolCallId, toolName: "subagent", content: [{ type: "text", text: "launched" }],
      details: { runId, asyncDir, state: "running" }, isError: false, timestamp: Date.now(),
    });
    const claim = vi.spyOn(slot.ownedTurns, "claimExtensionReceiptOwnership");
    claim.mockReturnValueOnce(undefined);
    const offered = vi.spyOn(slot.ownedTurns, "discoverExtensionArtifact");
    const projected = () => slot.snapshot().extensionActivities?.find((activity) => activity.toolCallId === toolCallId);

    await discoverExtensionArtifactsUntil(fixture.registry, () => projected() !== undefined);
    expect(projected()).toMatchObject({ status: "completed", runId });
    expect(offered.mock.calls.length).toBeGreaterThanOrEqual(2);
    await rm(delegated.root, { recursive: true, force: true });
  });

  it("does not reopen an unchanged ambient artifact for a live slot", async () => {
    const delegated = await delegatedFixtureRoot("ambient-steady-state");
    const startedAt = Date.now();
    const runsRoot = join(delegated.delegatedRoot, "async-subagent-runs");
    await mkdir(runsRoot, { recursive: true });
    const finishedStatus = (runId: string) => JSON.stringify({
      lifecycleArtifactVersion: 3, runId, state: "complete",
      startedAt: startedAt - 120_000, lastUpdate: startedAt - 120_000, endedAt: startedAt - 120_000,
    });
    const fixture = await coldFixture("ambient-steady-state", { delegatedRoot: delegated.delegatedRoot });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    vi.spyOn(slot as unknown as { extensionToolOrigin: (name: string) => { source: string } | undefined }, "extensionToolOrigin")
      .mockReturnValue({ source: "pi-subagents" });
    const finishedRunId = "owned-finished-run";
    const liveRunId = "owned-live-run";
    const finishedDir = join(runsRoot, finishedRunId);
    const liveDir = join(runsRoot, liveRunId);
    for (const runId of [finishedRunId, liveRunId]) await mkdir(join(runsRoot, runId), { recursive: true });
    await writeFile(join(finishedDir, "status.json"), finishedStatus(finishedRunId));
    await writeFile(join(liveDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3, runId: liveRunId, state: "running",
      startedAt: startedAt - 60_000, lastUpdate: startedAt - 1_000,
    }));
    const manager = (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } }).runtime.session.sessionManager;
    for (const [runId, asyncDir] of [[finishedRunId, finishedDir], [liveRunId, liveDir]] as const) {
      manager.appendMessage({
        role: "toolResult", toolCallId: `${runId}-tool`, toolName: "subagent",
        content: [{ type: "text", text: "launched" }],
        details: { runId, asyncDir, state: "running" }, isError: false, timestamp: Date.now(),
      });
    }
    const routed = vi.spyOn(slot.ownedTurns, "discoverExtensionArtifact");

    await discoverExtensionArtifactsUntil(fixture.registry, () => routed.mock.calls.length >= 2);
    expect(new Set(routed.mock.calls.map(([asyncDir]) => asyncDir))).toEqual(new Set([finishedDir, liveDir]));

    routed.mockClear();
    await discoverExtensionArtifactsUntil(fixture.registry);
    expect(new Set(routed.mock.calls.map(([asyncDir]) => asyncDir))).toEqual(new Set([liveDir]));

    await writeFile(join(finishedDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3, runId: finishedRunId, state: "complete",
      startedAt: startedAt - 120_000, lastUpdate: startedAt + 1_000, endedAt: startedAt + 1_000,
    }));
    await discoverExtensionArtifactsUntil(fixture.registry, () => routed.mock.calls.some(([asyncDir]) => asyncDir === finishedDir));
    expect(routed.mock.calls.some(([asyncDir]) => asyncDir === finishedDir)).toBe(true);
    await rm(delegated.root, { recursive: true, force: true });
  });

  it("retries a status.json read that raced an atomic replacement instead of rejecting it", async () => {
    const delegated = await delegatedFixtureRoot("artifact-atomic-replace");
    const fixture = await coldFixture("artifact-atomic-replace", { delegatedRoot: delegated.delegatedRoot });
    const runId = "atomic-replace-run";
    const toolCallId = "atomic-replace-tool";
    const asyncDir = join(delegated.delegatedRoot, "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const registryInternal = fixture.registry as unknown as { artifactDiscoveryTimer?: NodeJS.Timeout };
    if (registryInternal.artifactDiscoveryTimer) clearInterval(registryInternal.artifactDiscoveryTimer);
    registryInternal.artifactDiscoveryTimer = undefined;
    vi.spyOn(slot as unknown as { extensionToolOrigin: (name: string) => { source: string } | undefined }, "extensionToolOrigin")
      .mockReturnValue({ source: "pi-subagents" });
    (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } }).runtime.session.sessionManager.appendMessage({
      role: "toolResult", toolCallId, toolName: "subagent", content: [{ type: "text", text: "launched" }],
      details: { runId, asyncDir, state: "running" }, isError: false, timestamp: Date.now(),
    });
    const payload = JSON.stringify({
      lifecycleArtifactVersion: 3, runId, state: "running",
      startedAt: Date.now() - 1_000, lastUpdate: Date.now(),
    });
    const statusPath = join(asyncDir, "status.json");
    await writeFile(statusPath, payload);
    const warnings: Array<{ reason: string }> = [];
    (slot as unknown as { dependencies: { extensionArtifactWarning?: (warning: { reason: string }) => void } })
      .dependencies.extensionArtifactWarning = (warning) => warnings.push(warning);
    await slot.ownedTurns.discoverExtensionArtifact(asyncDir);
    const projected = () => slot.snapshot().extensionActivities?.find((activity) => activity.toolCallId === toolCallId);
    expect(projected()).toMatchObject({ status: "running" });

    const slotInternals = slot.ownedTurns.artifacts;
    const readOnce = slotInternals.readExtensionStatusArtifact.bind(slotInternals);
    const readWithRetry = slotInternals.readExtensionStatusArtifactWithReplacementRetry.bind(slotInternals);
    const retryInvocation = new AsyncLocalStorage<{ reads: number }>();
    statusJsonReplace.insideRetryInvocation = () => retryInvocation.getStore() !== undefined;
    let retriedLosingReads = 0;
    vi.spyOn(slotInternals, "readExtensionStatusArtifact").mockImplementation(async (directory: string) => {
      const invocation = retryInvocation.getStore();
      if (invocation) invocation.reads += 1;
      return readOnce(directory);
    });
    vi.spyOn(slotInternals, "readExtensionStatusArtifactWithReplacementRetry")
      .mockImplementation((directory: string) => retryInvocation.run({ reads: 0 }, async () => {
        const invocation = retryInvocation.getStore()!;
        try {
          return await readWithRetry(directory);
        } finally {
          if (invocation.reads > 1) retriedLosingReads += 1;
        }
      }));
    const canonicalAsyncDir = await realpath(asyncDir);
    statusJsonReplace.armed = true;
    statusJsonReplace.losses = 0;
    statusJsonReplace.replacements = 0;
    statusJsonReplace.payload = payload;
    statusJsonReplace.statusPath = join(canonicalAsyncDir, "status.json");
    statusJsonReplace.tempPath = join(canonicalAsyncDir, "status.tmp");
    try {
      await slot.ownedTurns.discoverExtensionArtifact(asyncDir);
    } finally {
      statusJsonReplace.armed = false;
      statusJsonReplace.insideRetryInvocation = () => false;
    }
    expect(statusJsonReplace.replacements, "the injected replace").toBe(1);
    expect(retriedLosingReads, "the read that lost the race and was retried").toBe(1);
    expect(warnings.filter((warning) => warning.reason === "artifact-replacement-in-progress")).toEqual([]);
    expect(projected()).toMatchObject({ status: "running", runId });
    await rm(delegated.root, { recursive: true, force: true });
  });

  it("reconciles the launch owner after a supervisor reply references the same run", async () => {
    const fixture = await coldFixture("supervisor-reply-ownership");
    const slot = await fixture.registry.acquire(fixture.manager.getSessionId());
    const manager = (slot as unknown as { runtime: { session: { sessionManager: SessionManager } } }).runtime.session.sessionManager;
    const runId = "supervisor-target-run";
    const toolCallId = "subagent-launch-call";
    const asyncDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", runId);
    await mkdir(asyncDir, { recursive: true });
    vi.spyOn(slot as unknown as { extensionToolOrigin: (name: string) => { source: string } | undefined }, "extensionToolOrigin")
      .mockReturnValue({ source: "pi-subagents" });
    manager.appendMessage({
      role: "toolResult", toolCallId, toolName: "subagent",
      content: [{ type: "text", text: "launched" }],
      details: { runId, asyncId: runId, asyncDir, mode: "single", results: [] },
      isError: false, timestamp: Date.now(),
    });
    const startedAt = Date.now() - 1_000;
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3, runId, state: "running", startedAt, lastUpdate: Date.now(),
    }));
    const internal = slot.ownedTurns;
    const started = new Date(startedAt).toISOString();
    internal.extensionActivities.set(toolCallId, {
      id: toolCallId, activityId: "supervisor-launch-activity", runId, toolCallId,
      source: { source: "pi-subagents" }, title: "worker", status: "running",
      startedAt: started, updatedAt: started, children: [],
      lifecycle: { version: 1, state: "running", attention: "none", sequence: 1, observedAt: started },
    });
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    expect(slot.isDrainBusy).toBe(true);

    const reply = { content: [{ type: "text" as const, text: "Replied" }], details: { replyTo: "request-1", runId, agent: "worker" } };
    manager.appendMessage({
      role: "toolResult", toolCallId: "supervisor-reply-call", toolName: "subagent_supervisor",
      ...reply, isError: false, timestamp: Date.now(),
    });
    const now = new Date().toISOString();
    expect(updateExtensionActivity(internal, "supervisor-reply-call", "subagent_supervisor", { source: "pi-subagents" }, "completed", now, now, reply, now)).toBeUndefined();

    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3, runId, state: "complete", startedAt, lastUpdate: Date.now(), endedAt: Date.now(),
    }));
    await slot.ownedTurns.discoverExtensionArtifact(asyncDir);
    expect(slot.snapshot().extensionActivities).toMatchObject([{ toolCallId, lifecycle: { state: "completed" } }]);
    expect(slot.snapshot().extensionActivities).toHaveLength(1);
    await fixture.registry.waitUntilIdle();
    expect(slot.isDrainBusy).toBe(false);
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
    const internal = slot.ownedTurns;
    await refreshSubagentActivityFromArtifact(internal, asyncDir);
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
    await refreshSubagentActivityFromArtifact(internal, unboundHistoricalDir);
    expect(slot.snapshot().extensionActivities ?? []).toEqual([]);

    const pathPolicy = slot.ownedTurns;
    expect(pathPolicy.extensionArtifactPathAllowed(projectRoot)).toBe(false);
    expect(pathPolicy.extensionArtifactPathAllowed(`${projectRoot}/.`)).toBe(false);
    expect(pathPolicy.extensionArtifactPathAllowed(`${projectRoot}/../escape`)).toBe(false);

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
    await refreshSubagentActivityFromArtifact(internal, ordinaryDir);
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
    const internal = slot.ownedTurns;
    internal.extensionActivities.set(toolCallId, activity);
    internal.extensionRunOwnership.set(runId, { toolCallId, asyncDir, terminal: false });
    const admissionWindowStartedAt = Date.now();
    await writeFile(join(asyncDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3,
      runId,
      state: "completed",
      startedAt: Date.parse(activity.startedAt),
      lastUpdate: Date.parse(artifactCompletedAt),
      endedAt: Date.parse(artifactCompletedAt),
    }));
    await refreshSubagentActivityFromArtifact(internal, asyncDir);
    const admitted = slot.snapshot().extensionActivities?.find((candidate) => candidate.toolCallId === toolCallId);
    expect(admitted).toMatchObject({
      toolCallId,
      status: "completed",
      completedAt: artifactCompletedAt,
    });
    const terminalAt = Date.parse(admitted?.lifecycle?.terminalAt ?? "");
    expect(terminalAt).toBeGreaterThanOrEqual(admissionWindowStartedAt);
    expect(terminalAt).toBeLessThanOrEqual(Date.parse(admitted?.lifecycle?.observedAt ?? ""));
    await new Promise((resolve) => setTimeout(resolve, 2));
    await refreshSubagentActivityFromArtifact(internal, asyncDir);
    const reobserved = slot.snapshot().extensionActivities?.find((candidate) => candidate.toolCallId === toolCallId);
    expect(reobserved?.lifecycle?.terminalAt).toBe(admitted?.lifecycle?.terminalAt);

    const foreignDir = join(fixture.cwd, ".pi", "subagents", "async-subagent-runs", "foreign-run");
    await mkdir(foreignDir, { recursive: true });
    await writeFile(join(foreignDir, "status.json"), JSON.stringify({
      lifecycleArtifactVersion: 3,
      runId,
      state: "running",
      startedAt: Date.parse(activity.startedAt),
      lastUpdate: Date.parse("2026-01-01T00:00:05.000Z"),
    }));
    await refreshSubagentActivityFromArtifact(internal, foreignDir);
    await refreshExtensionActivityFromArtifact(internal, toolCallId, foreignDir);
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
    const duplicateFact = canonicalExtensionRunFacts(internal).get("duplicate-canonical-run");
    expect(duplicateFact?.toolCallId).toBeUndefined();
    expect(duplicateFact?.ambiguous).toBe(true);
  });
});
