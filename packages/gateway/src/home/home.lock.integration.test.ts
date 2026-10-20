import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall, getCurrentSystemPrompt, type TranscriptContext } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { compareWithGolden, hashPromptText, lockPaths, lockUpdateRequested, normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { waitFor } from "../../test-support/wait-for.js";

/**
 * `gateway/home` scenario lock (restructure E0a, docs/restructure/k0-kernel.md §7):
 * the Home behavior kernel extraction E1-E7 must keep. Through the real Gateway
 * (`gateway-lock-harness.ts`, Home wired as gateway-main wires it) the phone
 * designates Home, sets its memory queue, opens the new chapter (its first
 * runtime) and sends one activation that delegates a task; the worker reports,
 * and the result wakes Home into a second activation.
 *
 * The trace records the client's request/response values, every event topic's
 * payload structure, each provider request split into Home's and the worker's
 * (tools in order, prompt sections and hash, messages; Home's own `## ` headings),
 * both canonical JSONL files, the transcript and the Home store's files.
 * Home's and the worker's requests interleave by host timing, so each stream is
 * kept in its own order; everything else is ordered by the scenario.
 */

const MODULE = "gateway/home";
const LOCK = "home-activation-wake";
const WORKER_MARKER = "This is a finite Home task.";
const TASK_ID = "lock-task";
const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

interface HomeLockTrace {
  readonly lock: string;
  readonly exchanges: readonly TraceValue[];
  readonly events: readonly TraceValue[];
  readonly providerRequests: { readonly home: readonly TraceValue[]; readonly worker: readonly TraceValue[] };
  readonly homePrompts: readonly TraceValue[];
  readonly canonicalJsonl: { readonly home: readonly TraceValue[]; readonly worker: readonly TraceValue[] };
  readonly homeStore: { readonly files: readonly string[]; readonly designation: TraceValue; readonly task: TraceValue };
}

/** Pi's 8-hex entry ids, which every reference to a canonical entry repeats. */
const ENTRY_ID = /^[0-9a-f]{8}$/;
/**
 * Home's per-run values the shared normalization does not cover: entry ids under
 * Home's own keys (`entryId`, `activationStartEntryId`, …), the host's load in
 * `hostPressure` (structure only), a chapter's byte count (zero or not), which
 * moves with recorded durations, and the result notice's measured duration.
 */
function stabilize(value: TraceValue, key = ""): TraceValue {
  if (typeof value === "string") {
    if (ENTRY_ID.test(value)) return "<entry>";
    return value.replace(/\| duration: \d+ms/g, "| duration: <duration>");
  }
  if (typeof value === "number") return key === "currentBytes" && value > 0 ? "<bytes>" : value;
  if (Array.isArray(value)) return value.map((item) => stabilize(item, key));
  if (value !== null && typeof value === "object") {
    if (key === "hostPressure") return Object.fromEntries(Object.keys(value).map((name) => [name, "<host>"]));
    return Object.fromEntries(Object.entries(value).map(([name, child]) => [name, stabilize(child, name)]));
  }
  return value;
}

type Caller = "home-input" | "home-delegated" | "home-wake" | "worker";

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
    const gateway = await startLockGateway(LOCK, { home: { memorySummarizer: () => async () => fauxAssistantMessage("Lock memory summary.") } });
    gateways.push(gateway);
    const settings = JSON.parse(await readFile(join(gateway.agentDir, "settings.json"), "utf8")) as { defaultProvider: string; defaultModel: string };
    const model = { provider: settings.defaultProvider, id: settings.defaultModel };

    // The worker reports only after Home's delegating activation settles, so the
    // wake is a separate activation rather than a delivery into the running one.
    let releaseWorker = (): void => {};
    const workerReleased = new Promise<void>((resolve) => { releaseWorker = resolve; });
    const callers: Caller[] = [];
    const homePrompts: Array<{ caller: Caller; headings: string[]; promptHash: string }> = [];
    const route = async (context: TranscriptContext) => {
      const caller = callerOf(context);
      callers.push(caller);
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

    const phone = await gateway.connect("phone");
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
    expect((await phone.request("home.context", {})).ok).toBe(true);
    expect((await phone.request("session.transcript", { sessionId: homeSessionId })).ok).toBe(true);

    const recorded = gateway.record();
    const requests = recorded.providerRequests as unknown as Array<{ promptSections: readonly string[]; messages: readonly TraceValue[] }>;
    const isWorker = (request: { messages: readonly TraceValue[] }) => JSON.stringify(request.messages).includes(WORKER_MARKER);
    const homeRoot = join(gateway.tronHome, "gateway", "home");
    const taskFile = (await readdir(join(homeRoot, "tasks"))).find((name) => name.endsWith(`-${TASK_ID}.json`));
    const trace = stabilize({
      lock: LOCK,
      exchanges: recorded.exchanges,
      events: recorded.events,
      providerRequests: {
        home: requests.filter((request) => !isWorker(request)) as unknown as TraceValue[],
        worker: requests.filter(isWorker) as unknown as TraceValue[],
      },
      homePrompts: homePrompts.map((prompt) => normalizeTraceValue(prompt, gateway.normalization)),
      canonicalJsonl: { home: await gateway.canonical(homeSessionId), worker: await gateway.canonical(workerSessionId) },
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
    } });
  }, 60_000);
});
