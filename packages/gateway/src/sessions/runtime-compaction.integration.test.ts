import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type AgentSession, ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { SettingsService } from "../admin/settings-service.js";
import type { SessionSnapshot } from "../protocol/types.js";
import { INVOCATION_RECEIPT_TYPE } from "./invocation-receipts.js";
import { RuntimeRegistry } from "./runtime-registry.js";

async function waitUntil(predicate: () => boolean, timeoutMs = 2_000): Promise<void> {
  const deadline = performance.now() + timeoutMs;
  while (!predicate()) {
    if (performance.now() >= deadline) throw new Error("condition timed out");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

describe.sequential("compaction cancellation with the pinned runtime", () => {
  it("settles one Stop during between-turn compaction without starting another summary", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-compaction-stop-"));
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
    process.env.PI_CODING_AGENT_DIR = agentDir;
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    await writeFile(join(cwd, "large.txt"), "context ".repeat(6_000));
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ compaction: {
      enabled: true, reserveTokens: 120_000, keepRecentTokens: 13_000,
      thinkingLevel: "low", instructions: "retain API decisions",
    } }));
    const faux = fauxProvider({ provider: "tron-compaction-stop", models: [{ id: "faux-reasoning", reasoning: true }], tokensPerSecond: 1_000_000, tokenSize: { min: 100_000, max: 100_000 } });
    const summarySignals: AbortSignal[] = [];
    const providerRequests: Array<{ context: { systemPrompt?: string }; options: { reasoning?: string } | undefined }> = [];
    const ordinaryRequests: typeof providerRequests = [];
    const releaseSummaries = new Set<() => void>();
    let cleaningUp = false;
    faux.setResponses([
      async (context, options) => {
        ordinaryRequests.push({ context, options });
        return fauxAssistantMessage("Earlier ".repeat(1_000));
      },
      async (context, options) => {
        ordinaryRequests.push({ context, options });
        return fauxAssistantMessage(fauxToolCall("read", { path: "large.txt" }));
      },
      ...Array.from({ length: 8 }, () => async (context: { systemPrompt?: string }, options: { signal?: AbortSignal; reasoning?: string } | undefined) => {
        providerRequests.push({ context, options });
        const signal = options?.signal;
        if (!signal) throw new Error("summary must carry cancellation");
        summarySignals.push(signal);
        await new Promise<void>((resolve) => {
          const release = () => {
            signal.removeEventListener("abort", release);
            releaseSummaries.delete(release);
            resolve();
          };
          releaseSummaries.add(release);
          signal.addEventListener("abort", release, { once: true });
          if (signal.aborted || cleaningUp) release();
        });
        return fauxAssistantMessage("Summary of earlier work.");
      }),
    ]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime, trust: new TrustService(agentDir),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    let session: AgentSession | undefined;
    let stopping: Promise<void> | undefined;
    try {
      await registry.initialize();
      const slot = await registry.create(cwd);
      session = (slot as unknown as { runtime: { session: AgentSession } }).runtime.session;
      const model = faux.getModel();
      await slot.setModel(model.provider, model.id);
      await slot.prompt("An earlier request.");
      await waitUntil(() => !slot.isBusy);
      const { operationId } = await slot.prompt("Read large.txt, then explain it.");
      await waitUntil(() => summarySignals.length > 0);
      expect(providerRequests.length).toBeGreaterThan(0);
      expect(ordinaryRequests).toHaveLength(2);
      expect(ordinaryRequests.every(request => request.options?.reasoning !== "low")).toBe(true);
      expect(ordinaryRequests.every(request => !request.context.systemPrompt?.includes("retain API decisions"))).toBe(true);
      expect(providerRequests.every(request => request.options?.reasoning === "low")).toBe(true);
      expect(providerRequests.every(request => request.context.systemPrompt?.includes("retain API decisions"))).toBe(true);
      expect(slot.snapshot().phase).toBe("compacting");
      const callsAtStop = faux.state.callCount;
      stopping = slot.abort("compaction", slot.snapshot().operation!.id);
      let stopped = false;
      void stopping.then(() => { stopped = true; }, () => {});
      await waitUntil(() => stopped);
      await stopping;
      await waitUntil(() => !slot.isBusy);
      expect(summarySignals.every((signal) => signal.aborted)).toBe(true);
      expect(faux.state.callCount).toBe(callsAtStop);
      expect(session.isIdle).toBe(true);
      expect(slot.snapshot()).toMatchObject({ phase: "idle", compactionQueued: false });
      expect(slot.snapshot().operation).toBeUndefined();
      expect(registry.administrativeWorkRegistry.size).toBe(0);
      expect(await readdir(join(root, "tron", "gateway", "runtime-markers"))).toEqual([]);
      const entries = (await readFile(slot.sessionFile!, "utf8")).trimEnd().split("\n").map((line) => JSON.parse(line));
      expect(entries.filter((entry) => entry.type === "compaction")).toEqual([]);
      expect(entries.filter((entry) => entry.message?.role === "assistant").at(-1)?.message)
        .toMatchObject({ stopReason: "aborted" });
      expect(entries.find((entry) => entry.customType === INVOCATION_RECEIPT_TYPE
        && entry.data.receiptKind === "terminal" && entry.data.operationId === operationId)?.data)
        .toMatchObject({ lifecycle: "interrupted", errorCode: "user-abort" });

      // Stop is scoped to the cancelled request, not a persistent ban on compaction.
      faux.setResponses(Array.from({ length: 6 }, () => fauxAssistantMessage("Fresh response after Stop.")));
      await slot.prompt("Continue after Stop.");
      await waitUntil(() => !slot.isBusy);
      expect(session.sessionManager.getBranch().some((entry) => entry.type === "compaction")).toBe(true);
      expect(session.messages.at(-1)).toMatchObject({ role: "assistant", stopReason: "stop" });
      expect(slot.snapshot().phase).toBe("idle");
    } finally {
      // Failure cleanup must also release the *second* summary on the unfixed SDK path.
      cleaningUp = true;
      session?.settingsManager.applyOverrides({ compaction: { enabled: false } });
      session?.abortCompaction();
      session?.agent.abort();
      for (const release of releaseSummaries) release();
      await stopping?.catch(() => {});
      await registry.dispose();
      if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
      else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
      await rm(root, { recursive: true, force: true });
    }
  });
});

const disposals: Array<() => Promise<void>> = [];
afterEach(async () => { for (const dispose of disposals.splice(0).reverse()) await dispose(); });

async function boundaryFixture(historyRepeats = 8_000) {
  const root = await mkdtemp(join(tmpdir(), "tron-compaction-boundary-"));
  const agentDir = join(root, "agent");
  const cwd = join(root, "project");
  await Promise.all([mkdir(agentDir), mkdir(cwd)]);
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ compaction: {
    enabled: false, reserveTokens: 120_000, keepRecentTokens: 13_000, thinkingLevel: "low", instructions: "Retain the API contract",
  } }));
  const faux = fauxProvider({ provider: "tron-compaction-boundary", models: [{ id: "fixture", reasoning: true }], tokensPerSecond: 1_000_000, tokenSize: { min: 100_000, max: 100_000 } });
  const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
  runtime.registerNativeProvider(faux.provider);
  const snapshots: SessionSnapshot[] = [];
  let onSnapshot: ((snapshot: SessionSnapshot) => void) | undefined;
  const registry = new RuntimeRegistry({
    agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
    modelRuntimeFactory: async () => runtime, trust: new TrustService(agentDir),
    broadcast: (_id, event, value) => {
      if (event === "session.snapshot") {
        const snapshot = value as unknown as SessionSnapshot;
        snapshots.push(snapshot);
        onSnapshot?.(snapshot);
      }
    }, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
  });
  const settings = new SettingsService(agentDir, runtime);
  disposals.push(async () => { await registry.dispose(); await rm(root, { recursive: true, force: true }); });
  await registry.initialize();
  const slot = await registry.create(cwd);
  const session = (slot as unknown as { runtime: { session: AgentSession } }).runtime.session;
  await slot.setModel(faux.getModel().provider, faux.getModel().id);
  faux.setResponses([fauxAssistantMessage("Earlier work ".repeat(historyRepeats))]);
  await slot.prompt("Establish the API contract");
  await waitUntil(() => !slot.isBusy);
  const update = async (compaction: Record<string, unknown>) => {
    await settings.update({ compaction }, { cwd, scope: "global", projectTrusted: false });
    registry.refreshCompactionPolicies("global", cwd);
  };
  return { root, slot, session, faux, snapshots, registry, update,
    observe: (callback: typeof onSnapshot) => { onSnapshot = callback; },
    entries: async () => (await readFile(slot.sessionFile!, "utf8")).trim().split("\n").map(line => JSON.parse(line)),
  };
}

async function expectSettled(item: Awaited<ReturnType<typeof boundaryFixture>>) {
  await waitUntil(() => !item.slot.isBusy);
  expect(item.slot.snapshot()).toMatchObject({ phase: "idle", compactionQueued: false });
  expect(item.slot.snapshot().operation).toBeUndefined();
  expect(item.slot.snapshot().compactionPolicy?.active).toBeUndefined();
  expect(item.registry.administrativeWorkRegistry.size).toBe(0);
  expect(await readdir(join(item.root, "tron", "gateway", "runtime-markers"))).toEqual([]);
}

describe.sequential("compaction operation admission and authoritative reconciliation", () => {
  it.each(["start", "provider"] as const)("one Stop at preflight %s prevents the waiting prompt from reaching the provider", async timing => {
    const item = await boundaryFixture();
    await item.update({ enabled: true });
    expect(item.slot.snapshot().compactionPolicy).toMatchObject({ next: { enabled: true }, currentBudgets: { enabled: false } });
    let entered = false;
    let release: (() => void) | undefined;
    item.faux.setResponses([
      async (_context, options) => {
        entered = true;
        await new Promise<void>(resolve => {
          release = resolve;
          options?.signal?.addEventListener("abort", () => resolve(), { once: true });
          if (options?.signal?.aborted) resolve();
        });
        return fauxAssistantMessage("Cancelled summary");
      },
      () => { throw new Error("A stopped pending prompt must never reach the provider"); },
    ]);
    let stopping: Promise<void> | undefined;
    let stoppedID: string | undefined;
    if (timing === "start") {
      item.session.subscribe(event => {
        if (event.type !== "compaction_start" || stopping) return;
        stoppedID = item.slot.snapshot().operation!.id;
        stopping = item.slot.abort("compaction", stoppedID);
      });
    }
    const outcome = item.slot.prompt("This pending request must not run").then(value => ({ value, error: undefined }), error => ({ value: undefined, error }));
    try {
      if (timing === "provider") {
        await waitUntil(() => entered);
        expect(item.slot.snapshot().compactionPolicy?.active).toMatchObject({ reason: "threshold", thinkingLevel: "low", effectiveThinkingLevel: "low" });
        stoppedID = item.slot.snapshot().operation!.id;
        stopping = item.slot.abort("compaction", stoppedID);
      }
      await waitUntil(() => stopping !== undefined);
      await stopping;
      expect((await outcome).error).toBeDefined();
      await expectSettled(item);
      expect(item.faux.state.callCount).toBe(timing === "start" ? 1 : 2);
      const entries = await item.entries();
      expect(entries.some(entry => entry.type === "compaction")).toBe(false);
      expect(entries.filter(entry => entry.message?.role === "user")).toHaveLength(1);
      expect(entries.filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data.receiptKind === "terminal").at(-1)?.data)
        .toMatchObject({ lifecycle: "interrupted", errorCode: "user-abort" });
      await expect(item.slot.abort("compaction", stoppedID)).rejects.toMatchObject({ code: "conflict" });
      await item.update({ enabled: false });
      item.faux.setResponses([fauxAssistantMessage("Explicit later request succeeded")]);
      await item.slot.prompt("A later user-requested continuation");
      await expectSettled(item);
      expect((await item.entries()).filter(entry => entry.message?.role === "user")).toHaveLength(2);
    } finally { release?.(); await outcome; await stopping?.catch(() => {}); }
  });

  it.each(["preflight", "post-run"] as const)("keeps Stop authoritative while %s compaction auth is still preparing", async mode => {
    const item = await boundaryFixture(mode === "preflight" ? 8_000 : 10);
    await item.update({ enabled: true });
    let entered = false;
    let release!: () => void;
    const original = item.session.modelRuntime.getAuth.bind(item.session.modelRuntime);
    const auth = vi.spyOn(item.session.modelRuntime, "getAuth").mockImplementation(async (...args) => {
      if (!entered && (mode === "preflight" || item.faux.state.callCount >= 2)) {
        entered = true;
        await new Promise<void>(resolve => { release = resolve; });
      }
      return original(...args);
    });
    item.faux.setResponses([
      ...(mode === "post-run" ? [fauxAssistantMessage("Completed assistant response ".repeat(5_000))] : []),
      ...Array.from({ length: 4 }, () => fauxAssistantMessage("This summary must not start")),
    ]);
    const prompting = item.slot.prompt("Stop during summary auth").catch(error => error);
    let stopping: Promise<void> | undefined;
    try {
      await waitUntil(() => entered);
      expect(item.slot.snapshot().phase).toBe("running");
      stopping = item.slot.abort("agent", item.slot.snapshot().operation!.id);
      release();
      await stopping;
      if (mode === "preflight") expect(await prompting).toBeInstanceOf(Error);
      else expect(await prompting).toMatchObject({ operationId: expect.any(String) });
      await expectSettled(item);
      expect(item.faux.state.callCount).toBe(mode === "preflight" ? 1 : 2);
      expect((await item.entries()).filter(entry => entry.message?.role === "user")).toHaveLength(mode === "preflight" ? 1 : 2);
      expect((await item.entries()).filter(entry => entry.type === "compaction")).toHaveLength(0);
      expect((await item.entries()).filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data.receiptKind === "terminal").at(-1)?.data.lifecycle).toBe("interrupted");
    } finally { release?.(); auth.mockRestore(); await prompting; await stopping?.catch(() => {}); }
  });

  it("honors Stop after Gateway manual admission but before the SDK creates its controller", async () => {
    const item = await boundaryFixture();
    let stopping: Promise<void> | undefined;
    item.observe(snapshot => {
      if (snapshot.operation?.kind === "compaction" && snapshot.operation.reason === "manual" && !stopping) {
        stopping = item.slot.abort("compaction", snapshot.operation.id);
      }
    });
    const result = item.slot.compact().catch(error => error);
    await waitUntil(() => stopping !== undefined);
    await stopping;
    expect(await result).toBeInstanceOf(Error);
    await expectSettled(item);
    expect(item.faux.state.callCount).toBe(1);
    expect((await item.entries()).some(entry => entry.type === "compaction")).toBe(false);
  });

  it("reconciles overflow compaction and automatic continuation without an intermediate idle owner", async () => {
    const item = await boundaryFixture();
    await item.update({ enabled: true, reserveTokens: 4_096, keepRecentTokens: 0 });
    let ordinary = 0;
    let summaries = 0;
    const reasons: string[] = [];
    item.session.subscribe(event => { if (event.type === "compaction_start") reasons.push(event.reason); });
    const respond = () => {
      if (item.slot.snapshot().compactionPolicy?.active) {
        summaries += 1;
        return fauxAssistantMessage("The API contract remains authoritative. Continue the latest request.");
      }
      ordinary += 1;
      return ordinary === 1
        ? fauxAssistantMessage("", { stopReason: "error", errorMessage: "maximum context length is 128000 tokens; context_length_exceeded" })
        : fauxAssistantMessage("Recovered after overflow");
    };
    item.faux.setResponses(Array.from({ length: 6 }, () => respond));
    const start = item.snapshots.length;
    const { operationId } = await item.slot.prompt("Recover this request after context overflow");
    await expectSettled(item);
    expect(reasons).toEqual(["overflow"]);
    expect(ordinary).toBe(2);
    expect(summaries).toBeGreaterThan(0);
    const entries = await item.entries();
    expect(entries.filter(entry => entry.type === "compaction")).toHaveLength(1);
    expect(entries.filter(entry => entry.message?.role === "user")).toHaveLength(2);
    expect(entries.find(entry => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data.operationId === operationId && entry.data.receiptKind === "terminal")?.data.lifecycle).toBe("completed");
    const states = item.snapshots.slice(start);
    const compacting = states.findIndex(snapshot => snapshot.phase === "compacting");
    const finalIdle = states.findIndex((snapshot, index) => index > compacting && snapshot.phase === "idle");
    expect(compacting).toBeGreaterThanOrEqual(0);
    expect(finalIdle).toBeGreaterThan(compacting);
    expect(states.slice(finalIdle).every(snapshot => snapshot.phase === "idle")).toBe(true);
  });

  it("publishes saved, active and next policy independently; successful completion is one canonical checkpoint", async () => {
    const item = await boundaryFixture();
    let entered = false;
    let release!: () => void;
    const requests: Array<{ reasoning?: string; prompt?: string }> = [];
    item.faux.setResponses([
      async (context, options) => {
        requests.push({ reasoning: options?.reasoning, prompt: context.systemPrompt });
        entered = true;
        await new Promise<void>(resolve => { release = resolve; });
        return fauxAssistantMessage("API preserved. Continue implementation.");
      },
      (context, options) => {
        requests.push({ reasoning: options?.reasoning, prompt: context.systemPrompt });
        return fauxAssistantMessage("Recent task context");
      },
    ]);
    const compacting = item.slot.compact();
    try {
      await waitUntil(() => entered);
      const id = item.slot.snapshot().operation!.id;
      await item.update({ thinkingLevel: "high", instructions: "New focus", reserveTokens: 100_000 });
      const reconnect = item.slot.snapshot();
      expect(reconnect.operation?.id).toBe(id);
      expect(reconnect.compactionPolicy).toMatchObject({
        next: { thinkingLevel: "high", instructions: "New focus", reserveTokens: 100_000 },
        currentBudgets: { reserveTokens: 120_000 },
        active: { thinkingLevel: "low", instructions: "Retain the API contract", reserveTokens: 120_000 },
      });
      release();
      await compacting;
      await expectSettled(item);
      const checkpoints = (await item.entries()).filter(entry => entry.type === "compaction");
      expect(checkpoints).toHaveLength(1);
      expect(requests.every(request => request.reasoning === "low" && request.prompt?.includes("Retain the API contract"))).toBe(true);
      expect(item.slot.snapshot().compactionPolicy?.active).toBeUndefined();
      expect(item.snapshots.filter(snapshot => snapshot.phase === "idle").at(-1)?.compactionPolicy?.active).toBeUndefined();
      item.faux.setResponses([fauxAssistantMessage("Continuation uses the checkpoint")]);
      await item.slot.prompt("Continue");
      await expectSettled(item);
      expect(item.slot.snapshot().compactionPolicy?.currentBudgets.reserveTokens).toBe(100_000);
    } finally { release?.(); await compacting.catch(() => {}); }
  });
});
