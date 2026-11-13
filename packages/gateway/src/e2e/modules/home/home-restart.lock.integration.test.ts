import { chmod, mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { GatewayLogger } from "../../../transport/logger.js";
import { fauxAssistantMessage, fauxToolCall, type SimpleStreamOptions, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../../../test-support/gateway-lock-harness.js";
import { compareWithGolden, lockPaths, lockUpdateRequested, normalizeTraceValue, type TraceValue } from "../../../../test-support/scenario-lock.js";
import { awaitsWithin, waitFor } from "../../../../test-support/wait-for.js";
import { homeOwnerOf } from "../../../../test-support/gateway-registry.js";

const MODULE = "gateway/e2e";
const NARROWED_ENTRY_TYPES = new Set(["tron.settings.v1", "tron.chat-invocation.v1", "tron.context-delivery.v4", "tron.home-task-result.v1"]);

function narrowed(entry: TraceValue): boolean {
  const record = entry as { type?: unknown; customType?: unknown; message?: { role?: unknown } };
  return (record.type === "message" && record.message?.role === "system")
    || ((record.type === "custom" || record.type === "custom_message") && NARROWED_ENTRY_TYPES.has(String(record.customType)));
}
const LOCK = "home-contention-restart";
const WORKER_MARKER = "This is a finite Home task.";
const TASK_ID = "lock-restart-task";
const owned: Array<() => Promise<void>> = [];
afterEach(async () => { for (const release of owned.splice(0).reverse()) await release(); });

const ENTRY_ID = /^[0-9a-f]{8}$/;
const SIZE_KEYS = new Set(["bytes", "currentBytes", "viewBytes", "effectiveTokens", "inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens", "tokens"]);
function stabilize(value: TraceValue, key = ""): TraceValue {
  if (typeof value === "string") {
    if (ENTRY_ID.test(value)) return "<entry>";
    return value.replace(/\| duration: \d+ms/g, "| duration: <duration>").replace(/^task-result-[0-9a-f]{64}$/, "task-result-<digest>")
;
  }
  if (typeof value === "number") return SIZE_KEYS.has(key) && value > 0 ? "<size>" : value;
  if (Array.isArray(value)) return value.map((item) => stabilize(item, key));
  if (value !== null && typeof value === "object") {
    if (key === "error" && (value as { code?: unknown }).code === "internal") return { ...value, message: "<internal error message>" };
    if (key === "episodic") return Object.fromEntries(Object.keys(value).map((name) => [name, "<memory>"]));
    if (key === "hostPressure") return Object.fromEntries(Object.keys(value).map((name) => [name, "<host>"]));
    return Object.fromEntries(Object.entries(value).map(([name, child]) => [name, stabilize(child, name)]));
  }
  return value;
}

function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  return Array.isArray(content) ? content.map((part) => (part as { text?: unknown }).text ?? "").join("") : "";
}

type Caller = "worker" | "home-input" | "home-delegated" | "home-second" | "home-followup" | "home-wake";

function callerOf(context: TranscriptContext): Caller {
  const messages = context.messages as Array<{ role: string; content?: unknown; toolName?: string }>;
  if (messages.some((message) => (message.role === "user" || message.role === "system") && textOf(message.content).includes(WORKER_MARKER))) return "worker";
  const last = messages.at(-1);
  if (last?.role === "toolResult" && last.toolName === "delegate") return "home-delegated";
  const text = last?.role === "user" ? textOf(last.content) : "";
  if (text.includes("Delegate the restart work")) return "home-input";
  if (text.includes("A second message while busy")) return "home-second";
  if (text.includes("Follow up after the activation")) return "home-followup";
  return "home-wake";
}

function untilAborted(options: SimpleStreamOptions | undefined): Promise<void> {
  return new Promise<void>((resolve) => {
    const signal = options?.signal;
    if (!signal || signal.aborted) { resolve(); return; }
    signal.addEventListener("abort", () => resolve(), { once: true });
  });
}

describe("gateway/home contention, publication and restart lock", () => {
  it("home-contention-restart: a busy activation's contenders, a failed ledger write, and task recovery after a restart", async () => {
    const callers: Array<{ phase: "first" | "restarted"; caller: Caller }> = [];
    let phase: "first" | "restarted" = "first";
    let releaseInput = (): void => {};
    const inputHeld = new Promise<void>((resolve) => { releaseInput = resolve; });
    let workerReached = (): void => {};
    const workerStarted = new Promise<void>((resolve) => { workerReached = resolve; });
    const route = async (context: TranscriptContext, options: SimpleStreamOptions | undefined) => {
      const caller = callerOf(context);
      callers.push({ phase, caller });
      switch (caller) {
        case "home-input":
          await inputHeld;
          return fauxAssistantMessage([fauxToolCall("delegate", { taskId: TASK_ID, intent: "Summarize notes.txt in the lock project.", target: first.cwd, title: "Restart task" }, { id: "lock-delegate" })], { stopReason: "toolUse" });
        case "home-delegated": return fauxAssistantMessage("Delegated the restart task.");
        case "home-second": return fauxAssistantMessage("Second message answered.");
        case "home-followup": return fauxAssistantMessage("Follow-up answered.");
        case "worker":
          workerReached();
          await untilAborted(options);
          return fauxAssistantMessage("Worker stopped with its Gateway.");
        case "home-wake": return fauxAssistantMessage("The restart task ended without a report.");
      }
    };
    const home = { memorySummarizer: () => async () => fauxAssistantMessage("Lock memory summary.") };
    const diagnosticRoot = await mkdtemp(join(tmpdir(), "tron-home-errors-"));
    owned.push(() => rm(diagnosticRoot, { recursive: true, force: true }));
    const diagnosticPath = join(diagnosticRoot, "gateway.jsonl");
    const first: LockGateway = await startLockGateway(LOCK, { home, logger: new GatewayLogger(diagnosticPath) });
    let firstDisposed = false;
    owned.push(async () => { if (!firstDisposed) await first.dispose(); });
    first.script(Array.from({ length: 8 }, () => route));
    const settings = JSON.parse(await readFile(join(first.agentDir, "settings.json"), "utf8")) as { defaultProvider: string; defaultModel: string };
    const model = { provider: settings.defaultProvider, id: settings.defaultModel };
    const homeRoot = join(first.tronHome, "state", "home");
    const ledger = () => first.file(join(homeRoot, "home.json"));

    const phone = await first.connect("phone", { clientRole: "mobile" });
    const command = (method: string, params: Record<string, unknown> = {}) => phone.request(method, { commandId: first.commandId(), ...params });
    expect((await command("home.designate", { model })).ok).toBe(true);
    expect((await command("settings.change", { target: { kind: "home" },
      changes: [{ key: "model.queue[role=background]", layer: "session", op: "set", value: [`${model.provider}/${model.id}`] }] })).ok).toBe(true);
    const opened = await phone.request("home.open", {});
    const homeSessionId = opened.result.sessionId as string;
    const session = await phone.request("session.open", { sessionId: homeSessionId });
    expect((await phone.request("session.sync", { sessionId: homeSessionId, syncToken: session.result.syncToken })).ok).toBe(true);

    const admitted = await command("home.prompt", { text: "Delegate the restart work." });
    expect(admitted.ok, JSON.stringify(admitted)).toBe(true);
    await waitFor(() => callers.some((entry) => entry.caller === "home-input"), "the held Home activation");
    const second = await command("home.prompt", { text: "A second message while busy." });
    const followUp = await command("home.prompt", { text: "Follow up after the activation.", behavior: "followUp" });
    const disableWhileBusy = await command("home.disable");
    releaseInput();
    await awaitsWithin(workerStarted, "the task worker's first request");
    await waitFor(() => callers.some((entry) => entry.caller === "home-followup"), "the follow-up activation");
    await first.settled(homeSessionId);

    const ledgerBefore = await ledger();
    await chmod(homeRoot, 0o500);
    let pauseRefused: Awaited<ReturnType<typeof command>>;
    try { pauseRefused = await command("home.pauseMemory"); } finally { await chmod(homeRoot, 0o700); }
    expect(pauseRefused).toMatchObject({ ok: false, error: { code: "internal", message: "Unexpected gateway failure", retryable: false } });
    expect(JSON.stringify(pauseRefused)).not.toContain(homeRoot);
    const diagnostic = (await readFile(diagnosticPath, "utf8")).trim().split("\n").map(line => JSON.parse(line))
      .find(record => record.event === "rpc.error" && record.method === "home.pauseMemory");
    expect(diagnostic).toMatchObject({ level: "error", code: "exception", error: { code: "EACCES" } });
    expect(diagnostic.error.message).toContain(homeRoot);
    expect(diagnostic.error.stack).toContain("EACCES");
    const ledgerAfterRefusal = await ledger();
    const statusAfterRefusal = await phone.request("home.status", {});
    const paused = await command("home.pauseMemory");
    const resumed = await command("home.resumeMemory");
    const taskBeforeRestart = await phone.request("home.taskStatus", { taskId: TASK_ID });

    const firstRecord = first.record();
    firstDisposed = true;
    await first.dispose({ keepRoot: true });
    const taskName = (await readdir(join(homeRoot, "tasks"))).find((name) => name.endsWith(`-${TASK_ID}.json`));
    const taskAtRestart = taskName ? await first.file(join(homeRoot, "tasks", taskName)) as { lifecycle?: string } | null : null;
    phase = "restarted";
    const restarted = await startLockGateway(LOCK, { home, root: first.root });
    owned.push(() => restarted.dispose());
    restarted.script(Array.from({ length: 8 }, () => route));
    const mac = await restarted.connect("mac");
    const owner = homeOwnerOf(restarted.registry);
    await waitFor(async () => (await owner.taskResult(TASK_ID)).wake?.state === "acknowledged", "the recovered result's wake to be acknowledged");
    await waitFor(() => callers.some((entry) => entry.phase === "restarted" && entry.caller === "home-wake"), "the recovered result's wake activation");
    await restarted.settled(homeSessionId);
    const taskAfterRestart = await mac.request("home.taskStatus", { taskId: TASK_ID });
    const statusAfterRestart = await mac.request("home.status", {});
    const reopened = await mac.request("home.open", {});
    const reopenedSession = await mac.request("session.open", { sessionId: homeSessionId });
    expect(reopenedSession.ok, JSON.stringify(reopenedSession)).toBe(true);
    const transcript = await mac.request("session.transcript", { sessionId: homeSessionId });
    const restartedRecord = restarted.record();
    const taskFile = (await readdir(join(homeRoot, "tasks"))).find((name) => name.endsWith(`-${TASK_ID}.json`));

    const isWorker = (request: { tools: readonly string[] }) => request.tools.includes("report");
    const messages = (requests: ReadonlyArray<{ messages: readonly TraceValue[]; tools: readonly string[] }>, worker: boolean) =>
      requests.filter((request) => isWorker(request) === worker).map((request) => request.messages) as unknown as TraceValue[];
    const trace = stabilize(normalizeTraceValue({
      lock: LOCK,
      callers: {
        home: callers.filter((entry) => entry.caller !== "worker").map((entry) => `${entry.phase}:${entry.caller}`),
        worker: callers.filter((entry) => entry.caller === "worker").map((entry) => entry.phase),
      },
      first: { exchanges: firstRecord.exchanges, homeRequests: messages(firstRecord.providerRequests, false) },
      restarted: { exchanges: restartedRecord.exchanges, homeRequests: messages(restartedRecord.providerRequests, false) },
      publication: { ledgerUnchanged: JSON.stringify(ledgerAfterRefusal) === JSON.stringify(ledgerBefore), ledger: await restarted.file(join(homeRoot, "home.json")) },
      canonicalJsonl: { home: await restarted.canonical(homeSessionId) },
      task: { atRestart: taskAtRestart as TraceValue, recovered: taskFile ? await restarted.file(join(homeRoot, "tasks", taskFile)) : null },
    } as unknown as TraceValue, restarted.normalization));
    const homeEntries = (trace as unknown as { canonicalJsonl: { home: TraceValue[] } }).canonicalJsonl.home;
    const kept = homeEntries.filter(narrowed);
    let placeholder = 0;
    const inline = homeEntries.map((entry) => narrowed(entry) ? { narrowedGolden: placeholder++ } : entry);
    await compareWithGolden({
      module: MODULE, ...lockPaths(import.meta.url, LOCK), trace: { lock: LOCK, canonicalJsonl: { home: kept } },
      inlineTrace: { ...(trace as unknown as Record<string, unknown>), canonicalJsonl: { home: inline } } as TraceValue,
      update: lockUpdateRequested(MODULE),
      validate: () => {
        expect(second.ok || second.error).toBeTruthy();
        expect(followUp.ok, JSON.stringify(followUp)).toBe(true);
        expect(disableWhileBusy.ok).toBe(false);
        expect(pauseRefused!.ok).toBe(false);
        expect(JSON.stringify(ledgerAfterRefusal)).toBe(JSON.stringify(ledgerBefore));
        expect(statusAfterRefusal.ok).toBe(true);
        expect(paused.ok, JSON.stringify(paused)).toBe(true);
        expect(resumed.ok, JSON.stringify(resumed)).toBe(true);
        expect(taskBeforeRestart.result.lifecycle).not.toBe("terminal");
        expect(taskAtRestart?.lifecycle).toBe("active");
        expect(JSON.stringify(trace)).toContain("cold-no-report");
        expect(taskAfterRestart.result.lifecycle).toBe("terminal");
        expect(statusAfterRestart.ok).toBe(true);
        expect(reopened.result.sessionId).toBe(homeSessionId);
        expect(transcript.ok).toBe(true);
        expect(JSON.stringify(trace)).toContain("tron.home-task-result.v1");
      },
    });
  }, 120_000);
});
