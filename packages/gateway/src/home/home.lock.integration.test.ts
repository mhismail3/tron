import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall, getCurrentSystemPrompt, getCurrentTools, type SimpleStreamOptions, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { compareWithGolden, hashPromptText, lockPaths, lockUpdateRequested, normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { waitFor } from "../../test-support/wait-for.js";
import { NotificationGrantStore } from "../notifications/grant-store.js";
import { NotificationService } from "../notifications/notification-service.js";
import { PushRelayClient } from "../notifications/relay-client.js";

/**
 * `gateway/home` scenario lock (restructure E0a, docs/restructure/k0-kernel.md §7):
 * the Home behavior kernel extraction E1-E7 must keep. Through the real Gateway
 * (`gateway-lock-harness.ts`, Home wired as gateway-main wires it) the phone
 * designates Home, sets its memory queue, opens the new chapter (its first
 * runtime) and sends one activation that delegates a task; the worker reports,
 * and the result wakes Home into a second activation.
 *
 * The trace records the client's request/response values (a second device's
 * reopen snapshot of the settled chapter among them), the payload structure of
 * every event topic the outbound queue never drops, each provider request split
 * into Home's and the worker's (tools in order, prompt sections and hash,
 * messages, stream options; Home's own `## ` headings), each runtime's tool
 * schema digests and loaded extensions (paths, tools, handlers, commands, in
 * load order), the `home.context` section names, every push at the relay
 * boundary (the production push owner, as in the push lock), both canonical
 * JSONL files and the Home store's files. Home's and the worker's requests
 * interleave by host timing, so each stream keeps its own order; everything
 * else is ordered by the scenario.
 */

const MODULE = "gateway/home";
const LOCK = "home-activation-wake";
const WORKER_MARKER = "This is a finite Home task.";
const TASK_ID = "lock-task";
const RELAY_ORIGIN = "https://relay.lock.invalid";
const owned: Array<() => Promise<void>> = [];
afterEach(async () => { for (const release of owned.splice(0).reverse()) await release(); });

interface HomeLockTrace {
  readonly lock: string;
  readonly exchanges: readonly TraceValue[];
  readonly events: readonly TraceValue[];
  readonly providerRequests: { readonly home: readonly TraceValue[]; readonly worker: readonly TraceValue[] };
  readonly contextSections: TraceValue;
  readonly homePrompts: readonly TraceValue[];
  readonly requestOptions: readonly TraceValue[];
  readonly toolSchemas: { readonly home: TraceValue; readonly worker: TraceValue };
  readonly extensions: { readonly home: TraceValue; readonly worker: TraceValue };
  readonly canonicalJsonl: { readonly home: readonly TraceValue[]; readonly worker: readonly TraceValue[] };
  readonly pushes: readonly TraceValue[];
  readonly homeStore: { readonly files: readonly string[]; readonly designation: TraceValue; readonly task: TraceValue };
}

/**
 * Topics a newer snapshot re-states, which the outbound queue may drop while a
 * socket lags (`SNAPSHOT_STATED_TOPICS`, transport/ordered-outbound-queue.ts):
 * which of them a client receives is host timing. Their state is recorded by the
 * settled reopen snapshot and the transcript instead.
 */
const SNAPSHOT_STATED_TOPICS = new Set(["session.snapshot", "session.rebaseline", "session.progress", "session.configuration",
  "session.toolProgress", "session.processActivity", "session.extensionActivity", "session.compaction"]);
/** Sizes that include the result notice's measured duration, and token counts the
 * faux provider derives from text holding the host's temp and checkout paths. */
const SIZE_KEYS = new Set(["bytes", "currentBytes", "viewBytes", "effectiveTokens", "inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens", "tokens"]);
/** Pi's 8-hex entry ids, which every reference to a canonical entry repeats. */
const ENTRY_ID = /^[0-9a-f]{8}$/;
/**
 * Home's per-run values the shared normalization does not cover: entry ids under
 * Home's own keys (`entryId`, `activationStartEntryId`, …), the host's load in
 * `hostPressure` (structure only), byte and token counts (zero or not), which
 * move with the result notice's measured duration and the host's paths, and that
 * duration itself.
 */
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

/** Each loaded extension of a live runtime, in load order: its tools, event
 * handlers (with their count) and commands. This is the profile a slot was
 * built with (k0-kernel.md §8 B1), which no request carries. */
async function loadedExtensions(gateway: LockGateway, sessionId: string): Promise<TraceValue> {
  const slot = await gateway.registry.acquire(sessionId) as unknown as { runtime: { session: { resourceLoader: { getExtensions(): { extensions: Array<{
    path: string; tools: Map<string, unknown>; handlers: Map<string, unknown[]>; commands: Map<string, unknown>;
  }> } } } } };
  return normalizeTraceValue(slot.runtime.session.resourceLoader.getExtensions().extensions.map((extension) => ({
    path: extension.path,
    tools: [...extension.tools.keys()],
    handlers: [...extension.handlers].map(([event, handlers]) => `${event}×${handlers.length}`),
    commands: [...extension.commands.keys()],
  })), gateway.normalization);
}

function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  return Array.isArray(content) ? content.map((part) => (part as { text?: unknown }).text ?? "").join("") : "";
}

/** Faux serves one queue to every runtime, so each step decides its caller from its context. */
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
    // The production push owner, as in the push lock: only the relay's HTTP fetcher is replaced.
    const relayRequests: Array<{ method: string; path: string; envelope: unknown }> = [];
    let notifications!: NotificationService;
    let gateway!: LockGateway;
    gateway = await startLockGateway(LOCK, {
      home: { memorySummarizer: () => async () => fauxAssistantMessage("Lock memory summary.") },
      notifications: async (tronHome) => {
        const relay = new PushRelayClient(RELAY_ORIGIN, async (url, init) => {
          relayRequests.push({ method: String(init.method), path: new URL(url).pathname, envelope: init.body ? JSON.parse(String(init.body)) : null });
          return new Response(JSON.stringify({ status: "accepted_by_apns" }), { status: 200 }) as never;
        });
        notifications = new NotificationService(new NotificationGrantStore(tronHome), relay, Date.now, () => {}, () => {}, () => {},
          (sessionId) => gateway?.registry.homeOwner().chapterStateFor(sessionId).homeId !== undefined);
        await notifications.initialize();
        return notifications;
      },
    });
    owned.push(() => gateway.dispose());
    owned.push(async () => notifications.dispose());
    const settings = JSON.parse(await readFile(join(gateway.agentDir, "settings.json"), "utf8")) as { defaultProvider: string; defaultModel: string };
    const model = { provider: settings.defaultProvider, id: settings.defaultModel };

    // The worker reports only after Home's delegating activation settles, so the
    // wake is a separate activation rather than a delivery into the running one.
    let releaseWorker = (): void => {};
    const workerReleased = new Promise<void>((resolve) => { releaseWorker = resolve; });
    const callers: Caller[] = [];
    const homePrompts: Array<{ caller: Caller; headings: string[]; promptHash: string }> = [];
    // Model-visible tool text: each tool's description and parameter schema, as the first request of each runtime sent them.
    const toolSchemas: { home?: TraceValue; worker?: TraceValue } = {};
    // The stream options each request reached the provider with (cache retention, reasoning, …), minus callbacks and signals.
    const requestOptions: Array<{ caller: Caller; options: Record<string, unknown> }> = [];
    const route = async (context: TranscriptContext, options: SimpleStreamOptions | undefined) => {
      const caller = callerOf(context);
      callers.push(caller);
      requestOptions.push({ caller, options: Object.fromEntries(Object.entries(options ?? {})
        .filter(([, value]) => typeof value !== "function" && !(value instanceof AbortSignal))) });
      const runtime = caller === "worker" ? "worker" : "home";
      toolSchemas[runtime] ??= getCurrentTools(context.messages).map((tool) => ({
        name: tool.name, schema: hashPromptText(JSON.stringify({ description: tool.description, parameters: tool.parameters }), gateway.normalization),
      }));
      if (caller !== "worker") {
        const prompt = getCurrentSystemPrompt(context.messages);
        homePrompts.push({ caller, headings: [...prompt.matchAll(/^#{1,3} .+$/gm)].map((match) => match[0]), promptHash: hashPromptText(prompt, gateway.normalization) });
      }
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
      changes: [{ key: "model.queue[role=background]", layer: "profile", op: "set", value: [`${model.provider}/${model.id}`] }] });
    expect(queue.ok, JSON.stringify(queue)).toBe(true);
    const opened = await phone.request("home.open", {});
    expect(opened.ok, JSON.stringify(opened)).toBe(true);
    const homeSessionId = opened.result.sessionId as string;
    // The phone opens the chapter as iOS does: the new Home session's first runtime.
    const session = await phone.request("session.open", { sessionId: homeSessionId });
    expect(session.ok, JSON.stringify(session)).toBe(true);
    expect((await phone.request("session.sync", { sessionId: homeSessionId, syncToken: session.result.syncToken })).ok).toBe(true);
    expect((await phone.request("home.status", {})).ok).toBe(true);

    const admitted = await phone.request("home.prompt", { commandId: gateway.commandId(), text: "Delegate the lock work." });
    expect(admitted.ok, JSON.stringify(admitted)).toBe(true);
    await waitFor(() => callers.includes("home-delegated"), "Home's delegating activation to answer the admission");
    await gateway.settled(homeSessionId);
    releaseWorker();
    const owner = gateway.registry.homeOwner();
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

    // Each Home activation's end pushes "finished" (the phone does not present the chapter); the worker's end pushes nothing.
    await waitFor(() => relayRequests.length >= 2, "both Home activations' finished pushes to reach the relay");
    // A second device opens the settled chapter: the snapshot every dropped frame converges to.
    const reopen = await gateway.connect("reopen");
    const reopened = await reopen.request("session.open", { sessionId: homeSessionId });
    expect(reopened.ok, JSON.stringify(reopened)).toBe(true);

    const recorded = gateway.record();
    const requests = recorded.providerRequests as unknown as Array<{ promptSections: readonly string[]; messages: readonly TraceValue[] }>;
    const isWorker = (request: { messages: readonly TraceValue[] }) => JSON.stringify(request.messages).includes(WORKER_MARKER);
    const homeRoot = join(gateway.tronHome, "gateway", "home");
    const taskFile = (await readdir(join(homeRoot, "tasks"))).find((name) => name.endsWith(`-${TASK_ID}.json`));
    const trace = stabilize({
      lock: LOCK,
      exchanges: recorded.exchanges,
      events: recorded.events.filter((event) => !SNAPSHOT_STATED_TOPICS.has((event as { topic: string }).topic)),
      providerRequests: {
        home: requests.filter((request) => !isWorker(request)) as unknown as TraceValue[],
        worker: requests.filter(isWorker) as unknown as TraceValue[],
      },
      // The exchange normalizes section `id`s as identities; their names are the breakdown's contract.
      contextSections: normalizeTraceValue((context.result.breakdown.sections as Array<{ id: string; count?: number; tokens: number }>)
        .map(({ id, count, tokens }) => ({ name: id, ...(count === undefined ? {} : { count }), tokens })), gateway.normalization),
      homePrompts: homePrompts.map((prompt) => normalizeTraceValue(prompt, gateway.normalization)),
      requestOptions: requestOptions.filter((request) => request.caller !== "worker")
        .concat(requestOptions.filter((request) => request.caller === "worker"))
        .map((request) => normalizeTraceValue(request, gateway.normalization)),
      toolSchemas: { home: toolSchemas.home ?? null, worker: toolSchemas.worker ?? null },
      extensions: { home: await loadedExtensions(gateway, homeSessionId), worker: await loadedExtensions(gateway, workerSessionId) },
      canonicalJsonl: { home: await gateway.canonical(homeSessionId), worker: await gateway.canonical(workerSessionId) },
      pushes: normalizeTraceValue(relayRequests, gateway.normalization) as TraceValue[],
      homeStore: {
        files: await gateway.tree(homeRoot),
        designation: await gateway.file(join(homeRoot, "home.json")),
        task: taskFile ? await gateway.file(join(homeRoot, "tasks", taskFile)) : null,
      },
    } satisfies HomeLockTrace as unknown as TraceValue) as unknown as HomeLockTrace;
    await compareWithGolden({ module: MODULE, ...lockPaths(import.meta.url, LOCK), trace, update: lockUpdateRequested(MODULE), validate: (actual) => {
      expect(callers.filter((caller) => caller !== "worker")).toEqual(["home-input", "home-delegated", "home-wake"]);
      expect(actual.providerRequests.home).toHaveLength(3);
      expect(actual.providerRequests.worker.length).toBeGreaterThanOrEqual(1);
      expect(new Set(actual.homePrompts.map((prompt) => (prompt as { promptHash: string }).promptHash)).size).toBe(1);
      expect(JSON.stringify(actual.homePrompts)).toContain("## Tron Home");
      expect(JSON.stringify(actual.canonicalJsonl.home)).toContain("tron.home-task-result.v1");
      expect(JSON.stringify(actual.canonicalJsonl.worker)).toContain("lock-result");
      expect(actual.homeStore.task).not.toBeNull();
      expect(actual.pushes).toHaveLength(2);
    } });
  }, 60_000);
});
