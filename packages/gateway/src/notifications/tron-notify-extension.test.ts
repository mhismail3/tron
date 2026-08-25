import { describe, expect, it } from "vitest";
import { createTronNotifyExtension } from "./tron-notify-extension.js";

function fixture() {
  let tool: any;
  const handlers = new Map<string, (event: any, ctx: any) => any>();
  const admitted: any[] = [];
  const factory = createTronNotifyExtension({
    sessionId: () => "canonical-session",
    sessionTitle: () => "Canonical title",
    machineId: "machine-abcdefgh",
    enqueue: async (input) => { admitted.push(input); return "queued"; },
  });
  return {
    tool: () => tool,
    handlers,
    admitted,
    load: () => factory({
      registerTool(value: unknown) { tool = value; },
      on(name: string, handler: (event: any, ctx: any) => any) { handlers.set(name, handler); },
    } as any),
  };
}

const assistant = (id: string, stopReason: string) => ({
  id,
  type: "message",
  message: { role: "assistant", stopReason },
});

describe("first-party Tron notify extension", () => {
  it("registers one minimal reserved tool and sends the exact settled completion route", async () => {
    const value = fixture();
    await value.load();
    const tool = value.tool();
    expect(tool.name).toBe("notify");
    expect(Object.keys(tool.parameters.properties)).toEqual(["message"]);
    expect(tool.parameters.additionalProperties).toBe(false);
    const result = await tool.execute("canonical-tool", { message: "Ready" });
    expect(value.admitted[0]).toEqual({ sessionId: "canonical-session", sourceId: "canonical-tool", kind: "explicit", message: "Ready" });
    expect(result.details).toEqual({ status: "queued" });

    value.handlers.get("agent_start")?.({}, {});
    value.handlers.get("agent_end")?.({ messages: [{ role: "assistant", stopReason: "stop" }] }, {});
    await value.handlers.get("agent_settled")?.({}, {
      isIdle: () => true,
      sessionManager: { getBranch: () => [assistant("assistant-entry", "stop")] },
    });
    expect(value.admitted[1]).toEqual({
      sessionId: "canonical-session",
      sourceId: "assistant-entry",
      kind: "agent_finished",
      title: "Canonical title",
      message: "The agent finished responding.",
      route: { sessionId: "canonical-session", machineId: "machine-abcdefgh" },
    });
  });

  it("waits through an overlapping continuation and notifies only its final response", async () => {
    const value = fixture();
    await value.load();
    value.handlers.get("agent_start")?.({}, {});
    value.handlers.get("agent_end")?.({ messages: [{ role: "assistant", stopReason: "stop" }] }, {});
    // Another extension starts run B before run A's settled handlers finish.
    value.handlers.get("agent_start")?.({}, {});
    await value.handlers.get("agent_settled")?.({}, {
      isIdle: () => false,
      sessionManager: { getBranch: () => [assistant("assistant-a", "stop")] },
    });
    expect(value.admitted).toEqual([]);

    value.handlers.get("agent_end")?.({ messages: [{ role: "assistant", stopReason: "stop" }] }, {});
    await value.handlers.get("agent_settled")?.({}, {
      isIdle: () => true,
      sessionManager: { getBranch: () => [assistant("assistant-a", "stop"), assistant("assistant-b", "stop")] },
    });
    expect(value.admitted).toHaveLength(1);
    expect(value.admitted[0]).toMatchObject({ sourceId: "assistant-b", kind: "agent_finished" });
  });

  it("does not reuse an earlier success when the final continuation fails", async () => {
    const value = fixture();
    await value.load();
    value.handlers.get("agent_start")?.({}, {});
    value.handlers.get("agent_end")?.({ messages: [{ role: "assistant", stopReason: "stop" }] }, {});
    value.handlers.get("agent_start")?.({}, {});
    value.handlers.get("agent_end")?.({ messages: [{ role: "assistant", stopReason: "error" }] }, {});
    await value.handlers.get("agent_settled")?.({}, {
      isIdle: () => true,
      sessionManager: { getBranch: () => [assistant("success", "stop"), assistant("failed", "error")] },
    });
    expect(value.admitted).toEqual([]);
  });
});
