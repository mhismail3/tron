import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { dispatch, disposeFixtures, fixture, reportCall } from "../../../../test-support/home-task-fixture.js";

afterEach(async () => {
  vi.restoreAllMocks();
  await disposeFixtures();
});

describe("Home task managed provider", () => {
  it.each(["report", "natural"] as const)("loads the managed provider into task workers and admits a launch the provider then rejects (%s)", async ending => {
    const f = await fixture(undefined, false, undefined, true);
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("subagent", { action: "guide" }, { id: "managed-guide" })], { stopReason: "toolUse" }),
      fauxAssistantMessage([fauxToolCall("subagent", { agent: "missing-task-test-agent", task: "must not execute", async: false }, { id: "managed-execution" })], { stopReason: "toolUse" }),
      ...(ending === "report"
        ? [fauxAssistantMessage([reportCall()], { stopReason: "toolUse" })]
        : [fauxAssistantMessage("No explicit report"), fauxAssistantMessage("Still no explicit report")]),
    ]);
    const run = await dispatch(f);
    const result = await run.completion;
    const rows = (await f.registry.readTaskEvidence(run.sessionId)) as any[];
    const tools = rows.filter(row => row.type === "message" && row.message?.role === "toolResult").map(row => row.message);
    expect(tools).toContainEqual(expect.objectContaining({ toolCallId: "managed-guide", isError: false }));
    expect(tools).toContainEqual(expect.objectContaining({ toolCallId: "managed-execution", isError: true,
      content: expect.arrayContaining([expect.objectContaining({ type: "text", text: expect.stringContaining("missing-task-test-agent") })]) }));
    expect(f.signals.filter(signal => signal.event === "home.task.producer-refused")).toEqual([]);
    const receipts = rows.filter(row => row.type === "custom" && row.customType === "tron.chat-invocation.v1"
      && row.data?.receiptKind === "terminal" && row.data.operationId === run.operationId);
    expect(receipts).toHaveLength(1);
    expect(receipts[0].data).toMatchObject({ sessionId: run.sessionId, operationId: run.operationId, lifecycle: "completed" });
    expect(receipts[0].data.errorCode).toBeUndefined();
    expect(rows.some(row => row.type === "message" && row.message?.role === "assistant" && row.message.stopReason === "aborted")).toBe(false);
    expect(result.terminalEvidence?.outcome).toBe(ending === "report" ? "final" : "unknown");
    expect(f.notifications).toHaveLength(1);
    expect(f.notifications[0]).toMatchObject({ kind: "agent_finished", title: "Home", sessionId: f.home.sessionId });
  }, 20_000);
});
