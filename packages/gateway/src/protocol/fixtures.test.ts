import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";
import type { SessionSnapshot } from "./types.js";

describe("shared protocol-v3 fixtures", () => {
  it("covers every projected transcript kind and reconnect state", async () => {
    const path = new URL("../../../protocol-fixtures/session-snapshot-v3.json", import.meta.url);
    const snapshot = JSON.parse(await readFile(path, "utf8")) as SessionSnapshot;
    expect(snapshot.runtimeGeneration).toBe("fixture-generation");
    expect(snapshot.transcriptStart).toBe(0);
    expect(snapshot.transcriptTotal).toBe(snapshot.transcript.length);
    expect(snapshot.transcriptTotal).toBe(11);
    expect(snapshot.extensionPresentation).toBeDefined();
    expect(snapshot.toolExecutions).toBeDefined();
    expect(snapshot.diagnostics).toBeDefined();
    expect(new Set(snapshot.transcript.map((item) => item.kind))).toEqual(new Set([
      "message", "bash", "customMessage", "customEntry", "compaction",
      "branchSummary", "modelChange", "thinkingChange", "label",
    ]));
    expect(snapshot.transcript[0]).toMatchObject({
      content: expect.arrayContaining([
        {
          id: "user-entry:2", ordinal: 2, type: "text", text: "fixture.pdf",
          attachment: { name: "fixture.pdf", mimeType: "application/pdf", size: 55_972 },
        },
      ]),
    });
    const assistant = snapshot.transcript.find(
      (item) => item.kind === "message" && item.role === "assistant",
    );
    expect(assistant).toMatchObject({
      presentationId: "assistant-entry",
      content: expect.arrayContaining([
        expect.objectContaining({ ordinal: 0, thinkingRunOrdinal: 0, type: "thinking" }),
      ]),
    });
    expect(snapshot.streaming).toMatchObject({ presentationId: "streaming" });
    expect(snapshot.toolExecutions[0]).toMatchObject({
      toolCallId: "live-tool",
      order: 0,
      status: "running",
      output: "working\nstep two",
      progressSequence: 2,
    });
    expect(snapshot.transcript.find((item) => item.kind === "message" && item.role === "toolResult"))
      .toMatchObject({ durationMs: 1_000, progressSequence: 3 });
    expect(snapshot.extensionPresentation).toMatchObject({ version: 2, hostEpoch: "fixture-host-epoch", revision: 9, semanticState: { toolsExpanded: true } });
    expect(snapshot.extensionPresentation.surfaces[0]).toMatchObject({ id: "fixture-surface", kind: "unknown", frame: { plainText: "Readable fallback" } });
    expect(snapshot.extensionPresentation.inputLease).toMatchObject({ id: "fixture-lease", surfaceRevision: 1 });
    expect(snapshot.extensionPresentation.pendingInteractions[0]).toMatchObject({ method: "select", hostEpoch: "fixture-host-epoch", presentationRevision: 9 });
    expect(snapshot.queueRevision).toBe(3);
    expect(snapshot.queuedItems).toEqual([
      { id: "queued-steer", behavior: "steer", text: "correct course", attachmentCount: 0 },
      { id: "queued-follow-up", behavior: "followUp", text: "then verify", attachmentCount: 0 },
    ]);
    expect(snapshot.eventSequence).toBeGreaterThan(snapshot.revision);
  });
});
