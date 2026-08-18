import { describe, expect, it } from "vitest";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import { BlobStore } from "./blob-store.js";
import type { SessionSnapshot } from "../protocol/types.js";
import {
  admitCommandCatalog,
  COMMAND_CATALOG_BYTES,
  COMMAND_CATALOG_ITEMS,
  COMMAND_CATALOG_STRING_BYTES,
  fitSessionSnapshot,
  projectJson,
  projectMessage,
  projectToolOutput,
  projectTranscript,
  projectTranscriptPage,
  projectTree,
  safeJson,
  SESSION_SNAPSHOT_BYTES,
  TRANSCRIPT_PAGE_BYTES,
  TRANSCRIPT_PAGE_ITEMS,
  TREE_PROJECTION_BYTES,
} from "./projection.js";

describe("catalog projection admission", () => {
  it("admits command catalogs atomically without changing their order", () => {
    const commands = [
      { name: "zeta", source: "prompt" as const, argumentHint: "[value]" },
      { name: "alpha", source: "extension" as const, description: "Alpha" },
    ];
    expect(admitCommandCatalog(commands)).toBe(commands);
    expect(admitCommandCatalog(commands).map((command) => command.name)).toEqual(["zeta", "alpha"]);
  });

  it("rejects duplicate, malformed, count-excess, and byte-excess command catalogs", () => {
    expect(() => admitCommandCatalog([
      { name: "same", source: "skill" },
      { name: "same", source: "skill", description: "duplicate" },
    ])).toThrow(/duplicate/);
    expect(() => admitCommandCatalog([{ name: "", source: "prompt" }])).toThrow(/invalid/);
    expect(() => admitCommandCatalog([{
      name: "valid", source: "prompt", sourcePath: "x".repeat(COMMAND_CATALOG_STRING_BYTES + 1),
    }])).toThrow(/invalid/);
    expect(() => admitCommandCatalog(Array.from({ length: COMMAND_CATALOG_ITEMS + 1 }, (_, index) => ({
      name: `command-${index}`, source: "extension" as const,
    })))).toThrow(/item limit/);
    expect(() => admitCommandCatalog(Array.from({ length: 100 }, (_, index) => ({
      name: `command-${index}`, source: "prompt" as const,
      description: "x".repeat(Math.ceil(COMMAND_CATALOG_BYTES / 100)),
    })))).toThrow(/byte limit/);
  });
});

describe("transcript projection", () => {
  it("retains optional extension provenance only in the disposable tool projection", () => {
    const message: AgentMessage = {
      role: "toolResult",
      toolCallId: "call-extension",
      toolName: "example-tool",
      content: [{ type: "text", text: "done" }],
      isError: false,
      timestamp: 1,
    };
    const projected = projectMessage(
      "result",
      null,
      "2026-01-01T00:00:00Z",
      message,
      new BlobStore(),
      {
        startedAt: "2026-01-01T00:00:00Z",
        lastProgressAt: "2026-01-01T00:00:01Z",
        progressSequence: 1,
        extensionOrigin: { source: "public-source" },
      },
    );
    expect(projected).toMatchObject({ extensionOrigin: { source: "public-source" } });
  });

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

  it("omits oversized or capacity-excess images without failing the snapshot", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const entry = manager.appendMessage({
      role: "user",
      content: [
        { type: "image", data: Buffer.from("one").toString("base64"), mimeType: "image/png" },
        { type: "image", data: Buffer.from("two").toString("base64"), mimeType: "image/png" },
      ],
      timestamp: 1,
    });
    const blobs = new BlobStore({ maximumItemBytes: 3, maximumItems: 1, maximumTotalBytes: 3 });
    const projected = projectTranscript(manager, blobs)[0];
    expect(projected).toMatchObject({
      id: entry,
      content: [
        { id: `${entry}:0`, type: "image" },
        { id: `${entry}:1`, type: "text", text: "Image omitted from this bounded mobile projection" },
      ],
    });
    const firstBlob = projected?.kind === "message" && projected.content[0]?.type === "image"
      ? projected.content[0].blobId
      : "";
    expect(blobs.get(firstBlob).data.toString()).toBe("one");

    const oversized = SessionManager.inMemory("/tmp/project");
    oversized.appendMessage({
      role: "user",
      content: [{ type: "image", data: Buffer.from("four").toString("base64"), mimeType: "image/png" }],
      timestamp: 2,
    });
    expect(projectTranscript(oversized, blobs)[0]).toMatchObject({
      content: [{ type: "text", text: "Image omitted from this bounded mobile projection" }],
    });
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
    expect(tree).toHaveLength(1_000);
    expect(tree[0]).toMatchObject({ depth: 4_000, isCurrentPath: true });
    expect(tree.at(-1)).toMatchObject({ depth: 4_999, isCurrentPath: true });
    expect(Buffer.byteLength(JSON.stringify(tree))).toBeLessThanOrEqual(TREE_PROJECTION_BYTES);
    expect(JSON.stringify(tree)).not.toContain('"children"');
  });

  it("rejects duplicate canonical tree IDs and oversized retained strings", () => {
    const duplicate = SessionManager.inMemory("/tmp/duplicate-tree-id");
    duplicate.appendMessage({ role: "user", content: "one", timestamp: 1 });
    const entry = duplicate.getEntries()[0]!;
    const duplicateEntries = {
      getTree: () => duplicate.getTree(),
      getBranch: () => duplicate.getBranch(),
      getEntries: () => [entry, entry],
    } as unknown as SessionManager;
    expect(() => projectTree(duplicateEntries, new BlobStore())).toThrow(/duplicate canonical entry ID/);

    const oversized = SessionManager.inMemory("/tmp/oversized-tree-string");
    oversized.appendCustomEntry("x".repeat(8_193), {});
    expect(() => projectTree(oversized, new BlobStore())).toThrow(/oversized string/);

    const malformedTimestamp = SessionManager.inMemory("/tmp/malformed-tree-timestamp");
    malformedTimestamp.appendMessage({ role: "user", content: "message", timestamp: 1 });
    const malformedEntry = malformedTimestamp.getEntries()[0]! as { timestamp: string };
    malformedEntry.timestamp = "not-a-timestamp";
    expect(() => projectTree(malformedTimestamp, new BlobStore())).toThrow(/invalid or oversized string/);
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
      extensionPresentation: {
        version: 2, hostEpoch: "test-host", revision: 0, capabilities: [], diagnostics: [],
        semanticState: { statuses: {}, working: { visible: true, indicator: { kind: "default", frames: [] } }, widgets: [], toolsExpanded: false, editorRevision: 0, editorText: "" },
        surfaces: [], pendingInteractions: [],
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

    const tinySnapshot: SessionSnapshot = {
      ...snapshot,
      transcript: Array.from({ length: 1_200 }, (_, index) => ({
        id: `tiny-${index}`, parentId: index ? `tiny-${index - 1}` : null,
        timestamp: new Date(index).toISOString(), kind: "message" as const, role: "user" as const,
        content: [{ id: `tiny-${index}:0`, type: "text" as const, text: "x" }],
      })),
      transcriptStart: 0,
      transcriptTotal: 1_200,
      toolExecutions: [],
    };
    const fittedTiny = fitSessionSnapshot(tinySnapshot);
    expect(fittedTiny.transcript).toHaveLength(TRANSCRIPT_PAGE_ITEMS);
    expect(fittedTiny.transcriptStart).toBe(1_200 - TRANSCRIPT_PAGE_ITEMS);
    expect(fittedTiny.transcriptStart + fittedTiny.transcript.length).toBe(fittedTiny.transcriptTotal);
    expect(safeJson(fittedTiny)).toEqual(fittedTiny);
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
      extensionPresentation: { version: 2, hostEpoch: "test-host", revision: 0, capabilities: [], diagnostics: [], semanticState: { statuses: {}, working: { visible: false, indicator: { kind: "default", frames: [] } }, widgets: [], toolsExpanded: false, editorRevision: 0, editorText: "" }, surfaces: [], pendingInteractions: [] },
      diagnostics: [],
    };

    const fitted = fitSessionSnapshot(snapshot, 180_000);
    expect(fitted.transcriptStart).toBeGreaterThan(0);
    expect(fitted.transcriptStart + fitted.transcript.length).toBe(snapshot.transcriptTotal);
  });

  it("preserves actionable interaction identity before decorative surfaces under snapshot pressure", () => {
    const snapshot: SessionSnapshot = {
      sessionId: "pressure", runtimeGeneration: "generation", revision: 1, eventSequence: 1,
      phase: "idle", cwd: "/tmp/project", thinkingLevel: "off", availableThinkingLevels: ["off"],
      stats: { userMessages: 0, assistantMessages: 0, toolCalls: 0, toolResults: 0, totalMessages: 0,
        tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }, cost: 0 },
      queued: { steering: [], followUp: [] }, transcript: [], transcriptStart: 0, transcriptTotal: 0,
      toolExecutions: [], diagnostics: [],
      extensionPresentation: {
        version: 2, hostEpoch: "host", revision: 4, capabilities: [], diagnostics: [],
        semanticState: { statuses: { decorative: "x".repeat(40_000) }, working: { visible: true, indicator: { kind: "default", frames: [] } }, widgets: [], toolsExpanded: false, editorRevision: 0, editorText: "" },
        surfaces: [{
          id: "decorative", kind: "widget", placement: "aboveEditor", lifecycle: "retained", revision: 5,
          focused: false, inputMode: "none",
          frame: { width: 160, height: 1, plainText: "x".repeat(60_000), lines: [{ plainText: "x".repeat(60_000), runs: [{ text: "x".repeat(60_000), style: {} }] }] },
        }, {
          id: "blocking", kind: "overlay", placement: "overlay", lifecycle: "blocking", revision: 3,
          focused: true, inputMode: "keys",
          frame: { width: 160, height: 1, plainText: "confirm", lines: [{ plainText: "confirm", runs: [{ text: "confirm", style: {} }] }] },
        }],
        inputLease: { id: "lease", connectionId: "connection", surfaceId: "blocking", surfaceRevision: 3, acquiredAt: new Date(0).toISOString() },
        pendingInteractions: [{ id: "interaction", hostEpoch: "host", presentationRevision: 4, method: "confirm", title: "Confirm" }],
      },
    };
    const fitted = fitSessionSnapshot(snapshot, 100_000);
    expect(fitted.extensionPresentation.pendingInteractions).toHaveLength(1);
    expect(fitted.extensionPresentation.surfaces.map((surface) => surface.id)).toEqual(["blocking"]);
    expect(fitted.extensionPresentation.inputLease?.surfaceId).toBe("blocking");
    expect(fitted.extensionPresentation.projection).toMatchObject({
      complete: false,
      omittedSurfaces: [{ id: "decorative", revision: 5 }],
    });
    expect(fitted.extensionPresentation.diagnostics.at(-1)?.code).toContain("projection.");
  });

  it("retains the revisioned editor baseline when decorative presentation is omitted", () => {
    const editorText = "draft\n".repeat(1_000);
    const snapshot: SessionSnapshot = {
      sessionId: "editor-pressure", runtimeGeneration: "generation", revision: 1, eventSequence: 1,
      phase: "idle", cwd: "/tmp/project", thinkingLevel: "off", availableThinkingLevels: ["off"],
      stats: { userMessages: 0, assistantMessages: 0, toolCalls: 0, toolResults: 0, totalMessages: 0,
        tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }, cost: 0 },
      queued: { steering: [], followUp: [] }, transcript: [], transcriptStart: 0, transcriptTotal: 0,
      toolExecutions: [], diagnostics: [],
      extensionPresentation: {
        version: 2, hostEpoch: "host", revision: 9, capabilities: [], diagnostics: [],
        semanticState: {
          statuses: { decorative: "x".repeat(40_000) },
          working: { visible: false, indicator: { kind: "default", frames: [] } },
          widgets: [], toolsExpanded: false, editorRevision: 7, editorText,
        },
        surfaces: [], pendingInteractions: [],
      },
    };

    const fitted = fitSessionSnapshot(snapshot, 16_000);
    expect(fitted.extensionPresentation.semanticState.statuses).toEqual({});
    expect(fitted.extensionPresentation.semanticState.editorRevision).toBe(7);
    expect(fitted.extensionPresentation.semanticState.editorText).toBe(editorText);
    expect(fitted.extensionPresentation.projection?.omitted).not.toContain("editorText");
  });

  it("advances a page containing one projected item above the requested page target", () => {
    const manager = SessionManager.inMemory("/tmp/oversized-page-item");
    manager.appendMessage({ role: "user", content: "x".repeat(2_000), timestamp: 1 });
    const page = projectTranscriptPage(manager, new BlobStore(), undefined, 1_024);
    expect(page.start).toBe(0);
    expect(page.end).toBe(1);
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
    expect(tail.end).toBe(24);
    expect(tail.total).toBe(24);
    expect(Buffer.byteLength(JSON.stringify(tail.items))).toBeLessThanOrEqual(TRANSCRIPT_PAGE_BYTES);

    const earlier = projectTranscriptPage(manager, blobs, tail.start, TRANSCRIPT_PAGE_BYTES, tail.items[0]?.id);
    expect(earlier.start).toBeLessThan(tail.start);
    expect(earlier.end).toBe(tail.start);
    expect(earlier.items.at(-1)?.id).not.toBe(tail.items[0]?.id);
    expect(() => projectTranscriptPage(manager, blobs, tail.start, TRANSCRIPT_PAGE_BYTES, "stale-anchor")).toThrow("anchor changed");
    expect(Buffer.byteLength(JSON.stringify(earlier.items))).toBeLessThanOrEqual(TRANSCRIPT_PAGE_BYTES);
  });

  it("caps nested content before generic JSON projection can truncate it", () => {
    const manager = SessionManager.inMemory("/tmp/tiny-content-parts");
    manager.appendMessage({
      role: "user",
      content: Array.from({ length: 1_100 }, () => ({ type: "text", text: "x" })) as never,
      timestamp: 1,
    });

    const page = projectTranscriptPage(manager, new BlobStore());
    expect(page.items).toHaveLength(1);
    const item = page.items[0]!;
    expect(item.kind).toBe("message");
    if (item.kind !== "message") throw new Error("expected message");
    expect(item.content).toHaveLength(1_000);
    expect(item.content.at(-1)).toMatchObject({ type: "text", text: expect.stringContaining("omitted") });
    expect(safeJson(page)).toEqual(page);
  });

  it("caps tiny-item pages before generic JSON projection can truncate them", () => {
    const manager = SessionManager.inMemory("/tmp/tiny-page-items");
    for (let index = 0; index < 1_200; index += 1) {
      manager.appendMessage({ role: "user", content: "x", timestamp: index });
    }
    manager.appendMessage({
      role: "custom", customType: "hidden-runtime", content: [], display: false,
      timestamp: 1_201,
    } as never);

    const page = projectTranscriptPage(manager, new BlobStore());
    expect(page.items).toHaveLength(TRANSCRIPT_PAGE_ITEMS);
    expect(page.end).toBe(1_200);
    expect(page.start).toBe(page.end - page.items.length);
    expect(safeJson(page)).toEqual(page);
  });
});
