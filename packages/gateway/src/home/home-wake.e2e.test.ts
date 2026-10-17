import { fauxAssistantMessage, fauxToolCall, type FauxResponseFactory } from "@earendil-works/pi-ai";
import { setHomeMemoryModels } from "../../test-support/settings-dependencies.js";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { BlobStore } from "../sessions/blob-store.js";
import { projectTranscript } from "../sessions/projection.js";
import { disposeFixtures, dispatch, fixture, reportCall } from "../../test-support/home-task-fixture.js";
import { waitFor } from "../../test-support/wait-for.js";
import type { GatewayError } from "../errors.js";

afterEach(async () => {
  vi.restoreAllMocks();
  await disposeFixtures();
});

type Fixture = Awaited<ReturnType<typeof fixture>>;
type Entry = { type: string; id: string; customType?: string; message?: { role: string }; details?: { operationId?: string; eventId?: string } };

const RESULT = "tron.home-task-result.v1";
const checkinEvidence: unknown[] = [];
afterAll(async () => {
  const { mkdir, writeFile } = await import("node:fs/promises");
  await mkdir("test-results", { recursive: true });
  await writeFile("test-results/home-task-checkin-wake.json", JSON.stringify(checkinEvidence, null, 2));
});
/** An inbox notice. A wake reply sends none: its turn's own terminal push is the only push for it. */
const isWakePush = (input: { sourceId: string }) => input.sourceId.startsWith("home-wake:");
const isWaitingPush = (input: { sourceId: string }) => input.sourceId.startsWith("home-waiting:");
/** Every push Home's session sent: each turn's terminal push, and the inbox's notices. */
const homePushes = (f: Fixture) => f.notifications.filter(input => input.sessionId === f.home.sessionId);
/** A reply that stays open until its operation is stopped, then ends aborted. */
const untilStopped = (text: string): FauxResponseFactory => (_context, options) => new Promise(resolve => {
  options?.signal?.addEventListener("abort", () => resolve(fauxAssistantMessage(text)), { once: true });
});

function gate() {
  let open!: () => void;
  const wait = new Promise<void>(resolve => { open = resolve; });
  return { wait, open };
}
async function configure(f: Fixture): Promise<void> {
  const model = f.faux.getModel();
  await setHomeMemoryModels(f.registry, [{ provider: model.provider, id: model.id }]);
}
async function settledTask(f: Fixture, taskId: string) {
  return (await f.registry.homeOwner().taskResult(taskId));
}
async function waitAcknowledged(f: Fixture, taskId: string): Promise<void> {
  await waitFor(async () => (await settledTask(f, taskId)).wake?.state === "acknowledged", `wake of ${taskId} acknowledged`);
}
function results(entries: readonly Entry[]): Entry[] {
  return entries.filter(entry => entry.type === "custom_message" && entry.customType === RESULT);
}
function userMessages(entries: readonly Entry[]): Entry[] {
  return entries.filter(entry => entry.type === "message" && entry.message?.role === "user");
}
/** Wake operations are the operations whose results are attributed and that have no user message. */
function operationsWithResults(entries: readonly Entry[]): string[] {
  return [...new Set(results(entries).map(entry => entry.details?.operationId ?? ""))];
}

describe("Home wakes on its own task results (#749)", () => {
  it("wakes for a worker blocker without ending it, rate limits across resume, and preserves the separate final result", async () => {
    const f = await fixture();
    await configure(f);
    const owner = f.registry.homeOwner();
    const home = await f.registry.acquire(f.home.sessionId);
    let workerTurns = 0;
    let homeTurns = 0;
    const alert = { step: "Validation", done: "Reproduced failure", next: "Continue independent checks", blocker: "Need Home to coordinate the shared test lane", needsAttention: true };
    const respond: FauxResponseFactory = (context, options) => {
      if (context.messages.some(message => message.role === "system" && JSON.stringify(message).includes("This is a finite Home task."))) {
        workerTurns++;
        if (workerTurns <= 2) return fauxAssistantMessage([fauxToolCall("checkin", alert)], { stopReason: "toolUse" });
        return untilStopped("worker stopped")(context, options);
      }
      homeTurns++;
      return fauxAssistantMessage("I will coordinate the lane; continue independent checks.");
    };
    f.faux.setResponses(Array.from({ length: 20 }, () => respond));
    const run = await dispatch(f, "attention-worker");
    await waitFor(async () => (await settledTask(f, run.taskId)).attention?.wake.state === "acknowledged" && workerTurns >= 3, "blocker wake acknowledged while worker continues").catch(async error => { throw new Error(`${error.message}; worker=${workerTurns}; home=${homeTurns}; task=${JSON.stringify(await settledTask(f, run.taskId))}; signals=${JSON.stringify(f.signals.slice(-20))}`); });
    const active = await owner.taskStatus(run.taskId);
    expect(active.lifecycle).toBe("active");
    expect(active.reportRef).toBeNull();
    expect(active.checkins?.map(row => row.attention)).toEqual(["requested", "rate-limited"]);
    expect(homeTurns).toBe(1);
    expect(results(home.canonicalSessionEntries() as Entry[])).toHaveLength(1);
    expect(JSON.stringify(results(home.canonicalSessionEntries() as Entry[]))).toContain("not a final report");
    await owner.stopTask({ taskId: run.taskId, operationId: run.operationId });
    await run.completion;
    await waitAcknowledged(f, run.taskId);
    expect((await settledTask(f, run.taskId)).attention?.wake.state).toBe("acknowledged");
    const beforeResume = homeTurns;
    let resumedTurns = 0;
    const resumedResponse: FauxResponseFactory = (context, options) => {
      if (context.messages.some(message => message.role === "system" && JSON.stringify(message).includes("This is a finite Home task."))) {
        if (++resumedTurns === 1) return fauxAssistantMessage([fauxToolCall("checkin", alert)], { stopReason: "toolUse" });
        return untilStopped("resumed stopped")(context, options);
      }
      homeTurns++;
      return fauxAssistantMessage("Stopped result acknowledged.");
    };
    f.faux.setResponses(Array.from({ length: 20 }, () => resumedResponse));
    const resumed = await owner.taskTool(f.home.sessionId, { action: "resume", taskId: run.taskId }) as { taskId: string; operationId: string };
    await waitFor(() => resumedTurns === 2, "resumed worker continues after limited checkin");
    const resumedStatus = await owner.taskStatus(resumed.taskId);
    expect(resumedStatus.checkins?.at(-1)).toMatchObject({ attention: "rate-limited", operationId: resumed.operationId });
    expect(resumedStatus.lastAttentionAt).toBe(active.lastAttentionAt);
    expect(homeTurns).toBe(beforeResume);
    await owner.stopTask(resumed);
    await waitAcknowledged(f, resumed.taskId);
    const realNow = Date.now.bind(Date);
    vi.spyOn(Date, "now").mockImplementation(() => realNow() + 31 * 60 * 1000);
    resumedTurns = 0;
    const afterCooldown = await owner.taskTool(f.home.sessionId, { action: "resume", taskId: resumed.taskId }) as { taskId: string; operationId: string };
    await waitFor(async () => (await settledTask(f, afterCooldown.taskId)).attention?.wake.state === "acknowledged" && resumedTurns === 2, "attention allowed again after durable cooldown");
    const later = await owner.taskStatus(afterCooldown.taskId);
    expect(later.checkins?.at(-1)).toMatchObject({ attention: "requested", operationId: afterCooldown.operationId });
    expect(later.lifecycle).toBe("active");
    await owner.stopTask(afterCooldown);
    await waitAcknowledged(f, afterCooldown.taskId);
    checkinEvidence.push({ case: "attention-wake-rate-limit-resume", active, resumed: resumedStatus, afterCooldown: later, delivered: results(home.canonicalSessionEntries() as Entry[]) });
  }, 30_000);

  it("keeps an admitted blocker wake intact when the worker reports before Home replies", async () => {
    const f = await fixture();
    await configure(f);
    const hold = gate();
    let workerTurns = 0;
    let homeTurns = 0;
    let releaseWorker!: () => void;
    const homeEntered = new Promise<void>(resolve => { releaseWorker = resolve; });
    const response: FauxResponseFactory = async context => {
      if (context.messages.some(message => message.role === "system" && JSON.stringify(message).includes("This is a finite Home task."))) {
        if (++workerTurns === 1) return fauxAssistantMessage([fauxToolCall("checkin", { step: "Testing", done: "Investigated", next: "Report findings", blocker: "Home coordination needed", needsAttention: true })], { stopReason: "toolUse" });
        await homeEntered;
        return fauxAssistantMessage([reportCall()], { stopReason: "toolUse" });
      }
      if (++homeTurns === 1) { releaseWorker(); await hold.wait; }
      return fauxAssistantMessage("Acknowledged task update");
    };
    f.faux.setResponses(Array.from({ length: 8 }, () => response));
    const run = await dispatch(f, "attention-report-race");
    try {
      const final = await run.completion;
      expect(final.attention?.wake.state).toBe("admitted");
      expect(final.wake?.state).toBe("pending");
      expect(final.terminalEvidence?.outcome).toBe("final");
      expect(final.attention?.wake.eventId).not.toBe(final.wake?.eventId);
    } finally { hold.open(); }
    await waitAcknowledged(f, run.taskId);
    const final = await settledTask(f, run.taskId);
    expect(final.attention?.wake.state).toBe("acknowledged");
    expect(homeTurns).toBe(2);
    checkinEvidence.push({ case: "attention-report-race", task: final });
  }, 30_000);

  it("delivers a known provider usage limit without inventing a report or exposing provider text", async () => {
    const f = await fixture();
    await configure(f);
    f.faux.setResponses([
      fauxAssistantMessage("", { stopReason: "error", errorMessage: "Subscription usage limit reached: fixture-private-provider-detail" }),
      fauxAssistantMessage("Provider limit noted; work outcome remains unknown"),
    ]);
    const run = await dispatch(f, "limited-no-report");
    await run.completion;
    await waitAcknowledged(f, run.taskId);
    const home = await f.registry.acquire(f.home.sessionId);
    const delivered = results(home.canonicalSessionEntries() as Entry[])[0] as Entry & { content: string; details: { terminalEvidence: unknown; resultRef: unknown } };
    expect(delivered.content).toContain("No accepted report. Outcome: unknown (no-report; provider-usage-limit)");
    expect(delivered.content).not.toContain("fixture-private-provider-detail");
    expect(delivered.details).toMatchObject({ resultRef: null, terminalEvidence: { outcome: "unknown", reason: "no-report", failureCause: "provider-usage-limit" } });
    checkinEvidence.push({ case: "provider-failure-delivery", delivered });
  });

  it("wakes an idle Home on a settled result, and Home replies with no user message", async () => {
    const f = await fixture();
    await configure(f);
    f.faux.setResponses([fauxAssistantMessage([reportCall("ra", "Verified result")], { stopReason: "toolUse" }),
      fauxAssistantMessage("Summary for the maintainer")]);
    const run = await dispatch(f, "task-wake");
    await run.completion;
    await waitAcknowledged(f, "task-wake");
    const home = await f.registry.acquire(f.home.sessionId);
    const entries = home.canonicalSessionEntries() as Entry[];
    // Only the wake ran: no user message exists in this chapter, and the delivered result is the first entry of its turn.
    expect(userMessages(entries)).toHaveLength(0);
    expect(results(entries)).toHaveLength(1);
    const delivered = results(entries)[0] as Entry & { content?: string };
    expect(delivered.content).toMatch(/^Home task: Finite work \| outcome: final \| subagents: 0 started, 0 stopped at end \| duration: \d+ms\n\nVerified result\n\nEvidence:\n- focused check passed$/);
    expect(delivered.content).not.toContain("task-wake");
    expect(delivered.content).not.toContain('"taskId"');
    expect(entries.some(entry => entry.type === "message" && entry.message?.role === "assistant"
      && JSON.stringify(entry).includes("Summary for the maintainer"))).toBe(true);
    // One push for the wake: its turn's own terminal push. The inbox sends no wake notice, and no per-task push.
    await waitFor(() => homePushes(f).length === 1, "wake reply push");
    expect(f.notifications.filter(isWakePush)).toHaveLength(0);
    const eventId = (await settledTask(f, "task-wake")).wake!.eventId;
    expect(f.notifications.filter(input => input.sourceId === eventId)).toHaveLength(0);
    // The wake's run is an idle admission like any other: SDK auto-compaction stays disabled for Home (`_checkCompaction`
    // returns early when compaction is not enabled), so the wake's pre-run check cannot compact.
    const session = (home as unknown as { runtime: { session: { settingsManager: { getCompactionSettings(model: unknown): { enabled: boolean } }; model: unknown } } }).runtime.session;
    expect(session.settingsManager.getCompactionSettings(session.model).enabled).toBe(false);
    // The wake's turn projects to the delivered-context row, then Home's reply: no user row.
    const rows = projectTranscript((home as unknown as { sessionManager: never }).sessionManager, new BlobStore())
      .map(item => item.kind === "message" ? `message:${item.role}` : item.kind)
      .filter(kind => kind !== "modelChange");
    // The wake's turn starts at its delivered result: no user row before Home's reply.
    expect(rows.slice(rows.indexOf("customMessage"))).toEqual(["customMessage", "message:assistant"]);
  }, 30_000);

  it("delivers two results that settle during a user turn in one wake, after that turn", async () => {
    const f = await fixture();
    await configure(f);
    const hold = gate();
    f.faux.setResponses([
      async () => { await hold.wait; return fauxAssistantMessage("user reply"); },
      fauxAssistantMessage([reportCall("ra", "Result A")], { stopReason: "toolUse" }),
      fauxAssistantMessage([reportCall("rb", "Result B")], { stopReason: "toolUse" }),
      fauxAssistantMessage("Wake reply for both"),
    ]);
    const home = await f.registry.acquire(f.home.sessionId);
    const turn = home.prompt("hello");
    await waitFor(() => f.faux.state.callCount >= 1, "user turn request");
    const a = await dispatch(f, "task-a");
    const b = await dispatch(f, "task-b");
    await a.completion; await b.completion;
    await waitFor(async () => (await settledTask(f, "task-a")).lifecycle === "terminal" && (await settledTask(f, "task-b")).lifecycle === "terminal", "both results settled");
    // Both settled while the user turn runs: nothing wakes Home yet.
    expect(results(home.canonicalSessionEntries() as Entry[])).toHaveLength(0);
    hold.open();
    await turn;
    await waitAcknowledged(f, "task-a");
    await waitAcknowledged(f, "task-b");
    const entries = home.canonicalSessionEntries() as Entry[];
    expect(results(entries)).toHaveLength(2);
    expect(operationsWithResults(entries)).toHaveLength(1);
    // The user turn and the one wake each end with their own terminal push; the inbox sends no wake notice.
    await waitFor(() => homePushes(f).length === 2, "user turn and wake pushes");
    expect(f.notifications.filter(isWakePush)).toHaveLength(0);
  }, 30_000);

  it("does not wake a paused Home, and the task-finished push stays as it is today", async () => {
    const f = await fixture();
    await configure(f);
    const hold = gate();
    f.faux.setResponses([async () => { await hold.wait; return fauxAssistantMessage([reportCall("rp", "Paused result")], { stopReason: "toolUse" }); }]);
    const run = await dispatch(f, "task-paused");
    await f.registry.homeOwner().pauseMemory();
    hold.open();
    const task = await run.completion;
    await waitFor(async () => (await settledTask(f, "task-paused")).wake?.push === "decided", "task-finished push decided");
    expect(f.faux.state.callCount).toBe(1);
    expect(results((await f.registry.acquire(f.home.sessionId)).canonicalSessionEntries() as Entry[])).toHaveLength(0);
    expect(f.notifications.filter(input => input.sourceId === task.wake!.eventId)).toHaveLength(1);
    expect(f.notifications.filter(isWakePush)).toHaveLength(0);
    // Resuming delivers the waiting result at once (#1279), not at the user's next message.
    f.faux.setResponses([fauxAssistantMessage("Reviewed after resume")]);
    await f.registry.homeOwner().resumeMemory();
    await waitAcknowledged(f, "task-paused");
    const entries = (await f.registry.acquire(f.home.sessionId)).canonicalSessionEntries() as Entry[];
    expect(results(entries)).toHaveLength(1);
    expect(userMessages(entries)).toHaveLength(0);
  }, 30_000);

  it("does not wake a disabled Home, and the task-finished push stays as it is today", async () => {
    const f = await fixture();
    await configure(f);
    const hold = gate();
    f.faux.setResponses([async () => { await hold.wait; return fauxAssistantMessage([reportCall("rd", "Disabled result")], { stopReason: "toolUse" }); }]);
    const run = await dispatch(f, "task-disabled");
    const disable = f.registry.homeOwner().disable();
    hold.open();
    await disable;
    const task = await run.completion;
    await waitFor(async () => (await settledTask(f, "task-disabled")).wake?.push === "decided", "task-finished push decided");
    expect(f.faux.state.callCount).toBe(1);
    expect(f.notifications.filter(input => input.sourceId === task.wake!.eventId)).toHaveLength(1);
    expect(f.notifications.filter(isWakePush)).toHaveLength(0);
  }, 30_000);

  it("refuses the ninth wake: results wait, and the push says Home is waiting", async () => {
    const f = await fixture();
    await configure(f);
    const responses = [];
    for (let i = 0; i < 9; i++) {
      responses.push(fauxAssistantMessage([reportCall(`r${i}`, `Result ${i}`)], { stopReason: "toolUse" }));
      if (i < 8) responses.push(fauxAssistantMessage(`Wake ${i}`));
    }
    f.faux.setResponses(responses);
    for (let i = 0; i < 8; i++) {
      await (await dispatch(f, `ceiling-${i}`)).completion;
      await waitAcknowledged(f, `ceiling-${i}`);
    }
    await (await dispatch(f, "ceiling-8")).completion;
    await waitFor(async () => (await settledTask(f, "ceiling-8")).wake?.push === "decided", "waiting push decided");
    // Eight wakes ran; the ninth result stayed pending and was announced as waiting.
    expect(f.faux.state.callCount).toBe(9 + 8);
    expect((await settledTask(f, "ceiling-8")).wake?.state).toBe("pending");
    await waitFor(() => homePushes(f).length === 9, "eight wake pushes and the waiting notice");
    expect(f.notifications.filter(isWaitingPush)).toHaveLength(1);
    expect(f.notifications.filter(isWakePush)).toHaveLength(0);
  }, 60_000);

  it("wakes exactly once after a restart that finds pending results", async () => {
    const f = await fixture();
    await configure(f);
    // A delegation comes from a Home activation, so Home has a conversation before its result settles.
    f.faux.setResponses([fauxAssistantMessage("Hello reply")]);
    await (await f.registry.acquire(f.home.sessionId)).prompt("hello");
    await waitFor(async () => (await f.registry.acquire(f.home.sessionId)).snapshot().operation === undefined, "hello settled");
    f.faux.setResponses([fauxAssistantMessage([reportCall("rr", "Restart result")], { stopReason: "toolUse" })]);
    await f.registry.homeOwner().pauseMemory();
    await (await dispatch(f, "task-restart")).completion;
    await waitFor(async () => (await settledTask(f, "task-restart")).wake?.push === "decided", "paused push decided");
    const beforeRestart = f.faux.state.callCount;
    await f.registry.homeOwner().resumeMemory();
    f.faux.setResponses([fauxAssistantMessage("Restart wake reply")]);
    f.registry = await f.restart();
    await waitAcknowledged(f, "task-restart");
    // Exactly one wake request after startup. The result's task-finished notice went out while paused, so
    // the wake sends no second notice for it.
    expect(f.faux.state.callCount).toBe(beforeRestart + 1);
    expect(f.notifications.filter(isWakePush)).toHaveLength(0);
    const restartEventId = (await settledTask(f, "task-restart")).wake!.eventId;
    expect(f.notifications.filter(input => input.sourceId === restartEventId)).toHaveLength(1);
  }, 60_000);

  it("keeps one delivery when a user prompt races a wake", async () => {
    const f = await fixture();
    await configure(f);
    f.faux.setResponses([
      fauxAssistantMessage([reportCall("rx", "Raced result")], { stopReason: "toolUse" }),
      fauxAssistantMessage("Reply to the race"),
      fauxAssistantMessage("Second reply"),
    ]);
    const run = await dispatch(f, "task-race");
    await run.completion;
    const home = await f.registry.acquire(f.home.sessionId);
    await home.prompt("racing input");
    await waitAcknowledged(f, "task-race");
    await waitFor(() => home.snapshot().operation === undefined && home.snapshot().configurationBlocker === null, "race settled");
    const entries = home.canonicalSessionEntries() as Entry[];
    expect(results(entries)).toHaveLength(1);
    expect(userMessages(entries)).toHaveLength(1);
    expect(operationsWithResults(entries)).toHaveLength(1);
  }, 30_000);

  it("does not count a user activation's drained results toward the ceiling: eight wakes still run", async () => {
    const f = await fixture();
    await configure(f);
    const home = await f.registry.acquire(f.home.sessionId);
    // A result that settles while Home is paused waits for the maintainer's next message.
    await f.registry.homeOwner().pauseMemory();
    f.faux.setResponses([fauxAssistantMessage([reportCall("drained-report", "Drained result")], { stopReason: "toolUse" })]);
    await (await dispatch(f, "drained")).completion;
    await f.registry.homeOwner().resumeMemory();
    const responses = [fauxAssistantMessage("Reply to the maintainer")];
    for (let i = 0; i < 9; i++) {
      responses.push(fauxAssistantMessage([reportCall(`ceiling-${i}`, `Result ${i}`)], { stopReason: "toolUse" }));
      if (i < 8) responses.push(fauxAssistantMessage(`Wake ${i}`));
    }
    f.faux.setResponses(responses);
    const eventsBeforeDrain = f.events.length;
    await home.prompt("hello");
    await waitAcknowledged(f, "drained");
    // The user activation delivers its result as context: no client error follows (#730).
    expect(f.events.slice(eventsBeforeDrain).filter(event => event.topic === "session.extensionError")).toEqual([]);
    for (let i = 0; i < 8; i++) {
      await (await dispatch(f, `ceiling-${i}`)).completion;
      await waitAcknowledged(f, `ceiling-${i}`);
    }
    await (await dispatch(f, "ceiling-8")).completion;
    await waitFor(async () => (await settledTask(f, "ceiling-8")).wake?.push === "decided", "waiting push decided");
    // The drained result counted for nothing: the eighth wake ran, and the ninth result waits.
    expect((await settledTask(f, "ceiling-8")).wake?.state).toBe("pending");
    expect(f.faux.state.callCount).toBe(19);
    await waitFor(() => f.notifications.some(isWaitingPush), "waiting notice");
    expect(f.notifications.filter(isWaitingPush)).toHaveLength(1);
  }, 60_000);

  // #881: delivering a waiting result needs the memory view. When that refuses,
  // the prompt fails before any run starts and must leave Home idle, not stuck
  // "running" with nothing running, which made every later prompt wait forever.
  it("leaves Home idle when a prompt is refused while delivering a waiting result, so the next prompt runs", async () => {
    const f = await fixture();
    await configure(f);
    const hold = gate();
    f.faux.setResponses([async () => { await hold.wait; return fauxAssistantMessage([reportCall("rf", "Refused delivery result")], { stopReason: "toolUse" }); }]);
    const run = await dispatch(f, "task-refused-delivery");
    await f.registry.homeOwner().pauseMemory();
    hold.open();
    await run.completion;
    await waitFor(async () => (await settledTask(f, "task-refused-delivery")).wake?.push === "decided", "task-finished push decided");
    const home = await f.registry.acquire(f.home.sessionId);
    const calls = f.faux.state.callCount;
    await expect(home.prompt("while memory is paused")).rejects.toThrow();
    expect(f.faux.state.callCount).toBe(calls);
    expect(home.snapshot()).toMatchObject({ phase: "idle", configurationBlocker: null });
    expect(home.snapshot().operation).toBeUndefined();

    await f.registry.homeOwner().resumeMemory();
    f.faux.setResponses([fauxAssistantMessage("Answered after resume")]);
    await home.prompt("after resume");
    await waitFor(() => home.snapshot().configurationBlocker === null, "second prompt settled");
    expect(f.faux.state.callCount).toBe(calls + 1);
  }, 30_000);

  it("refuses a prompt admitted with a waiting result by its memory cause, not an admission failure", async () => {
    // A plan limit blocks Home's memory; a task result then settles and waits. The
    // user's prompt is admitted with that result, and its refusal reaches the client.
    const f = await fixture(false, false, undefined, false, undefined, { queueSummarizer: true });
    await configure(f);
    const hold = gate();
    const LIMIT = "429 You have hit your ChatGPT usage limit (usage_limit_reached). Try again in 3 days.";
    let homeTurns = 0;
    let workerTurns = 0;
    f.faux.setResponses(Array.from({ length: 60 }, () => async (_context: unknown, options: { sessionId?: string } | undefined) => {
      if (options?.sessionId?.startsWith("tron-episodic:")) return fauxAssistantMessage("", { stopReason: "error", errorMessage: LIMIT });
      if (homeTurns === 0) { homeTurns += 1; return fauxAssistantMessage("First Home answer"); }
      workerTurns += 1;
      await hold.wait;
      return fauxAssistantMessage([reportCall("rl", "Result while limited")], { stopReason: "toolUse" });
    }));
    const home = await f.registry.acquire(f.home.sessionId);
    // A message over the memory's node size is summarized (a short one is kept verbatim).
    await home.prompt(`first turn for the limit ${"first detail ".repeat(200)}`);
    await waitFor(async () => (await f.registry.homeOwner().memoryStatus()).blocked === "usage-limit", "memory blocked by the limit");
    const run = await dispatch(f, "task-limited-result");
    hold.open();
    await run.completion;
    await waitFor(async () => (await settledTask(f, "task-limited-result")).wake?.push === "decided", "task-finished push decided");
    const wake = (await settledTask(f, "task-limited-result")).wake;
    const refusal = await home.prompt("prompt while the limit holds").then(() => undefined, (error: unknown) => error as GatewayError);
    expect(refusal).toBeDefined();
    // The client reads the cause first; the uncertain-outcome marker still blocks a replay.
    expect(refusal!.message).toMatch(/^Home request refused \(memory-usage-limit\): .*usage limit/u);
    expect(refusal!.details).toMatchObject({ outcomeUnknown: true });
    expect(wake?.state).toBe("pending");
  }, 60_000);

  // #1279: a blocked memory refused every wake, so finished task results waited
  // silently until someone found a resume control. A wake now re-arms the memory
  // like any activation: a failure that persists keeps the result pending and
  // says Home is waiting, and the first wake after the cause clears delivers.
  it("wakes through a blocked memory once its cause clears, keeping results pending until then", async () => {
    const f = await fixture(false, false, undefined, false, undefined, { queueSummarizer: true });
    await configure(f);
    const REFUSAL = "invalid_request_error: unsupported message";
    let memoryFails = true;
    let summaries = 0;
    let homeTurns = 0;
    const work: Record<string, ReturnType<typeof gate>> = { first: gate(), second: gate() };
    f.faux.setResponses(Array.from({ length: 80 }, () => async (context: { messages: unknown[] }, options: { sessionId?: string } | undefined) => {
      if (options?.sessionId?.startsWith("tron-episodic:")) {
        summaries += 1;
        return memoryFails ? fauxAssistantMessage("", { stopReason: "error", errorMessage: REFUSAL }) : fauxAssistantMessage("bounded summary");
      }
      const text = JSON.stringify(context.messages);
      if (text.includes("worker-first") && !text.includes("Home task:")) { await work.first!.wait; return fauxAssistantMessage([reportCall("rf", "First result")], { stopReason: "toolUse" }); }
      if (text.includes("worker-second") && !text.includes("Home task:")) { await work.second!.wait; return fauxAssistantMessage([reportCall("rs", "Second result")], { stopReason: "toolUse" }); }
      homeTurns += 1;
      return fauxAssistantMessage(homeTurns === 1 ? "First Home answer" : "Reviewed both results");
    }));
    const home = await f.registry.acquire(f.home.sessionId);
    // A message over the memory's node size is summarized (a short one is kept verbatim).
    await home.prompt(`first turn ${"first detail ".repeat(200)}`);
    await waitFor(async () => (await f.registry.homeOwner().memoryStatus()).blocked === "permanent-failure", "memory blocked");

    // The cause persists: the wake re-arms, blocks again and is refused before admitting the result.
    const first = await f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "task-first", intent: "worker-first", target: f.cwd });
    work.first!.open();
    await first.completion;
    await waitFor(async () => (await settledTask(f, "task-first")).wake?.push === "decided", "first result push decided");
    const pendingWhileFailing = (await settledTask(f, "task-first")).wake?.state;
    const turnsWhileFailing = homeTurns;
    const summariesWhileFailing = summaries;
    const pushesWhileFailing = f.notifications.length;

    // The cause clears. Nobody resumes memory: the next result's wake heals it and delivers both.
    memoryFails = false;
    const second = await f.registry.homeOwner().dispatchTask(f.home.sessionId, { taskId: "task-second", intent: "worker-second", target: f.cwd });
    work.second!.open();
    await second.completion;
    await waitAcknowledged(f, "task-first");
    await waitAcknowledged(f, "task-second");
    const row = {
      pendingWhileFailing,
      homeTurnsWhileFailing: turnsWhileFailing,
      wakeRearmedWhileFailing: summariesWhileFailing > 1,
      // The refused wake still tells the user a result is waiting.
      pushesWhileFailing,
      delivered: results(home.canonicalSessionEntries() as Entry[]).length,
      blockedAfter: (await f.registry.homeOwner().memoryStatus()).blocked ?? null,
    };
    checkinEvidence.push({ case: "wake-heals-blocked-memory", ...row });
    expect(row.pendingWhileFailing).toBe("pending");
    expect(row.homeTurnsWhileFailing).toBe(1);
    expect(row.wakeRearmedWhileFailing).toBe(true);
    expect(row.pushesWhileFailing).toBeGreaterThan(0);
    expect(row.delivered).toBe(2);
    expect(row.blockedAfter).toBeNull();
    expect(homeTurns).toBe(2);
  }, 60_000);

  it("never wakes Home for a user activation that Stop ends, even with a result waiting", async () => {
    const f = await fixture();
    await configure(f);
    const home = await f.registry.acquire(f.home.sessionId);
    f.faux.setResponses([untilStopped("never delivered")]);
    const turn = home.prompt("hello");
    await waitFor(() => f.faux.state.callCount === 1, "user turn request");
    f.faux.setResponses([fauxAssistantMessage([reportCall("stop-report", "Waiting result")], { stopReason: "toolUse" })]);
    await (await dispatch(f, "stop-user")).completion;
    // The result settled while the user turn ran: it waits for Home to be idle.
    expect((await settledTask(f, "stop-user")).wake?.state).toBe("pending");
    await home.abort("agent");
    await turn.catch(() => {});
    await waitFor(() => home.snapshot().operation === undefined, "stopped user activation settled");
    // A wake that Stop should have prevented starts within a few milliseconds; wait well past that.
    await new Promise(resolve => setTimeout(resolve, 600));
    // No wake followed the Stop: no provider call, and the result still waits.
    expect(f.faux.state.callCount).toBe(2);
    expect((await settledTask(f, "stop-user")).wake?.state).toBe("pending");
  }, 30_000);

  it("never wakes Home again after Stop ends a wake, though another result waits", async () => {
    const f = await fixture();
    await configure(f);
    const home = await f.registry.acquire(f.home.sessionId);
    f.faux.setResponses([fauxAssistantMessage([reportCall("stop-a", "Result A")], { stopReason: "toolUse" }), untilStopped("never delivered")]);
    await (await dispatch(f, "stop-wake-a")).completion;
    await waitFor(() => f.faux.state.callCount === 2, "wake for A in flight");
    f.faux.setResponses([fauxAssistantMessage([reportCall("stop-b", "Result B")], { stopReason: "toolUse" })]);
    await (await dispatch(f, "stop-wake-b")).completion;
    // Home is busy with wake A, so B waits for an idle moment.
    expect((await settledTask(f, "stop-wake-b")).wake?.state).toBe("pending");
    await home.abort("agent");
    await waitFor(() => home.snapshot().operation === undefined, "stopped wake settled");
    // A wake that Stop should have prevented starts within a few milliseconds; wait well past that.
    await new Promise(resolve => setTimeout(resolve, 600));
    expect(f.faux.state.callCount).toBe(3);
    expect((await settledTask(f, "stop-wake-b")).wake?.state).toBe("pending");
  }, 30_000);

  it("restarts during a wake: its trigger is never replayed, and the waiting result wakes Home once after recovery", async () => {
    const f = await fixture();
    await configure(f);
    f.faux.setResponses([
      fauxAssistantMessage([reportCall("mid-a", "Result A")], { stopReason: "toolUse" }),
      untilStopped("never delivered"),
      fauxAssistantMessage([reportCall("mid-b", "Result B")], { stopReason: "toolUse" }),
    ]);
    await (await dispatch(f, "midwake-a")).completion;
    // The wake for A is in flight: its trigger is in the canonical session and its reply is held open.
    await waitFor(() => f.faux.state.callCount === 2, "wake for A in flight");
    await (await dispatch(f, "midwake-b")).completion;
    expect((await settledTask(f, "midwake-b")).wake?.state).toBe("pending");
    const beforeRestart = f.faux.state.callCount;
    f.faux.setResponses([fauxAssistantMessage("Wake reply for B")]);
    f.registry = await f.restart();
    await waitAcknowledged(f, "midwake-b");
    // The trigger was proven or left outcome-unknown, never sent again: its result is in the chapter once.
    const a = await settledTask(f, "midwake-a");
    expect(["acknowledged", "outcome-unknown"]).toContain(a.wake?.state);
    const entries = (await f.registry.acquire(f.home.sessionId)).canonicalSessionEntries() as Entry[];
    expect(results(entries).filter(entry => JSON.stringify(entry).includes("Result A"))).toHaveLength(1);
    // Exactly one wake after recovery: it delivered B and nothing else.
    expect(f.faux.state.callCount).toBe(beforeRestart + 1);
    expect(f.notifications.filter(isWakePush)).toHaveLength(0);
  }, 60_000);
});
