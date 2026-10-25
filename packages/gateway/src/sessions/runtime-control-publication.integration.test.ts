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

async function fixture(extension = false) {
  const root = await mkdtemp(join(tmpdir(), "tron-control-publication-"));
  const agentDir = join(root, "agent"), cwd = join(root, "project"), tronHome = join(root, "tron");
  await mkdir(agentDir); await mkdir(cwd);
  const previousTmp = process.env.TMPDIR;
  const temporary = join(root, "tmp");
  await mkdir(temporary);
  process.env.TMPDIR = temporary;
  disposals.push(async () => {
    if (previousTmp === undefined) delete process.env.TMPDIR;
    else process.env.TMPDIR = previousTmp;
    await rm(root, { recursive: true, force: true });
  });
  await writeFile(join(agentDir, "settings.json"), JSON.stringify({ enabledModels: ["tron-control-publication/first"], cacheWarming: "streaming", compaction: { enabled: false } }));
  if (extension) {
    await mkdir(join(agentDir, "extensions"));
    await writeFile(join(agentDir, "extensions", "navigate.ts"), `export default pi => {
      pi.registerCommand("summarize-branch", { description: "Summarize the abandoned branch", handler: async (args, ctx) => {
        await ctx.navigateTree(args, { summarize: true });
      } });
    };`);
  }
  const faux = fauxProvider({ provider: "tron-control-publication", tokensPerSecond: 300,
    models: [{ id: "first", contextWindow: 20_000, cost: { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 300 } }, { id: "second" }] });
  const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
  runtime.registerNativeProvider(faux.provider);
  const trust = new TrustService(agentDir);
  await trust.set(cwd, true);
  const registry = await createTestRegistry({ agentDir, tronHome, idleRuntimeMs: 60_000, trust, modelRuntimeFactory: async () => runtime,
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {} });
  disposals.push(() => registry.dispose());
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
  it("refuses the retired offered-model control while the real catalog and selection remain available", async () => {
    const f = await fixture();
    await expect(f.change("model.offered", [`${f.faux.provider.id}/first`])).rejects.toThrow();
    const catalog = await f.settingsModel.options({ kind: "global" }, undefined, { key: "model.ref[role=chat]", query: f.faux.provider.id });
    expect(catalog.options.map(option => option.value)).toEqual([
      { provider: f.faux.provider.id, id: "first" }, { provider: f.faux.provider.id, id: "second" },
    ]);
    await f.slot.setModel(f.faux.provider.id, "second");
    expect(f.session.model?.id).toBe("second");
  });

  it("applies cache warming off to a new session without changing an existing session", async () => {
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
    expect(warmCalls.length).toBeGreaterThan(0);
    const callsBeforeNewSession = warmCalls.length;
    const fresh = await f.registry.create(f.cwd);
    await fresh.setModel(f.faux.provider.id, "first");
    f.faux.setResponses([response("primed")]);
    await fresh.prompt("context ".repeat(1_000));
    await waitFor(() => !fresh.isBusy, "fresh session primed");
    f.faux.setResponses(Array.from({ length: 6 }, () => response("streaming reply ".repeat(120))));
    await fresh.prompt("new session with warming off");
    await waitFor(() => !fresh.isBusy, "fresh streaming request idle");
    expect(warmCalls).toHaveLength(callsBeforeNewSession);
    const freshSession = (fresh as unknown as { runtime: { session: AgentSession } }).runtime.session;
    expect(freshSession.cacheWarmingStatus).toMatchObject({ state: "inactive", reason: "cache warming disabled" });
  });

  it.each(["native", "extension"])("does not start %s branch summarization after Stop during settings resolution", async route => {
    const f = await fixture(route === "extension");
    const target = f.session.sessionManager.appendMessage({ role: "user", content: "branch root", timestamp: Date.now() });
    const leaf = f.session.sessionManager.appendMessage(fauxAssistantMessage("abandoned branch"));
    let release!: () => void;
    const held = new Promise<void>(resolve => { release = resolve; });
    let entered = false;
    // Delay the real resolver at its I/O boundary, without substituting values.
    const resolve = f.settingsModel.resolve.bind(f.settingsModel);
    f.settingsModel.resolve = async (...args) => {
      if (args[2]?.includes("context.branchSummary.reserveTokens")) { entered = true; await held; }
      return resolve(...args);
    };
    const requests: unknown[] = [];
    f.faux.setResponses([context => { requests.push(context); return fauxAssistantMessage("unexpected summary"); }]);
    const navigating = route === "native" ? f.slot.navigate(target, { summarize: true }) : f.slot.prompt(`/summarize-branch ${target}`);
    // Observe rejections immediately, so an intentional cancellation is not unhandled.
    const navigationResult = navigating.then(() => "completed", () => "cancelled");
    try {
      await waitFor(() => entered, "branch-summary settings resolution");
      const stopping = f.slot.abort("branchSummary");
      release();
      await stopping;
      await navigationResult;
      await waitFor(() => !f.slot.isBusy, "stopped navigation idle");
      expect(requests).toEqual([]);
      // Extension command receipts may append, but Stop must not leave the old branch.
      expect(f.session.sessionManager.getBranch().map(entry => entry.id)).toContain(leaf);
      expect(f.session.sessionManager.getBranch().some(entry => entry.type === "branch_summary")).toBe(false);
    } finally { release(); await navigationResult; }
  });

  it.each([
    ["native", "global"], ["extension", "global"], ["native", "project"], ["extension", "project"],
  ])("publishes branch-summary reserve before %s navigation from %s settings", async (route, scope) => {
    const f = await fixture(route === "extension");
    // Real persisted branches, without paying for ordinary requests: the oldest
    // entry fits the old 3616-token budget but not the new 1000-token budget.
    const target = f.session.sessionManager.appendMessage({ role: "user", content: "branch root", timestamp: Date.now() });
    f.session.sessionManager.appendMessage({ role: "user", content: "OLDEST-BRANCH-SENTINEL " + "older ".repeat(1_000), timestamp: Date.now() });
    f.session.sessionManager.appendMessage(fauxAssistantMessage("latest branch reply"));
    const requests: string[] = [];
    f.faux.setResponses([(context) => { requests.push(JSON.stringify(context.messages)); return fauxAssistantMessage("branch summary"); }]);
    await f.change("context.branchSummary.reserveTokens", scope === "global" ? 19_000 : 1_024);
    if (scope === "project") {
      await mkdir(join(f.cwd, ".pi"));
      await writeFile(join(f.cwd, ".pi", "settings.json"), JSON.stringify({ branchSummary: { reserveTokens: 19_000 } }));
    }
    if (route === "extension") {
      await f.slot.prompt(`/summarize-branch ${target}`);
      await waitFor(() => !f.slot.isBusy, "extension summary settled");
    } else await f.slot.navigate(target, { summarize: true });
    expect(requests).toHaveLength(1);
    expect(requests[0]).toContain("latest branch reply");
    expect(requests[0]).not.toContain("OLDEST-BRANCH-SENTINEL");
  });
});
