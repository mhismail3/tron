import { describe, expect, it, vi } from "vitest";
import { createTronScheduleExtension } from "./tron-schedule-extension.js";
import { withInvocationContext } from "../extensions/owner-attribution.js";

function fixture() {
  let tool: any;
  const operations = { execute: vi.fn(async () => ({ message: "Created automation.", details: { id: "automation-one" } })) };
  const factory = createTronScheduleExtension({ sessionId: () => "session-one", operations });
  factory({ registerTool(definition: unknown) { tool = definition; } } as any);
  return { tool, operations };
}

describe("Tron schedule extension", () => {
  it("registers a bounded first-party schedule tool", async () => {
    const { tool, operations } = fixture();
    const result = await tool.execute("tool-call-one", {
      action: "create", name: "Review", prompt: "Review", everyMinutes: 60, activate: true,
    }, undefined, undefined, { hasUI: true, ui: { confirm: vi.fn(async () => true) } });
    expect(tool.name).toBe("schedule");
    expect(tool.executionMode).toBe("sequential");
    expect(operations.execute).toHaveBeenCalledWith("session-one", "tool-call-one", expect.objectContaining({ action: "create" }));
    expect(result).toMatchObject({ content: [{ type: "text", text: "Created automation." }] });
  });

  it("requires confirmation and blocks recursive automation mutation", async () => {
    const { tool, operations } = fixture();
    const declined = await tool.execute("tool-call-two", {
      action: "pause", automationId: "automation-one", expectedRevision: 1,
    }, undefined, undefined, { hasUI: true, ui: { confirm: vi.fn(async () => false) } });
    expect(declined.details).toEqual({ cancelled: true });
    expect(operations.execute).not.toHaveBeenCalled();

    await expect(withInvocationContext(
      { invocationId: "invocation-one", operationId: "automation:10000000-0000-4000-8000-000000000001" },
      () => tool.execute("tool-call-three", {
        action: "enable", automationId: "automation-one", expectedRevision: 1,
      }, undefined, undefined, { hasUI: true, ui: { confirm: vi.fn(async () => true) } }),
    )).rejects.toThrow("cannot mutate automations");
  });
});
