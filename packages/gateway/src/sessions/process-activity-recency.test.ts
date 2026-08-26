import { describe, expect, it, vi } from "vitest";
import type { SessionProcessActivity } from "../protocol/types.js";
import { PROCESS_ACTIVITY_RECENT_MS, ProcessActivityRecency, type ProcessActivityClock } from "./process-activity-recency.js";

class Clock implements ProcessActivityClock {
  wall = Date.parse("2026-01-01T00:00:00.000Z");
  mono = 1_000;
  callback: (() => void) | undefined;
  delay: number | undefined;
  wallNow = () => this.wall;
  monotonicNow = () => this.mono;
  setTimeout = (callback: () => void, delay: number) => { this.callback = callback; this.delay = delay; return callback; };
  clearTimeout = () => { this.callback = undefined; this.delay = undefined; };
  advance(milliseconds: number) { this.wall += milliseconds; this.mono += milliseconds; }
}

function activity(state: SessionProcessActivity["lifecycle"]["state"], sequence = 1): SessionProcessActivity {
  const terminal = state === "completed" || state === "failed";
  const terminalAt = "2026-01-01T00:00:00.000Z";
  return {
    version: 1,
    processId: "process:subagent:test",
    kind: "subagent",
    executionMode: "asynchronous",
    source: "delegatedAgent",
    lifecycle: {
      version: 1,
      state,
      attention: "none",
      sequence,
      observedAt: terminalAt,
      ...(terminal ? { terminalAt, recentUntil: new Date(Date.parse(terminalAt) + 900_000).toISOString() } : {}),
    },
    visibility: terminal ? "recent" : "active",
    title: "worker",
    outputTruncated: false,
  };
}

describe("ProcessActivityRecency", () => {
  it("owns the exact five-minute deadline regardless of a producer deadline", () => {
    const clock = new Clock();
    const recency = new ProcessActivityRecency(clock);
    const installed = recency.upsert(activity("completed"));
    expect(installed.activity.lifecycle.recentUntil).toBe("2026-01-01T00:05:00.000Z");
    expect(clock.delay).toBe(PROCESS_ACTIVITY_RECENT_MS);

    clock.advance(PROCESS_ACTIVITY_RECENT_MS - 1);
    expect(recency.currentAndRecent().activities).toHaveLength(1);
    clock.advance(1);
    expect(recency.currentAndRecent().activities).toHaveLength(0);
  });

  it("keeps active work regardless of age and rejects terminal resurrection", () => {
    const clock = new Clock();
    const recency = new ProcessActivityRecency(clock);
    recency.upsert(activity("running", 1));
    clock.advance(PROCESS_ACTIVITY_RECENT_MS * 10);
    expect(recency.currentAndRecent().activities[0]?.visibility).toBe("active");

    const latchClock = new Clock();
    const latch = new ProcessActivityRecency(latchClock);
    latch.upsert(activity("completed", 2));
    expect(latch.upsert(activity("running", 3)).accepted).toBe(false);
    expect(latch.currentAndRecent().activities[0]?.lifecycle.state).toBe("completed");
  });

  it("retains a bounded terminal latch after ambient expiry", () => {
    const clock = new Clock();
    const recency = new ProcessActivityRecency(clock);
    recency.upsert(activity("completed", 2));
    clock.advance(PROCESS_ACTIVITY_RECENT_MS);
    clock.callback?.();
    expect(recency.currentAndRecent().activities).toEqual([]);
    expect(recency.upsert(activity("running", 99)).accepted).toBe(false);
    expect(recency.currentAndRecent().activities).toEqual([]);
  });

  it("does not retain unknown evidence without an expiry", () => {
    const clock = new Clock();
    const recency = new ProcessActivityRecency(clock);
    const unknown = {
      ...activity("running"),
      lifecycle: { ...activity("running").lifecycle, state: "unknown" as const },
      visibility: "unknown" as const,
    };
    expect(recency.upsert(unknown).accepted).toBe(false);
    expect(recency.currentAndRecent().activities).toEqual([]);
    expect(clock.delay).toBeUndefined();
  });

  it("fails closed instead of extending recency for implausible future timestamps", () => {
    const clock = new Clock();
    const recency = new ProcessActivityRecency(clock);
    const future = activity("completed");
    const terminalAt = new Date(clock.wall + 60 * 60_000).toISOString();
    const installed = recency.upsert({
      ...future,
      lifecycle: { ...future.lifecycle, terminalAt, observedAt: terminalAt },
    });
    expect(installed.activity.visibility).toBe("historical");
    expect(recency.currentAndRecent().activities).toEqual([]);
  });

  it("publishes one expiry callback without deleting canonical history", () => {
    const clock = new Clock();
    const recency = new ProcessActivityRecency(clock);
    const callback = vi.fn();
    recency.registerExpiryCallback(callback);
    recency.upsert(activity("failed"));
    clock.advance(PROCESS_ACTIVITY_RECENT_MS);
    clock.callback?.();
    expect(callback).toHaveBeenCalledOnce();
    expect(callback.mock.calls[0]?.[0].expiredProcessIds).toEqual(["process:subagent:test"]);
  });
});
