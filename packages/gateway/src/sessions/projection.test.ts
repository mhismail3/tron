import { describe, expect, it } from "vitest";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { BlobStore } from "./blob-store.js";
import { projectTranscript, projectTranscriptPage, projectTree, safeJson, TRANSCRIPT_PAGE_BYTES } from "./projection.js";

describe("transcript projection", () => {
  it("preserves Pi entry IDs and branch order", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const first = manager.appendMessage({ role: "user", content: "hello", timestamp: 1 });
    manager.appendMessage({
      role: "assistant",
      content: [{ type: "text", text: "world" }],
      api: "openai-responses",
      provider: "test",
      model: "model",
      usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
      stopReason: "stop",
      timestamp: 2,
    });
    const assistant = manager.getLeafId()!;
    const modelChange = manager.appendModelChange("provider", "next-model");
    manager.appendCustomEntry("state", { count: 1 });
    manager.appendLabelChange(assistant, "checkpoint");
    const transcript = projectTranscript(manager, new BlobStore());
    expect(transcript.map((item) => item.id)).toEqual([first, assistant, modelChange, manager.getEntries()[3]!.id, manager.getLeafId()]);
    expect(transcript[0]).toMatchObject({
      kind: "message",
      content: [{ id: `${first}:0`, type: "text", text: "hello" }],
    });
    expect(transcript[2]).toMatchObject({ kind: "modelChange", modelRef: { provider: "provider", id: "next-model" } });
    expect(transcript[3]).toMatchObject({ kind: "customEntry", customType: "state", data: { count: 1 } });
    expect(transcript[4]).toMatchObject({ kind: "label", targetId: assistant, label: "checkpoint" });
  });

  it("bounds cycles in extension-owned details", () => {
    const value: Record<string, unknown> = {};
    value.self = value;
    expect(safeJson(value)).toEqual({ self: "[circular]" });
  });

  it("projects deep history without recursive stack overflow", () => {
    const manager = SessionManager.inMemory("/tmp/deep-history");
    for (let index = 0; index < 5_000; index += 1) {
      manager.appendMessage({ role: "user", content: `message ${index}`, timestamp: index });
    }
    const tree = projectTree(manager, new BlobStore());
    let count = 0;
    let nodes = tree;
    while (nodes.length > 0) {
      count += nodes.length;
      nodes = nodes.flatMap((node) => node.children);
    }
    expect(count).toBe(4_000);
  });

  it("pages large canonical branches without exceeding the snapshot frame budget", () => {
    const manager = SessionManager.inMemory("/tmp/large-project");
    for (let index = 0; index < 24; index += 1) {
      manager.appendMessage({ role: "user", content: `${index}: ${"x".repeat(100_000)}`, timestamp: index });
    }
    const blobs = new BlobStore();
    const tail = projectTranscriptPage(manager, blobs);
    expect(tail.start).toBeGreaterThan(0);
    expect(tail.total).toBe(24);
    expect(Buffer.byteLength(JSON.stringify(tail.items))).toBeLessThanOrEqual(TRANSCRIPT_PAGE_BYTES);

    const earlier = projectTranscriptPage(manager, blobs, tail.start);
    expect(earlier.start).toBeLessThan(tail.start);
    expect(earlier.items.at(-1)?.id).not.toBe(tail.items[0]?.id);
    expect(Buffer.byteLength(JSON.stringify(earlier.items))).toBeLessThanOrEqual(TRANSCRIPT_PAGE_BYTES);
  });
});
