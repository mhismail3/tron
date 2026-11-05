import { afterEach, describe, expect, it } from "vitest";
import { type LockGateway } from "../../test-support/gateway-lock-harness.js";
import { compareWithGolden, lockPaths, lockUpdateRequested, normalizeTraceValue, type TraceValue } from "../../test-support/scenario-lock.js";
import { openLockSession, queueControlScenario, type QueueState } from "../../test-support/lock-scenarios.js";

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

describe("gateway/run queue lock", () => {
  it("run-queue-control: queued follow-ups keep order, a retried command replays, edits and clears are exact, a stopped steer is delivered", async () => {
    const session = await openLockSession("run-queue-control");
    gateways.push(session.gateway);
    const { gateway, sessionId } = session;
    const { queuedThree, staleEdit, unknownEdit, afterEdit, wrongAbort, retriedResponse, followUps, afterClear, beforeStop, finalQueue, transcript } =
      await queueControlScenario(session);

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
