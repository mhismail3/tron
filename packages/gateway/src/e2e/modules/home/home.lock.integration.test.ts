import { mkdtemp, readFile, readdir } from "node:fs/promises";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall, getCurrentSystemPrompt, getCurrentTools, type SimpleStreamOptions, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../../../test-support/gateway-lock-harness.js";
import { compareWithGolden, lockPaths, lockUpdateRequested, normalizeTraceValue, type TraceValue } from "../../../../test-support/scenario-lock.js";
import { waitFor } from "../../../../test-support/wait-for.js";
import { NotificationGrantStore } from "../../../notifications/grant-store.js";
import { NotificationService } from "../../../notifications/notification-service.js";
import { PushRelayClient } from "../../../notifications/relay-client.js";
import { homeOwnerOf } from "../../../../test-support/gateway-registry.js";

const MODULE = "gateway/e2e";
const LOCK = "home-activation-wake";
const LOCK_PROVIDER = `tron-lock-${LOCK}`;
const WORKER_MARKER = "This is a finite Home task.";
const TASK_ID = "lock-task";
const RELAY_ORIGIN = "https://relay.lock.invalid";
const owned: Array<() => Promise<void>> = [];
afterEach(async () => { for (const release of owned.splice(0).reverse()) await release(); });

interface HomeLockTrace {
  readonly lock: string;
  readonly providerRequests: { readonly home: readonly TraceValue[]; readonly worker: readonly TraceValue[] };
  readonly systemEntries: { readonly home: TraceValue; readonly worker: TraceValue };
}

const SNAPSHOT_STATED_TOPICS = new Set(["session.snapshot", "session.rebaseline", "session.progress", "session.configuration",
  "session.toolProgress", "session.processActivity", "session.extensionActivity", "session.compaction"]);
const SIZE_KEYS = new Set(["bytes", "currentBytes", "viewBytes", "effectiveTokens", "inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens", "tokens"]);
const ENTRY_ID = /^[0-9a-f]{8}$/;
function stabilize(value: TraceValue, key = ""): TraceValue {
  if (typeof value === "string") {
    if (ENTRY_ID.test(value)) return "<entry>";
    return value.replace(/\| duration: \d+ms/g, "| duration: <duration>");
  }
  if (typeof value === "number") return SIZE_KEYS.has(key) && value > 0 ? "<size>" : value;
  if (Array.isArray(value)) return value.map((item) => stabilize(item, key));
  if (value !== null && typeof value === "object") {
    if (key === "hostPressure") return Object.fromEntries(Object.keys(value).map((name) => [name, "<host>"]));
    return Object.fromEntries(Object.entries(value).map(([name, child]) => [name, stabilize(child, name)]));
  }
  return value;
}

type Caller = "home-input" | "home-delegated" | "home-wake" | "worker";

async function loadedExtensions(gateway: LockGateway, sessionId: string): Promise<string[]> {
  const slot = await gateway.registry.acquire(sessionId) as unknown as { runtime: { session: { resourceLoader: { getExtensions(): { extensions: Array<{
    path: string; tools: Map<string, unknown>; handlers: Map<string, unknown[]>; commands: Map<string, unknown>;
  }> } } } } };
  return slot.runtime.session.resourceLoader.getExtensions().extensions.map((extension) => [String(normalizeTraceValue(extension.path, gateway.normalization)),
    ...(extension.tools.size ? [`tools ${[...extension.tools.keys()].join(",")}`] : []),
    ...(extension.handlers.size ? [`on ${[...extension.handlers].map(([event, handlers]) => `${event}×${handlers.length}`).join(",")}`] : []),
    ...(extension.commands.size ? [`commands ${[...extension.commands.keys()].join(",")}`] : [])].join(" | "));
}
const HOME_EXTENSIONS = [
  "<inline:tron-context-window> | on session_start×1,session_tree×1,model_select×1,before_agent_start×1,turn_start×1",
  "<inline:tron-compaction-policy> | on message_end×1,session_start×1,session_before_compact×1",
  "<inline:tron-settings> | tools settings",
  "<inline:tron-projects> | tools projects",
  "<inline:tron-ask-user> | tools ask_user",
  "<inline:tron-display> | tools display | on tool_result×1,agent_end×1,session_shutdown×1",
  "<inline:tron-notify> | tools notify",
  "<inline:tron-home> | tools zoom,date,memory_search,profile,obligation,delegate,task | on tool_call×1,cache_warming_decision×1,before_provider_request×1",
  "<inline:tron-home-research> | tools session_search,session_read",
  "<inline:tron-web-research> | tools web_search | on session_start×1,session_shutdown×1",
];
const WORKER_EXTENSIONS = [
  "builtin:codemode | tools codemode",
  "builtin:tool-search | tools tool_search",
  "builtin:mcp | on session_start×1,before_agent_start×1,tool_call×1,turn_start×1,mcp_servers_change×1,session_shutdown×1 | commands mcp",
  "<inline:tron-invocation-settlement> | on turn_start×1,message_end×1",
  "<inline:tron-context-window> | on session_start×1,session_tree×1,model_select×1,before_agent_start×1,turn_start×1",
  "<inline:tron-compaction-policy> | on message_end×1,session_start×1,session_before_compact×1",
  "<inline:tron-core> | tools jev | on before_agent_start×1,tool_call×1",
  "<inline:tron-web-research> | tools web_search | on session_start×1,session_shutdown×1",
  "<inline:tron-settings> | tools settings",
  "<inline:tron-projects> | tools projects",
  "<inline:tron-ask-user> | tools ask_user",
  "<inline:tron-display> | tools display | on tool_result×1,agent_end×1,session_shutdown×1",
  "<inline:tron-swift-apps> | tools swift_app",
  "<inline:tron-computer> | tools computer | on session_shutdown×1,before_agent_start×1",
  "<inline:tron-notify> | tools notify",
  "<inline:tron-model-queue> | on session_start×3,agent_before_settle×2,session_shutdown×1,tool_call×1",
  "<inline:tron-home-task-worker> | on before_agent_start×1,tool_call×1",
];

function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  return Array.isArray(content) ? content.map((part) => (part as { text?: unknown }).text ?? "").join("") : "";
}

function callerOf(context: TranscriptContext): Caller {
  const messages = context.messages as Array<{ role: string; content?: unknown; toolName?: string }>;
  if (messages.some((message) => (message.role === "user" || message.role === "system") && textOf(message.content).includes(WORKER_MARKER))) return "worker";
  const last = messages.at(-1);
  if (last?.role === "toolResult" && last.toolName === "delegate") return "home-delegated";
  if (last?.role === "user" && textOf(last.content).includes("Delegate the lock work")) return "home-input";
  return "home-wake";
}

describe("gateway/home scenario lock", () => {
  it("home-activation-wake: designation, first runtime, an activation that delegates, the worker's report and the wake", async () => {
    const relayRequests: Array<{ method: string; path: string; envelope: unknown }> = [];
    let notifications!: NotificationService;
    let gateway!: LockGateway;
    gateway = await startLockGateway(LOCK, {
      root: await mkdtemp("/tmp/tron-home-lock-"),
      home: { memorySummarizer: () => async () => fauxAssistantMessage("Lock memory summary.") },
      notifications: async (tronHome) => {
        const relay = new PushRelayClient(RELAY_ORIGIN, async (url, init) => {
          relayRequests.push({ method: String(init.method), path: new URL(url).pathname, envelope: init.body ? JSON.parse(String(init.body)) : null });
          return new Response(JSON.stringify({ status: "accepted_by_apns" }), { status: 200 }) as never;
        });
        notifications = new NotificationService(new NotificationGrantStore(tronHome), relay, Date.now, () => {}, () => {}, () => {},
          (sessionId) => (gateway ? homeOwnerOf(gateway.registry) : undefined)?.chapterStateFor(sessionId).homeId !== undefined);
        await notifications.initialize();
        return notifications;
      },
    });
    owned.push(() => gateway.dispose());
    owned.push(async () => notifications.dispose());
    const settings = JSON.parse(await readFile(join(gateway.agentDir, "settings.json"), "utf8")) as { defaultProvider: string; defaultModel: string };
    const model = { provider: settings.defaultProvider, id: settings.defaultModel };

    let releaseWorker = (): void => {};
    const workerReleased = new Promise<void>((resolve) => { releaseWorker = resolve; });
    const callers: Caller[] = [];
    const homeHeadings: Array<[Caller, string[]]> = [];
    const requestTools: { home?: unknown; worker?: unknown } = {};
    const requestOptions: Array<{ caller: Caller; options: Record<string, unknown> }> = [];
    const route = async (context: TranscriptContext, options: SimpleStreamOptions | undefined) => {
      const caller = callerOf(context);
      callers.push(caller);
      requestOptions.push({ caller, options: Object.fromEntries(Object.entries(options ?? {})
        .filter(([, value]) => typeof value !== "function" && !(value instanceof AbortSignal))) });
      requestTools[caller === "worker" ? "worker" : "home"] ??= getCurrentTools(context.messages)
        .map((tool) => ({ name: tool.name, description: tool.description, parameters: tool.parameters }));
      if (caller !== "worker") homeHeadings.push([caller, [...getCurrentSystemPrompt(context.messages).matchAll(/^#{1,3} .+$/gm)].map((match) => match[0])]);
      switch (caller) {
        case "home-input":
          return fauxAssistantMessage([fauxToolCall("delegate", { taskId: TASK_ID, intent: "Summarize notes.txt in the lock project.", target: gateway.cwd, title: "Lock task" }, { id: "lock-delegate" })], { stopReason: "toolUse" });
        case "home-delegated":
          return fauxAssistantMessage("Delegated the lock task.");
        case "worker": {
          await workerReleased;
          const reported = (context.messages as Array<{ role: string; toolName?: string }>).some((message) => message.role === "toolResult" && message.toolName === "report");
          return reported ? fauxAssistantMessage("Reported.")
            : fauxAssistantMessage([fauxToolCall("report", { resultId: "lock-result", outcome: "final", text: "The notes say: lock notes.", evidence: ["read notes.txt"] }, { id: "lock-report" })], { stopReason: "toolUse" });
        }
        case "home-wake":
          return fauxAssistantMessage("The lock task reported: lock notes.");
      }
    };
    gateway.script(Array.from({ length: 8 }, () => route));

    const phone = await gateway.connect("phone", { clientRole: "mobile" });
    const registered = await phone.request("push.registration.upsert", {
      commandId: gateway.commandId(), installationId: "lock-installation", grantId: "lock-grant-0001",
      secret: Buffer.alloc(32, 7).toString("base64url"), previewsEnabled: false, relayOrigin: RELAY_ORIGIN,
      notifyWhenAskPresented: true, notifyWhenFinished: true, notifyWhenWaiting: true,
    });
    expect(registered.ok, JSON.stringify(registered)).toBe(true);
    const undesignated = await phone.request("home.status", {});
    expect(undesignated.ok, JSON.stringify(undesignated)).toBe(true);
    const designated = await phone.request("home.designate", { commandId: gateway.commandId(), model });
    expect(designated.ok, JSON.stringify(designated)).toBe(true);
    const queue = await phone.request("settings.change", { commandId: gateway.commandId(), target: { kind: "home" },
      changes: [{ key: "model.queue[role=background]", layer: "session", op: "set", value: [`${model.provider}/${model.id}`] }] });
    expect(queue.ok, JSON.stringify(queue)).toBe(true);
    const opened = await phone.request("home.open", {});
    expect(opened.ok, JSON.stringify(opened)).toBe(true);
    const homeSessionId = opened.result.sessionId as string;
    const session = await phone.request("session.open", { sessionId: homeSessionId });
    expect(session.ok, JSON.stringify(session)).toBe(true);
    expect((await phone.request("session.sync", { sessionId: homeSessionId, syncToken: session.result.syncToken })).ok).toBe(true);
    expect((await phone.request("home.status", {})).ok).toBe(true);

    const admitted = await phone.request("home.prompt", { commandId: gateway.commandId(), text: "Delegate the lock work." });
    expect(admitted.ok, JSON.stringify(admitted)).toBe(true);
    await waitFor(() => callers.includes("home-delegated"), "Home's delegating activation to answer the admission");
    await gateway.settled(homeSessionId);
    releaseWorker();
    const owner = homeOwnerOf(gateway.registry);
    await waitFor(async () => (await owner.taskResult(TASK_ID)).wake?.state === "acknowledged", "the task result wake to be acknowledged");
    await waitFor(() => callers.includes("home-wake"), "the wake activation's request");
    await gateway.settled(homeSessionId);

    const task = await phone.request("home.taskStatus", { taskId: TASK_ID });
    expect(task.ok, JSON.stringify(task)).toBe(true);
    const workerSessionId = task.result.sessionId as string;
    await gateway.settled(workerSessionId);
    expect((await phone.request("home.taskList", {})).ok).toBe(true);
    expect((await phone.request("home.status", {})).ok).toBe(true);
    const context = await phone.request("home.context", {});
    expect(context.ok, JSON.stringify(context)).toBe(true);
    expect((await phone.request("session.transcript", { sessionId: homeSessionId })).ok).toBe(true);

    await waitFor(() => relayRequests.length >= 2, "both Home activations' finished pushes to reach the relay");
    const reopen = await gateway.connect("reopen");
    const reopened = await reopen.request("session.open", { sessionId: homeSessionId });
    expect(reopened.ok, JSON.stringify(reopened)).toBe(true);

    const recorded = gateway.record();
    const stable = (value: unknown) => stabilize(value as TraceValue) as any;
    const exchanges = stable(recorded.exchanges) as Array<{ client: string; method: string; response: any }>;
    expect(exchanges.map((exchange) => `${exchange.client} ${exchange.method}`), "the client's requests, in order").toEqual([
      "phone push.registration.upsert", "phone home.status", "phone home.designate", "phone settings.change", "phone home.open", "phone session.open",
      "phone session.sync", "phone home.status", "phone home.prompt", "phone home.taskStatus", "phone home.taskList", "phone home.status",
      "phone home.context", "phone session.transcript", "reopen session.open",
    ]);
    const answers = exchanges.map((exchange) => exchange.response);
    const MODEL = `${LOCK_PROVIDER}/faux-1`;
    const HOST = { eventLoopUtilization: "<host>", level: "<host>", load1PerCpu: "<host>", sampledAt: "<host>" };
    expect(answers[0], "the push registration").toEqual({ error: null, ok: true, result: {
      available: true, deviceRegistered: true, enabledDeviceCount: 1, notifyWhenAskPresented: true, notifyWhenFinished: true, notifyWhenWaiting: true,
      pendingCount: 0, registered: true, relayOrigin: RELAY_ORIGIN, requiresGrantRotation: false } });
    expect(answers[1], "status before designation: no Home, designate is the recovery").toEqual({ error: null, ok: true, result: {
      activation: { available: false }, available: true, enabled: false, hostPressure: HOST, live: false,
      memory: { configured: false, open: false, paused: false }, phase: "undesignated", readiness: { gaps: ["not-designated"], ready: false },
      recovery: { action: "designate" }, sessionPresent: false, taskRecovery: { available: true }, workers: { running: 0 } } });
    expect(answers[2], "the designation").toEqual({ error: null, ok: true, result: { generation: 1, homeId: "<id>", sessionId: "<id>" } });
    expect(answers[3], "the memory queue change applies at Home's session layer without a tap").toEqual({ error: null, ok: true, result: {
      changes: [{ after: [MODEL], before: null, changeId: "<id>", key: "model.queue[role=background]", layer: "session", qualifiers: { role: "background" }, status: "applied" }],
      review: { digest: "<base64:64>", requiresTap: false, title: "Background models", items: [{ after: MODEL, before: "Not set", detail: "Session stored value\nhome",
        exact: `{"target":{"kind":"home"},"key":"model.queue[role=background]","layer":"session","qualifiers":{"role":"background"},"op":"set","before":null,"after":["${MODEL}"]}`,
        label: "Background models" }] },
      status: "applied" } });
    expect(answers[4], "the chapter opens active").toEqual({ error: null, ok: true,
      result: { bindingRevision: 1, chapterState: "active", generation: 1, homeId: "<id>", logicalSessionId: "home", sessionId: "<id>" } });
    expect(answers[6], "the sync").toEqual({ error: null, ok: true, result: { synchronized: true } });
    expect(answers[7], "status once designated: ready, live, memory configured and closed").toEqual({ error: null, ok: true, result: {
      activation: { available: false }, available: true, bindingRevision: 1, chapter: { count: 1, currentBytes: 0, currentEntries: 7, recoveryDecision: "none" },
      enabled: true, generation: 1, homeId: "<id>", hostPressure: HOST, live: true, memory: { configured: true, models: [MODEL], open: false, paused: false },
      openSessionId: "<id>", phase: "ready", readiness: { gaps: [], ready: true }, recovery: { action: "none" }, routeGeneration: 1, sessionId: "<id>",
      sessionPresent: true, taskRecovery: { available: true }, waitingForUser: false, workers: { running: 0 } } });
    expect(answers[8], "the prompt's admission names Home's logical session").toEqual({ error: null, ok: true,
      result: { bindingRevision: 1, homeId: "<id>", logicalSessionId: "home", operationId: "<id>", sessionId: "<id>" } });
    const INTENT = `Summarize notes.txt in the lock project.\n\nWorker choice: model ${MODEL} (same as Home); thinking off (same as Home).`;
    const SPEND = { cacheReadTokens: 0, cacheWriteTokens: "<size>", inputTokens: 0, outputTokens: "<size>", sourceDigest: "<base64:64>" };
    const EVENT_ID = "task-result-d7f1ec6b5d880e396a4f3a69702854c5c99bb2cf41b996fac1975b340ada6091";
    const TERMINAL = { entryIds: ["<entry>"], outcome: "final", reason: "explicit-report", sessionId: "<id>" };
    const REPORT_REF = { digest: "<base64:64>", entryId: "<entry>", resultId: "lock-result", sessionId: "<id>" };
    const TASK = { createdAt: "<timestamp>", generation: 1, grantRef: null, homeId: "<id>", intent: { text: INTENT }, intentDigest: "<base64:64>",
      lifecycle: "terminal", operationId: "<id>", reportRef: REPORT_REF, revision: "<n>", routeGeneration: 1, scopeRef: "<id>", sessionId: "<id>",
      spend: SPEND, stopIntent: null, target: "<tmp>/workspace", taskId: TASK_ID, terminalEvidence: TERMINAL, updatedAt: "<timestamp>", version: 1,
      wake: { acknowledgedAt: "<timestamp>", createdAt: "<timestamp>", eventId: EVENT_ID, push: "decided", redeliveries: [], routeGeneration: 1, state: "acknowledged",
        delivery: { generation: 1, messageDigest: "<base64:64>", operationId: "<id>", routeGeneration: 1, sessionId: "<id>" } } };
    expect(answers[9], "the task: terminal by its explicit report, its wake delivered and acknowledged").toEqual({ error: null, ok: true, result: {
      ...TASK, checkins: [], ownerSettlement: null, project: "workspace", subagentRuns: { runs: [], total: 0 }, subagents: { started: 0, stoppedAtEnd: 0 },
      title: "Lock task", workerModel: { id: "<id>", provider: LOCK_PROVIDER } } });
    expect(answers[10], "the task list").toEqual({ error: null, ok: true, result: { counts: { active: 0, finished: 1 }, items: [{
      attention: false, checkins: [], createdAt: "<timestamp>", lifecycle: "terminal", outcome: "final", pendingGrant: false, project: "workspace", sessionId: "<id>",
      spend: SPEND, target: "<tmp>/workspace", taskId: TASK_ID, title: "Lock task", updatedAt: "<timestamp>" }] } });
    const CONTEXT = { activationOpen: false, activationStartEntryId: "<entry>", available: true, contextWindow: 128000, effectiveTokens: "<size>", viewBytes: "<size>", viewLines: 11,
      breakdown: { activation: { kind: "wake", startedAt: "<timestamp>", state: "settled" }, contextWindow: 128000, effectiveTokens: "<size>", sections: [
        { id: "<id>", tokens: "<size>" }, { count: 0, id: "<id>", tokens: "<size>" }, { count: 4, id: "<id>", tokens: "<size>" },
        { count: 0, id: "<id>", tokens: 0 }, { count: 0, id: "<id>", tokens: 0 }, { id: "<id>", tokens: "<size>" }] } };
    expect(answers[11], "status after the wake: the chapter grew, memory summarized all six messages").toEqual({ error: null, ok: true, result: {
      activation: CONTEXT, available: true, bindingRevision: 1, chapter: { count: 1, currentBytes: "<size>", currentEntries: 23, recoveryDecision: "none" },
      enabled: true, generation: 1, homeId: "<id>", hostPressure: HOST, live: true,
      memory: { configured: true, models: [MODEL], open: true, paused: false, spentTokens: 0, episodic: {
        blocked: null, coverage: { admitted: 6, summarized: 6 }, generation: 0, messages: 6, pump: { busy: 0 }, sourceSessionId: "<id>",
        nodes: { byLevel: [{ count: 6, level: 0 }, { count: 3, level: 1 }, { count: 1, level: 2 }], free: 10, summary: 0, total: 10 },
        tokens: { sinceOpen: { cacheRead: 0, cacheWrite: 0, input: 0, output: 0 }, used: 0 },
        view: { budgetBytes: 128000, built: 6, bytes: "<size>", truncatedParts: 0, unbuilt: 0,
          parts: [0, 1, 2, 3, 4, 5].map((start) => ({ address: `${start}+1`, built: true, bytes: "<size>", messages: 1, start })) } } },
      openSessionId: "<id>", phase: "ready", readiness: { gaps: [], ready: true }, recovery: { action: "none" }, routeGeneration: 1, sessionId: "<id>",
      sessionPresent: true, taskRecovery: { available: true }, waitingForUser: false, workers: { running: 0 } } });
    expect(answers[12], "home.context").toEqual({ error: null, ok: true, result: CONTEXT });
    expect((context.result.breakdown.sections as Array<{ id: string; count?: number }>).map(({ id, count }) => `${id}${count === undefined ? "" : `:${count}`}`),
      "the context sections").toEqual(["instructions", "profile:0", "memory:4", "chapter:0", "results:0", "input"]);

    const MODEL_REF = { id: "<id>", provider: LOCK_PROVIDER };
    const STATS = { assistantMessages: "<value>", cost: "<value>", toolCalls: "<value>", toolResults: "<value>", totalMessages: "<value>", userMessages: "<value>",
      tokens: { cacheRead: "<value>", cacheWrite: "<value>", input: "<value>", output: "<value>", total: "<value>" } };
    const snapshot = (transcriptTotal: number, extra: { warning?: string; latestCacheHitRate?: string }) => ({
      acceptsQueuedPrompts: false, automaticCompactionEnabled: false, availableThinkingLevels: ["off"], compactionQueued: false, configurationBlocker: null,
      compactionPolicy: { currentBudgets: { enabled: false, keepRecentTokens: 120, reserveTokens: 2048 }, extensionMayOverride: false, next: {
        effectiveThinkingLevel: "off", enabled: false, instructions: "", keepRecentTokens: 120, model: MODEL_REF, requestedThinkingLevel: "off", reserveTokens: 2048,
        source: { enabled: "global", instructions: "global", keepRecentTokens: "global", reserveTokens: "global", thinkingLevel: "global" }, thinkingLevel: "inherit" } },
      contextUsage: { contextWindow: "<value>", percent: "<value>", tokens: "<value>" },
      contextWindowPolicy: { default: 128000, effective: 128000, maximum: 128000, minimum: 3192, model: MODEL_REF, override: 128000, source: "session",
        ...(extra.warning === undefined ? {} : { warning: extra.warning }) },
      cwd: "<tmp>/tron/gateway/home/workspace", diagnostics: [], eventSequence: "<n>", extensionActivityAsOf: "<timestamp>",
      extensionPresentation: { hostEpoch: "<id>", pendingInteractions: [], revision: "<n>", surfaces: [], version: 3,
        capabilities: ["semantic.dialogs", "tron.form.v1", "semantic.notifications", "semantic.status", "semantic.working", "semantic.hidden-thinking-label",
          "semantic.string-widgets", "semantic.title", "semantic.revisioned-editor", "semantic.tools-expanded", "surfaces.full-frame"],
        diagnostics: [
          { code: "remote-components.enabled", message: "Retained string widgets and bounded read-only component frames are presented through the general extension-content sheet; blocking custom and overlay UI remain deferred." },
          { code: "remote-components.overlay-deferred", message: "Overlay and interactive component UI remain deferred until native rendering and input leases are available." },
          { code: "theme.baseline-only", message: "Per-session process-global Pi theme synchronization is unavailable through the pinned public API." },
        ],
        semanticState: { editorRevision: 0, editorText: "", statusOwners: {}, statuses: {}, toolsExpanded: false, widgets: [],
          working: { indicator: { frames: [], kind: "default" }, visible: true } } },
      leafEntryId: "<id>", liveActivityRevision: 0, model: MODEL_REF, name: "Home", phase: "idle",
      processOverview: { activeCount: 0, asOf: "<timestamp>", problemCount: 0, recentCount: 0, revision: "<n>", version: 1, visibility: "hidden" },
      queueRevision: 0, queuedItems: [], revision: "<n>", runtimeGeneration: "<id>", sessionId: "<id>",
      stats: extra.latestCacheHitRate === undefined ? STATS : { ...STATS, latestCacheHitRate: extra.latestCacheHitRate },
      thinkingLevel: "off", toolExecutions: [], transcriptStart: 0, transcriptTotal });
    const { transcript: openedRows, ...openedSession } = answers[5].result.session;
    expect({ ...answers[5], result: { ...answers[5].result, session: openedSession } }, "the new chapter's first runtime, before any message is saved").toEqual({ error: null, ok: true,
      result: { completionRevision: 0, subscriptionToken: "<id>", syncToken: "<id>", session: snapshot(3, { warning: "This new session and its context override are not yet saved to disk; they persist after the first user or assistant message." }) } });
    const { transcript: reopenedRows, ...reopenedSession } = answers[14].result.session;
    expect({ ...answers[14], result: { ...answers[14].result, session: reopenedSession } }, "the settled chapter a second device reopens: both activations completed").toEqual({ error: null, ok: true,
      result: { completionRevision: 2, subscriptionToken: "<id>", syncToken: "<id>", session: snapshot(9, { latestCacheHitRate: "<value>" }) } });
    expect(answers[13].ok, JSON.stringify(answers[13])).toBe(true);
    const { items: transcriptRows, ...transcriptPage } = answers[13].result;
    expect(transcriptPage, "the transcript page").toEqual({ end: 9, leafEntryId: "<id>", runtimeGeneration: "<id>", start: 0, total: 9 });
    const row = (item: any) => [item.kind === "message" ? item.role : item.kind, item.semantic.kind, item.semantic.direction, item.semantic.contextEffect,
      item.semantic.lifecycle ?? "", `${item.semantic.origin.kind}${item.semantic.origin.ownerId === undefined ? "" : `:${item.semantic.origin.ownerId}`}`,
      ...(item.content ?? []).map((part: any) => part.type === "toolCall" ? `${part.name}(${JSON.stringify(part.arguments)})` : part.text)].join(" | ");
    const RESULT_NOTICE = "Home task: Summarize notes.txt in the lock project. | outcome: final | subagents: 0 started, 0 stopped at end | duration: <duration>\n\nThe notes say: lock notes.\n\nEvidence:\n- read notes.txt";
    const ADMITTED = `Task admitted; a report is required for its result.\nWorker: ${MODEL} (same as Home), thinking off.`;
    const DELEGATE_ARGUMENTS = { intent: "Summarize notes.txt in the lock project.", target: "<tmp>/workspace", taskId: TASK_ID, title: "Lock task" };
    const STATUS = "status | ambientStatus | none |  | gateway";
    const SETTLED_ROWS = [`modelChange | ${STATUS}`, `thinkingChange | ${STATUS}`, `modelChange | ${STATUS}`,
      "user | resourcePrompt | inboundContext | modelInput | completed | user | Delegate the lock work.",
      `assistant | prompt | agentOutput | modelInput |  | assistant | delegate(${JSON.stringify(DELEGATE_ARGUMENTS)})`,
      `toolResult | tool | agentInvocation | toolResult |  | assistant | ${ADMITTED}`,
      "assistant | prompt | agentOutput | modelInput |  | assistant | Delegated the lock task.",
      `customMessage | message | inboundContext | modelInput |  | extension:${TASK_ID} | ${RESULT_NOTICE}`,
      "assistant | prompt | agentOutput | modelInput |  | assistant | The lock task reported: lock notes."];
    expect(transcriptRows.map(row), "the transcript after the wake").toEqual(SETTLED_ROWS);
    expect(reopenedRows, "the reopened chapter shows the same items").toEqual(transcriptRows);
    expect(openedRows, "the first runtime showed the chapter's first three items").toEqual(transcriptRows.slice(0, 3));
    const RESULT_DETAILS = { eventId: EVENT_ID, operationId: "<id>", resultRef: REPORT_REF, routeGeneration: 1, taskId: TASK_ID, taskTitle: "Lock task", terminalEvidence: TERMINAL };
    const notice = transcriptRows.find((item: any) => item.kind === "customMessage");
    expect({ customType: notice.customType, details: notice.details, origin: notice.semantic.origin, contextEffect: notice.semantic.contextEffect },
      "the result notice is the task's model input, attributed to the task").toEqual({ customType: "tron.home-task-result.v1", details: RESULT_DETAILS,
      origin: { confidence: "receipt", kind: "extension", ownerId: TASK_ID, title: "Home task" }, contextEffect: "modelInput" });

    expect(stable(recorded.events.filter((event) => !SNAPSHOT_STATED_TOPICS.has((event as { topic: string }).topic))),
      "the events the outbound queue never drops (topics and payload paths)").toEqual([
      { topic: "session.diagnostic", paths: [":object", "data.code:string", "data.followUpMode:string", "data.imagesBlocked:boolean", "data.retry.baseDelayMs:number",
        "data.retry.enabled:boolean", "data.retry.maxAgentDelayMs:number", "data.retry.maxRetries:number", "data.retry:object", "data.steeringMode:string",
        "data.transport:string", "data:object", "eventSequence:number", "revision:number", "runtimeGeneration:string"] },
      { topic: "session.listChanged", paths: [":object"] },
      { topic: "settings.changed", paths: [":object", "changeIds:array", "changeIds[]:string", "keys:array", "keys[]:string", "layer:string", "target.kind:string",
        "target.sessionId:string", "target:object"] },
    ]);

    expect(callers.filter((caller) => caller !== "worker"), "Home's activations' requests").toEqual(["home-input", "home-delegated", "home-wake"]);
    expect(callers.filter((caller) => caller === "worker"), "the worker reports in one request").toEqual(["worker"]);
    expect(homeHeadings, "every Home request carries Home's prompt and the learned profile").toEqual([
      ["home-input", ["## Tron Home", "## Learned profile"]], ["home-delegated", ["## Tron Home", "## Learned profile"]], ["home-wake", ["## Tron Home", "## Learned profile"]]]);
    const OPTIONS = { headers: {}, identity: { attribution: { categories: ["cli-agent"], name: "pi", url: "https://pi.dev" }, userAgent: "detailed", version: "1.5.1" },
      maxRetryDelayMs: 60000, sessionId: "<id>", timeoutMs: 300000, toolExecution: "parallel", transport: "auto",
      model: { api: "<api>", baseUrl: "http://localhost:0", contextWindow: 128000, cost: { cacheRead: "<value>", cacheWrite: "<value>", input: "<value>", output: "<value>" },
        id: "<id>", input: ["text", "image"], maxTokens: 16384, name: "Faux Model", provider: LOCK_PROVIDER, reasoning: false } };
    expect(requestOptions.filter(({ caller }) => caller !== "worker").concat(requestOptions.filter(({ caller }) => caller === "worker")).map(({ caller, options }) => [caller, normalizeTraceValue(options as TraceValue, gateway.normalization)]),
      "stream options, Home's then the worker's: Home keeps long cache retention, the worker the default").toEqual([
      ["home-input", { ...OPTIONS, cacheRetention: "long" }], ["home-delegated", { ...OPTIONS, cacheRetention: "long" }],
      ["home-wake", { ...OPTIONS, cacheRetention: "long" }], ["worker", OPTIONS]]);

    const homeSessionJsonl = stable(await gateway.canonical(homeSessionId)) as any[];
    const workerSessionJsonl = stable(await gateway.canonical(workerSessionId)) as any[];
    const kind = (entry: any) => [entry.type, entry.customType ?? entry.message?.role ?? ""].join(" ").trim();
    expect(homeSessionJsonl.map(kind), "Home's chapter entries").toEqual(["session", "model_change", "thinking_level_change", "custom tron.context-window.v1",
      "custom tron.settings.v1", "custom tron.settings.v1", "model_change", "custom tron.settings.v1", "custom tron.chat-invocation.v1", "custom tron.chat-invocation.v1",
      "message system", "message user", "custom tron.chat-invocation.v1", "message assistant", "message toolResult", "message assistant", "custom tron.chat-invocation.v1",
      "custom tron.chat-invocation.v1", "custom_message tron.home-task-result.v1", "custom tron.chat-invocation.v1", "custom tron.chat-invocation.v1",
      "custom tron.context-delivery.v4", "message assistant", "custom tron.chat-invocation.v1"]);
    expect(workerSessionJsonl.map(kind), "the worker's entries").toEqual(["session", "model_change", "thinking_level_change", "custom tron.context-window.v1",
      "custom tron.settings.v1", "custom tron.settings.v1", "session_info", "custom tron.settings.v1", "model_change", "custom tron.settings.v1", "custom tron.settings.v1",
      "custom tron-home-task", "custom tron.chat-invocation.v1", "custom tron.chat-invocation.v1", "message system", "message user", "custom tron.chat-invocation.v1",
      "message assistant", "custom tron-home-task-report", "message toolResult", "custom tron.chat-invocation.v1"]);
    expect(homeSessionJsonl[0], "Home's chapter runs in Home's workspace").toMatchObject({ type: "session", cwd: "<tmp>/tron/gateway/home/workspace" });
    expect(workerSessionJsonl[0], "the worker runs in the task's target").toMatchObject({ type: "session", cwd: "<tmp>/workspace" });
    expect(workerSessionJsonl.find((entry) => entry.type === "session_info")?.name, "the worker session is named for the task").toBe("Lock task");
    const receipt = (entry: any) => entry.customType !== "tron.chat-invocation.v1" ? [] : [[entry.data.receiptKind, entry.data.lifecycle ?? "", entry.data.source,
      entry.data.origin === undefined ? "" : `${entry.data.origin.kind}${entry.data.origin.ownerId === undefined ? "" : `:${entry.data.origin.ownerId}/${entry.data.origin.title}`}`].join(" ")];
    expect(homeSessionJsonl.flatMap(receipt), "Home's invocation receipts: the user's prompt, then the Gateway's wake owned by Home").toEqual([
      "start staged plain user", "transition accepted plain ", "binding  plain ", "terminal completed plain user",
      "start staged homeWake gateway:home/Home", "transition accepted homeWake ", "binding  homeWake ", "terminal completed homeWake gateway:home/Home"]);
    expect(workerSessionJsonl.flatMap(receipt), "the worker's invocation receipts, owned by the task").toEqual([
      "start staged plain gateway:lock-task/Home task", "transition accepted plain ", "binding  plain ", "terminal completed plain gateway:lock-task/Home task"]);
    const message = (entry: any) => {
      if (entry.type !== "message" || entry.message.role === "system") return [];
      const { timestamp: _timestamp, usage: _usage, api: _api, durationMs: _durationMs, ...rest } = entry.message;
      return [rest];
    };
    const ASSISTANT = { model: "faux-1", provider: LOCK_PROVIDER, role: "assistant", thinkingLevel: "off" };
    expect(homeSessionJsonl.flatMap(message), "Home's persisted messages").toEqual([
      { content: [{ text: "Delegate the lock work.", type: "text" }], role: "user" },
      { ...ASSISTANT, stopReason: "toolUse", content: [{ arguments: DELEGATE_ARGUMENTS, id: "<id>", name: "delegate", type: "toolCall" }] },
      { content: [{ text: ADMITTED, type: "text" }], isError: false, role: "toolResult", toolCallId: "<id>", toolName: "delegate",
        details: { operationId: "<id>", sessionId: "<id>", taskId: TASK_ID, worker: { model: MODEL, modelSource: "same as Home", thinking: "off", thinkingSource: "same as Home" } } },
      { ...ASSISTANT, stopReason: "stop", content: [{ text: "Delegated the lock task.", type: "text" }] },
      { ...ASSISTANT, stopReason: "stop", content: [{ text: "The lock task reported: lock notes.", type: "text" }] },
    ]);
    const WORKER_PROMPT = `${INTENT}\n\nWorker at start: ${MODEL}; thinking off.\n\n${WORKER_MARKER} Send a short checkin at milestones and about every 30 minutes `
      + "(step, done, next; optional blocker/refs). It does not pause or finish work. Use needsAttention only for blockers needing Home; it is rate-limited. "
      + "Use report with explicit evidence to finish. A normal reply is not a task result.";
    const REPORT = { evidence: ["read notes.txt"], outcome: "final", resultId: "lock-result", text: "The notes say: lock notes." };
    expect(workerSessionJsonl.flatMap(message), "the worker's persisted messages").toEqual([
      { content: [{ text: WORKER_PROMPT, type: "text" }], role: "user" },
      { ...ASSISTANT, stopReason: "toolUse", content: [{ arguments: REPORT, id: "<id>", name: "report", type: "toolCall" }] },
      { content: [{ text: "Task report sealed.", type: "text" }], details: { entryId: "<entry>" }, isError: false, role: "toolResult", toolCallId: "<id>", toolName: "report" },
    ]);
    const custom = (jsonl: any[], customType: string) => jsonl.filter((entry) => entry.customType === customType)
      .map(({ id: _id, parentId: _parentId, timestamp: _timestamp, ...rest }) => rest);
    expect(custom(homeSessionJsonl, "tron.home-task-result.v1"), "the wake delivers the result notice once, displayed").toEqual([
      { type: "custom_message", customType: "tron.home-task-result.v1", content: RESULT_NOTICE, details: RESULT_DETAILS, display: true }]);
    expect(custom(homeSessionJsonl, "tron.context-delivery.v4"), "the notice's delivery is attributed to the Home task").toEqual([{ type: "custom",
      customType: "tron.context-delivery.v4", data: { delivery: "stored", origin: { owner: { id: "<id>", source: "gateway:home-task", title: "Home task" }, source: "gateway:home-task" },
        source: "extension", targetEntryId: "<entry>", version: 4, writer: "gateway" } }]);
    expect(custom(workerSessionJsonl, "tron-home-task"), "the worker's task binding").toEqual([{ type: "custom", customType: "tron-home-task",
      data: { generation: 1, homeId: "<id>", operationId: "<id>", receiptId: "<id>", sessionId: "<id>", taskId: TASK_ID, version: 1 } }]);
    expect(custom(workerSessionJsonl, "tron-home-task-report"), "the accepted report").toEqual([{ type: "custom", customType: "tron-home-task-report",
      data: { ...REPORT, acceptedAt: "<timestamp>", generation: 1, homeId: "<id>", operationId: "<id>", receiptId: "<id>", sessionId: "<id>", taskId: TASK_ID, version: 1 } }]);
    const provenance = (jsonl: any[]) => custom(jsonl, "tron.settings.v1").map(({ data }) => {
      expect(data.settings, "no session-stored settings").toEqual({});
      return [...Object.entries(data.fixed).map(([key, value]: [string, any]) => `${key}<-${value.from}${value.via === undefined ? "" : `/${value.via}`}`),
        ...Object.keys(data.requestPins).map((key) => `pin:${key}`)].join(" ");
    });
    const GLOBAL_FIXED = "context.images.autoResize<-global model.contextWindow<-global";
    expect(provenance(homeSessionJsonl), "Home's settings: global, then the image pin, then Home's own model").toEqual([
      `${GLOBAL_FIXED} model.ref[role=chat]<-global model.thinking[role=chat]<-global tools.active<-global`,
      `${GLOBAL_FIXED} model.ref[role=chat]<-global model.thinking[role=chat]<-global tools.active<-global pin:context.images.block`,
      `${GLOBAL_FIXED} model.ref[role=chat]<-session model.thinking[role=chat]<-global tools.active<-global pin:context.images.block`]);
    const LAUNCH = "model.queue[role=subagent]<-delegate/home-profile model.queue[role=worker]<-delegate/home-profile";
    expect(provenance(workerSessionJsonl), "the worker's settings: resolved at launch from the Home profile, model and thinking same as Home").toEqual([
      `${GLOBAL_FIXED} model.ref[role=chat]<-global model.thinking[role=chat]<-global tools.active<-global`,
      `${GLOBAL_FIXED} model.ref[role=chat]<-global model.thinking[role=chat]<-global tools.active<-global pin:context.images.block`,
      `${GLOBAL_FIXED} ${LAUNCH} model.ref[role=chat]<-global model.thinking[role=chat]<-global tools.active<-global pin:context.images.block`,
      `${GLOBAL_FIXED} ${LAUNCH} model.ref[role=chat]<-delegate/home-profile:sameAs:home model.thinking[role=chat]<-global tools.active<-global pin:context.images.block`,
      `${GLOBAL_FIXED} ${LAUNCH} model.ref[role=chat]<-delegate/home-profile:sameAs:home model.thinking[role=chat]<-delegate/home-profile:sameAs:home tools.active<-global pin:context.images.block`]);
    const values = (jsonl: any[]) => {
      const { data } = custom(jsonl, "tron.settings.v1").at(-1)!;
      return { fixed: Object.fromEntries(Object.entries(data.fixed).map(([key, { at: _at, ref: _ref, from: _from, via: _via, ...rest }]: [string, any]) => [key, rest])),
        requestPins: Object.fromEntries(Object.entries(data.requestPins).map(([key, entry]: [string, any]) => [key, entry.value])) };
    };
    const FIXED = { "context.images.autoResize": { value: true }, "model.contextWindow": { qualifiers: { model: MODEL }, value: 128000 } };
    const HOME_TOOLS = ["ask_user", "display", "notify", "zoom", "date", "memory_search", "delegate", "task", "profile", "obligation", "web_search", "session_search",
      "session_read", "settings", "projects", "read", "write", "edit", "bash", "grep", "find", "ls"];
    const WORKER_TOOLS = ["read", "bash", "edit", "write", "jev", "web_search", "settings", "projects", "ask_user", "display", "swift_app", "computer", "notify", "checkin", "report"];
    expect(values(homeSessionJsonl), "Home's resolved settings").toEqual({ requestPins: { "context.images.block": false }, fixed: { ...FIXED,
      "model.ref[role=chat]": { qualifiers: { role: "chat" }, value: MODEL_REF },
      "model.thinking[role=chat]": { qualifiers: { model: MODEL, role: "chat" }, value: "off" }, "tools.active": { value: HOME_TOOLS } } });
    const RESOLVED = "Resolved at task launch; later Home profile changes do not retarget this worker";
    expect(values(workerSessionJsonl), "the worker's resolved settings").toEqual({ requestPins: { "context.images.block": false }, fixed: { ...FIXED,
      "model.queue[role=subagent]": { reason: RESOLVED, value: [] }, "model.queue[role=worker]": { reason: RESOLVED, value: [] },
      "model.ref[role=chat]": { reason: "same as Home", value: MODEL_REF }, "model.thinking[role=chat]": { reason: "same as Home", value: "off" },
      "tools.active": { value: WORKER_TOOLS } } });
    expect(custom(homeSessionJsonl, "tron.context-window.v1").concat(custom(workerSessionJsonl, "tron.context-window.v1")).map(({ data }) => data),
      "both sessions' context window").toEqual([1, 2].map(() => ({ contextWindow: 128000, modelId: "faux-1", provider: LOCK_PROVIDER, version: 1 })));

    const systemEntry = (jsonl: any[]) => jsonl.find((entry) => entry.message?.role === "system").message;
    const homeSystem = systemEntry(homeSessionJsonl);
    const workerSystem = systemEntry(workerSessionJsonl);
    const declared = (system: any) => system.toolsAdded.map(({ name, description, parameters }: any) => ({ name, description, parameters }));
    expect(stable(normalizeTraceValue(requestTools.home as TraceValue, gateway.normalization)), "Home's request tools are its persisted tools").toEqual(declared(homeSystem));
    expect(stable(normalizeTraceValue(requestTools.worker as TraceValue, gateway.normalization)), "the worker's request tools are its persisted tools").toEqual(declared(workerSystem));
    expect(homeSystem.toolsAdded.map((tool: any) => tool.name)).toEqual(HOME_TOOLS);
    expect(workerSystem.toolsAdded.map((tool: any) => tool.name)).toEqual(WORKER_TOOLS);

    expect(await Promise.all([homeSessionId, workerSessionId].map((sessionId) => loadedExtensions(gateway, sessionId))),
      "each runtime's extensions in load order: tools, handlers, commands").toEqual([HOME_EXTENSIONS, WORKER_EXTENSIONS]);

    const PUSH = { method: "POST", path: "/v3/notifications", envelope: { expiresAt: "<timestamp>", kind: "agent_alert", machineId: "lock-machine",
      message: "The agent finished responding.", notificationKind: "agent_finished", requestId: "<id>", sessionId: "<id>", title: "Home", version: 1 } };
    expect(normalizeTraceValue(relayRequests as unknown as TraceValue, gateway.normalization), "each Home activation pushes finished; the worker pushes nothing").toEqual([PUSH, PUSH]);

    const homeRoot = join(gateway.tronHome, "gateway", "home");
    const taskFile = (await readdir(join(homeRoot, "tasks"))).find((name) => name.endsWith(`-${TASK_ID}.json`));
    expect(await gateway.tree(homeRoot), "the Home store's files").toEqual(["home.json", "profile.json", "tasks/<epoch>-lock-task.json", "tasks/authorization.json"]);
    expect(stable(await gateway.file(join(homeRoot, "home.json"))), "the designation: one active chapter whose activation started").toEqual({ bindingRevision: 1,
      chapters: [{ activationStarted: true, createdAt: "<timestamp>", ordinal: 1, sessionId: "<id>", state: "active" }], createdAt: "<timestamp>", enabled: true,
      generation: 1, homeId: "<id>", policyRevision: 3, routeGeneration: 1, updatedAt: "<timestamp>", version: 2 });
    expect(stable(await gateway.file(join(homeRoot, "tasks", taskFile!))), "the persisted task").toEqual(TASK);

    const requests = recorded.providerRequests as unknown as Array<{ messages: readonly TraceValue[] }>;
    const isWorker = (request: { messages: readonly TraceValue[] }) => JSON.stringify(request.messages).includes(WORKER_MARKER);
    const trace = stabilize({
      lock: LOCK,
      providerRequests: {
        home: requests.filter((request) => !isWorker(request)) as unknown as TraceValue[],
        worker: requests.filter(isWorker) as unknown as TraceValue[],
      },
      systemEntries: { home: homeSystem, worker: workerSystem },
    } satisfies HomeLockTrace as unknown as TraceValue) as unknown as HomeLockTrace;
    await compareWithGolden({ module: MODULE, ...lockPaths(import.meta.url, LOCK), trace, update: lockUpdateRequested(MODULE), validate: (actual) => {
      expect(actual.providerRequests.home).toHaveLength(3);
      expect(actual.providerRequests.worker).toHaveLength(1);
    } });
  }, 60_000);
});
