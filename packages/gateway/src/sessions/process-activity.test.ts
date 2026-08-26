import { describe, expect, it } from "vitest";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import type { ExtensionRunActivity, ToolExecutionState } from "../protocol/types.js";
import { EXTENSION_ACTIVITY_RECEIPT_TYPE, makeExtensionActivityReceipt } from "./extension-activity-history.js";
import {
  boundProcessActivities,
  canonicalProcessHistory,
  commandProcessFromTool,
  listProcessHistory,
  processOverview,
  redactProcessText,
  subagentProcessesFromActivity,
} from "./process-activity.js";

function tool(name = "bash"): ToolExecutionState {
  return {
    toolCallId: "call-1",
    toolName: name,
    order: 0,
    status: "running",
    arguments: { command: "printf hello" },
    output: "hello",
    isError: false,
    startedAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:01.000Z",
    lastProgressAt: "2026-01-01T00:00:01.000Z",
    durationMs: 1_000,
    progressSequence: 2,
  };
}

const subagent: ExtensionRunActivity = {
  id: "tool-subagent",
  activityId: "extension-activity:test",
  runId: "run-1",
  toolCallId: "call-subagent",
  source: { source: "pi-subagents" },
  title: "Pi Subagents",
  mode: "async",
  status: "completed",
  startedAt: "2026-01-01T00:00:00.000Z",
  updatedAt: "2026-01-01T00:00:03.000Z",
  completedAt: "2026-01-01T00:00:02.000Z",
  children: [{
    id: "child-1",
    producerId: "child-1",
    label: "worker",
    status: "completed",
    lifecycle: "completed",
    childSessionRef: "child-session-1",
    durationMs: 1_800,
    toolCount: 2,
  }],
  lifecycle: {
    version: 1,
    state: "completed",
    attention: "none",
    sequence: 4,
    observedAt: "2026-01-01T00:00:03.000Z",
    terminalAt: "2026-01-01T00:00:02.000Z",
    recentUntil: "2026-01-01T00:15:02.000Z",
  },
};

describe("session process projection", () => {
  it("admits only the assistant bash tool adapter", () => {
    const projected = commandProcessFromTool("session-1", tool());
    expect(projected).toMatchObject({
      kind: "command", executionMode: "foreground", command: "printf hello", durationMs: 1_000,
    });
    expect(commandProcessFromTool("session-1", tool("read"))).toBeUndefined();
    expect(commandProcessFromTool("session-1", {
      ...tool(),
      extensionOrigin: { source: "project", owner: { id: "extension:1", title: "Override", source: "project" } },
    })).toBeUndefined();
  });

  it("redacts common credential forms only in process previews", () => {
    const projected = commandProcessFromTool("session-1", {
      ...tool(),
      arguments: { command: "API_KEY=top-secret curl -H 'Authorization: Bearer abc123' https://user:pass@example.test" },
      output: "{\"access_token\":\"response-secret\"}\npassword=hunter2\nAWS_SECRET_ACCESS_KEY=aws-secret\n-----BEGIN PRIVATE KEY-----\nprivate-material\n-----END PRIVATE KEY-----\nghp_1234567890abcdefghijklmnop",
    });
    expect(projected?.command).not.toContain("top-secret");
    expect(projected?.command).not.toContain("abc123");
    expect(projected?.command).not.toContain(":pass@");
    expect(projected?.outputTail).not.toContain("response-secret");
    expect(projected?.outputTail).not.toContain("hunter2");
    expect(projected?.outputTail).not.toContain("aws-secret");
    expect(projected?.outputTail).not.toContain("private-material");
    expect(projected?.outputTail).not.toContain("1234567890abcdefghijklmnop");
    expect(redactProcessText("curl -H 'X-Api-Key: header-secret' -b cookie-secret -p short-secret"))
      .not.toMatch(/header-secret|cookie-secret|short-secret/u);
    expect(redactProcessText("ordinary output remains")).toBe("ordinary output remains");
  });

  it("projects executable subagent children with opaque session references", () => {
    const rows = subagentProcessesFromActivity("session-1", subagent);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      kind: "subagent",
      executionMode: "asynchronous",
      title: "worker",
      childSessionRef: "child-session-1",
      visibility: "recent",
      durationMs: 1_800,
    });
    expect(rows[0]?.lifecycle.recentUntil).toBe("2026-01-01T00:05:02.000Z");
  });

  it("does not turn compatibility label/index child IDs into process ownership", () => {
    const rows = subagentProcessesFromActivity("session-1", {
      ...subagent,
      children: [{
        id: "worker:0", label: "worker", status: "running", lifecycle: "running", currentTool: "read",
      }],
      lifecycle: { ...subagent.lifecycle!, state: "running", terminalAt: undefined, recentUntil: undefined },
    });
    expect(rows).toEqual([]);
  });

  it("keeps an async workflow active after its launcher tool has already settled", () => {
    const rows = subagentProcessesFromActivity("session-1", {
      ...subagent,
      // The foreground launcher result may settle in milliseconds. Structured
      // lifecycle evidence, not that coarse tool result, owns async liveness.
      status: "completed",
      completedAt: "2026-01-01T00:00:00.044Z",
      lifecycle: {
        version: 1,
        state: "running",
        attention: "activeLongRunning",
        sequence: 5,
        observedAt: "2026-01-01T00:00:01.000Z",
      },
      children: [{
        id: "child-1",
        producerId: "child-1",
        label: "worker",
        status: "running",
        lifecycle: "running",
        currentTool: "write",
        currentPath: "/private/worktree/Sources/Feature.swift",
      }],
    });

    expect(rows).toEqual([expect.objectContaining({
      kind: "subagent",
      executionMode: "asynchronous",
      visibility: "active",
      currentTool: "write",
      currentPathBasename: "Feature.swift",
      lifecycle: expect.objectContaining({ state: "running" }),
    })]);
  });

  it("retains a terminal child while siblings run and omits workflow-only containers", () => {
    const activeParent: ExtensionRunActivity = {
      ...subagent,
      status: "running",
      completedAt: undefined,
      lifecycle: {
        version: 1, state: "running", attention: "none", sequence: 5,
        observedAt: "2026-01-01T00:00:04.000Z",
      },
      children: [{
        id: "workflow", producerId: "workflow", label: "workflow", status: "running", lifecycle: "running",
        children: [
          { id: "failed-child", producerId: "failed-child", label: "reviewer", status: "failed", lifecycle: "failed" },
          { id: "active-child", producerId: "active-child", label: "worker", status: "running", lifecycle: "running", currentTool: "read" },
        ],
      }],
    };
    const rows = subagentProcessesFromActivity("session-1", activeParent);
    expect(rows.map((row) => row.title).sort()).toEqual(["reviewer", "worker"]);
    expect(rows.find((row) => row.title === "reviewer")).toMatchObject({
      visibility: "recent",
      lifecycle: { state: "failed", terminalAt: "2026-01-01T00:00:04.000Z" },
    });
    expect(rows.find((row) => row.title === "worker")?.visibility).toBe("active");

    const receiptRows = subagentProcessesFromActivity("session-1", {
      ...subagent,
      children: [{ id: "stale-running-child", producerId: "stale-running-child", label: "worker", status: "running", lifecycle: "running" }],
    });
    expect(receiptRows[0]).toMatchObject({
      visibility: "recent",
      lifecycle: { state: "completed", terminalAt: "2026-01-01T00:00:02.000Z" },
    });
  });

  it("merges canonical assistant command results and subagent receipts", () => {
    const manager = SessionManager.inMemory("/tmp/process-test", { id: "session-1" });
    manager.appendMessage({
      role: "assistant",
      content: [{ type: "toolCall", id: "call-1", name: "bash", arguments: { command: "printf hello" } }],
      api: "anthropic-messages",
      provider: "test",
      model: "test",
      usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
      stopReason: "toolUse",
      timestamp: Date.parse("2026-01-01T00:00:00.000Z"),
    } as never);
    manager.appendMessage({
      role: "toolResult",
      toolCallId: "call-1",
      toolName: "bash",
      content: [{ type: "text", text: "hello" }],
      isError: false,
      timestamp: Date.parse("2026-01-01T00:00:01.000Z"),
    });
    const receipt = makeExtensionActivityReceipt(subagent, "session-1");
    expect(receipt).toBeDefined();
    manager.appendCustomEntry(EXTENSION_ACTIVITY_RECEIPT_TYPE, receipt);

    const history = canonicalProcessHistory(manager);
    expect(history.map((row) => row.kind).sort()).toEqual(["command", "subagent"]);
    expect(history.find((row) => row.kind === "command")).toMatchObject({ outputTail: "hello", durationMs: 1_000 });
    expect(history.find((row) => row.kind === "subagent")).toMatchObject({
      childSessionRef: "child-session-1",
      durationMs: 2_000,
      visibility: "historical",
    });

    const first = listProcessHistory(manager, undefined, 1);
    expect(first.activities).toHaveLength(1);
    expect(first.nextCursor).toBeDefined();
    expect(listProcessHistory(manager, first.nextCursor, 1).activities).toHaveLength(1);
    expect(() => listProcessHistory(manager, "stale:1", 1)).toThrow(/cursor conflict/u);
  });

  it("excludes canonical bash-shaped calls proven to belong to an extension", () => {
    const manager = SessionManager.inMemory("/tmp/process-extension-bash", { id: "session-1" });
    manager.appendMessage({
      role: "assistant",
      content: [{ type: "toolCall", id: "call-1", name: "bash", arguments: { command: "not the built-in" } }],
      api: "anthropic-messages", provider: "test", model: "test",
      usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
      stopReason: "toolUse", timestamp: Date.parse("2026-01-01T00:00:00.000Z"),
    } as never);
    manager.appendMessage({
      role: "toolResult", toolCallId: "call-1", toolName: "bash",
      content: [{ type: "text", text: "extension result" }], isError: false,
      timestamp: Date.parse("2026-01-01T00:00:01.000Z"),
    });
    const receipt = makeExtensionActivityReceipt({
      ...subagent,
      toolCallId: "call-1",
      mode: "single",
      currentTool: "read",
      children: [],
    }, "session-1")!;
    manager.appendCustomEntry(EXTENSION_ACTIVITY_RECEIPT_TYPE, receipt);
    expect(canonicalProcessHistory(manager).filter((row) => row.kind === "command")).toEqual([]);
  });

  it("keeps byte-deferred history rows reachable from the next stable cursor", () => {
    const manager = SessionManager.inMemory("/tmp/process-byte-pages", { id: "session-byte-pages" });
    for (let index = 0; index < 12; index += 1) {
      const toolCallId = `byte-call-${index}`;
      manager.appendMessage({
        role: "assistant",
        content: [{ type: "toolCall", id: toolCallId, name: "bash", arguments: { command: `printf ${index}` } }],
        api: "anthropic-messages",
        provider: "test",
        model: "test",
        usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        stopReason: "toolUse",
        timestamp: Date.parse("2026-01-01T00:00:00.000Z") + index * 2_000,
      } as never);
      manager.appendMessage({
        role: "toolResult",
        toolCallId,
        toolName: "bash",
        content: [{ type: "text", text: `${index}:${"x".repeat(40 * 1_024)}` }],
        isError: false,
        timestamp: Date.parse("2026-01-01T00:00:01.000Z") + index * 2_000,
      });
    }

    const expected = canonicalProcessHistory(manager).map((activity) => activity.processId);
    const reached: string[] = [];
    let cursor: string | undefined;
    let pages = 0;
    do {
      const page = listProcessHistory(manager, cursor, 50);
      reached.push(...page.activities.map((activity) => activity.processId));
      expect(page.omissions).toBeUndefined();
      cursor = page.nextCursor;
      pages += 1;
    } while (cursor);

    expect(pages).toBeGreaterThan(1);
    expect(reached).toEqual(expected);
  });

  it("reads subagent receipts only from the selected canonical branch", () => {
    const manager = SessionManager.inMemory("/tmp/process-branch", { id: "session-1" });
    const root = manager.appendMessage({
      role: "user", content: [{ type: "text", text: "root" }], timestamp: Date.parse("2026-01-01T00:00:00.000Z"),
    } as never);
    const abandoned = makeExtensionActivityReceipt({
      ...subagent,
      activityId: "abandoned-activity",
      toolCallId: "abandoned-tool",
      children: [{ ...subagent.children[0]!, id: "abandoned-child", label: "abandoned" }],
    }, "session-1")!;
    manager.appendCustomEntry(EXTENSION_ACTIVITY_RECEIPT_TYPE, abandoned);
    manager.branch(root);
    const selected = makeExtensionActivityReceipt({
      ...subagent,
      activityId: "selected-activity",
      toolCallId: "selected-tool",
      children: [{ ...subagent.children[0]!, id: "selected-child", label: "selected" }],
    }, "session-1")!;
    manager.appendCustomEntry(EXTENSION_ACTIVITY_RECEIPT_TYPE, selected);

    const history = canonicalProcessHistory(manager).filter((row) => row.kind === "subagent");
    expect(history.map((row) => row.title)).toEqual(["selected"]);
  });

  it("bounds ambient rows and authors a shallow aggregate", () => {
    const rows = Array.from({ length: 40 }, (_, index) => ({
      ...commandProcessFromTool("session-1", { ...tool(), toolCallId: `call-${index}`, progressSequence: index + 1 })!,
      processId: `process-${index}`,
    }));
    const bounded = boundProcessActivities(rows);
    expect(bounded.activities).toHaveLength(32);
    const overview = processOverview(bounded.activities, 7, "2026-01-01T00:00:02.000Z", {
      count: bounded.omittedCount,
      bytes: bounded.omittedBytes,
      reason: "count",
    });
    expect(overview).toMatchObject({ revision: 7, visibility: "active", activeCount: 32 });
    expect(overview.omissions?.count).toBe(8);
  });
});
