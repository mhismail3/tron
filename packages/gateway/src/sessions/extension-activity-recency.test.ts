import { describe, expect, it } from "vitest";
import type { ExtensionRunActivity } from "../protocol/types.js";
import { ExtensionActivityRecency, type ExtensionActivityClock } from "./extension-activity-recency.js";

function clock(start = Date.parse("2026-01-01T00:00:00.000Z")) {
  let wall = start;
  let mono = 0;
  const timers: Array<{ at: number; callback: () => void }> = [];
  const value: ExtensionActivityClock = {
    wallNow: () => wall,
    monotonicNow: () => mono,
    setTimeout: (callback, delayMs) => { timers.push({ at: mono + delayMs, callback }); return callback; },
    clearTimeout: (handle) => { const index = timers.findIndex((timer) => timer.callback === handle); if (index >= 0) timers.splice(index, 1); },
  };
  return { value, advance(ms: number) { wall += ms; mono += ms; for (const timer of timers.splice(0)) if (timer.at <= mono) timer.callback(); }, setWall(valueMs: number) { wall = valueMs; } };
}

function activity(terminalAt?: string): ExtensionRunActivity {
  return {
    id: "tool-1", activityId: "session/tool-1", toolCallId: "tool-1", source: { source: "ext" }, title: "tool", status: terminalAt ? "completed" : "running", startedAt: "2026-01-01T00:00:00.000Z", updatedAt: terminalAt ?? "2026-01-01T00:00:00.000Z", children: [],
    ...(terminalAt ? { completedAt: terminalAt, lifecycle: { version: 1 as const, state: "completed" as const, attention: "none" as const, sequence: 1, observedAt: terminalAt, terminalAt, recentUntil: new Date(Date.parse(terminalAt) + 900_000).toISOString() } } : {}),
  };
}

describe("ExtensionActivityRecency", () => {
  it("keeps terminal work at 14:59.999 and removes it exactly at 15 minutes", () => {
    const testClock = clock();
    const recency = new ExtensionActivityRecency(testClock.value);
    const expiryFrames: Array<{ count: number; revision: number; asOf: string }> = [];
    recency.registerExpiryCallback((frame) => expiryFrames.push({ count: frame.expiredActivityIds.length, revision: frame.revision, asOf: frame.asOf }));
    recency.upsert(activity("2026-01-01T00:00:00.000Z"));
    testClock.advance(899_999);
    expect(recency.currentAndRecent().activities).toHaveLength(1);
    testClock.advance(1);
    expect(recency.currentAndRecent().activities).toHaveLength(0);
    expect(expiryFrames).toEqual([{ count: 1, revision: 2, asOf: "2026-01-01T00:15:00.000Z" }]);
  });

  it("reconstructs restart remaining from recentUntil minus wallNow", () => {
    const testClock = clock();
    const recency = new ExtensionActivityRecency(testClock.value);
    recency.upsert(activity("2026-01-01T00:00:00.000Z"));
    testClock.setWall(Date.parse("2026-01-01T00:05:00.000Z"));
    expect(recency.visibility(activity("2026-01-01T00:00:00.000Z"))).toMatchObject({ visibility: "recent", remainingMs: 600_000 });
  });

  it("does not serialize terminal recency onto current work", () => {
    const testClock = clock();
    const recency = new ExtensionActivityRecency(testClock.value);
    expect(recency.upsert(activity())).toEqual({
      visibility: "current",
      accepted: true,
    });
    testClock.setWall(Date.parse("2030-01-01T00:00:00.000Z"));
    expect(recency.currentAndRecent().activities).toHaveLength(1);
    expect(recency.visibility(activity())).toEqual({ visibility: "current" });
  });

  it("keeps a scheduled recent deadline monotonic across a wall-clock jump", () => {
    const testClock = clock();
    const recency = new ExtensionActivityRecency(testClock.value);
    recency.upsert(activity("2026-01-01T00:00:00.000Z"));
    testClock.setWall(Date.parse("2030-01-01T00:00:00.000Z"));
    expect(recency.currentAndRecent().activities).toHaveLength(1);
    testClock.advance(899_999);
    expect(recency.currentAndRecent().activities).toHaveLength(1);
    testClock.advance(1);
    expect(recency.currentAndRecent().activities).toHaveLength(0);
  });
});
