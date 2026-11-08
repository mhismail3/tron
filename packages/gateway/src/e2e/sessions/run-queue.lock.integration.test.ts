import { afterEach, describe, expect, it } from "vitest";
import { type LockGateway } from "../../../test-support/gateway-lock-harness.js";
import { expectRequestShapes, expectSystemShapes } from "../../../test-support/lock-projections.js";
import { openLockSession, queueControlScenario } from "../../../test-support/lock-scenarios.js";

/**
 * Queue lock (packages/gateway/docs/scenario-locks.md#locks; K-0 §7, guarding E5 `kernel/run`'s
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
 *
 * Effects are asserted by name: queue revisions and contents, exact refusals,
 * the replayed retry, every persisted invocation receipt in order, the transcript
 * rows, each provider request's messages and the `session-shapes` shapes.
 */

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
    const canonicalJsonl = await gateway.canonical(sessionId);
    const userTexts = canonicalJsonl.flatMap((entry) => {
      const message = (entry as { message?: { role?: string; content?: unknown } }).message;
      return message?.role === "user" ? [JSON.stringify(message.content)] : [];
    });
    const items = (state: typeof queuedThree) => state.queuedItems.map((item) => `${item.behavior}:${item.text}`);
    expect([queuedThree, afterEdit, afterClear, beforeStop, finalQueue].map((state) => state.queueRevision)).toEqual([3, 4, 9, 10, 11]);
    expect(items(queuedThree)).toEqual(["followUp:first follow-up", "followUp:second follow-up", "followUp:third follow-up"]);
    const queueChanged = { code: "conflict", message: "The message queue changed. Review the latest queue and try again.", retryable: true };
    expect(staleEdit.error).toEqual(queueChanged);
    expect(unknownEdit.error).toEqual(queueChanged);
    expect(items(afterEdit)).toEqual(["followUp:third follow-up", "followUp:first follow-up"]);
    expect(wrongAbort.error).toEqual({ code: "conflict", message: "The active operation changed before it could be stopped", retryable: true });
    expect(retriedResponse.ok).toBe(true);
    expect(retriedResponse.result).toEqual(followUps[1]!.result);
    expect(afterClear.queuedItems).toEqual([]);
    expect(items(beforeStop)).toEqual(["steer:steer queued at stop"]);
    expect(finalQueue.queuedItems).toEqual([]);
    expect(userTexts.map((text) => ["hold the first run open", "third follow-up", "first follow-up", "hold the second run open",
      "hold a run to stop", "steer queued at stop"].findIndex((needle) => text.includes(needle)))).toEqual([0, 1, 2, 3, 4, 5]);
    // Every invocation receipt in file order: the replaced item, the two cleared ones and the stopped run end interrupted.
    const receipts = canonicalJsonl.flatMap((entry) => {
      const record = entry as { customType?: string; data?: { receiptKind?: string; lifecycle?: string; errorCode?: string } };
      return record.customType === "tron.chat-invocation.v1" ? [`${record.data?.receiptKind}:${record.data?.lifecycle ?? ""}:${record.data?.errorCode ?? ""}`] : [];
    });
    expect(receipts).toEqual([
      "start:staged:", "transition:accepted:", "binding::", "start:staged:", "transition:accepted:", "start:staged:", "transition:accepted:",
      "start:staged:", "transition:accepted:", "terminal:interrupted:queue-replaced", "terminal:completed:", "binding::", "terminal:completed:",
      "binding::", "terminal:completed:", "start:staged:", "transition:accepted:", "binding::", "start:staged:", "transition:accepted:",
      "start:staged:", "transition:accepted:", "terminal:interrupted:queue-cleared", "terminal:interrupted:queue-cleared", "terminal:completed:",
      "start:staged:", "transition:accepted:", "binding::", "start:staged:", "transition:accepted:", "terminal:interrupted:user-abort",
      "binding::", "terminal:completed:",
    ]);
    expectSystemShapes(canonicalJsonl, ["chat#0"]);
    expect(transcript.result).toMatchObject({ end: 14, total: 14 });
    // The transcript the client reads: each row's head, prompt lifecycle and text (or the abort reason).
    expect(transcript.result.items.map((item: { kind: string; role?: string; stopReason?: string; errorMessage?: string; semantic?: { lifecycle?: string };
      content?: Array<{ text?: string }> }) => [item.kind === "message" ? `${item.role}${item.stopReason ? `:${item.stopReason}` : ""}` : item.kind,
      item.semantic?.lifecycle ?? "", ...(item.content ?? []).map((part) => part.text), ...(item.errorMessage ? [item.errorMessage] : [])].join(" | "))).toEqual([
      "modelChange | ", "thinkingChange | ",
      "user | completed | hold the first run open", "assistant:stop |  | Held run settled.",
      "user | completed | third follow-up", "assistant:stop |  | Third follow-up answered.",
      "user | completed | first follow-up", "assistant:stop |  | First follow-up answered.",
      "user | completed | hold the second run open", "assistant:stop |  | Second held run settled.",
      "user | interrupted | hold a run to stop", "assistant:aborted |  | Request was aborted",
      "user | completed | steer queued at stop", "assistant:stop |  | Stopped steer answered.",
    ]);
    // Each request's result: every admitted prompt names its operation; the edit returns the new queue; clear and stop succeed.
    const results = (method: string) => (recorded.exchanges as Array<{ method: string; response: { ok: boolean; result: unknown } }>)
      .filter((exchange) => exchange.method === method).map((exchange) => exchange.response.ok ? exchange.response.result : "refused");
    expect(results("session.prompt")).toEqual(Array.from({ length: 10 }, () => ({ operationId: "<id>" })));
    expect(results("session.queue.replace")).toEqual(["refused", "refused", { queueRevision: 4, items: [
      { attachmentCount: 0, behavior: "followUp", id: "<id>", text: "third follow-up" }, { attachmentCount: 0, behavior: "followUp", id: "<id>", text: "first follow-up" }] }]);
    expect(results("session.clearQueue")).toEqual([{ cleared: true }]);
    expect(results("session.abort")).toEqual(["refused", { aborted: true }]);
    const receipt = "tron.chat-invocation.v1";
    expect(canonicalJsonl.map((entry) => { const { type, customType } = entry as { type?: string; customType?: string }; return type === "custom" ? customType : type; }))
      .toEqual(["session", "model_change", "thinking_level_change", "tron.context-window.v1", "tron.settings.v1", "tron.settings.v1",
        receipt, receipt, "message", "message", ...Array(8).fill(receipt), "message", receipt, "message", receipt, "message", receipt, "message", receipt,
        "message", receipt, receipt, receipt, "message", ...Array(7).fill(receipt), "message", receipt, receipt, receipt, "message", receipt, receipt, receipt,
        "message", receipt, "message", receipt, "message", receipt]);
    // The edited order reaches the model, the cleared items never do, and the steer is the turn after the stop.
    const conversation = ["user:hold the first run open", "assistant:Held run settled.", "user:third follow-up", "assistant:Third follow-up answered.",
      "user:first follow-up", "assistant:First follow-up answered.", "user:hold the second run open", "assistant:Second held run settled.",
      "user:hold a run to stop", "assistant:", "user:steer queued at stop"];
    expect(recorded.providerRequests.map((request) => request.messages.map((message) => {
      const { role, text } = message as { role: string; text?: string };
      return `${role}:${text ?? ""}`;
    }))).toEqual([1, 3, 5, 7, 9, 11].map((length) => conversation.slice(0, length)));
    expectRequestShapes(recorded.providerRequests, ["chat", "chat", "chat", "chat", "chat", "chat"]);
  }, 60_000);
});
