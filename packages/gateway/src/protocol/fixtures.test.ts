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
    expect(snapshot.toolExecutions[0]).toMatchObject({ toolCallId: "live-tool", status: "running" });
    expect(snapshot.extensionUI.pendingInteractions[0]).toMatchObject({ method: "select" });
    expect(snapshot.eventSequence).toBeGreaterThan(snapshot.revision);
  });
});
