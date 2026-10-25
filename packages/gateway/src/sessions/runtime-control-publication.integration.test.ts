import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime, type AgentSession } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { createTestRegistry } from "../../test-support/gateway-registry.js";
import { settingsDependencies } from "../../test-support/settings-dependencies.js";
import { waitFor } from "../../test-support/wait-for.js";
import { TrustService } from "../kernel/resources/trust-service.js";

const disposals: Array<() => Promise<void>> = [];
afterEach(async () => { for (const dispose of disposals.splice(0).reverse()) await dispose(); });

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-control-publication-"));
  const agentDir = join(root, "agent"), cwd = join(root, "project"), tronHome = join(root, "tron");
  await mkdir(agentDir); await mkdir(cwd);
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ cacheWarming: "streaming", compaction: { enabled: false } }));
  const faux = fauxProvider({ provider: "tron-control-publication", tokensPerSecond: 300,
    models: [{ id: "first", contextWindow: 20_000, cost: { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 300 } }, { id: "second" }] });
  const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
  runtime.registerNativeProvider(faux.provider);
  const trust = new TrustService(agentDir);
  const registry = await createTestRegistry({ agentDir, tronHome, idleRuntimeMs: 60_000, trust, modelRuntimeFactory: async () => runtime,
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {} });
  disposals.push(async () => { await registry.dispose(); await rm(root, { recursive: true, force: true }); });
  const settings = settingsDependencies({ agentDir, tronHome, trust, modelRuntime: runtime, registry });
  await registry.initialize();
  const slot = await registry.create(cwd);
  await slot.setModel(faux.provider.id, "first");
  const session = (slot as unknown as { runtime: { session: AgentSession } }).runtime.session;
  const change = (key: string, value: unknown) => settings.settingsChanges.change({ kind: "global" }, [{ key, layer: "global", op: "set", value }],
    { actor: { kind: "ui", id: "fixture" } });
  return { ...settings, root, agentDir, cwd, faux, runtime, registry, slot, session, change };
}

describe("runtime control publication through canonical settings", () => {
  it("filters the real model catalog when offered models changes", async () => {
    const f = await fixture();
    await f.change("model.offered", [`${f.faux.provider.id}/first`]);
    const catalog = await f.settingsModel.options({ kind: "global" }, undefined, { key: "model.ref[role=chat]", query: f.faux.provider.id });
    expect(catalog.options.map(option => option.value)).toEqual([{ provider: f.faux.provider.id, id: "first" }]);
  });

  it("publishes cache warming off to an existing session before its next streaming request", async () => {
    const f = await fixture();
    (f.runtime.getModel(f.faux.provider.id, "first")! as unknown as { promptCache: { short: number } }).promptCache = { short: 11 };
    const warmCalls: number[] = [];
    const response = (text: string) => (_context: unknown, options: { maxTokens?: number } | undefined) => {
      if (options?.maxTokens === 1) warmCalls.push(Date.now());
      return fauxAssistantMessage(text);
    };
    f.faux.setResponses([response("primed")]);
    await f.slot.prompt("context ".repeat(1_000));
    await waitFor(() => !f.slot.isBusy, "first request idle");
    await f.change("run.cacheWarming", "off");
    f.faux.setResponses(Array.from({ length: 6 }, () => response("streaming reply ".repeat(120))));
    await f.slot.prompt("second request");
    await waitFor(() => !f.slot.isBusy, "streaming request idle");
    expect(warmCalls).toEqual([]);
    expect(f.session.cacheWarmingStatus).toMatchObject({ state: "inactive", reason: "disabled by setting" });
  });

  it("publishes branch-summary reserve before navigating an existing session", async () => {
    const f = await fixture();
    // Real persisted branches, without paying for ordinary requests: the oldest
    // entry fits the old 3616-token budget but not the new 1000-token budget.
    const target = f.session.sessionManager.appendMessage({ role: "user", content: "branch root", timestamp: Date.now() });
    f.session.sessionManager.appendMessage({ role: "user", content: "OLDEST-BRANCH-SENTINEL " + "older ".repeat(1_000), timestamp: Date.now() });
    f.session.sessionManager.appendMessage(fauxAssistantMessage("latest branch reply"));
    const requests: string[] = [];
    f.faux.setResponses([(context) => { requests.push(JSON.stringify(context.messages)); return fauxAssistantMessage("branch summary"); }]);
    await f.change("context.branchSummary.reserveTokens", 19_000);
    await f.slot.navigate(target, { summarize: true });
    expect(requests).toHaveLength(1);
    expect(requests[0]).toContain("latest branch reply");
    expect(requests[0]).not.toContain("OLDEST-BRANCH-SENTINEL");
  });
});
