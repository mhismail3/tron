import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { startLockGateway, type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { compareWithGolden, lockPaths, lockUpdateRequested, normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { awaitsWithin, waitFor } from "../../test-support/wait-for.js";

/**
 * Queue lock (restructure plan §6.4, V3; K-0 §7, guarding E5 `kernel/run`'s
 * admission, queue and abort) for the `gateway/run` module, through the real
 * Gateway over a loopback WebSocket (`gateway-lock-harness.ts`).
 *
 * `run-queue-control`: while one run is held open, three follow-ups queue in
 * order and a retried `commandId` replays its receipt instead of queueing
 * again. `session.queue.replace` refuses a stale revision and an unknown item,
 * then reorders two follow-ups and drops the third; `session.abort` refuses an
 * operation that is not the live one. The run and the follow-ups then reach the
 * model in the edited order. A second held run's follow-ups are cleared by
 * `session.clearQueue`, and stopping a third run with a queued steer delivers
 * that steer as the next turn. Canonical JSONL records each queued item's
 * terminal receipt (`queue-replaced`, `queue-cleared`).
 */

const MODULE = "gateway/run";
const gateways: LockGateway[] = [];
afterEach(async () => { await Promise.all(gateways.splice(0).map((gateway) => gateway.dispose())); });

/** A gate a scripted provider step holds until the test opens it. */
function gate(): { opened: Promise<void>; open(): void; reached: Promise<void>; reach(): void } {
  let open = (): void => {};
  let reach = (): void => {};
  const opened = new Promise<void>((resolve) => { open = resolve; });
  const reached = new Promise<void>((resolve) => { reach = resolve; });
  return { opened, open: () => open(), reached, reach: () => reach() };
}

/** A provider step that holds until the request is aborted. */
function untilAborted(reached: () => void) {
  return async (_context: unknown, options: { signal?: AbortSignal } | undefined) => {
    reached();
    await new Promise<void>((resolve) => {
      const signal = options?.signal;
      if (!signal || signal.aborted) { resolve(); return; }
      signal.addEventListener("abort", () => resolve(), { once: true });
    });
    return fauxAssistantMessage("Aborted turn response.");
  };
}

interface QueueState { queueRevision: number; queuedItems: Array<{ id: string; behavior: string; text: string }> }

describe("gateway/run queue lock", () => {
  it("run-queue-control: queued follow-ups keep order, a retried command replays, edits and clears are exact, a stopped steer is delivered", async () => {
    const gateway = await startLockGateway("run-queue-control");
    gateways.push(gateway);
    const phone = await gateway.connect("phone");
    const created = await phone.request("session.create", { commandId: gateway.commandId(), cwd: gateway.cwd });
    expect(created.ok, JSON.stringify(created)).toBe(true);
    const sessionId = created.result.sessionId as string;
    const opened = await phone.request("session.open", { sessionId });
    expect((await phone.request("session.sync", { sessionId, syncToken: opened.result.syncToken })).ok).toBe(true);
    const slot = await gateway.registry.acquire(sessionId);
    const queue = (): QueueState => {
      const snapshot = slot.snapshot() as unknown as QueueState;
      return { queueRevision: snapshot.queueRevision, queuedItems: snapshot.queuedItems.map(({ id, behavior, text }) => ({ id, behavior, text })) };
    };
    const queued = (count: number, label: string) => waitFor(() => queue().queuedItems.length === count ? queue() : undefined, label);
    const prompt = (text: string, extra: Record<string, unknown> = {}, commandId = gateway.commandId()) =>
      phone.send("session.prompt", { commandId, sessionId, text, ...extra });

    const first = gate();
    const second = gate();
    let thirdReached!: () => void;
    const third = new Promise<void>((resolve) => { thirdReached = resolve; });
    gateway.script([
      async () => { first.reach(); await first.opened; return fauxAssistantMessage("Held run settled."); },
      () => fauxAssistantMessage("Third follow-up answered."),
      () => fauxAssistantMessage("First follow-up answered."),
      async () => { second.reach(); await second.opened; return fauxAssistantMessage("Second held run settled."); },
      untilAborted(() => thirdReached()),
      () => fauxAssistantMessage("Stopped steer answered."),
    ]);

    // 1. Three follow-ups queue behind a held run; a retried command id replays.
    const held = await prompt("hold the first run open");
    expect(held.ok, JSON.stringify(held)).toBe(true);
    await awaitsWithin(first.reached, "the first held provider request");
    const retriedCommand = gateway.commandId();
    const followUps = [
      await prompt("first follow-up", { behavior: "followUp" }),
      await prompt("second follow-up", { behavior: "followUp" }, retriedCommand),
      await prompt("third follow-up", { behavior: "followUp" }),
    ];
    for (const response of followUps) expect(response.ok, JSON.stringify(response)).toBe(true);
    const retried = prompt("second follow-up", { behavior: "followUp" }, retriedCommand);
    const queuedThree = await queued(3, "three queued follow-ups");

    // 2. Edits: a stale revision and an unknown item are refused; then reorder and drop.
    const [one, two, three] = queuedThree.queuedItems;
    const staleEdit = await phone.request("session.queue.replace", {
      commandId: gateway.commandId(), sessionId, expectedRevision: queuedThree.queueRevision - 1, items: [three, one],
    });
    const unknownEdit = await phone.request("session.queue.replace", {
      commandId: gateway.commandId(), sessionId, expectedRevision: queuedThree.queueRevision,
      items: [three, { ...one!, id: "lock-unknown-queue-item" }],
    });
    const edited = await phone.request("session.queue.replace", {
      commandId: gateway.commandId(), sessionId, expectedRevision: queuedThree.queueRevision, items: [three, one],
    });
    expect(edited.ok, JSON.stringify(edited)).toBe(true);
    const afterEdit = queue();
    const wrongAbort = await phone.request("session.abort", { commandId: gateway.commandId(), sessionId, operationId: two!.id });

    // 3. The held run ends; the edited queue reaches the model in order.
    first.open();
    await gateway.settled(sessionId);
    const retriedResponse = await retried;

    // 4. A second held run: its follow-ups are cleared before they are delivered.
    expect((await prompt("hold the second run open")).ok).toBe(true);
    await awaitsWithin(second.reached, "the second held provider request");
    expect((await prompt("cleared follow-up one", { behavior: "followUp" })).ok).toBe(true);
    expect((await prompt("cleared follow-up two", { behavior: "followUp" })).ok).toBe(true);
    await queued(2, "two follow-ups to clear");
    const cleared = await phone.request("session.clearQueue", { commandId: gateway.commandId(), sessionId });
    expect(cleared.ok, JSON.stringify(cleared)).toBe(true);
    const afterClear = queue();
    second.open();
    await gateway.settled(sessionId);

    // 5. A third run is stopped with a steer queued: the steer becomes the next turn.
    const stoppable = await prompt("hold a run to stop");
    expect(stoppable.ok).toBe(true);
    await awaitsWithin(third, "the abortable provider request");
    expect((await prompt("steer queued at stop", { behavior: "steer" })).ok).toBe(true);
    const beforeStop = await queued(1, "the steer to queue");
    const stopped = await phone.request("session.abort", { commandId: gateway.commandId(), sessionId, operationId: stoppable.result.operationId });
    expect(stopped.ok, JSON.stringify(stopped)).toBe(true);
    await gateway.settled(sessionId);
    const finalQueue = queue();
    const transcript = await phone.request("session.transcript", { sessionId });

    const recorded = gateway.record();
    const userTexts = (await gateway.canonical(sessionId)).flatMap((entry) => {
      const message = (entry as { message?: { role?: string; content?: unknown } }).message;
      return message?.role === "user" ? [JSON.stringify(message.content)] : [];
    });
    const queueValue = (state: QueueState) => normalizeTraceValue(state as unknown as TraceValue, gateway.normalization);
    const trace = {
      lock: "run-queue-control",
      exchanges: recorded.exchanges,
      events: recorded.events,
      providerRequests: recorded.providerRequests as unknown as TraceValue[],
      canonicalJsonl: await gateway.canonical(sessionId),
      transcript: normalizeTraceValue(transcript.result, gateway.normalization),
      observed: {
        queuedThree: queueValue(queuedThree), afterEdit: queueValue(afterEdit), afterClear: queueValue(afterClear),
        beforeStop: queueValue(beforeStop), final: queueValue(finalQueue),
        retriedReplaysOriginal: JSON.stringify(retriedResponse.result) === JSON.stringify(followUps[1]!.result),
      },
    };
    await compareWithGolden({
      module: MODULE, ...lockPaths(import.meta.url, trace.lock), trace, update: lockUpdateRequested(MODULE),
      validate: () => {
        expect(queuedThree.queuedItems.map((item) => item.text)).toEqual(["first follow-up", "second follow-up", "third follow-up"]);
        expect(staleEdit.error).toMatchObject({ code: "conflict" });
        expect(unknownEdit.error).toMatchObject({ code: "conflict" });
        expect(afterEdit.queuedItems.map((item) => item.text)).toEqual(["third follow-up", "first follow-up"]);
        expect(wrongAbort.error).toMatchObject({ code: "conflict" });
        expect(retriedResponse.ok).toBe(true);
        expect(trace.observed.retriedReplaysOriginal).toBe(true);
        expect(afterClear.queuedItems).toEqual([]);
        expect(beforeStop.queuedItems.map((item) => item.behavior)).toEqual(["steer"]);
        expect(finalQueue.queuedItems).toEqual([]);
        expect(userTexts.map((text) => ["hold the first run open", "third follow-up", "first follow-up", "hold the second run open",
          "hold a run to stop", "steer queued at stop"].findIndex((needle) => text.includes(needle)))).toEqual([0, 1, 2, 3, 4, 5]);
        const canonical = JSON.stringify(trace.canonicalJsonl);
        expect(canonical).toContain("queue-replaced");
        expect(canonical).toContain("queue-cleared");
        expect(recorded.providerRequests).toHaveLength(6);
      },
    });
  }, 60_000);
});
