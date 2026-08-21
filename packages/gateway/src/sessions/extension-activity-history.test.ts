import { describe, expect, it } from "vitest";
import { EXTENSION_ACTIVITY_RECEIPT_TYPE, admitExtensionActivityReceipt, extensionReceiptActivity, listExtensionActivityHistory, makeExtensionActivityReceipt } from "./extension-activity-history.js";
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
      children: [{ id: "child", label: "worker", status: "completed", lifecycle: "paused", attention: "needsAttention", task: "private", output: "private", currentPath: "/private" }],
    }, "session-1")!;
    expect(JSON.stringify(receipt)).not.toMatch(/task|output|currentPath|currentTool|lastActivityAt|durationMs/);
    const admitted = admitExtensionActivityReceipt(receipt, "session-1")!;
    const historical = extensionReceiptActivity(admitted);
    expect(historical).toMatchObject({ toolCount: 4, turnCount: 2, children: [{ id: "child", label: "worker", status: "running", lifecycle: "paused", attention: "needsAttention" }] });
    expect(historical.lifecycle?.visibility).toBe("historical");
  });

  it("pages reserved custom entries with immutable cursor revisions", () => {
    const first = makeExtensionActivityReceipt(activity, "session-1")!;
    const second = { ...first, activityId: "activity-2", terminalAt: "2026-01-01T00:00:02.000Z" };
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
