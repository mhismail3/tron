import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type AgentSession, ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall, getCurrentSystemPrompt } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { SettingsService } from "../admin/settings-service.js";
import type { SessionSnapshot } from "../protocol/types.js";
import { INVOCATION_RECEIPT_TYPE } from "./invocation-receipts.js";
import { RuntimeRegistry } from "./runtime-registry.js";
import type { RunMarkerStore } from "./run-markers.js";

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
    const providerRequests: Array<{ context: string; options: { reasoning?: string } | undefined }> = [];
    const ordinaryRequests: typeof providerRequests = [];
    const releaseSummaries = new Set<() => void>();
    let cleaningUp = false;
    faux.setResponses([
      async (context, options) => {
        ordinaryRequests.push({ context: getCurrentSystemPrompt(context.messages), options });
        return fauxAssistantMessage("Earlier ".repeat(1_000));
      },
      async (context, options) => {
        ordinaryRequests.push({ context: getCurrentSystemPrompt(context.messages), options });
        return fauxAssistantMessage(fauxToolCall("read", { path: "large.txt" }));
      },
      ...Array.from({ length: 8 }, () => async (context, options: { signal?: AbortSignal; reasoning?: string } | undefined) => {
        providerRequests.push({ context: getCurrentSystemPrompt(context.messages), options });
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
      expect(ordinaryRequests.every(request => !request.context.includes("retain API decisions"))).toBe(true);
      expect(providerRequests.every(request => request.options?.reasoning === "low")).toBe(true);
      expect(providerRequests.every(request => request.context.includes("retain API decisions"))).toBe(true);
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

async function boundaryFixture(historyRepeats = 8_000, extension?: (root: string) => string) {
  const root = await mkdtemp(join(tmpdir(), "tron-compaction-boundary-"));
  const agentDir = join(root, "agent");
  const cwd = join(root, "project");
  await Promise.all([mkdir(agentDir), mkdir(cwd)]);
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ compaction: {
    enabled: false, reserveTokens: 120_000, keepRecentTokens: 13_000, thinkingLevel: "low", instructions: "Retain the API contract",
  } }));
  if (extension) {
    await mkdir(join(agentDir, "extensions"));
    await writeFile(join(agentDir, "extensions", "continuation.ts"), extension(root));
  }
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

function compactionContinuationExtension(root: string): string {
  return `
    import { existsSync } from "node:fs";
    import { setTimeout } from "node:timers/promises";
    export default function(pi) {
      pi.on("session_compact", async () => {
        pi.sendMessage({ customType: "compaction-continuation", content: "Continue after compaction", display: false }, { triggerTurn: true });
        while (!existsSync(${JSON.stringify(join(root, "release-hook"))})) await setTimeout(5);
      });
    }
  `;
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

  it.each(["preflight", "preflight-grace", "post-run"] as const)("keeps Stop authoritative while %s compaction auth is still preparing", async mode => {
    const preflight = mode !== "post-run";
    const item = await boundaryFixture(preflight ? 8_000 : 10);
    await item.update({ enabled: true });
    let entered = false;
    let release!: () => void;
    let authSignal: AbortSignal | undefined;
    const original = item.session.modelRuntime.getAuth.bind(item.session.modelRuntime);
    const auth = vi.spyOn(item.session.modelRuntime, "getAuth").mockImplementation(async (...args) => {
      if (!entered && (preflight || item.faux.state.callCount >= 2)) {
        entered = true;
        authSignal = (args[1] as { signal?: AbortSignal } | undefined)?.signal;
        await new Promise<void>(resolve => {
          release = resolve;
          if (mode !== "preflight-grace") authSignal?.addEventListener("abort", resolve, { once: true });
        });
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
      expect(authSignal).toBeDefined();
      expect(item.slot.snapshot().phase).toBe("compacting");
      const operationId = item.slot.snapshot().operation!.id;
      stopping = item.slot.abort("compaction", operationId);
      if (mode === "preflight-grace") {
        await waitUntil(() => authSignal!.aborted);
        expect(item.slot.snapshot()).toMatchObject({ phase: "compacting", operation: { id: operationId } });
        expect(item.registry.administrativeWorkRegistry.size).toBeGreaterThan(0);
        const receipts = (await item.entries()).filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data.receiptKind === "start");
        expect(receipts.at(-1)?.data.lifecycle).toBe("staged");
        // This mock deliberately ignores AbortSignal; keep its owner visible until
        // the held auth call returns rather than asserting false cancellation.
      }
      release();
      await stopping;
      if (preflight) expect(await prompting).toBeInstanceOf(Error);
      else expect(await prompting).toMatchObject({ operationId: expect.any(String) });
      await expectSettled(item);
      expect(item.faux.state.callCount).toBe(preflight ? 1 : 2);
      expect((await item.entries()).filter(entry => entry.message?.role === "user")).toHaveLength(preflight ? 1 : 2);
      expect((await item.entries()).filter(entry => entry.type === "compaction")).toHaveLength(0);
      expect((await item.entries()).filter(entry => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data.receiptKind === "terminal").at(-1)?.data.lifecycle).toBe("interrupted");
    } finally { release?.(); auth.mockRestore(); await prompting; await stopping?.catch(() => {}); }
  }, 10_000);

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

  it("recovers a provider request-size rejection by compacting and retrying once", async () => {
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
      // Captured verbatim from opencode-go rejecting an oversized conversation:
      // it matches none of the pinned SDK's overflow patterns.
      return ordinary === 1
        ? fauxAssistantMessage("", { stopReason: "error", errorMessage: "413: {\"type\":\"server_error\",\"code\":\"server_error\",\"message\":\"Error from provider (Console Go): Upstream request failed: [server_error] Upstream response was not valid JSON\"}" })
        : fauxAssistantMessage("Recovered after the provider request-size rejection");
    };
    item.faux.setResponses(Array.from({ length: 6 }, () => respond));
    const { operationId } = await item.slot.prompt("Continue the oversized request");
    await expectSettled(item);
    expect(reasons).toEqual(["overflow"]);
    expect(ordinary).toBe(2);
    expect(summaries).toBeGreaterThan(0);
    const entries = await item.entries();
    expect(entries.filter(entry => entry.type === "compaction")).toHaveLength(1);
    // Provider text stays intact; the classification prefix is what the SDK recovered from.
    expect(entries.find(entry => entry.message?.role === "assistant" && entry.message.stopReason === "error")?.message.errorMessage)
      .toContain("context_length_exceeded: 413:");
    expect(entries.find(entry => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data.operationId === operationId && entry.data.receiptKind === "terminal")?.data.lifecycle).toBe("completed");
  });

  it("retires late manual Stop intent after durable marker cleanup", async () => {
    const item = await boundaryFixture();
    item.faux.setResponses(Array.from({ length: 3 }, () => fauxAssistantMessage("Preserved API contract")));
    const internal = item.slot as unknown as { dependencies: { markers: RunMarkerStore }; abortedOperations: Set<string> };
    const original = internal.dependencies.markers.clear.bind(internal.dependencies.markers);
    let release!: () => void;
    let clearing = false;
    const barrier = new Promise<void>(resolve => { release = resolve; });
    const clear = vi.spyOn(internal.dependencies.markers, "clear").mockImplementation(async (...args) => {
      clearing = true;
      await barrier;
      await original(...args);
    });
    const compacting = item.slot.compact();
    let stopping: Promise<void> | undefined;
    try {
      await waitUntil(() => clearing);
      const id = item.slot.snapshot().operation!.id!;
      stopping = item.slot.abort("compaction", id);
      expect(internal.abortedOperations.has(id)).toBe(true);
      release();
      await compacting;
      await stopping;
      await expectSettled(item);
      expect(internal.abortedOperations.has(id)).toBe(false);
      expect((await item.entries()).filter(entry => entry.type === "compaction")).toHaveLength(1);
    } finally { release(); clear.mockRestore(); await compacting.catch(() => {}); await stopping?.catch(() => {}); }
  });

  it("preserves a real extension-triggered successor across manual compaction cleanup and Stop", async () => {
    const item = await boundaryFixture(8_000, compactionContinuationExtension);
    let successorSignal: AbortSignal | undefined;
    let releaseSuccessor: (() => void) | undefined;
    item.faux.setResponses(Array.from({ length: 5 }, () => async (context, options) => {
      if (getCurrentSystemPrompt(context.messages).includes("User-configured summary focus:")) return fauxAssistantMessage("Preserved the API contract.");
      successorSignal = options?.signal;
      await new Promise<void>(resolve => { releaseSuccessor = resolve; });
      return fauxAssistantMessage("Successor response");
    }));
    const compacting = item.slot.compact();
    let stopping: Promise<void> | undefined;
    try {
      await waitUntil(() => successorSignal !== undefined);
      const successor = item.slot.snapshot();
      expect(successor).toMatchObject({ phase: "running", operation: { kind: "prompt" }, compactionPolicy: { active: { reason: "manual" } } });
      const start = item.snapshots.length;
      stopping = item.slot.abort(undefined, successor.operation!.id);
      await waitUntil(() => successorSignal!.aborted);
      await writeFile(join(item.root, "release-hook"), "release");
      await compacting;
      expect(item.slot.snapshot()).toMatchObject({ phase: "running", operation: { id: successor.operation!.id } });
      expect(item.slot.snapshot().compactionPolicy?.active).toBeUndefined();
      expect(item.snapshots.slice(start).every(snapshot => snapshot.phase !== "idle")).toBe(true);
      const markers = JSON.parse(await readFile(join(item.root, "tron", "gateway", "runtime-markers", `${item.slot.id}.json`), "utf8"));
      expect(markers.operations.map((operation: { operationId: string }) => operation.operationId)).toEqual([successor.operation!.id]);
      releaseSuccessor!();
      await stopping;
      await expectSettled(item);
      const entries = await item.entries();
      expect(entries.filter(entry => entry.type === "compaction")).toHaveLength(1);
      expect(entries.filter(entry => entry.message?.role === "assistant").at(-1)?.message.stopReason).toBe("aborted");
    } finally {
      await writeFile(join(item.root, "release-hook"), "release");
      releaseSuccessor?.();
      await compacting.catch(() => {});
      await stopping?.catch(() => {});
    }
  });

  it.each(["running", "settled"] as const)("rejects preflight displaced by a %s public compaction continuation without misattribution or replay", async state => {
    const item = await boundaryFixture(8_000, compactionContinuationExtension);
    await item.update({ enabled: true });
    let stagedId: string | undefined;
    item.observe(snapshot => {
      if (snapshot.operation?.lifecycle === "staged") stagedId ??= snapshot.operation.id;
    });
    let releaseSuccessor: (() => void) | undefined;
    let cleaningUp = false;
    item.faux.setResponses(Array.from({ length: 5 }, () => async (context) => {
      if (cleaningUp) return fauxAssistantMessage("Cleanup response");
      if (getCurrentSystemPrompt(context.messages).includes("User-configured summary focus:")) return fauxAssistantMessage("Preserved API contract.");
      await new Promise<void>(resolve => { releaseSuccessor = resolve; });
      return fauxAssistantMessage("Extension continuation completed");
    }));
    const prompting = item.slot.prompt("The original pending request must not be lost or replayed").catch(error => error);
    try {
      await waitUntil(() => releaseSuccessor !== undefined);
      const successorId = item.slot.snapshot().operation!.id;
      expect(stagedId).toBeDefined();
      expect(successorId).not.toBe(stagedId);
      if (state === "settled") {
        releaseSuccessor!();
        await waitUntil(() => !item.session.isStreaming && item.slot.snapshot().phase === "compacting");
        expect(item.slot.snapshot()).toMatchObject({ operation: { kind: "compaction" }, compactionPolicy: { active: { reason: "threshold" } } });
      }
      await writeFile(join(item.root, "release-hook"), "release");
      expect(await prompting).toMatchObject({ code: "busy", retryable: true });
      if (state === "running") expect(item.slot.snapshot()).toMatchObject({ phase: "running", operation: { id: successorId } });
      releaseSuccessor!();
      await expectSettled(item);
      const entries = await item.entries();
      expect(entries.filter(entry => entry.message?.role === "user")).toHaveLength(1);
      expect(entries.find(entry => entry.customType === INVOCATION_RECEIPT_TYPE && entry.data.operationId === stagedId && entry.data.receiptKind === "terminal")?.data.lifecycle).toBe("failed");
      await item.update({ enabled: false });
      item.faux.setResponses([fauxAssistantMessage("A later explicit request succeeded")]);
      await item.slot.prompt("A new explicit request");
      await expectSettled(item);
      expect((await item.entries()).filter(entry => entry.message?.role === "user")).toHaveLength(2);
    } finally {
      cleaningUp = true;
      await writeFile(join(item.root, "release-hook"), "release");
      releaseSuccessor?.();
      await prompting;
    }
  });

  it("publishes saved, active and next policy independently; successful completion is one canonical checkpoint", async () => {
    const item = await boundaryFixture();
    let entered = false;
    let release!: () => void;
    const requests: Array<{ reasoning?: string; prompt?: string }> = [];
    item.faux.setResponses([
      async (context, options) => {
        requests.push({ reasoning: options?.reasoning, prompt: getCurrentSystemPrompt(context.messages) });
        entered = true;
        await new Promise<void>(resolve => { release = resolve; });
        return fauxAssistantMessage("API preserved. Continue implementation.");
      },
      (context, options) => {
        requests.push({ reasoning: options?.reasoning, prompt: getCurrentSystemPrompt(context.messages) });
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
