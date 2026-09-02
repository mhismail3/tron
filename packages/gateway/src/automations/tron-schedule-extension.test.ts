import { describe, expect, it, vi } from "vitest";
import { createTronScheduleExtension } from "./tron-schedule-extension.js";

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
    });
    expect(tool.name).toBe("schedule");
    expect(tool.executionMode).toBe("sequential");
    expect(operations.execute).toHaveBeenCalledWith("session-one", "tool-call-one", expect.objectContaining({ action: "create" }));
    expect(result).toMatchObject({ content: [{ type: "text", text: "Created automation." }] });
  });
});
