import { describe, expect, it } from "vitest";
import { createTronNotifyExtension } from "./tron-notify-extension.js";

describe("first-party Tron notify extension", () => {
  it("registers one minimal reserved tool and passes only canonical runtime identity to its closure", async () => {
    let tool: any;
    let admitted: unknown;
    const factory = createTronNotifyExtension({
      sessionId: () => "canonical-session",
      enqueue: async (input) => { admitted = input; return "queued"; },
    });
    await factory({ registerTool(value: unknown) { tool = value; } } as any);
    expect(tool.name).toBe("notify");
    expect(Object.keys(tool.parameters.properties)).toEqual(["message"]);
    expect(tool.parameters.additionalProperties).toBe(false);
    const result = await tool.execute("canonical-tool", { message: "Ready" });
    expect(admitted).toEqual({ sessionId: "canonical-session", toolCallId: "canonical-tool", kind: "explicit", message: "Ready" });
    expect(result.details).toEqual({ status: "queued" });
  });
});
