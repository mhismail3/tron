import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { InMemoryCredentialStore, fauxAssistantMessage, fauxProvider, type Model } from "@earendil-works/pi-ai";
import { createAgentSession, DefaultResourceLoader, ModelRuntime, SessionManager, SettingsManager, type AgentSession } from "@earendil-works/pi-coding-agent";
import { afterEach, describe, expect, it, vi } from "vitest";
import { CONTEXT_WINDOW_ENTRY, contextModelKey, contextWindowExtension, contextWindowLimits, contextWindowPreferences, SessionContextWindowPolicy, validateContextWindow } from "./context-window-policy.js";

const astra = {
  id: "gpt-6-astra", provider: "openai-codex", api: "openai-codex-responses", baseUrl: "https://chatgpt.com/backend-api",
  name: "GPT-6 Astra", reasoning: true, input: ["text"], contextWindow: 272_000, maxTokens: 128_000,
  cost: { input: 10, output: 50, cacheRead: 1, cacheWrite: 0, tiers: [{ inputTokensAbove: 272_000, input: 20, output: 75, cacheRead: 2, cacheWrite: 0 }] },
} satisfies Model<any>;

describe("context window policy", () => {
  const sessions: AgentSession[] = [];
  const roots: string[] = [];
  afterEach(async () => {
    for (const session of sessions.splice(0)) await session.dispose();
    await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
  });

  async function fixture(preferences: Record<string, number> = {}, manager = SessionManager.inMemory()) {
    const root = await mkdtemp(join(tmpdir(), "tron-context-window-"));
    roots.push(root);
    const faux = fauxProvider({ provider: "openai-codex", api: "openai-codex-responses", tokensPerSecond: 100_000,
      models: [{ ...astra }, { id: "other", contextWindow: 128_000, maxTokens: 8_000 }] });
    Object.assign(faux.getModel(), astra);
    const modelRuntime = await ModelRuntime.create({ modelsPath: null, credentials: new InMemoryCredentialStore(), refreshOnCreate: false });
    modelRuntime.registerNativeProvider(faux.provider);
    const settingsManager = SettingsManager.inMemory({ modelContextWindows: preferences } as any);
    let policy: SessionContextWindowPolicy | undefined;
    const loader = new DefaultResourceLoader({
      cwd: root, agentDir: root, settingsManager, noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
      extensionFactories: [{ name: "context-window", factory: contextWindowExtension(() => policy) }],
    });
    await loader.reload();
    const { session } = await createAgentSession({ cwd: root, agentDir: root, sessionManager: manager,
      modelRuntime, settingsManager, resourceLoader: loader, model: faux.getModel(), tools: [] });
    sessions.push(session);
    policy = new SessionContextWindowPolicy(session);
    await session.bindExtensions({ mode: "rpc" });
    return { session, policy, faux, modelRuntime, settingsManager };
  }

  it("separates Astra's documented maximum from its default without guessing for aliases/proxies", () => {
    expect(contextWindowLimits(astra)).toEqual({ minimum: 37_408, maximum: 1_050_000, default: 272_000, longContextThreshold: 272_000 });
    expect(contextWindowLimits({ ...astra, provider: "openai", api: "openai-responses", baseUrl: "https://api.openai.com/v1" })?.maximum).toBe(1_050_000);
    for (const model of [{ ...astra, id: "gpt-6-astra-copy" }, { ...astra, provider: "proxy" }, { ...astra, baseUrl: "https://proxy.invalid" }]) {
      expect(contextWindowLimits(model)?.maximum).toBe(272_000);
    }
    expect(contextWindowLimits({ ...astra, id: "custom", contextWindow: 2_000_000 })?.maximum).toBe(2_000_000);
    expect(contextWindowLimits({ ...astra, id: "tiny", contextWindow: 4_096 })?.minimum).toBe(4_096);
    expect(contextWindowLimits({ ...astra, contextWindow: 0 })).toBeUndefined();
  });

  it("inherits Opus 5.5's adaptive-thinking and long-context metadata from the pinned SDK", async () => {
    const runtime = await ModelRuntime.create({ modelsPath: null, credentials: new InMemoryCredentialStore(), refreshOnCreate: false });
    expect(runtime.getModel("anthropic", "claude-opus-5-5")).toMatchObject({
      id: "claude-opus-5-5", contextWindow: 1_000_000, maxTokens: 128_000,
      compat: { forceAdaptiveThinking: true, supportsMidConvoEffort: true, supportsMidConvoSystemMessages: true },
    });
  });

  it("rejects noninteger/unbounded values and malformed canonical preferences", () => {
    const limits = contextWindowLimits(astra);
    for (const value of [undefined, "1000000", NaN, Infinity, 1.5, 0, -1, 1_050_001, 16_384]) {
      expect(() => validateContextWindow(value, limits)).toThrow();
    }
    expect(validateContextWindow(1_050_000, limits)).toBe(1_050_000);
    for (const modelContextWindows of [null, [], { bad: 1000 }, { "provider/id": 0 }, { "provider/id": "1000" }]) {
      expect(() => contextWindowPreferences({ modelContextWindows })).toThrow();
    }
  });

  it("applies defaults and session overrides without changing catalog, output, costs or reasoning", async () => {
    const { session, policy, modelRuntime } = await fixture({ [contextModelKey(astra)]: 500_000 });
    expect(policy.snapshot()).toMatchObject({ effective: 500_000, default: 500_000, source: "global", override: null });
    session.setThinkingLevel("high");
    policy.set(astra, 1_050_000);
    expect(session.model).toMatchObject({ contextWindow: 1_050_000, maxTokens: 128_000, cost: astra.cost });
    expect(session.thinkingLevel).toBe("high");
    expect(modelRuntime.getModels().find(model => model.id === astra.id)?.contextWindow).toBe(272_000);
    expect(session.getContextUsage()?.contextWindow).toBe(1_050_000);
    expect(policy.snapshot()).toMatchObject({ effective: 1_050_000, override: 1_050_000, source: "session", warning: expect.stringContaining("pricing") });
    policy.set(astra, null);
    expect(session.model?.contextWindow).toBe(500_000);
    expect(session.thinkingLevel).toBe("high");
  });

  it("uses branch-local canonical state and restores override/reset after reconstruction", async () => {
    const { session, policy } = await fixture();
    const before = session.sessionManager.appendMessage({ role: "user", content: "before budget", timestamp: 1 });
    policy.set(astra, 1_000_000);
    const overridden = session.sessionManager.getLeafId()!;
    policy.set(astra, null);
    expect(policy.snapshot()?.source).toBe("model");
    session.sessionManager.branch(overridden);
    policy.restore();
    expect(session.model?.contextWindow).toBe(1_000_000);
    session.sessionManager.branch(before);
    policy.restore();
    expect(session.model?.contextWindow).toBe(272_000);
    expect(session.sessionManager.getEntries().filter(entry => entry.type === "custom" && entry.customType === CONTEXT_WINDOW_ENTRY)).toHaveLength(2);
    expect(session.sessionManager.buildSessionContext().messages).toHaveLength(1);
  });

  it("rejects stale identities and unsafe reductions without appending or altering the model", async () => {
    const { session, policy } = await fixture();
    policy.set(astra, 1_050_000);
    const message = fauxAssistantMessage("prior response");
    message.usage.input = 400_000;
    session.sessionManager.appendMessage(message);
    const append = vi.spyOn(session.sessionManager, "appendCustomEntry");
    expect(() => policy.set({ provider: astra.provider, id: "other" }, 100_000)).toThrow(/model changed/);
    expect(() => policy.set(astra, 200_000)).toThrow(/Compact/);
    expect(() => policy.set(astra, null)).toThrow(/Compact/);
    expect(append).not.toHaveBeenCalled();
    expect(session.model?.contextWindow).toBe(1_050_000);
  });

  it("does not change the live model when canonical append fails", async () => {
    const { session, policy } = await fixture();
    vi.spyOn(session.sessionManager, "appendCustomEntry").mockImplementation(() => { throw new Error("disk unavailable"); });
    expect(() => policy.set(astra, 1_000_000)).toThrow(/disk/);
    expect(session.model?.contextWindow).toBe(272_000);
    expect(policy.snapshot()?.override).toBeNull();
  });

  it("reports uncertain persistence after the SDK staged an entry without inventing rollback", async () => {
    const { session, policy } = await fixture();
    const append = session.sessionManager.appendCustomEntry.bind(session.sessionManager);
    const spy = vi.spyOn(session.sessionManager, "appendCustomEntry").mockImplementationOnce((type, value) => {
      append(type, value);
      throw new Error("disk append failed after staging");
    });
    try { policy.set(astra, 1_000_000); throw new Error("expected uncertain persistence"); }
    catch (error) { expect(error).toMatchObject({ code: "conflict", details: { outcomeUnknown: true } }); }
    expect(policy.snapshot()).toMatchObject({ override: 1_000_000, effective: 1_000_000 });
    policy.set(astra, 1_000_000);
    expect(spy).toHaveBeenCalledTimes(2);
  });

  it("isolates sessions and models and reapplies when returning to a model", async () => {
    const first = await fixture();
    const second = await fixture();
    first.policy.set(astra, 1_050_000);
    expect(second.session.model?.contextWindow).toBe(272_000);
    await first.session.setModel(first.faux.getModel("other")!);
    expect(first.session.model?.contextWindow).toBe(128_000);
    await first.session.setModel(first.faux.getModel());
    expect(first.session.model?.contextWindow).toBe(1_050_000);
    // The SDK's silent provider-registration refresh also calls getModel.
    expect(first.modelRuntime.getModel(astra.provider, astra.id)?.contextWindow).toBe(1_050_000);
  });

  it("uses the larger window at provider and compaction boundaries, and keeps it on resource reload", async () => {
    const { session, policy, faux } = await fixture();
    policy.set(astra, 1_050_000);
    const response = fauxAssistantMessage("large prior request");
    response.provider = astra.provider;
    response.model = astra.id;
    response.usage.input = 300_000;
    session.sessionManager.appendMessage({ role: "user", content: "history ".repeat(20_000), timestamp: 1 });
    session.sessionManager.appendMessage(response);
    session.agent.state.messages = session.sessionManager.buildSessionContext().messages;
    const seen: number[] = [];
    faux.setResponses([(_context, _options, _state, model) => { seen.push(model.contextWindow); return fauxAssistantMessage("done"); }]);
    await session.reload();
    expect(session.model?.contextWindow).toBe(1_050_000);
    await session.prompt("continue");
    expect(seen).toEqual([1_050_000]);
    expect(faux.state.callCount).toBe(1);
    expect(session.sessionManager.getEntries().some(entry => entry.type === "compaction")).toBe(false);
  });

  it("uses current compaction headroom for both projection and validation", async () => {
    const { policy, settingsManager } = await fixture();
    settingsManager.applyOverrides({ compaction: { reserveTokens: 200_000, keepRecentTokens: 100_000 } });
    policy.restore();
    expect(policy.snapshot()).toMatchObject({ minimum: 301_024, default: 301_024, effective: 301_024, warning: expect.stringContaining("bounded") });
    expect(() => policy.set(astra, 300_000)).toThrow(/301024/);
    policy.set(astra, 301_024);
    expect(policy.snapshot()?.effective).toBe(301_024);
  });

  it("projects actual usage while changed metadata is awaiting application", async () => {
    const { session, policy, faux, modelRuntime } = await fixture();
    await session.setModel(faux.getModel("other")!);
    const model = session.model!;
    policy.set(model, 100_000);
    modelRuntime.getModels().find(value => value.id === "other")!.contextWindow = 64_000;
    expect(policy.snapshot()).toMatchObject({ maximum: 64_000, effective: 100_000, override: 100_000, warning: expect.stringContaining("next turn") });
    expect(session.getContextUsage()?.contextWindow).toBe(100_000);
    policy.apply();
    expect(policy.snapshot()).toMatchObject({ maximum: 64_000, effective: 64_000, override: 100_000, warning: expect.stringContaining("bounded") });
  });

  it("bounds stale persisted preferences to changed capacity and reports the adjustment", async () => {
    const { policy } = await fixture({ [contextModelKey(astra)]: 2_000_000 });
    expect(policy.snapshot()).toMatchObject({ effective: 1_050_000, default: 1_050_000, source: "global", warning: expect.stringContaining("bounded") });
  });
});
