import { describe, expect, it } from "vitest";
import type { SessionSnapshot } from "../protocol/types.js";
import { SessionSyncBarrier } from "./session-sync.js";

function snapshot(sequence: number): SessionSnapshot {
  return {
    sessionId: "session",
    runtimeGeneration: "generation",
    revision: sequence,
    eventSequence: sequence,
    phase: "running",
    cwd: "/workspace",
    thinkingLevel: "off",
    availableThinkingLevels: ["off"],
    stats: {
      userMessages: 0, assistantMessages: 0, toolCalls: 0, toolResults: 0, totalMessages: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }, cost: 0,
    },
    queued: { steering: [], followUp: [] },
    transcript: [], transcriptStart: 0, transcriptTotal: 0,
    toolExecutions: [],
    extensionUI: { statuses: {}, working: { visible: false }, widgets: [], editorRevision: 0, editorText: "", pendingInteractions: [] },
    diagnostics: [],
  };
}

function event(sequence: number, generation = "generation") {
  return {
    type: "event" as const,
    topic: "session.progress",
    sessionId: "session",
    payload: { runtimeGeneration: generation, eventSequence: sequence, revision: sequence, data: {} },
  };
}

describe("atomic session synchronization barrier", () => {
  it("captures events that arrive before the baseline is read", () => {
    const barrier = new SessionSyncBarrier();
    barrier.begin("request");
    barrier.offer(event(11));
    barrier.establish(snapshot(10));
    expect(barrier.commit("request")).toEqual({ events: [event(11)], overflowed: false });
  });

  it("quarantines events until after the baseline and removes covered events", () => {
    const barrier = new SessionSyncBarrier();
    barrier.begin("request");
    barrier.establish(snapshot(10));
    expect(barrier.offer(event(10))).toBeUndefined();
    expect(barrier.offer(event(11))).toBeUndefined();
    expect(barrier.commit("request")).toEqual({ events: [event(11)], overflowed: false });
  });

  it("retains a new runtime generation even when its sequence restarted", () => {
    const barrier = new SessionSyncBarrier();
    barrier.begin("request");
    barrier.establish(snapshot(100));
    barrier.offer(event(1, "replacement"));
    expect(barrier.commit("request")).toEqual({ events: [event(1, "replacement")], overflowed: false });
  });

  it("converts an unbounded catch-up into an explicit resync requirement", () => {
    const barrier = new SessionSyncBarrier();
    barrier.begin("request");
    barrier.establish(snapshot(0));
    for (let sequence = 1; sequence <= 1_100; sequence += 1) barrier.offer(event(sequence));
    expect(barrier.commit("request")).toEqual({ events: [], overflowed: true });
  });
});
