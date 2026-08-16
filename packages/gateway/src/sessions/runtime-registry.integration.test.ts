import { randomUUID } from "node:crypto";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import type { SessionSummaryUpdate } from "../protocol/types.js";
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

  afterEach(async () => {
    await Promise.all(registries.splice(0).map((registry) => registry.dispose()));
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
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

  it("does not let an older settlement hide an extension-triggered continuation", async () => {
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
    await slot.prompt("start");

    await waitUntil(() => faux.state.callCount === 2);
    expect(slot.snapshot()).toMatchObject({ phase: "running", operation: { kind: "prompt" } });
    const continuationSnapshotIndex = snapshots.length;
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(snapshots.slice(continuationSnapshotIndex).every((snapshot) => snapshot.phase === "running" && snapshot.operation)).toBe(true);
    await waitUntil(() => !slot.isBusy);
    expect(slot.snapshot()).toMatchObject({ phase: "idle" });
    expect(snapshots.some((snapshot) => snapshot.phase === "running" && snapshot.operation)).toBe(true);
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
      const prompting = slot.prompt("delayed preflight");
      await started;
      await vi.advanceTimersByTimeAsync(6_000);
      await expect(prompting).resolves.toMatchObject({ operationId: expect.any(String) });
    } finally {
      vi.useRealTimers();
    }
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
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);

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

    await slot.prompt("first steer", [], "steer", {
      text: "first steer",
      attachmentEnvelope: "",
      attachmentCount: 0,
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
    const queued = slot.snapshot();
    expect(queued.queuedItems).toHaveLength(3);
    expect(queued.queuedItems?.map((item) => item.behavior)).toEqual(["steer", "steer", "followUp"]);
    expect(queued.queuedItems?.map((item) => item.text)).toEqual(["first steer", "first steer", "later follow-up"]);
    expect(new Set(queued.queuedItems?.map((item) => item.id)).size).toBe(3);

    const [first, duplicate, followUp] = queued.queuedItems!;
    const replaced = await slot.replaceQueue(queued.queueRevision!, [
      { id: duplicate!.id, behavior: "steer", text: duplicate!.text },
      { id: followUp!.id, behavior: "steer", text: "edited and earlier" },
      { id: first!.id, behavior: "followUp", text: first!.text },
    ]);
    expect(replaced.items.map(({ id, behavior, text }) => ({ id, behavior, text }))).toEqual([
      { id: duplicate!.id, behavior: "steer", text: "first steer" },
      { id: followUp!.id, behavior: "steer", text: "edited and earlier" },
      { id: first!.id, behavior: "followUp", text: "first steer" },
    ]);
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
      });
    const firstRunning = new Map<string, number>();
    for (const event of progress) {
      if (event.status === "running" && !firstRunning.has(event.toolCallId)) firstRunning.set(event.toolCallId, event.order);
    }
    expect(firstRunning).toEqual(new Map([["call-read", 0], ["call-bash", 1]]));
    const finalOrder = new Map(progress.map((event) => [event.toolCallId, event.order]));
    expect(finalOrder).toEqual(new Map([["call-read", 0], ["call-bash", 1]]));
    const bashProgress = progress.filter((event) => event.toolCallId === "call-bash");
    expect(bashProgress.some((event) => event.status === "running" && event.output?.includes("start"))).toBe(true);
    expect(bashProgress.at(-1)).toMatchObject({ status: "completed", output: "startend" });
    expect(bashProgress.at(-1)!.progressSequence).toBeGreaterThan(2);
    expect(bashProgress.at(-1)!.durationMs).toBeGreaterThanOrEqual(300);
    expect(bashProgress.at(-1)!.completedAt).toBeTypeOf("string");
    const settled = slot.snapshot();
    expect(settled.toolExecutions).toEqual([]);
    expect(settled.transcript.find((item) => item.kind === "message" && item.role === "toolResult" && item.toolCallId === "call-bash"))
      .toMatchObject({ durationMs: expect.any(Number), startedAt: expect.any(String), completedAt: expect.any(String) });
    expect(slot.sessionFile?.startsWith(sessionDir)).toBe(true);
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
    await Promise.all([
      writeFile(join(pi, "extensions", "tool.ts"), `export default function (pi) { pi.registerTool({ name: "project_echo", label: "Project echo", description: "Echo project text", parameters: { type: "object", properties: { text: { type: "string" } }, required: ["text"] }, execute: async (_id, params) => ({ content: [{ type: "text", text: params.text }], details: {} }) }); }\n`),
      writeFile(join(pi, "prompts", "review.md"), `---\ndescription: Review the current change\n---\nReview $ARGUMENTS\n`),
      writeFile(join(pi, "skills", "review", "SKILL.md"), `---\nname: review-skill\ndescription: Inspect a code change\n---\nReview carefully.\n`),
    ]);
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

    await trust.set(cwd, false);
    await registry.reloadProject(cwd);
    const untrusted = slot.resources() as any;
    expect(untrusted.tools).not.toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "project_echo" }),
    ]));
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
    expect(defaultCatalog.map((session) => session.id)).toEqual(expect.arrayContaining([parentId, fork.getSessionId()]));
    expect(defaultCatalog.map((session) => session.id)).not.toContain(nestedId);
    expect(defaultCatalog.map((session) => session.id)).not.toContain(directSubagent.getSessionId());
    expect(defaultCatalog.map((session) => session.id)).not.toContain(externalId);
    expect(completeCatalog.map((session) => session.id)).not.toContain(externalId);
    expect(completeCatalog.find((session) => session.id === parentId)).toMatchObject({ kind: "user" });
    expect(completeCatalog.find((session) => session.id === fork.getSessionId())).toMatchObject({ kind: "user", parentSessionId: parentId });
    expect(completeCatalog.find((session) => session.id === directSubagent.getSessionId())).toMatchObject({
      kind: "subagent",
      parentSessionId: parentId,
    });
    expect(completeCatalog.find((session) => session.id === nestedId)).toMatchObject({
      kind: "subagent",
      parentSessionId: parentId,
    });
    await expect(registry.acquire(nestedId)).rejects.toMatchObject({ code: "conflict" });
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
    await slot.prompt("fork this");
    await waitUntil(() => !slot.isBusy);
    const original = slot.id;
    const userEntry = slot.snapshot().transcript.find((item) => item.role === "user");
    expect(userEntry).toBeDefined();

    const fork = await slot.fork(userEntry!.id, "at");
    expect(fork.sessionId).not.toBe(original);
    expect((await registry.acquire(fork.sessionId)).id).toBe(fork.sessionId);
  });
});
