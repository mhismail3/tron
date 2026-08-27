import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import { BlobStore } from "./blob-store.js";
import { EXTENSION_ACTIVITY_RECEIPT_TYPE } from "./extension-activity-history.js";
import { SESSION_INPUT_RECEIPT_TYPE, makeSessionInputReceipt } from "./session-input-receipts.js";
import type { SessionSnapshot, TranscriptItem } from "../protocol/types.js";
import {
  admitCommandCatalog,
  boundCommandContent,
  boundStreamingProgressItem,
  canonicalToolResultCallIDs,
  COMMAND_CATALOG_BYTES,
  COMMAND_CATALOG_ITEMS,
  COMMAND_CATALOG_STRING_BYTES,
  COMMAND_DETAIL_CONTENT_BYTES,
  fitSessionSnapshot,
  STREAMING_PROGRESS_BYTES,
  projectJson,
  projectMessage,
  projectSkillInvocation,
  mergeLiveToolOutput,
  MINIMUM_TRANSCRIPT_CONTINUITY_MESSAGES,
  projectToolOutput,
  projectTranscript,
  projectTranscriptPage,
  projectTree,
  safeJson,
  SESSION_SNAPSHOT_BYTES,
  TRANSCRIPT_PAGE_BYTES,
  TRANSCRIPT_PAGE_ITEMS,
  TREE_PROJECTION_BYTES,
  toolSegmentId,
} from "./projection.js";

describe("canonical tool ownership", () => {
  it("recognizes exact tool-result call IDs across the full branch", () => {
    const manager = {
      getBranch: () => [
        { type: "message", message: { role: "toolResult", toolCallId: "call-old" } },
        { type: "message", message: { role: "toolResult", toolCallId: "call-error" } },
        { type: "message", message: { role: "assistant", content: [] } },
      ] as any,
    };
    expect([...canonicalToolResultCallIDs(manager)]).toEqual(["call-old", "call-error"]);
    expect(canonicalToolResultCallIDs(manager).has("call-old")).toBe(true);
    expect(canonicalToolResultCallIDs(manager).has("call-missing")).toBe(false);
  });
});

describe("catalog projection admission", () => {
  it("admits command catalogs atomically without changing their order", () => {
    const commands = [
      { name: "zeta", source: "prompt" as const, argumentHint: "[value]" },
      { name: "alpha", source: "extension" as const, description: "Alpha" },
    ];
    expect(admitCommandCatalog(commands)).toBe(commands);
    expect(admitCommandCatalog(commands).map((command) => command.name)).toEqual(["zeta", "alpha"]);
  });

  it("bounds selected command content without splitting UTF-8 scalars", () => {
    const exact = "Council guidance";
    expect(boundCommandContent(exact)).toEqual({
      content: exact,
      contentBytes: Buffer.byteLength(exact),
      contentTruncated: false,
    });

    const oversized = `${"x".repeat(COMMAND_DETAIL_CONTENT_BYTES - 1)}🙂tail`;
    const bounded = boundCommandContent(oversized);
    expect(Buffer.byteLength(bounded.content)).toBeLessThanOrEqual(COMMAND_DETAIL_CONTENT_BYTES);
    expect(bounded.content.endsWith("�")).toBe(false);
    expect(bounded.contentBytes).toBe(Buffer.byteLength(oversized));
    expect(bounded.contentTruncated).toBe(true);
  });

  it("rejects duplicate, malformed, count-excess, and byte-excess command catalogs", () => {
    expect(() => admitCommandCatalog([
      { name: "same", source: "skill" },
      { name: "same", source: "skill", description: "duplicate" },
    ])).toThrow(/duplicate/);
    expect(() => admitCommandCatalog([{ name: "", source: "prompt" }])).toThrow(/invalid/);
    expect(() => admitCommandCatalog([{
      name: "valid", source: "prompt", resourceScope: "machine" as "project",
    }])).toThrow(/invalid/);
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

  it("projects extension-authored tool labels without replacing canonical tool names", () => {
    const labels = new Map([["subagent_wait", "Subagent Wait"]]);
    const assistant = projectMessage(
      "assistant",
      null,
      "2026-01-01T00:00:00Z",
      {
        role: "assistant",
        content: [{ type: "toolCall", id: "wait", name: "subagent_wait", arguments: {} }],
        api: "openai-responses",
        provider: "test",
        model: "test",
        usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        stopReason: "toolUse",
        timestamp: 1,
      },
      new BlobStore(),
      undefined,
      "assistant",
      true,
      labels,
    );
    const result = projectMessage(
      "result",
      "assistant",
      "2026-01-01T00:00:01Z",
      {
        role: "toolResult", toolCallId: "wait", toolName: "subagent_wait",
        content: [{ type: "text", text: "done" }], isError: false, timestamp: 2,
      },
      new BlobStore(),
      undefined,
      "result",
      true,
      labels,
    );

    expect(assistant).toMatchObject({
      content: [expect.objectContaining({ name: "subagent_wait", label: "Subagent Wait" })],
    });
    expect(result).toMatchObject({ toolName: "subagent_wait", toolLabel: "Subagent Wait" });
  });

  it("projects contiguous finalized groups with stable declaration metadata", () => {
    const message: AgentMessage = {
      role: "assistant",
      content: [
        { type: "text", text: "before" },
        { type: "toolCall", id: "call-a", name: "read", arguments: { path: "a" } },
        { type: "toolCall", id: "call-b", name: "write", arguments: { path: "b" } },
        { type: "text", text: "between" },
        { type: "toolCall", id: "call-c", name: "bash", arguments: { command: "true" } },
      ],
      api: "openai-responses", provider: "test", model: "model",
      usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
      stopReason: "toolUse", timestamp: 2,
    };
    const segmentId = toolSegmentId("operation-1");
    const live = projectMessage(
      "streaming", null, "2026-01-01T00:00:00Z", message, new BlobStore(),
      undefined, "stream:turn", false, undefined, undefined, segmentId,
    );
    const settled = projectMessage(
      "canonical", null, "2026-01-01T00:00:00Z", message, new BlobStore(),
      undefined, "stream:turn", true, undefined, undefined, segmentId,
    );
    if (live?.kind !== "message" || settled?.kind !== "message") throw new Error("expected messages");
    expect(live.content.filter((part) => part.type === "toolCall").every((part) =>
      !part.groupFinalized && part.toolSegmentId === segmentId
    )).toBe(true);
    const calls = settled.content.filter((part) => part.type === "toolCall");
    expect(calls).toMatchObject([
      { toolCallId: "call-a", toolSegmentId: segmentId, groupIndex: 0, groupCount: 2, groupFinalized: true },
      { toolCallId: "call-b", toolSegmentId: segmentId, groupIndex: 1, groupCount: 2, groupFinalized: true },
      { toolCallId: "call-c", toolSegmentId: segmentId, groupIndex: 0, groupCount: 1, groupFinalized: true },
    ]);
    expect(calls[0]?.type === "toolCall" && calls[1]?.type === "toolCall" ? calls[0].groupId : undefined)
      .toBe(calls[1]?.type === "toolCall" ? calls[1].groupId : undefined);
    expect(calls[0]?.type === "toolCall" && calls[2]?.type === "toolCall" ? calls[0].groupId : undefined)
      .not.toBe(calls[2]?.type === "toolCall" ? calls[2].groupId : undefined);

    const bounded = boundStreamingProgressItem(settled, 900);
    if (bounded.kind !== "message") throw new Error("expected bounded message");
    const retained = bounded.content.filter((part) => part.type === "toolCall");
    for (const groupId of new Set(retained.map((part) => part.type === "toolCall" ? part.groupId : undefined))) {
      if (!groupId) continue;
      const members = retained.filter((part) => part.type === "toolCall" && part.groupId === groupId);
      expect(members).toHaveLength(members[0]?.type === "toolCall" ? members[0].groupCount : 0);
    }
  });

  it("derives one canonical tool segment per exact conversation turn", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    const usage = {
      input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
    };
    const appendTool = (id: string, leadingThinking = false) => manager.appendMessage({
      role: "assistant",
      content: [
        ...(leadingThinking ? [{ type: "thinking" as const, thinking: "planning" }] : []),
        { type: "toolCall", id, name: "read", arguments: { path: id } } as const,
      ],
      api: "openai-responses",
      provider: "test",
      model: "model",
      usage,
      stopReason: "toolUse",
      timestamp: Date.now(),
    });
    const firstInput = manager.appendMessage({ role: "user", content: "first", timestamp: 1 });
    appendTool("call-a", true);
    manager.appendMessage({
      role: "toolResult", toolCallId: "call-a", toolName: "read",
      content: [{ type: "text", text: "a" }], isError: false, timestamp: 2,
    });
    appendTool("call-b");
    manager.appendMessage({
      role: "assistant", content: [{ type: "text", text: "done" }],
      api: "openai-responses", provider: "test", model: "model", usage,
      stopReason: "stop", timestamp: Date.now(),
    });
    appendTool("call-after-barrier");
    const secondInput = manager.appendMessage({ role: "user", content: "second", timestamp: 3 });
    appendTool("call-c");

    const transcript = projectTranscript(manager, new BlobStore());
    const segmentByCall = new Map(transcript.flatMap((item) => item.kind === "message"
      ? item.content.flatMap((part) => part.type === "toolCall"
        ? [[part.toolCallId, part.toolSegmentId] as const]
        : [])
      : []));
    expect(segmentByCall.get("call-a")).toBe(toolSegmentId(firstInput));
    expect(segmentByCall.get("call-b")).toBe(toolSegmentId(firstInput));
    expect(segmentByCall.get("call-after-barrier")).not.toBe(toolSegmentId(firstInput));
    expect(segmentByCall.get("call-c")).toBe(toolSegmentId(secondInput));
    expect(segmentByCall.get("call-c")).not.toBe(segmentByCall.get("call-b"));
  });

  it("keeps presentation and ordinal identity across live and canonical owners", () => {
    const message: AgentMessage = {
      role: "assistant",
      content: [
        { type: "thinking", thinking: "one" },
        { type: "thinking", thinking: "two" },
        { type: "text", text: "answer" },
      ],
      api: "openai-responses",
      provider: "test",
      model: "model",
      usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
      stopReason: "stop",
      timestamp: 2,
    };
    const blobs = new BlobStore();
    const live = projectMessage("streaming", "user", "2026-01-01T00:00:00Z", message, blobs, undefined, "stream:turn");
    const settled = projectMessage("canonical", "user", "2026-01-01T00:00:00Z", message, blobs, undefined, "stream:turn");
    expect(live).toMatchObject({ id: "streaming", presentationId: "stream:turn" });
    expect(settled).toMatchObject({ id: "canonical", presentationId: "stream:turn" });
    if (live?.kind !== "message" || settled?.kind !== "message") throw new Error("expected messages");
    expect(live.content.map(({ id, ordinal }) => ({ id, ordinal }))).toEqual(
      settled.content.map(({ id, ordinal }) => ({ id, ordinal })),
    );
    expect(live.content.slice(0, 2)).toMatchObject([
      { ordinal: 0, thinkingRunOrdinal: 0 },
      { ordinal: 1, thinkingRunOrdinal: 0 },
    ]);
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

  it("projects only receipt-backed triggered custom messages as session input", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    manager.appendCustomMessageEntry("hidden-status", [{ type: "text", text: "not delivered" }], false);
    const input = manager.appendCustomMessageEntry(
      "subagent-notify",
      [{ type: "text", text: "Background worker finished" }],
      false,
      { runId: "run-1" },
    );
    manager.appendCustomEntry(SESSION_INPUT_RECEIPT_TYPE, makeSessionInputReceipt(input, {
      source: "npm:pi-subagents",
      owner: { id: "extension:opaque", title: "Pi Subagents", source: "npm:pi-subagents" },
    }));

    const transcript = projectTranscript(manager, new BlobStore());
    expect(transcript).toHaveLength(1);
    expect(transcript[0]).toMatchObject({
      id: input,
      kind: "customMessage",
      customType: "subagent-notify",
      content: [{ text: "Background worker finished" }],
      details: { runId: "run-1" },
      sessionInput: {
        source: "extension",
        trigger: "turn",
        origin: {
          source: "npm:pi-subagents",
          owner: { id: "extension:opaque", title: "Pi Subagents", source: "npm:pi-subagents" },
        },
      },
    });
    const page = projectTranscriptPage(manager, new BlobStore());
    expect(page).toMatchObject({ start: 0, end: 1, total: 1, items: [{ id: input }] });
    expect(transcript.some((item) => item.customType === SESSION_INPUT_RECEIPT_TYPE)).toBe(false);
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
      content: `Review this\n\n<attachment name="Boarding &amp; notes.pdf" mime-type="application/pdf" size="55972" path="/Users/private/00000000-0000-4000-8000-000000000001/content.pdf" />`,
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
          blobId: "upload:00000000-0000-4000-8000-000000000001",
        },
      ],
    });
    expect(JSON.stringify(transcript[0])).not.toContain("/Users/private");
  });

  it("projects Pi skill envelopes as exact user arguments and preserves attachment extraction", () => {
    const envelope = `<skill name="review" location="/private/skills/review/SKILL.md">\nReferences are relative to /private/skills/review.\n\nReview carefully.\n</skill>\n\nInspect this\n\n<attachment name="notes.txt" mime-type="text/plain" size="4" path="/private/upload/content.txt" />`;
    expect(projectSkillInvocation(envelope)).toEqual({
      skillName: "review",
      text: `Inspect this\n\n<attachment name="notes.txt" mime-type="text/plain" size="4" path="/private/upload/content.txt" />`,
    });
    const item = projectMessage(
      "skill-entry",
      null,
      "2026-01-01T00:00:00Z",
      { role: "user", content: envelope, timestamp: 1 },
      new BlobStore(),
    );
    expect(item).toMatchObject({
      kind: "message",
      role: "user",
      content: [
        { type: "text", text: "Inspect this" },
        { type: "text", attachment: { name: "notes.txt", mimeType: "text/plain", size: 4 } },
      ],
    });
    expect(JSON.stringify(item)).not.toContain("/private/");
  });

  it("uses the final Pi delimiter when skill Markdown contains an envelope-like close", () => {
    const envelope = `<skill name="review" location="/private/skills/review/SKILL.md">\nReferences are relative to /private/skills/review.\n\nExplain this literal:\n</skill>\n\nwithout treating it as the envelope close\n</skill>\n\nInspect this`;
    expect(projectSkillInvocation(envelope)).toEqual({ skillName: "review", text: "Inspect this" });
  });

  it("fails closed for malformed skill envelopes", () => {
    const malformed = [
      `<skill name="review" location="/private/skill">\nWrong reference\n\nbody\n</skill>\n\ntext`,
      `<skill name="bad name" location="/private/skill">\nReferences are relative to /private.\n\nbody\n</skill>\n\ntext`,
      `<skill name="review" location="/private/skill">\nReferences are relative to /private.\n\nbody\n</skill>trailing`,
    ];
    for (const value of malformed) expect(projectSkillInvocation(value)).toBeUndefined();
    const item = projectMessage(
      "malformed-skill",
      null,
      "2026-01-01T00:00:00Z",
      { role: "user", content: malformed[0]!, timestamp: 1 },
      new BlobStore(),
    );
    expect(item).toMatchObject({
      content: [{ type: "text", text: "Skill invocation omitted from this bounded mobile projection" }],
    });
    expect(JSON.stringify(item)).not.toContain("/private/");
  });

  it("keeps malformed attachment-like text visible without projecting its private path", () => {
    const manager = SessionManager.inMemory("/tmp/project");
    manager.appendMessage({
      role: "user",
      content: `Literal <attachment name="unfinished" upload-id="00000000-0000-4000-8000-000000000001" path="/Users/private/content.pdf" />`,
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

  it("reprojects shared sibling objects instead of marking them circular", () => {
    const metadata = { source: "shared-package", scope: "user", origin: "package" };
    const value = {
      skills: [
        { path: "/skills/one", enabled: true, metadata },
        { path: "/skills/two", enabled: true, metadata },
      ],
    };
    expect(safeJson(value)).toEqual({
      skills: [
        { path: "/skills/one", enabled: true, metadata },
        { path: "/skills/two", enabled: true, metadata },
      ],
    });
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

  it("projects tree images lazily so omitted candidates do not consume blobs", () => {
    const manager = SessionManager.inMemory("/tmp/lazy-tree-images");
    for (let index = 0; index < 1_001; index += 1) {
      manager.appendMessage({
        role: "user",
        content: [{ type: "image", data: Buffer.from(`image-${index}`).toString("base64"), mimeType: "image/png" }],
        timestamp: index + 1,
      });
    }
    const blobs = new BlobStore({ maximumItemBytes: 64, maximumItems: 1, maximumTotalBytes: 64 });
    const tree = projectTree(manager, blobs);
    expect(tree).toHaveLength(1_000);
    const imageNodes = tree.filter((node) => node.kind === "message");
    expect(imageNodes).toHaveLength(1_000);
    // The newest admitted candidate registers; the structurally omitted oldest
    // candidate never reaches BlobStore registration.
    const blobID = (index: number) => createHash("sha256").update("image/png").update("\0").update(`image-${index}`).digest("base64url");
    expect(blobs.get(blobID(1_000)).data.toString()).toBe("image-1000");
    expect(() => blobs.get(blobID(0))).toThrow();
    expect(tree.at(-1)?.id).toBe(manager.getEntries().at(-1)?.id);
  });

  it("validates malformed canonical payloads even when the oldest node is omitted", () => {
    const manager = SessionManager.inMemory("/tmp/malformed-oldest-tree");
    for (let index = 0; index < 1_001; index += 1) {
      manager.appendMessage({ role: "user", content: `message ${index}`, timestamp: index });
    }
    const oldest = manager.getEntries()[0]! as { message: unknown };
    oldest.message = { role: "user" };
    expect(() => projectTree(manager, new BlobStore())).toThrow(/invalid canonical entry payload/);
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

  it("replaces live output frames in place while empty updates preserve readable output", () => {
    const first = mergeLiveToolOutput(undefined, { output: "waiting\nworker: thinking", outputTruncated: true });
    expect(mergeLiveToolOutput(first, {})).toEqual(first);
    expect(mergeLiveToolOutput(first, { output: "waiting" })).toEqual({ output: "waiting" });
    const latest = mergeLiveToolOutput(first, { output: "worker: read complete" });
    expect(latest).toEqual({ output: "worker: read complete" });
    expect(latest.output).not.toContain("worker: thinking");
    const bounded = mergeLiveToolOutput({ output: "old" }, { output: "x".repeat(2_000) }, 256);
    expect(bounded.outputTruncated).toBe(true);
    expect(bounded.output).not.toContain("old");
    expect(Buffer.byteLength(bounded.output!)).toBeLessThanOrEqual(256);
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
    const removedTranscriptRows = fitted.transcriptStart - snapshot.transcriptStart;
    expect(removedTranscriptRows).toBeGreaterThanOrEqual(0);
    expect(fitted.transcript.map((item) => item.id)).toEqual(
      snapshot.transcript.slice(removedTranscriptRows).map((item) => item.id),
    );

    const maximumToolSnapshot: SessionSnapshot = {
      ...snapshot,
      transcript: Array.from({ length: 20 }, (_, index) => ({
        id: `continuity-${index}`, parentId: index ? `continuity-${index - 1}` : null,
        timestamp: new Date(index).toISOString(), kind: "message" as const, role: "assistant" as const,
        content: [{ id: `continuity-${index}:0`, type: "text" as const, text: `message-${index}` }],
      })),
      transcriptStart: 0,
      transcriptTotal: 20,
      toolExecutions: Array.from({ length: 256 }, (_, index) => ({
        toolCallId: `maximum-tool-${index}`, toolName: "bash", order: index,
        status: "running" as const, arguments: { command: "x".repeat(150_000) },
        partialResult: { output: "y".repeat(150_000) }, output: "z".repeat(96 * 1_024),
        isError: false, startedAt: new Date(index).toISOString(), updatedAt: new Date(index).toISOString(),
        lastProgressAt: new Date(index).toISOString(), progressSequence: index + 1,
      })),
    };
    const maximumToolFitted = fitSessionSnapshot(maximumToolSnapshot);
    expect(Buffer.byteLength(JSON.stringify(maximumToolFitted))).toBeLessThanOrEqual(SESSION_SNAPSHOT_BYTES);
    expect(maximumToolFitted.toolExecutions.map((tool) => tool.toolCallId)).toEqual(
      maximumToolSnapshot.toolExecutions.map((tool) => tool.toolCallId),
    );
    expect(maximumToolFitted.transcript.filter(
      (item) => !(item.kind === "message" && item.role === "toolResult"),
    )).toHaveLength(20);

    const resultDominated: SessionSnapshot = {
      ...snapshot,
      transcript: Array.from({ length: 60 }, (_, index) => index % 2 === 0 ? ({
        id: `visible-${index}`, parentId: index ? `result-dominated-${index - 1}` : null,
        timestamp: new Date(index).toISOString(), kind: "message" as const, role: "assistant" as const,
        content: [{ id: `visible-${index}:0`, type: "text" as const, text: "v".repeat(2_000) }],
      }) : ({
        id: `result-dominated-${index}`, parentId: `visible-${index - 1}`,
        timestamp: new Date(index).toISOString(), kind: "message" as const, role: "toolResult" as const,
        content: [{ id: `result-${index}:0`, type: "text" as const, text: "r".repeat(2_000) }],
        toolCallId: `call-${index}`, toolName: "read", isError: false,
      })),
      transcriptStart: 0,
      transcriptTotal: 60,
      toolExecutions: [],
    };
    const resultDominatedFitted = fitSessionSnapshot(resultDominated, 70_000);
    expect(Buffer.byteLength(JSON.stringify(resultDominatedFitted))).toBeLessThanOrEqual(70_000);
    expect(resultDominatedFitted.transcript.filter(
      (item) => !(item.kind === "message" && item.role === "toolResult"),
    ).length).toBeGreaterThanOrEqual(MINIMUM_TRANSCRIPT_CONTINUITY_MESSAGES);

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

  it("compacts the recent idle continuity floor before trimming canonical rows", () => {
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
    expect(fitted.transcript).toHaveLength(10);
    expect(fitted.transcriptStart).toBe(0);
    expect(fitted.transcriptStart + fitted.transcript.length).toBe(snapshot.transcriptTotal);
    expect(Buffer.byteLength(JSON.stringify(fitted))).toBeLessThanOrEqual(180_000);
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

  it("retains the editor baseline and clears status ownership atomically under pressure", () => {
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
          statusOwners: {
            decorative: { id: "extension:subagents", title: "Subagents", source: "npm:pi-subagents" },
          },
          working: { visible: false, indicator: { kind: "default", frames: [] } },
          widgets: [], toolsExpanded: false, editorRevision: 7, editorText,
        },
        surfaces: [], pendingInteractions: [],
      },
    };

    const fitted = fitSessionSnapshot(snapshot, 16_000);
    expect(fitted.extensionPresentation.semanticState.statuses).toEqual({});
    expect(fitted.extensionPresentation.semanticState.statusOwners).toEqual({});
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
    expect(earlier.nextEntryId).toBe(tail.items[0]?.id);
    expect(earlier.items.at(-1)?.id).not.toBe(tail.items[0]?.id);
    expect(() => projectTranscriptPage(manager, blobs, tail.start, TRANSCRIPT_PAGE_BYTES, "stale-anchor")).toThrow("anchor changed");
    expect(Buffer.byteLength(JSON.stringify(earlier.items))).toBeLessThanOrEqual(TRANSCRIPT_PAGE_BYTES);
  });

  it("pages across filtered canonical entries without treating raw parents as projected adjacency", () => {
    const manager = SessionManager.inMemory("/tmp/filtered-page-adjacency");
    const first = manager.appendMessage({ role: "user", content: "first", timestamp: 1 });
    manager.appendCustomEntry(EXTENSION_ACTIVITY_RECEIPT_TYPE, {
      version: 1,
      activity: { id: "filtered-receipt" },
    });
    const second = manager.appendMessage({ role: "assistant", content: "second", timestamp: 3 });
    const next = manager.appendMessage({ role: "user", content: "next", timestamp: 4 });

    const page = projectTranscriptPage(manager, new BlobStore(), 2, TRANSCRIPT_PAGE_BYTES, next);
    expect(page.items.map((item) => item.id)).toEqual([first, second]);
    expect(page.items[1]?.parentId).not.toBe(first);
    expect(page.nextEntryId).toBe(next);
    expect(page.start).toBe(0);
    expect(page.end).toBe(2);
    expect(page.total).toBe(3);
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

describe("streaming progress bounds", () => {
  const streamingItem = (parts: Array<{ type: "text" | "thinking"; text: string }>): TranscriptItem => {
    let activeThinkingRunOrdinal: number | undefined;
    return {
      id: "streaming",
      parentId: null,
      timestamp: "2026-01-01T00:00:00Z",
      kind: "message",
      role: "assistant",
      presentationId: "stream:fixture",
      content: parts.map((part, ordinal) => {
        if (part.type === "thinking") {
          activeThinkingRunOrdinal ??= ordinal;
          return {
            id: `streaming:${ordinal}`, ordinal,
            thinkingRunOrdinal: activeThinkingRunOrdinal,
            ...part,
          };
        }
        activeThinkingRunOrdinal = undefined;
        return { id: `streaming:${ordinal}`, ordinal, ...part };
      }),
    };
  };
  const frameBytes = (value: unknown) => Buffer.byteLength(JSON.stringify(value));

  it("returns an item inside the budget unchanged", () => {
    const item = streamingItem([{ type: "text", text: "short live answer" }]);
    expect(boundStreamingProgressItem(item)).toBe(item);
  });

  it("keeps whole trailing parts and tail-trims only the oldest kept part", () => {
    const tail = "final streamed sentence";
    const item = streamingItem([
      { type: "thinking", text: "t".repeat(STREAMING_PROGRESS_BYTES) },
      { type: "text", text: "x".repeat(STREAMING_PROGRESS_BYTES) },
      { type: "text", text: tail },
    ]);
    const bounded = boundStreamingProgressItem(item);
    expect(frameBytes(bounded)).toBeLessThanOrEqual(STREAMING_PROGRESS_BYTES);
    expect(bounded).toMatchObject({ id: "streaming", kind: "message", role: "assistant" });
    if (bounded.kind !== "message") throw new Error("expected message");
    expect(bounded.content.at(-1)).toMatchObject({ id: "streaming:2", ordinal: 2, type: "text", text: tail });
    const trimmed = bounded.content[0]!;
    if (trimmed.type !== "text") throw new Error("expected trimmed text part");
    expect(trimmed.text.startsWith("…")).toBe(true);
    expect(trimmed.text.endsWith("x".repeat(64))).toBe(true);
    expect(bounded.content.some((part) => part.id === "streaming:0")).toBe(false);
  });

  it("bounds one oversized part to a marked tail", () => {
    const body = "y".repeat(STREAMING_PROGRESS_BYTES * 4);
    const item = streamingItem([{ type: "text", text: body }]);
    const bounded = boundStreamingProgressItem(item);
    expect(frameBytes(bounded)).toBeLessThanOrEqual(STREAMING_PROGRESS_BYTES);
    if (bounded.kind !== "message") throw new Error("expected message");
    expect(bounded.content).toHaveLength(1);
    const part = bounded.content[0]!;
    if (part.type !== "text") throw new Error("expected text part");
    expect(part.text.startsWith("…")).toBe(true);
    expect(body.endsWith(part.text.slice(1))).toBe(true);
  });

  it("retains a thinking run identity when its leading part is trimmed", () => {
    const item = streamingItem([
      { type: "thinking", text: "a".repeat(STREAMING_PROGRESS_BYTES) },
      { type: "thinking", text: "b".repeat(STREAMING_PROGRESS_BYTES) },
      { type: "text", text: "answer" },
    ]);
    const bounded = boundStreamingProgressItem(item);
    if (bounded.kind !== "message") throw new Error("expected message");
    const thinking = bounded.content.find((part) => part.type === "thinking");
    expect(thinking).toMatchObject({ thinkingRunOrdinal: 0 });
  });

  it("does not let JSON escaping bypass the exact frame bound", () => {
    const item = streamingItem([{ type: "text", text: "\\\"\n".repeat(STREAMING_PROGRESS_BYTES) }]);
    const bounded = boundStreamingProgressItem(item);
    expect(frameBytes(bounded)).toBeLessThanOrEqual(STREAMING_PROGRESS_BYTES);
  });

  it("never emits an empty live frame", () => {
    const item: TranscriptItem = {
      id: "streaming",
      parentId: null,
      timestamp: "2026-01-01T00:00:00Z",
      kind: "message",
      role: "assistant",
      presentationId: "stream:fixture",
      content: [{ id: "streaming:0", ordinal: 0, type: "toolCall", toolCallId: "call", name: "bash", arguments: { command: "x".repeat(STREAMING_PROGRESS_BYTES * 4) } }],
    };
    const bounded = boundStreamingProgressItem(item);
    if (bounded.kind !== "message") throw new Error("expected message");
    expect(bounded.content.length).toBeGreaterThan(0);
    expect(frameBytes(bounded)).toBeLessThanOrEqual(STREAMING_PROGRESS_BYTES);
  });

  it("drops oversized optional envelope metadata to preserve the exact budget", () => {
    const item = {
      ...streamingItem([{ type: "text", text: "answer" }]),
      errorMessage: "\\\"\n".repeat(STREAMING_PROGRESS_BYTES),
    } as TranscriptItem;
    const bounded = boundStreamingProgressItem(item);
    expect(frameBytes(bounded)).toBeLessThanOrEqual(STREAMING_PROGRESS_BYTES);
    expect(bounded).toMatchObject({ presentationId: "stream:fixture" });
    if (bounded.kind !== "message") throw new Error("expected message");
    expect(bounded.content).toHaveLength(1);
  });
});
