import { describe, expect, it, vi } from "vitest";
import { createTronNotifyExtension, notifyTronAgentTerminal, type AgentTerminalOutcome } from "./tron-notify-extension.js";

describe("first-party Tron notifications", () => {
  it("registers only the minimal reserved tool; RuntimeSlot owns automatic terminal alerts", async () => {
    let tool: any;
    const on = vi.fn();
    const enqueue = vi.fn(async () => "queued" as const);
    await createTronNotifyExtension({
      sessionId: () => "canonical-session",
      sessionTitle: () => "Canonical title",
      machineId: "machine-abcdefgh",
      enqueue,
    })({ registerTool(value: unknown) { tool = value; }, on } as any);
    expect(on).not.toHaveBeenCalled();
    expect(tool.name).toBe("notify");
    expect(Object.keys(tool.parameters.properties)).toEqual(["message"]);
    expect(tool.parameters.additionalProperties).toBe(false);
    const result = await tool.execute("canonical-tool", { message: "Ready" });
    expect(enqueue).toHaveBeenCalledExactlyOnceWith({
      sessionId: "canonical-session", sourceId: "canonical-tool", kind: "explicit",
      title: "Canonical title", message: "Ready",
      route: { sessionId: "canonical-session", machineId: "machine-abcdefgh" },
    });
    expect(result.details).toEqual({ status: "queued" });
  });

  it.each<[AgentTerminalOutcome, string]>([
    ["completed", "The agent finished responding."],
    ["limited", "The agent reached its response limit."],
    ["failed", "The agent stopped because of an error."],
    ["stopped", "The agent was stopped."],
    ["unknown", "The agent stopped without a final response."],
    ["interrupted", "The agent was interrupted before its outcome could be confirmed."],
  ])("uses fixed, routed terminal copy for %s and receipt-only foreground suppression", async (outcome, message) => {
    const enqueue = vi.fn(async () => "queued" as const);
    const suppressAutomatic = vi.fn(async () => "suppressed" as const);
    const input = {
      sessionId: "session", sourceId: "terminal-source", sessionTitle: "Work title",
      machineId: "machine-abcdefgh", outcome, observed: false, enqueue, suppressAutomatic,
    };
    await notifyTronAgentTerminal(input);
    expect(enqueue).toHaveBeenCalledExactlyOnceWith({
      sessionId: "session", sourceId: "terminal-source", kind: "agent_finished",
      title: "Work title", message, route: { sessionId: "session", machineId: "machine-abcdefgh" },
    });
    await notifyTronAgentTerminal({ ...input, observed: true });
    expect(enqueue).toHaveBeenCalledTimes(1);
    expect(suppressAutomatic).toHaveBeenCalledExactlyOnceWith({
      sessionId: "session", sourceId: "terminal-source", kind: "agent_finished",
    });
    const { machineId: _machineId, ...unrouted } = input;
    await notifyTronAgentTerminal(unrouted);
    expect(enqueue).toHaveBeenCalledTimes(1);
  });
});
