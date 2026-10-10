import { fauxAssistantMessage, type FauxResponseFactory } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { BlobStore } from "../sessions/blob-store.js";
import { projectTranscript } from "../sessions/projection.js";
import { disposeFixtures, dispatch, fixture, reportCall } from "../../test-support/home-task-fixture.js";
import { waitFor } from "../../test-support/wait-for.js";

afterEach(async () => {
  vi.restoreAllMocks();
  await disposeFixtures();
});

type Fixture = Awaited<ReturnType<typeof fixture>>;
type Entry = { type: string; id: string; customType?: string; message?: { role: string }; details?: { operationId?: string; eventId?: string } };

const RESULT = "tron.home-task-result.v1";
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
  await f.registry.homeOwner().configureMemory({ model: { provider: model.provider, id: model.id } });
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

  it("never requests a wake for an activation that ended by Stop, through the idle seam", async () => {
    const f = await fixture();
    await configure(f);
    // Home is paused while the result settles, so the result waits without a wake and no push is pending for it.
    await f.registry.homeOwner().pauseMemory();
    f.faux.setResponses([fauxAssistantMessage([reportCall("seam-report", "Seam result")], { stopReason: "toolUse" })]);
    await (await dispatch(f, "seam-stop")).completion;
    await f.registry.homeOwner().resumeMemory();
    expect((await settledTask(f, "seam-stop")).wake?.state).toBe("pending");
    // The runtime reports an activation that a Stop ended: it must not start a wake.
    f.faux.setResponses([fauxAssistantMessage("Wake that must not run")]);
    f.registry.homeOwner().noteHomeIdle(f.home.sessionId, "user", true);
    await new Promise(resolve => setTimeout(resolve, 600));
    // Only the worker's report has called the provider: no wake ran for the Stop-ended activation.
    expect(f.faux.state.callCount).toBe(1);
    expect((await settledTask(f, "seam-stop")).wake?.state).toBe("pending");
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
