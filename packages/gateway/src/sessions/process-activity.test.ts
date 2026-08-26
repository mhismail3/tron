import { describe, expect, it } from "vitest";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import type { ExtensionRunActivity } from "../protocol/types.js";
import { EXTENSION_ACTIVITY_RECEIPT_TYPE, makeExtensionActivityReceipt } from "./extension-activity-history.js";
import {
  boundProcessActivities,
  canonicalProcessHistory,
  listProcessHistory,
  processOverview,
  redactProcessText,
  subagentProcessesFromActivity,
} from "./process-activity.js";

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
  it("redacts delegated output previews", () => {
    const secret = "API_KEY=top-secret curl -H 'Authorization: Bearer abc123' https://user:pass@example.test";
    expect(redactProcessText(secret)).not.toMatch(/top-secret|abc123|:pass@/u);
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

  it("keeps foreground parallel and chain children synchronous", () => {
    for (const mode of ["parallel", "chain"]) {
      const rows = subagentProcessesFromActivity("session-1", { ...subagent, mode });
      expect(rows).toEqual([expect.objectContaining({ executionMode: "synchronous", title: "worker" })]);
    }
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

  it("does not project supervisor or control receipts without a delegated execution mode", () => {
    expect(subagentProcessesFromActivity("session-1", {
      ...subagent,
      mode: undefined,
      children: [],
      currentTool: "subagent_supervisor",
    })).toEqual([]);
    expect(subagentProcessesFromActivity("session-1", {
      ...subagent,
      mode: undefined,
      children: [{
        id: "control-run", producerId: "control-run", label: "control", status: "completed",
        lifecycle: "completed", currentTool: "subagent_supervisor",
      }],
    })).toEqual([]);
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

  it("keeps canonical bash in JSONL but exposes only receipt-backed subagents", () => {
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
    expect(history.map((row) => row.kind)).toEqual(["subagent"]);
    expect(history[0]).toMatchObject({
      childSessionRef: "child-session-1",
      durationMs: 2_000,
      visibility: "historical",
    });

    expect(listProcessHistory(manager, undefined, 25).activities).toHaveLength(1);
    expect(listProcessHistory(manager, undefined, 25, { kind: "command" }).activities).toEqual([]);
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

  it("keeps subagent history rows reachable across stable cursors", () => {
    const manager = SessionManager.inMemory("/tmp/process-pages", { id: "session-pages" });
    for (let index = 0; index < 12; index += 1) {
      const receipt = makeExtensionActivityReceipt({
        ...subagent,
        activityId: `activity-${index}`,
        toolCallId: `call-${index}`,
        children: [{
          ...subagent.children[0]!,
          id: `child-${index}`,
          producerId: `child-${index}`,
          childSessionRef: `session-${index}`,
        }],
      }, "session-pages")!;
      manager.appendCustomEntry(EXTENSION_ACTIVITY_RECEIPT_TYPE, receipt);
    }
    const expected = canonicalProcessHistory(manager).map((activity) => activity.processId);
    const first = listProcessHistory(manager, undefined, 5);
    const second = listProcessHistory(manager, first.nextCursor, 50);
    expect(first.activities.map((activity) => activity.processId)
      .concat(second.activities.map((activity) => activity.processId))).toEqual(expected);
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

  it("bounds subagent rows and authors a shallow aggregate", () => {
    const rows = Array.from({ length: 40 }, (_, index) => subagentProcessesFromActivity("session-1", {
      ...subagent,
      toolCallId: `call-${index}`,
      status: "running",
      completedAt: undefined,
      lifecycle: {
        version: 1, state: "running", attention: "none", sequence: index + 1,
        observedAt: "2026-01-01T00:00:01.000Z",
      },
      children: [{
        id: `child-${index}`, producerId: `child-${index}`, label: "worker",
        status: "running", lifecycle: "running", currentTool: "read",
      }],
    })[0]!);
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
