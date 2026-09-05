import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type AgentSession, ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { describe, expect, it } from "vitest";
import { TrustService } from "../admin/trust-service.js";
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
    const faux = fauxProvider({ provider: "tron-compaction-stop", tokensPerSecond: 1_000_000 });
    const summarySignals: AbortSignal[] = [];
    const releaseSummaries = new Set<() => void>();
    let cleaningUp = false;
    faux.setResponses([
      fauxAssistantMessage("Earlier ".repeat(1_000)),
      fauxAssistantMessage(fauxToolCall("read", { path: "large.txt" })),
      ...Array.from({ length: 8 }, () => async (_context: unknown, options: { signal?: AbortSignal } | undefined) => {
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
      session.settingsManager.applyOverrides({
        compaction: { enabled: true, reserveTokens: 120_000, keepRecentTokens: 13_000 },
      });
      await slot.prompt("An earlier request.");
      await waitUntil(() => !slot.isBusy);
      const { operationId } = await slot.prompt("Read large.txt, then explain it.");
      await waitUntil(() => summarySignals.length > 0);
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
