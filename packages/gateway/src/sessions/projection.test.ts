import { describe, expect, it } from "vitest";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { BlobStore } from "./blob-store.js";
import type { SessionSnapshot } from "../protocol/types.js";
import {
  fitSessionSnapshot,
  projectJson,
  projectToolOutput,
  projectTranscript,
  projectTranscriptPage,
  projectTree,
  safeJson,
  SESSION_SNAPSHOT_BYTES,
  TRANSCRIPT_PAGE_BYTES,
  TREE_PROJECTION_BYTES,
} from "./projection.js";

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

  it("projects uploaded file envelopes as path-free attachment parts", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const entry = manager.appendMessage({
      role: "user",
      content: `Review this\n\n<attachment name="Boarding &amp; notes.pdf" mime-type="application/pdf" size="55972" path="/Users/private/content.pdf" />`,
      timestamp: 1,
    });

    const transcript = projectTranscript(manager, new BlobStore());
    expect(transcript[0]).toMatchObject({
      id: entry,
      kind: "message",
      role: "user",
      content: [
        { id: `${entry}:0`, type: "text", text: "Review this" },
        {
          id: `${entry}:1`, type: "text", text: "Boarding & notes.pdf",
          attachment: { name: "Boarding & notes.pdf", mimeType: "application/pdf", size: 55_972 },
        },
      ],
    });
    expect(JSON.stringify(transcript[0])).not.toContain("/Users/private");
  });

  it("keeps malformed attachment-like text visible without projecting its private path", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    manager.appendMessage({
      role: "user",
      content: `Literal <attachment name="unfinished" path="/Users/private/content.pdf" />`,
      timestamp: 1,
    });
    const projected = projectTranscript(manager, new BlobStore())[0];
    expect(projected).toMatchObject({
      content: [{ type: "text", text: `Literal <attachment name="unfinished" />` }],
    });
    expect(JSON.stringify(projected)).not.toContain("/Users/private");
  });

  it("projects multiple envelopes while redacting malformed neighbors", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    manager.appendMessage({
      role: "user",
      content: [
        "Before",
        `<attachment name="broken" path=/Users/private/broken.pdf />`,
        `<attachment name="one.pdf" mime-type="application/pdf" size="10" path="/owned/one.pdf" />`,
        `<attachment name="two.txt" mime-type="text/plain" size="20" path="/owned/two.txt" />`,
        "After",
      ].join("\n"),
      timestamp: 1,
    });
    const projected = projectTranscript(manager, new BlobStore())[0];
    expect(projected).toMatchObject({
      content: [
        { type: "text", text: "Before\n<attachment name=\"broken\" />" },
        { type: "text", attachment: { name: "one.pdf", size: 10 } },
        { type: "text", attachment: { name: "two.txt", size: 20 } },
        { type: "text", text: "After" },
      ],
    });
    expect(JSON.stringify(projected)).not.toContain("/Users/private");
    expect(JSON.stringify(projected)).not.toContain("/owned/");
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
    expect(tree.length).toBeGreaterThan(0);
    expect(tree.length).toBeLessThanOrEqual(1_000);
    expect(tree.at(-1)).toMatchObject({ depth: 4_999, isCurrentPath: true });
    expect(Buffer.byteLength(JSON.stringify(tree))).toBeLessThanOrEqual(TREE_PROJECTION_BYTES);
    expect(JSON.stringify(tree)).not.toContain('"children"');
  });

  it("marks abandoned branches outside the current path", () => {
    const manager = SessionManager.inMemory("/tmp/branch-history");
    const first = manager.appendMessage({ role: "user", content: "first", timestamp: 1 });
    const abandoned = manager.appendMessage({ role: "user", content: "abandoned", timestamp: 2 });
    manager.branch(first);
    const current = manager.appendMessage({ role: "user", content: "current", timestamp: 3 });

    const tree = projectTree(manager, new BlobStore());
    expect(tree.find((node) => node.id === abandoned)?.isCurrentPath).toBe(false);
    expect(tree.find((node) => node.id === current)?.isCurrentPath).toBe(true);
  });

  it("bounds arbitrary live JSON before it enters progress events", () => {
    const projected = projectJson({ output: "🙂".repeat(200_000) });
    expect(Buffer.byteLength(JSON.stringify(projected))).toBeLessThan(25_000);
    expect(projected).toMatchObject({ truncated: true });
  });

  it("projects display-safe cumulative tool output and retains the newest tail", () => {
    expect(projectToolOutput({ content: [{ type: "text", text: "building\nstep two" }] })).toEqual({
      output: "building\nstep two",
    });
    const bounded = projectToolOutput({ output: `old-${"x".repeat(80_000)}-new` }, 1_024);
    expect(bounded.outputTruncated).toBe(true);
    expect(bounded.output).toContain("earlier live output truncated");
    expect(bounded.output).toMatch(/-new$/);
    expect(Buffer.byteLength(bounded.output!)).toBeLessThanOrEqual(1_024);
  });

  it("fits pathological live snapshots while preserving run and tool identity", () => {
    const snapshot: SessionSnapshot = {
      sessionId: "session",
      runtimeGeneration: "generation",
      revision: 40,
      eventSequence: 80,
      phase: "running",
      cwd: "/tmp/project",
      thinkingLevel: "high",
      availableThinkingLevels: ["off", "high"],
      stats: {
        userMessages: 1, assistantMessages: 1, toolCalls: 6, toolResults: 0, totalMessages: 2,
        tokens: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, total: 2 }, cost: 0,
      },
      queued: { steering: [], followUp: [] },
      transcript: Array.from({ length: 12 }, (_, index) => ({
        id: `entry-${index}`,
        parentId: index === 0 ? null : `entry-${index - 1}`,
        timestamp: new Date(index).toISOString(),
        kind: "message" as const,
        role: "assistant" as const,
        content: [{ id: `entry-${index}:0`, type: "text" as const, text: "t".repeat(64_000) }],
      })),
      transcriptStart: 100,
      transcriptTotal: 112,
      operation: { id: "operation", kind: "prompt", startedAt: new Date(0).toISOString() },
      toolExecutions: Array.from({ length: 6 }, (_, index) => ({
        toolCallId: `tool-${index}`,
        toolName: "bash",
        order: index,
        status: "running" as const,
        arguments: { command: "x".repeat(150_000) },
        partialResult: { output: "y".repeat(150_000) },
        isError: false,
        startedAt: new Date(index).toISOString(),
        updatedAt: new Date(index).toISOString(),
        lastProgressAt: new Date(index).toISOString(),
        progressSequence: index + 1,
      })),
      extensionUI: {
        statuses: {}, working: { visible: true }, widgets: [], editorRevision: 0,
        editorText: "", pendingInteractions: [],
      },
      diagnostics: [],
    };

    const fitted = fitSessionSnapshot(snapshot);
    expect(Buffer.byteLength(JSON.stringify(fitted))).toBeLessThanOrEqual(SESSION_SNAPSHOT_BYTES);
    expect(fitted).toMatchObject({ phase: "running", operation: { id: "operation" } });
    expect(fitted.toolExecutions.map(({ toolCallId, order }) => ({ toolCallId, order }))).toEqual(
      Array.from({ length: 6 }, (_, index) => ({ toolCallId: `tool-${index}`, order: index })),
    );
    expect(fitted.transcriptStart).toBe(snapshot.transcriptStart);
    expect(fitted.transcript.map((item) => item.id)).toEqual(snapshot.transcript.map((item) => item.id));
  });

  it("allows only resumed idle snapshots to trim canonical rows under pressure", () => {
    const snapshot: SessionSnapshot = {
      sessionId: "idle-session", runtimeGeneration: "generation", revision: 1, eventSequence: 1,
      phase: "idle", cwd: "/tmp/project", thinkingLevel: "high", availableThinkingLevels: ["high"],
      stats: {
        userMessages: 10, assistantMessages: 0, toolCalls: 0, toolResults: 0, totalMessages: 10,
        tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }, cost: 0,
      },
      queued: { steering: [], followUp: [] },
      transcript: Array.from({ length: 10 }, (_, index) => ({
        id: `idle-${index}`, parentId: index ? `idle-${index - 1}` : null,
        timestamp: new Date(index).toISOString(), kind: "message" as const, role: "user" as const,
        content: [{ id: `idle-${index}:0`, type: "text" as const, text: "x".repeat(64_000) }],
      })),
      transcriptStart: 0, transcriptTotal: 10, toolExecutions: [],
      extensionUI: { statuses: {}, working: { visible: false }, widgets: [], editorRevision: 0, editorText: "", pendingInteractions: [] },
      diagnostics: [],
    };

    const fitted = fitSessionSnapshot(snapshot, 180_000);
    expect(fitted.transcriptStart).toBeGreaterThan(0);
    expect(fitted.transcriptStart + fitted.transcript.length).toBe(snapshot.transcriptTotal);
  });

  it("advances a page containing one projected item above the requested page target", () => {
    const manager = SessionManager.inMemory("/tmp/oversized-page-item");
    manager.appendMessage({ role: "user", content: "x".repeat(2_000), timestamp: 1 });
    const page = projectTranscriptPage(manager, new BlobStore(), undefined, 1_024);
    expect(page.start).toBe(0);
    expect(page.total).toBe(1);
    expect(page.items).toHaveLength(1);
    expect(Buffer.byteLength(JSON.stringify(page.items))).toBeLessThanOrEqual(1_024);
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

    const earlier = projectTranscriptPage(manager, blobs, tail.start, TRANSCRIPT_PAGE_BYTES, tail.items[0]?.id);
    expect(earlier.start).toBeLessThan(tail.start);
    expect(earlier.items.at(-1)?.id).not.toBe(tail.items[0]?.id);
    expect(() => projectTranscriptPage(manager, blobs, tail.start, TRANSCRIPT_PAGE_BYTES, "stale-anchor")).toThrow("anchor changed");
    expect(Buffer.byteLength(JSON.stringify(earlier.items))).toBeLessThanOrEqual(TRANSCRIPT_PAGE_BYTES);
  });
});
