import { once } from "node:events";
import { Worker } from "node:worker_threads";
import { describe, expect, it } from "vitest";
import { EXTENSION_ACTIVITY_RECEIPT_TYPE, MAX_EXTENSION_HISTORY_BYTES, admitExtensionActivityReceipt, extensionActivityHistoryRevision, extensionReceiptActivity, listExtensionActivityHistory, makeExtensionActivityReceipt } from "./extension-activity-history.js";
import type { ExtensionRunActivity } from "../protocol/types.js";
import { admitExtensionLifecycleArtifact } from "./extension-run-projection.js";

const activity: ExtensionRunActivity = {
  id: "activity-1", activityId: "activity-1", toolCallId: "tool-1", source: { source: "extension" }, title: "work", status: "completed",
  startedAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:01.000Z", completedAt: "2026-01-01T00:00:01.000Z", children: [],
  lifecycle: { version: 1, state: "completed", attention: "none", sequence: 2, observedAt: "2026-01-01T00:00:01.000Z", terminalAt: "2026-01-01T00:00:01.000Z", recentUntil: "2026-01-01T00:15:01.000Z" },
};

describe("extension activity canonical receipts", () => {
  it("bounds receipt data and admits only terminal schema v1", () => {
    const receipt = makeExtensionActivityReceipt(activity, "session-1");
    expect(receipt).toMatchObject({ version: 1, activityId: "activity-1", sessionId: "session-1", state: "completed" });
    expect(JSON.stringify(receipt)).not.toContain("currentPath");
    expect(admitExtensionActivityReceipt({ ...receipt, state: "running" }, "session-1")).toBeUndefined();
    expect(admitExtensionActivityReceipt({ ...receipt, terminalAt: "2026-01-01T00:00:02.000Z" }, "session-1")).toBeUndefined();
    expect(admitExtensionActivityReceipt({ ...receipt, observedAt: "2025-12-31T23:59:59.000Z" }, "session-1")).toBeUndefined();
    expect(makeExtensionActivityReceipt(activity, "session-1", "2025-12-31T23:59:59.000Z")).toBeUndefined();
    expect(admitExtensionActivityReceipt({ ...receipt, owner: { id: "id", title: "Title", source: "/private/path" } }, "session-1")).toBeUndefined();
    const versionedLegacy = { lifecycleArtifactVersion: 2, runId: "run", state: "running", startedAt: 1, lastUpdate: 2 };
    expect(admitExtensionLifecycleArtifact(versionedLegacy)).toBeUndefined();
    expect(admitExtensionLifecycleArtifact(versionedLegacy, { exactOwnedLegacy: true })).toBeDefined();
    expect(admitExtensionLifecycleArtifact({ lifecycleArtifactVersion: 3, runId: "run", state: "running", startedAt: 1, lastUpdate: 2 })).toBeDefined();
    const unversionedLegacy = { runId: "run", state: "running", startedAt: 1, lastUpdate: 2 };
    expect(admitExtensionLifecycleArtifact(unversionedLegacy)).toBeUndefined();
    expect(admitExtensionLifecycleArtifact(unversionedLegacy, { exactOwnedLegacy: true })).toBeDefined();
  });

  it.each([
    { name: "cycle", parents: ["b", "a", undefined], admitted: false },
    { name: "ancestry entering a cycle", parents: ["b", "c", "b"], admitted: false },
    { name: "shared ancestor", parents: [undefined, "a", "a"], admitted: true },
  ])("settles receipt admission for $name", async ({ parents, admitted }) => {
    const receipt = {
      ...makeExtensionActivityReceipt(activity, "session-1")!,
      summary: { children: ["a", "b", "c"].map((id, index) => ({
        id, label: id, state: "completed", attention: "none", parentId: parents[index],
      })) },
    };
    // Isolate the real parser so a synchronous cycle regression cannot hang the
    // test runner. Startup and execution are bounded; cleanup is not a pass.
    const worker = new Worker(`
      const { parentPort, workerData } = require("node:worker_threads");
      import(workerData).then(({ admitExtensionActivityReceipt }) => {
        parentPort.on("message", receipt => {
          parentPort.postMessage({ admitted: admitExtensionActivityReceipt(receipt, "session-1") !== undefined });
        });
        parentPort.postMessage("ready");
      });
    `, {
      eval: true,
      execArgv: ["--experimental-strip-types"],
      workerData: new URL("./extension-activity-history.ts", import.meta.url).href,
    });
    try {
      expect(await once(worker, "message", { signal: AbortSignal.timeout(5_000) })).toEqual(["ready"]);
      const result = once(worker, "message", { signal: AbortSignal.timeout(1_000) });
      worker.postMessage(receipt);
      expect(await result).toEqual([{ admitted }]);
    } finally {
      await worker.terminate();
    }
  }, 10_000);

  it("pages byte-limited history without losing rows that fit a fresh page", () => {
    const receipt = {
      ...makeExtensionActivityReceipt(activity, "session-1")!,
      summary: { children: Array.from({ length: 64 }, (_, index) => ({
        id: String(index).padEnd(256, "i"), label: "λ".repeat(128),
        producerId: "p".repeat(256), sessionOwnerId: "s".repeat(256),
        childSessionRef: "r".repeat(256), state: "completed", attention: "none",
      })) },
    };
    expect(admitExtensionActivityReceipt(receipt, "session-1")?.summary?.children).toHaveLength(64);
    const rowBytes = Buffer.byteLength(JSON.stringify(extensionReceiptActivity(admitExtensionActivityReceipt(receipt)!)));
    expect(rowBytes).toBeLessThan(MAX_EXTENSION_HISTORY_BYTES);
    expect(rowBytes * 5).toBeGreaterThan(MAX_EXTENSION_HISTORY_BYTES);
    const entries = Array.from({ length: 5 }, (_, index) => ({
      id: `entry-${index}`, type: "custom", customType: EXTENSION_ACTIVITY_RECEIPT_TYPE,
      data: { ...receipt, activityId: `activity-${index}` },
    }));
    const expectedIDs = ["activity-4", "activity-3", "activity-2", "activity-1", "activity-0"];
    const ids: string[] = [];
    let cursor: string | undefined;
    let revision: string | undefined;
    for (let pageIndex = 0; pageIndex < entries.length; pageIndex += 1) {
      const page = listExtensionActivityHistory(entries, "session-1", cursor, 50);
      revision ??= page.historyRevision;
      expect(page.historyRevision).toBe(revision);
      expect(page.activities.length).toBeGreaterThan(0);
      expect(Buffer.byteLength(JSON.stringify(page.activities))).toBeLessThanOrEqual(MAX_EXTENSION_HISTORY_BYTES);
      expect.soft(page.omissions).toBeUndefined();
      ids.push(...page.activities.map((value) => value.activityId!));
      if (!page.nextCursor) { cursor = undefined; break; }
      expect(page.nextCursor).not.toBe(cursor);
      cursor = page.nextCursor;
    }
    expect(cursor).toBeUndefined();
    expect(ids).toEqual(expectedIDs);
  });

  it("reports and consumes individually oversized rows without stalling the next page", () => {
    const receipt = makeExtensionActivityReceipt(activity, "session-1")!;
    const oversized = { ...receipt, activityId: "oversized", summary: {
      children: Array.from({ length: 64 }, (_, index) => ({
        id: String(index).padEnd(256, "\u0001"), label: "\u0001".repeat(256),
        producerId: "\u0001".repeat(256), sessionOwnerId: "\u0001".repeat(256),
        childSessionRef: "\u0001".repeat(256), state: "completed", attention: "none",
      })),
    } };
    const admitted = admitExtensionActivityReceipt(oversized, "session-1");
    expect(admitted?.summary?.children).toHaveLength(64);
    const oversizedBytes = Buffer.byteLength(JSON.stringify(extensionReceiptActivity(admitted!)));
    expect(oversizedBytes).toBeGreaterThan(MAX_EXTENSION_HISTORY_BYTES);
    const entries = [oversized, receipt].map((data, index) => ({
      id: `entry-${index}`, type: "custom", customType: EXTENSION_ACTIVITY_RECEIPT_TYPE, data,
    }));
    const first = listExtensionActivityHistory(entries, "session-1", undefined, 1);
    expect(first.activities).toEqual([]);
    expect(first.omissions).toMatchObject({ count: 1, reason: "bytes" });
    expect(first.omissions!.bytes).toBeGreaterThanOrEqual(oversizedBytes);
    expect(first.nextCursor).toBeDefined();
    const second = listExtensionActivityHistory(entries, "session-1", first.nextCursor, 1);
    expect(second.activities.map((value) => value.activityId)).toEqual([activity.activityId]);
    expect(second.nextCursor).toBeUndefined();
    expect(second.omissions).toBeUndefined();
  });

  it("round-trips only child identity/rich state and aggregate counts", () => {
    const receipt = makeExtensionActivityReceipt({
      ...activity,
      toolCount: 4,
      turnCount: 2,
      children: [{
        id: "child", producerId: "workflow-key", sessionOwnerId: "child-run", label: "worker", status: "completed", lifecycle: "paused", attention: "needsAttention",
        childSessionRef: "opaque-child-session", task: "private", output: "private", currentPath: "/private",
        children: [{ id: "nested", label: "reviewer", status: "completed", lifecycle: "completed", childSessionRef: "opaque-nested-session" }],
      }],
    }, "session-1")!;
    expect(JSON.stringify(receipt)).not.toMatch(/task|output|currentPath|currentTool|lastActivityAt|durationMs/);
    const admitted = admitExtensionActivityReceipt(receipt, "session-1")!;
    const historical = extensionReceiptActivity(admitted);
    expect(historical).toMatchObject({
      toolCount: 4,
      turnCount: 2,
      children: [{
        id: "child", producerId: "workflow-key", sessionOwnerId: "child-run", label: "worker", status: "running", lifecycle: "paused", attention: "needsAttention",
        childSessionRef: "opaque-child-session",
        children: [{ id: "nested", label: "reviewer", childSessionRef: "opaque-nested-session" }],
      }],
    });
    expect(historical.lifecycle?.visibility).toBe("historical");
    const pathRef = makeExtensionActivityReceipt({
      ...activity,
      children: [{ id: "unsafe", label: "worker", status: "completed", childSessionRef: "/private/session.jsonl", sessionOwnerId: "/private/run" }],
    }, "session-1")!;
    expect(JSON.stringify(pathRef)).not.toContain("/private/session.jsonl");
    expect(JSON.stringify(pathRef)).not.toContain("/private/run");

    const owned = makeExtensionActivityReceipt({ ...activity, source: { source: "package-source", owner: { id: "owner", title: "Owner", source: "package-source" } } }, "session-1")!;
    expect(extensionReceiptActivity(owned).source).toEqual({ source: "package-source", owner: owned.owner });
  });

  it("derives one order-independent global revision for filtered pages and details", () => {
    const first = makeExtensionActivityReceipt(activity, "session-1")!;
    const second = { ...first, activityId: "activity-2", runId: "run-2", terminalAt: "2026-01-01T00:00:02.000Z", observedAt: "2026-01-01T00:00:02.000Z" };
    const entries = [
      { id: "one", type: "custom", customType: EXTENSION_ACTIVITY_RECEIPT_TYPE, data: first },
      { id: "two", type: "custom", customType: EXTENSION_ACTIVITY_RECEIPT_TYPE, data: second },
    ];
    const reversed = [...entries].reverse();
    const global = extensionActivityHistoryRevision(entries, "session-1");
    expect(extensionActivityHistoryRevision(reversed, "session-1")).toBe(global);
    const filtered = listExtensionActivityHistory(entries, "session-1", undefined, 1, undefined, { runId: "run-2" });
    expect(filtered.activities.map((value) => value.activityId)).toEqual(["activity-2"]);
    expect(filtered.historyRevision).toBe(global);
    expect(listExtensionActivityHistory(entries, "session-1").historyRevision).toBe(global);
  });

  it("binds identical canonical history to its session and rejects cross-session cursors", () => {
    const sessionOne = makeExtensionActivityReceipt(activity, "session-1")!;
    const sessionTwo = { ...sessionOne, sessionId: "session-2" };
    const makeEntries = (data: typeof sessionOne) => [
      { id: "same-entry", parentId: null, type: "custom", customType: EXTENSION_ACTIVITY_RECEIPT_TYPE, data },
      { id: "next-entry", parentId: "same-entry", type: "custom", customType: EXTENSION_ACTIVITY_RECEIPT_TYPE, data: { ...data, activityId: "activity-2" } },
    ];
    const firstEntries = makeEntries(sessionOne);
    const secondEntries = makeEntries(sessionTwo);
    const first = extensionActivityHistoryRevision(firstEntries, "session-1");
    const second = extensionActivityHistoryRevision(secondEntries, "session-2");
    expect(first).not.toBe(second);
    const firstPage = listExtensionActivityHistory(firstEntries, "session-1", undefined, 1);
    expect(listExtensionActivityHistory(secondEntries, "session-2").activities).toHaveLength(2);
    expect(firstPage.nextCursor).toBeDefined();
    expect(() => listExtensionActivityHistory(secondEntries, "session-2", firstPage.nextCursor)).toThrow(/conflict/);
  });

  it("keeps duplicate activity IDs as revision inputs while deduplicating page content", () => {
    const receipt = makeExtensionActivityReceipt(activity, "session-1")!;
    const duplicate = { ...receipt, terminalAt: "2026-01-01T00:00:02.000Z", observedAt: "2026-01-01T00:00:02.000Z" };
    const entries = [
      { id: "one", type: "custom", customType: EXTENSION_ACTIVITY_RECEIPT_TYPE, data: receipt },
      { id: "two", type: "custom", customType: EXTENSION_ACTIVITY_RECEIPT_TYPE, data: duplicate },
    ];
    const page = listExtensionActivityHistory(entries, "session-1");
    expect(page.activities).toHaveLength(1);
    expect(page.historyRevision).not.toBe(extensionActivityHistoryRevision([entries[0]], "session-1"));
  });

  it("pages reserved custom entries with immutable cursor revisions", () => {
    const first = makeExtensionActivityReceipt(activity, "session-1")!;
    const second = { ...first, activityId: "activity-2", terminalAt: "2026-01-01T00:00:02.000Z", observedAt: "2026-01-01T00:00:02.000Z" };
    const entries = [
      { id: "one", parentId: null, type: "custom", customType: EXTENSION_ACTIVITY_RECEIPT_TYPE, data: first },
      { id: "two", parentId: "one", type: "custom", customType: EXTENSION_ACTIVITY_RECEIPT_TYPE, data: second },
      { id: "ignored", type: "message", message: { role: "user" } },
    ];
    const page = listExtensionActivityHistory(entries, "session-1", undefined, 1);
    expect(page.activities.map((item) => item.activityId)).toEqual(["activity-2"]);
    expect(page.activities[0]).toMatchObject({ id: "activity-2", status: "completed", lifecycle: { visibility: "historical" } });
    expect(page.activities[0]).not.toHaveProperty("summary");
    expect(page.nextCursor).toBeDefined();
    expect(() => listExtensionActivityHistory([...entries, { ...entries[0], id: "changed" }], "session-1", page.nextCursor, 1)).toThrow(/conflict/);
  });
});
