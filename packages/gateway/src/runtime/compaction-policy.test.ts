import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, describe, expect, it } from "vitest";
import { createAgentSessionServices, createAgentSessionFromServices, ModelRuntime, SessionManager, type AgentSession, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type, fauxProvider, fauxAssistantMessage, fauxToolCall, getCurrentSystemPrompt, getCurrentTools, normalizeContext, type TranscriptContext, type SimpleStreamOptions } from "@earendil-works/pi-ai";
import { abortAwareStream } from "./abort-aware-stream.js";
import { CompactionOperationPolicy, compactionPolicyExtension, oversizedRequestOverflow, resolveCompactionPolicy } from "./compaction-policy.js";

/** Captured verbatim from opencode-go rejecting a 48MB conversation: the
 * provider edge answered HTTP 413 with an opaque body, so the pinned SDK
 * classified it as a transient server error, retried the identical oversized
 * request, and left the session unable to continue until it was compacted. */
const OVERSIZED_REQUEST_ERROR = "413: {\"type\":\"server_error\",\"code\":\"server_error\",\"message\":\"Error from provider (Console Go): Upstream request failed: [server_error] Upstream response was not valid JSON\"}";

const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => { for (const dispose of cleanup.splice(0).reverse()) await dispose(); });

async function fixture(configuration: Record<string, unknown> = {}, adapted = true, extra?: ExtensionFactory, reasoning = true) {
  const root = await mkdtemp(join(tmpdir(), "tron-policy-sdk-"));
  const cwd = join(root, "project");
  await mkdir(cwd);
  const settingsPath = join(root, "settings.json");
  const save = async (patch: Record<string, unknown>) => writeFile(settingsPath, JSON.stringify({
    compaction: { enabled: false, reserveTokens: 4096, keepRecentTokens: 100, ...patch },
    retry: { enabled: true, maxRetries: 1, baseDelayMs: 0 },
  }));
  await save(configuration);
  const faux = fauxProvider({ provider: "tron-policy-fixture", models: [{ id: "fixture", reasoning }], tokensPerSecond: 1_000_000, tokenSize: { min: 100_000, max: 100_000 } });
  const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
  runtime.registerNativeProvider(faux.provider);
  let policy: CompactionOperationPolicy | undefined;
  const services = await createAgentSessionServices({ cwd, agentDir: root, modelRuntime: runtime, resourceLoaderOptions: {
    noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
    extensionFactories: [
      ...(adapted ? [{ name: "tron-compaction-policy", factory: compactionPolicyExtension(() => policy, () => false, () => {}) }] : []),
      ...(extra ? [{ name: "other", factory: extra }] : []),
    ],
  } });
  const manager = SessionManager.inMemory(cwd);
  manager.appendMessage({ role: "user", content: "Preserve the API invariant and unfinished task", timestamp: 1 });
  manager.appendMessage(fauxAssistantMessage("Decision: retain the original API. Still blocked on credentials.", { timestamp: 2 }));
  manager.appendMessage({ role: "user", content: "Read a.ts and finish the task", timestamp: 3 });
  manager.appendMessage(fauxAssistantMessage(fauxToolCall("read", { path: "a.ts" }, { id: "read-a" }), { timestamp: 4 }));
  manager.appendMessage({ role: "toolResult", toolCallId: "read-a", toolName: "read", content: [{ type: "text", text: "source ".repeat(600) }], isError: false, timestamp: 5 });
  manager.appendMessage(fauxAssistantMessage("Recent work ".repeat(150), { timestamp: 6 }));
  const { session } = await createAgentSessionFromServices({ services, sessionManager: manager, model: faux.getModel(), thinkingLevel: "high", noTools: true });
  cleanup.push(async () => { session.dispose(); await rm(root, { recursive: true, force: true }); });
  if (adapted) {
    policy = new CompactionOperationPolicy(session, root);
    session.agent.streamFunction = policy.wrap(abortAwareStream(session.agent.streamFunction));
  }
  // Like RuntimeSlot, bind an actual host callback so reload emits session_start.
  await session.bindExtensions({ mode: "rpc", onError: error => { throw new Error(error.error); } });
  const calls: Array<{ context: TranscriptContext; options?: SimpleStreamOptions }> = [];
  const record = (text: string) => (context: TranscriptContext, options: SimpleStreamOptions | undefined) => {
    calls.push({ context, ...(options ? { options } : {}) });
    return fauxAssistantMessage(text);
  };
  return { session, policy: policy!, faux, calls, record, save, settingsPath };
}

function normalized(calls: Awaited<ReturnType<typeof fixture>>["calls"]) {
  return calls.map(({ context, options }) => ({
    context: {
      systemPrompt: getCurrentSystemPrompt(context.messages),
      tools: getCurrentTools(context.messages),
      messages: context.messages.filter(message => message.role !== "system").map(({ timestamp: _timestamp, ...message }) => message),
    },
    options: Object.fromEntries(Object.entries(options ?? {}).filter(([key]) => !["signal", "sessionId"].includes(key))),
  }));
}

function checkpoint(session: AgentSession) {
  const entry = session.sessionManager.getBranch().findLast(entry => entry.type === "compaction");
  if (!entry || entry.type !== "compaction") throw new Error("No canonical checkpoint");
  // UUIDs are independent in the two canonical fixtures. Compare retained
  // content and every non-identity compaction field, not generated IDs.
  const { id: _id, parentId: _parent, timestamp: _time, firstKeptEntryId, ...result } = entry;
  return { ...result, retained: session.sessionManager.getEntry(firstKeptEntryId)?.type,
    context: session.sessionManager.buildSessionContext().messages.map(message => JSON.stringify(message, (key, value) => key === "timestamp" ? undefined : value)) };
}

describe.sequential("provider request-size overflow classification", () => {
  it("treats a provider body-limit rejection as recoverable context overflow and leaves other failures alone", () => {
    const rejected = fauxAssistantMessage("", { stopReason: "error", errorMessage: OVERSIZED_REQUEST_ERROR });
    const recovered = oversizedRequestOverflow(rejected);
    expect(recovered?.errorMessage).toBe(`context_length_exceeded: ${OVERSIZED_REQUEST_ERROR}`);
    expect(recovered?.content).toEqual(rejected.content);
    // Idempotent, and limited to a 413 status prefix.
    expect(oversizedRequestOverflow(recovered!)).toBeUndefined();
    for (const errorMessage of ["429: rate limit reached", "500: internal server error", "413 tokens were counted in the prompt"]) {
      expect(oversizedRequestOverflow(fauxAssistantMessage("", { stopReason: "error", errorMessage }))).toBeUndefined();
    }
    expect(oversizedRequestOverflow(fauxAssistantMessage("completed"))).toBeUndefined();
  });
});

describe.sequential("pinned SDK compaction request policy", () => {
  it("keeps exact built-in split-summary requests, checkpoint, file tracking and rebuilt context under standard behavior", async () => {
    const baseline = await fixture({}, false);
    const adapted = await fixture();
    for (const item of [baseline, adapted]) {
      item.faux.setResponses([item.record("API invariant retained; credentials still block completion."), item.record("Read a.ts; finish the task.")]);
      await item.session.compact("preserve exact identifiers");
      expect(item.calls).toHaveLength(2);
    }
    expect(normalized(adapted.calls)).toEqual(normalized(baseline.calls));
    expect(checkpoint(adapted.session)).toEqual(checkpoint(baseline.session));
    expect(checkpoint(adapted.session)).toMatchObject({ details: { readFiles: ["a.ts"], modifiedFiles: [] }, fromHook: false });
    expect(adapted.policy.snapshot().active).toBeUndefined();
  });

  it("preserves existing system prompt, structured sections, and tool deltas with the compaction focus", async () => {
    const item = await fixture({ instructions: "Keep decisions" });
    const retainedTool = { name: "retained-tool", description: "Existing declaration", parameters: Type.Object({}) };
    const stream = item.session.agent.streamFunction;
    item.session.agent.streamFunction = (model, context, options) => stream(model, normalizeContext({
      messages: [...context.messages, {
        role: "system", content: "Existing system prompt", sections: { runtime: "Existing named section" },
        toolsAdded: [retainedTool], timestamp: 7,
      }],
    }), options);
    item.faux.setResponses([item.record("History"), item.record("Prefix")]);
    await item.session.compact();
    const messages = item.calls[0]!.context.messages;
    const prompt = getCurrentSystemPrompt(messages);
    expect(prompt).toContain("Existing system prompt");
    expect(prompt).toContain("Existing named section");
    expect(prompt).toContain("User-configured summary focus:\nKeep decisions");
    expect(getCurrentTools(messages)).toMatchObject([{ name: "retained-tool", description: "Existing declaration" }]);
  });

  it("changes only reasoning for Low, including both split passes", async () => {
    const baseline = await fixture({}, false);
    const adapted = await fixture({ thinkingLevel: "low" });
    for (const item of [baseline, adapted]) {
      item.faux.setResponses([item.record("History"), item.record("Prefix")]);
      await item.session.compact();
    }
    expect(normalized(adapted.calls)).toEqual(normalized(baseline.calls).map(call => ({ ...call, options: { ...call.options, reasoning: "low" } })));
    expect(adapted.session.thinkingLevel).toBe("high");
  });

  it.each(["off", "low"])("resolves %s to off for a non-reasoning model", async thinkingLevel => {
    const item = await fixture({ thinkingLevel }, true, undefined, false);
    item.faux.setResponses([item.record("History"), item.record("Prefix")]);
    await item.session.compact();
    expect(item.calls.every(call => call.options?.reasoning === undefined)).toBe(true);
    expect(item.policy.snapshot().next.effectiveThinkingLevel).toBe("off");
  });

  it("captures policy once across a real transient retry and split pass while saved settings change", async () => {
    const item = await fixture({ thinkingLevel: "low", instructions: "First focus" });
    let changed = false;
    item.faux.setResponses([
      async (context, options) => {
        item.calls.push({ context, options });
        await item.save({ thinkingLevel: "high", instructions: "Next focus", enabled: true, keepRecentTokens: 500 });
        item.policy.refresh();
        changed = true;
        return fauxAssistantMessage("", { stopReason: "error", errorMessage: "terminated" });
      }, item.record("History"), item.record("Prefix"),
    ]);
    const events: string[] = [];
    item.session.subscribe(event => events.push(event.type));
    await item.session.compact();
    expect(changed).toBe(true);
    expect(item.calls).toHaveLength(3);
    expect(item.calls.every(call => call.options?.reasoning === "low" && getCurrentSystemPrompt(call.context.messages).endsWith("First focus"))).toBe(true);
    expect(new Set(item.calls.map(call => call.options?.signal)).size).toBe(1);
    expect(events).toContain("summarization_retry_scheduled");
    expect(item.policy.snapshot()).toMatchObject({ next: { thinkingLevel: "high", instructions: "Next focus", enabled: true }, currentBudgets: { enabled: false, keepRecentTokens: 100 } });
    expect(item.policy.snapshot().active).toBeUndefined();
  });

  it.each(["error", "length"] as const)("does not checkpoint a failed %s split prefix or launch fallback generation", async stopReason => {
    const item = await fixture({ thinkingLevel: "low" });
    item.faux.setResponses([item.record("A good history summary"), () => fauxAssistantMessage("Incomplete prefix", { stopReason, errorMessage: "invalid request" })]);
    await expect(item.session.compact()).rejects.toThrow();
    expect(item.faux.state.callCount).toBe(2);
    expect(item.session.sessionManager.getBranch().some(entry => entry.type === "compaction")).toBe(false);
    expect(item.policy.snapshot().active).toBeUndefined();
  });

  it("allows observational and custom-result hooks without replacing their lifecycle or spending on a default summary", async () => {
    const observer = await fixture({ thinkingLevel: "low" }, true, pi => { pi.on("session_before_compact", () => {}); });
    observer.faux.setResponses([observer.record("History"), observer.record("Prefix")]);
    await observer.session.compact();
    expect(observer.calls).toHaveLength(2);
    expect(observer.policy.snapshot().extensionMayOverride).toBe(true);
    const generator = await fixture({ thinkingLevel: "low" }, true, pi => {
      pi.on("session_before_compact", event => ({ compaction: { summary: "Extension-owned", firstKeptEntryId: event.preparation.firstKeptEntryId, tokensBefore: event.preparation.tokensBefore } }));
    });
    await generator.session.compact();
    expect(generator.faux.state.callCount).toBe(0);
    expect(checkpoint(generator.session)).toMatchObject({ summary: "Extension-owned", fromHook: true });
    expect(generator.policy.snapshot().active).toBeUndefined();
  });

  it("leaves real branch summarization unchanged and survives extension reload", async () => {
    const baseline = await fixture({}, false);
    const adapted = await fixture({ thinkingLevel: "low", instructions: "Compaction only" });
    for (const item of [baseline, adapted]) {
      await item.session.resourceLoader.reload();
      await item.session.reload();
      item.faux.setResponses([item.record("Branch summary")]);
      const target = item.session.sessionManager.getBranch()[0]!.id;
      await item.session.navigateTree(target, { summarize: true });
      expect(item.calls).toHaveLength(1);
    }
    expect(normalized(adapted.calls)).toEqual(normalized(baseline.calls));
    expect(getCurrentSystemPrompt(adapted.calls[0]!.context.messages)).not.toContain("Compaction only");
    expect(adapted.policy.snapshot().active).toBeUndefined();
    // The reloaded factory still binds the original live session policy.
    adapted.faux.setResponses([adapted.record("Compaction after reload"), adapted.record("Prefix after reload")]);
    adapted.session.sessionManager.appendMessage({ role: "user", content: "Next request", timestamp: 7 });
    adapted.session.sessionManager.appendMessage(fauxAssistantMessage("New response ".repeat(150)));
    await adapted.session.compact();
    expect(adapted.calls.at(-1)?.options?.reasoning).toBe("low");
    expect(getCurrentSystemPrompt(adapted.calls.at(-1)!.context.messages)).toContain("Compaction only");
  });

  it("refreshes policy provenance when project trust reloads, without retaining the retired project scope", async () => {
    const item = await fixture({ thinkingLevel: "low", instructions: "Global focus" });
    const project = join(item.session.sessionManager.getCwd(), ".pi");
    await mkdir(project);
    await writeFile(join(project, "settings.json"), JSON.stringify({ compaction: { thinkingLevel: "high", instructions: "Trusted focus", keepRecentTokens: 200 } }));
    await item.session.resourceLoader.reload({ resolveProjectTrust: async () => true });
    await item.session.reload();
    expect(item.policy.snapshot()).toMatchObject({ next: { thinkingLevel: "high", instructions: "Trusted focus", source: { thinkingLevel: "project", keepRecentTokens: "project" } }, currentBudgets: { keepRecentTokens: 200 } });
    await item.session.resourceLoader.reload({ resolveProjectTrust: async () => false });
    await item.session.reload();
    expect(item.policy.snapshot()).toMatchObject({ next: { thinkingLevel: "low", instructions: "Global focus", source: { thinkingLevel: "global", keepRecentTokens: "global" } }, currentBudgets: { keepRecentTokens: 100 } });
  });

  it("reports repeated malformed reads and recovers only after canonical settings are valid", async () => {
    const item = await fixture({ thinkingLevel: "low" });
    await writeFile(item.settingsPath, '{"compaction":');
    for (let i = 0; i < 2; i++) expect(() => item.policy.refresh()).toThrow(/could not be loaded/);
    expect(item.policy.snapshot()).toMatchObject({ next: { thinkingLevel: "low" }, warning: expect.any(String) });
    await item.save({ thinkingLevel: "inherit" });
    item.policy.refresh();
    expect(item.policy.snapshot().warning).toBeUndefined();
    expect(item.policy.snapshot().next.thinkingLevel).toBe("inherit");
  });

  it("resolves trusted inheritance, explicit standard resets, every thinking level, and rejects invalid canonical values", () => {
    expect(resolveCompactionPolicy({ compaction: { thinkingLevel: "low", instructions: "global" } }, { compaction: { thinkingLevel: "inherit", instructions: "" } }, true))
      .toMatchObject({ thinkingLevel: "inherit", instructions: "", source: { thinkingLevel: "project", instructions: "project" } });
    expect(resolveCompactionPolicy({}, { compaction: { thinkingLevel: "bad" } }, false).thinkingLevel).toBe("inherit");
    for (const thinkingLevel of ["inherit", "off", "minimal", "low", "medium", "high", "xhigh", "max"]) expect(resolveCompactionPolicy({ compaction: { thinkingLevel } }).thinkingLevel).toBe(thinkingLevel);
    for (const compaction of [{ thinkingLevel: "bad" }, { thinkingLevel: null }, { instructions: "a".repeat(4001) }, { reserveTokens: 0 }, { enabled: 1 }]) expect(() => resolveCompactionPolicy({ compaction })).toThrow();
  });
});
