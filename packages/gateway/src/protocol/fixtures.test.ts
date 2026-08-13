import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";
import type { SessionSnapshot } from "./types.js";

describe("shared protocol-v2 fixtures", () => {
  it("covers every projected transcript kind and reconnect state", async () => {
    const path = new URL("../../../protocol-fixtures/session-snapshot-v2.json", import.meta.url);
    const snapshot = JSON.parse(await readFile(path, "utf8")) as SessionSnapshot;
    expect(snapshot.runtimeGeneration).toBe("fixture-generation");
    expect(new Set(snapshot.transcript.map((item) => item.kind))).toEqual(new Set([
      "message", "bash", "customMessage", "customEntry", "compaction",
      "branchSummary", "modelChange", "thinkingChange", "label",
    ]));
    expect(snapshot.transcript[0]).toMatchObject({
      content: expect.arrayContaining([
        {
          id: "user-entry:2", type: "text", text: "fixture.pdf",
          attachment: { name: "fixture.pdf", mimeType: "application/pdf", size: 55_972 },
        },
      ]),
    });
    expect(snapshot.toolExecutions[0]).toMatchObject({
      toolCallId: "live-tool",
      order: 0,
      status: "running",
      output: "working\nstep two",
      progressSequence: 2,
    });
    expect(snapshot.transcript.find((item) => item.kind === "message" && item.role === "toolResult"))
      .toMatchObject({ durationMs: 1_000, progressSequence: 3 });
    expect(snapshot.extensionUI.pendingInteractions[0]).toMatchObject({ method: "select" });
    expect(snapshot.eventSequence).toBeGreaterThan(snapshot.revision);
  });
});
