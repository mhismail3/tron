import { describe, expect, it } from "vitest";
import { EXTENSION_ACTIVITY_RECEIPT_TYPE, admitExtensionActivityReceipt, extensionActivityHistoryRevision, extensionReceiptActivity, listExtensionActivityHistory, makeExtensionActivityReceipt } from "./extension-activity-history.js";
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

  it("round-trips only child identity/rich state and aggregate counts", () => {
    const receipt = makeExtensionActivityReceipt({
      ...activity,
      toolCount: 4,
      turnCount: 2,
      children: [{
        id: "child", label: "worker", status: "completed", lifecycle: "paused", attention: "needsAttention",
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
        id: "child", label: "worker", status: "running", lifecycle: "paused", attention: "needsAttention",
        childSessionRef: "opaque-child-session",
        children: [{ id: "nested", label: "reviewer", childSessionRef: "opaque-nested-session" }],
      }],
    });
    expect(historical.lifecycle?.visibility).toBe("historical");
    const pathRef = makeExtensionActivityReceipt({
      ...activity,
      children: [{ id: "unsafe", label: "worker", status: "completed", childSessionRef: "/private/session.jsonl" }],
    }, "session-1")!;
    expect(JSON.stringify(pathRef)).not.toContain("/private/session.jsonl");

    const owned = makeExtensionActivityReceipt({ ...activity, source: { source: "package-source", owner: { id: "owner", title: "Owner", source: "package-source" } } }, "session-1")!;
    expect(extensionReceiptActivity(owned).source).toEqual({ source: "package-source", owner: owned.owner });
  });

  it("derives one order-independent global revision for filtered pages and details", () => {
    const first = makeExtensionActivityReceipt(activity, "session-1")!;
    const second = { ...first, activityId: "activity-2", runId: "run-2", terminalAt: "2026-01-01T00:00:02.000Z" };
    const entries = [
      { id: "one", type: "custom", customType: EXTENSION_ACTIVITY_RECEIPT_TYPE, data: first },
      { id: "two", type: "custom", customType: EXTENSION_ACTIVITY_RECEIPT_TYPE, data: second },
    ];
    const reversed = [...entries].reverse();
    const global = extensionActivityHistoryRevision(entries, "session-1");
    expect(extensionActivityHistoryRevision(reversed, "session-1")).toBe(global);
    expect(listExtensionActivityHistory(entries, "session-1", undefined, 1, undefined, { runId: "run-2" }).historyRevision).toBe(global);
    expect(listExtensionActivityHistory(entries, "session-1").historyRevision).toBe(global);
  });

  it("binds identical canonical history to its session and rejects cross-session cursors", () => {
    const sessionOne = makeExtensionActivityReceipt(activity, "session-1")!;
    const sessionTwo = { ...sessionOne, sessionId: "session-2" };
    const makeEntries = (data: typeof sessionOne) => [
      { id: "same-entry", parentId: "same-parent", type: "custom", customType: EXTENSION_ACTIVITY_RECEIPT_TYPE, data },
    ];
    const firstEntries = makeEntries(sessionOne);
    const secondEntries = makeEntries(sessionTwo);
    const first = extensionActivityHistoryRevision(firstEntries, "session-1");
    const second = extensionActivityHistoryRevision(secondEntries, "session-2");
    expect(first).not.toBe(second);
    const firstPage = listExtensionActivityHistory(firstEntries, "session-1", undefined, 1);
    expect(listExtensionActivityHistory(secondEntries, "session-2").activities).toHaveLength(1);
    expect(() => listExtensionActivityHistory(secondEntries, "session-2", firstPage.nextCursor)).not.toThrow();
    const cursor = `${firstPage.historyRevision}:0`;
    expect(() => listExtensionActivityHistory(secondEntries, "session-2", cursor)).toThrow(/conflict/);
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
