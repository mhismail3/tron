import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { dispatch, disposeFixtures, fixture, reportCall } from "../../test-support/home-task-fixture.js";

// The managed pi-subagents provider is loaded from a fresh install root per
// fixture. Its first load transpiles the whole extension graph (jiti's cache is
// keyed by path), so these cases run in the nested serial pass rather than
// competing with the parallel suite (see vitest.nested.config.ts).
afterEach(async () => {
  vi.restoreAllMocks();
  await disposeFixtures();
});

describe("Home task managed provider", () => {
  it.each(["report", "natural"] as const)("loads the managed provider into ordinary task workers but refuses execution (%s)", async ending => {
    const f = await fixture(undefined, false, undefined, true);
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("subagent", { action: "guide" }, { id: "managed-guide" })], { stopReason: "toolUse" }),
      fauxAssistantMessage([fauxToolCall("subagent", { agent: "missing-task-test-agent", task: "must not execute", async: false }, { id: "managed-execution" })], { stopReason: "toolUse" }),
      ending === "report" ? fauxAssistantMessage([reportCall()], { stopReason: "toolUse" }) : fauxAssistantMessage("No explicit report"),
    ]);
    const run = await dispatch(f);
    const result = await run.completion;
    const rows = (await f.registry.readTaskEvidence(run.sessionId)) as any[];
    const tools = rows.filter(row => row.type === "message" && row.message?.role === "toolResult").map(row => row.message);
    expect(tools).toContainEqual(expect.objectContaining({ toolCallId: "managed-guide", isError: false }));
    expect(tools).toContainEqual(expect.objectContaining({ toolCallId: "managed-execution", isError: true,
      content: expect.arrayContaining([expect.objectContaining({ type: "text", text: expect.stringContaining("Home tasks can't launch subagents yet") })]) }));
    expect(f.signals).toContainEqual(expect.objectContaining({ event: "home.task.producer-refused", reason: "subagent-execution" }));
    const receipts = rows.filter(row => row.type === "custom" && row.customType === "tron.chat-invocation.v1"
      && row.data?.receiptKind === "terminal" && row.data.operationId === run.operationId);
    expect(receipts).toHaveLength(1);
    // A sealed report ends the run at its turn boundary: no aborted reply, no error.
    expect(receipts[0].data).toMatchObject({ sessionId: run.sessionId, operationId: run.operationId, lifecycle: "completed" });
    expect(receipts[0].data.errorCode).toBeUndefined();
    expect(rows.some(row => row.type === "message" && row.message?.role === "assistant" && row.message.stopReason === "aborted")).toBe(false);
    expect(result.terminalEvidence?.outcome).toBe(ending === "report" ? "final" : "unknown");
    expect(f.notifications).toHaveLength(1);
    // The push names Home's openable chapter, which a tap can open.
    expect(f.notifications[0]).toMatchObject({ kind: "agent_finished", title: "Tron Home task", sessionId: f.home.sessionId });
  }, 20_000);
});
