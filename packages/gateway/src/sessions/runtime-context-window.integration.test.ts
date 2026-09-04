import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { InMemoryCredentialStore, fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { afterEach, describe, expect, it } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { CONTEXT_WINDOW_ENTRY } from "../providers/context-window-policy.js";
import { RuntimeRegistry } from "./runtime-registry.js";

async function waitUntil(predicate: () => boolean): Promise<void> {
  const deadline = Date.now() + 5_000;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error("context fixture did not settle");
    await new Promise(resolve => setTimeout(resolve, 5));
  }
}

describe.sequential("Gateway session context windows", () => {
  const roots: string[] = [];
  const registries: RuntimeRegistry[] = [];
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  afterEach(async () => {
    await Promise.all(registries.splice(0).map(registry => registry.dispose()));
    await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
  });

  async function fixture() {
    const root = await mkdtemp(join(tmpdir(), "tron-runtime-context-"));
    roots.push(root);
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir), mkdir(join(cwd, ".pi"), { recursive: true })]);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    const faux = fauxProvider({ provider: "context-test", tokensPerSecond: 100_000,
      models: [{ id: "large", contextWindow: 1_050_000, reasoning: true }, { id: "small", contextWindow: 128_000 }] });
    const settingsPath = join(agentDir, "settings.json");
    const settings = { defaultProvider: "context-test", defaultModel: "large", modelContextWindows: { "context-test/large": 272_000 } };
    await writeFile(settingsPath, JSON.stringify(settings));
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const options = {
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      modelRuntimeFactory: async () => {
        const runtime = await ModelRuntime.create({ modelsPath: null, credentials: new InMemoryCredentialStore(), refreshOnCreate: false });
        runtime.registerNativeProvider(faux.provider);
        return runtime;
      },
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    };
    const registry = new RuntimeRegistry(options);
    registries.push(registry);
    await registry.initialize();
    const slot = await registry.create(cwd);
    return { registry, slot, faux, cwd, settingsPath, settings, options };
  }

  it("persists overrides through cold resume and isolates sessions, models and live defaults", async () => {
    const { registry, slot, faux, cwd, settingsPath, settings, options } = await fixture();
    expect(slot.snapshot().contextWindowPolicy).toMatchObject({ source: "global", effective: 272_000, override: null });
    await slot.setThinking("high");
    await slot.setContextWindow("context-test", "large", 1_000_000, slot.snapshot().revision, slot.snapshot().runtimeGeneration);
    expect(slot.snapshot()).toMatchObject({ thinkingLevel: "high", contextUsage: { contextWindow: 1_000_000 }, contextWindowPolicy: { source: "session", effective: 1_000_000, warning: expect.stringContaining("not yet saved to disk") } });
    await expect(readFile(slot.sessionFile!, "utf8")).rejects.toMatchObject({ code: "ENOENT" });
    const other = await registry.create(cwd);
    expect(other.snapshot().contextWindowPolicy?.effective).toBe(272_000);
    await writeFile(settingsPath, JSON.stringify({ ...settings, modelContextWindows: { "context-test/large": 500_000 } }));
    expect(other.snapshot().contextWindowPolicy?.effective).toBe(272_000);
    await other.reload();
    expect(other.snapshot().contextWindowPolicy?.effective).toBe(500_000);
    await slot.setModel("context-test", "small");
    expect(slot.snapshot().contextWindowPolicy?.effective).toBe(128_000);
    await slot.setModel("context-test", "large");
    expect(slot.snapshot().contextWindowPolicy?.effective).toBe(1_000_000);
    faux.setResponses([fauxAssistantMessage("materialize canonical session")]);
    await slot.prompt("remember this choice");
    await waitUntil(() => !slot.isBusy);
    expect(slot.snapshot().contextWindowPolicy?.warning).toBeUndefined();
    // An idle change in a materialized session must survive without another turn.
    await slot.setContextWindow("context-test", "large", 900_000, slot.snapshot().revision, slot.snapshot().runtimeGeneration);
    const id = slot.id;
    const generation = slot.snapshot().runtimeGeneration;
    const file = slot.sessionFile!;
    const entries = (await readFile(file, "utf8")).trim().split("\n").map(line => JSON.parse(line));
    expect(entries.filter(entry => entry.type === "custom" && entry.customType === CONTEXT_WINDOW_ENTRY)).toHaveLength(2);
    await registry.dispose();
    registries.splice(registries.indexOf(registry), 1);
    const cold = new RuntimeRegistry(options);
    registries.push(cold);
    await cold.initialize();
    const resumed = await cold.acquire(id);
    expect(resumed.snapshot().contextWindowPolicy).toMatchObject({ source: "session", effective: 900_000, default: 500_000 });
    await expect(resumed.setContextWindow("context-test", "large", null, resumed.snapshot().revision, generation)).rejects.toMatchObject({ code: "conflict" });
    await resumed.setContextWindow("context-test", "large", null, resumed.snapshot().revision, resumed.snapshot().runtimeGeneration);
    expect(resumed.snapshot().contextWindowPolicy).toMatchObject({ source: "global", effective: 500_000, override: null });
  });

  it("rejects changes during accepted work and stale model requests without changing context", async () => {
    const { slot, faux } = await fixture();
    let release!: () => void;
    const barrier = new Promise<void>(resolve => { release = resolve; });
    faux.setResponses([async () => { await barrier; return fauxAssistantMessage("settled"); }]);
    await slot.prompt("hold until test releases");
    try {
      await expect(slot.setContextWindow("context-test", "large", 1_000_000, slot.snapshot().revision, slot.snapshot().runtimeGeneration)).rejects.toMatchObject({ code: "busy" });
      expect(slot.snapshot().contextWindowPolicy?.effective).toBe(272_000);
    } finally { release(); }
    await waitUntil(() => !slot.isBusy);
    const revision = slot.snapshot().revision;
    await slot.setModel("context-test", "small");
    await expect(slot.setContextWindow("context-test", "large", 1_000_000, slot.snapshot().revision, slot.snapshot().runtimeGeneration)).rejects.toMatchObject({ code: "conflict" });
    expect(slot.snapshot().contextWindowPolicy?.effective).toBe(128_000);
    await slot.setModel("context-test", "large");
    await expect(slot.setContextWindow("context-test", "large", 1_000_000, revision, slot.snapshot().runtimeGeneration)).rejects.toMatchObject({ code: "conflict" });
    const current = slot.snapshot().revision;
    await slot.setContextWindow("context-test", "large", 1_000_000, current, slot.snapshot().runtimeGeneration);
    await expect(slot.setContextWindow("context-test", "large", 500_000, current, slot.snapshot().runtimeGeneration)).rejects.toMatchObject({ code: "conflict" });
    expect(slot.snapshot().contextWindowPolicy?.effective).toBe(1_000_000);
  });

  it("restores project inheritance and fork-local overrides with canonical SDK branching", async () => {
    const { registry, slot, faux, cwd } = await fixture();
    await writeFile(join(cwd, ".pi", "settings.json"), JSON.stringify({ modelContextWindows: { "context-test/large": 600_000 } }));
    await slot.reload();
    expect(slot.snapshot().contextWindowPolicy).toMatchObject({ source: "project", effective: 600_000 });
    await slot.setContextWindow("context-test", "large", 1_000_000, slot.snapshot().revision, slot.snapshot().runtimeGeneration);
    faux.setResponses([fauxAssistantMessage("checkpoint")]);
    await slot.prompt("create branch point");
    await waitUntil(() => !slot.isBusy);
    const parentId = slot.id;
    const leaf = slot.snapshot().leafEntryId!;
    const forked = await slot.fork(leaf);
    expect(forked.sessionId).not.toBe(parentId);
    expect(slot.snapshot().contextWindowPolicy).toMatchObject({ effective: 1_000_000, source: "session" });
    await slot.setContextWindow("context-test", "large", null, slot.snapshot().revision, slot.snapshot().runtimeGeneration);
    expect(slot.snapshot().contextWindowPolicy).toMatchObject({ effective: 600_000, source: "project" });
    const parent = await registry.acquire(parentId);
    expect(parent.snapshot().contextWindowPolicy).toMatchObject({ effective: 1_000_000, source: "session" });
  });
});
