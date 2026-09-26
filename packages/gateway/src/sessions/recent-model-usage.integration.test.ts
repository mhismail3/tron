import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { MAXIMUM_RECENT_MODELS, type RecentModelUsage } from "../providers/recent-models.js";
import { RuntimeRegistry } from "./runtime-registry.js";

async function waitUntil(predicate: () => boolean, timeoutMs = 10_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("condition timed out");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

describe.sequential("recent model usage", () => {
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  const registries: RuntimeRegistry[] = [];

  afterEach(async () => {
    await Promise.all(registries.splice(0).map((registry) => registry.dispose()));
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
  });

  /** One user session with two models, a delegated fork child, and a faux
   * provider so a real admitted `agent_start` drives the recording path. */
  async function fixture(label: string, seed?: RecentModelUsage[]) {
    const root = await mkdtemp(join(tmpdir(), `tron-recent-models-${label}-`));
    const agentDir = join(root, "agent");
    const tronHome = join(root, "tron");
    const cwd = join(root, "workspace");
    const sessionDirectory = join(agentDir, "sessions", "workspace");
    await Promise.all([mkdir(sessionDirectory, { recursive: true }), mkdir(tronHome, { recursive: true }), mkdir(cwd, { recursive: true })]);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const manager = SessionManager.create(cwd, sessionDirectory);
    manager.appendMessage(fauxAssistantMessage("recent usage fixture"));
    const parentFile = manager.getSessionFile()!;
    const forksDirectory = join(dirname(parentFile), basename(parentFile, ".jsonl"), "forks");
    await mkdir(forksDirectory, { recursive: true });
    const child = SessionManager.forkFrom(parentFile, cwd, forksDirectory);
    child.appendMessage(fauxAssistantMessage("delegated child"));
    if (seed) {
      await mkdir(join(tronHome, "gateway"), { recursive: true });
      await writeFile(join(tronHome, "gateway", "model-recents.json"), `${JSON.stringify({ version: 1, models: seed }, null, 2)}\n`, "utf8");
    }
    const faux = fauxProvider({ provider: `tron-recent-${label}`, models: [{ id: "recent-a" }, { id: "recent-b" }], tokensPerSecond: 10_000 });
    faux.setResponses([fauxAssistantMessage("done")]);
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    const changes: string[] = [];
    const registry = new RuntimeRegistry({
      agentDir,
      tronHome,
      idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime,
      trust: new TrustService(agentDir),
      broadcast: () => {},
      sessionSummaryChanged: () => {},
      sessionListChanged: () => {},
      recentModelsChanged: () => changes.push("models.recentChanged"),
    });
    registries.push(registry);
    await registry.initialize();
    return { root, registry, faux, parentId: manager.getSessionId(), childId: child.getSessionId(), changes };
  }

  async function run(slot: Awaited<ReturnType<RuntimeRegistry["acquire"]>>, model: { provider: string; id: string }, prompt: string): Promise<void> {
    await slot.setModel(model.provider, model.id);
    await slot.prompt(prompt);
    await waitUntil(() => !slot.isBusy);
  }

  it("orders, dedupes, and bounds recency from admitted user runs, and excludes subagents", async () => {
    const seed: RecentModelUsage[] = Array.from({ length: MAXIMUM_RECENT_MODELS }, (_, index) => ({
      provider: "seeded",
      id: `model-${String(index).padStart(2, "0")}`,
      lastUsedAt: new Date(Date.UTC(2026, 0, 1, 0, index)).toISOString(),
    }));
    const fixture_ = await fixture("ordering", seed);
    const modelA = fixture_.faux.getModel("recent-a")!;
    const modelB = fixture_.faux.getModel("recent-b")!;
    try {
      const slot = await fixture_.registry.acquire(fixture_.parentId);
      await run(slot, modelA, "first");
      expect(fixture_.registry.recentModelUsage()[0]).toMatchObject({ id: "recent-a" });
      // The seeded list is already at the bound, so the newest run displaces the
      // oldest entry instead of growing the document.
      expect(fixture_.registry.recentModelUsage()).toHaveLength(MAXIMUM_RECENT_MODELS);
      expect(fixture_.registry.recentModelUsage().map((model) => model.id).slice(0, 3)).toEqual(["recent-a", "model-00", "model-01"]);
      expect(fixture_.registry.recentModelUsage().some((model) => model.id === "model-11")).toBe(false);

      await run(slot, modelB, "second");
      expect(fixture_.registry.recentModelUsage().map((model) => model.id).slice(0, 3)).toEqual(["recent-b", "recent-a", "model-00"]);

      // Reusing a model moves it to the front instead of adding a second row.
      await run(slot, modelA, "third");
      const usage = fixture_.registry.recentModelUsage();
      expect(usage.map((model) => model.id).slice(0, 3)).toEqual(["recent-a", "recent-b", "model-00"]);
      expect(new Set(usage.map((model) => `${model.provider}/${model.id}`)).size).toBe(usage.length);
      expect(usage.every((model) => Number.isFinite(Date.parse(model.lastUsedAt)))).toBe(true);
      expect(fixture_.changes.length).toBeGreaterThan(0);

      // A delegated session never owns a Gateway runtime, so it can never
      // report a model as recently used by the user.
      await expect(fixture_.registry.acquire(fixture_.childId)).rejects.toMatchObject({
        code: "conflict",
        message: expect.stringContaining("Subagent sessions are informational"),
      });
      expect(fixture_.registry.recentModelUsage().map((model) => model.id).slice(0, 3)).toEqual(["recent-a", "recent-b", "model-00"]);
    } finally {
      await rm(fixture_.root, { recursive: true, force: true });
    }
  });

  it("replaces a malformed preference document instead of failing startup", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-recent-models-malformed-"));
    const agentDir = join(root, "agent");
    const tronHome = join(root, "tron");
    await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(join(tronHome, "gateway"), { recursive: true })]);
    await writeFile(join(tronHome, "gateway", "model-recents.json"), "{ not json", "utf8");
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
    try {
      await registry.initialize();
      expect(registry.recentModelUsage()).toEqual([]);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
