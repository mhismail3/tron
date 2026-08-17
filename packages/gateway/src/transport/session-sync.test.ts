import { describe, expect, it } from "vitest";
import type { SessionSnapshot } from "../protocol/types.js";
import { MAX_BUFFERED_SYNC_BYTES, MAX_BUFFERED_SYNC_EVENTS, SessionSyncBarrier } from "./session-sync.js";

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
    extensionPresentation: { version: 2, hostEpoch: "test-host", revision: 0, capabilities: [], diagnostics: [], semanticState: { statuses: {}, working: { visible: false, indicator: { kind: "default", frames: [] } }, widgets: [], toolsExpanded: false, editorRevision: 0, editorText: "" }, surfaces: [], pendingInteractions: [] },
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

function eventWithData(data: string, sequenceNumber = 1) {
  return {
    type: "event" as const,
    topic: "session.progress",
    sessionId: "session",
    payload: { runtimeGeneration: "generation", eventSequence: sequenceNumber, revision: sequenceNumber, data },
  };
}

function eventExactlyBytes(target: number) {
  const empty = eventWithData("");
  const emptyBytes = Buffer.byteLength(JSON.stringify(empty), "utf8");
  return eventWithData("x".repeat(target - emptyBytes));
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
    for (let sequence = 1; sequence <= MAX_BUFFERED_SYNC_EVENTS + 1; sequence += 1) barrier.offer(event(sequence));
    expect(barrier.commit("request")).toEqual({ events: [], overflowed: true });
  });

  it("retains an event exactly at the serialized byte budget", () => {
    const barrier = new SessionSyncBarrier();
    const boundary = eventExactlyBytes(MAX_BUFFERED_SYNC_BYTES);
    expect(Buffer.byteLength(JSON.stringify(boundary), "utf8")).toBe(MAX_BUFFERED_SYNC_BYTES);
    barrier.begin("request");
    barrier.establish(snapshot(0));
    expect(barrier.offer(boundary)).toBeUndefined();
    expect(barrier.commit("request")).toEqual({ events: [boundary], overflowed: false });
  });

  it("overflows and clears when aggregate serialized bytes exceed the budget", () => {
    const barrier = new SessionSyncBarrier();
    const first = eventWithData("x".repeat(Math.floor(MAX_BUFFERED_SYNC_BYTES / 2)));
    const second = eventWithData("x".repeat(Math.floor(MAX_BUFFERED_SYNC_BYTES / 2)), 2);
    barrier.begin("request");
    barrier.establish(snapshot(0));
    barrier.offer(first);
    barrier.offer(second);
    expect(barrier.commit("request")).toEqual({ events: [], overflowed: true });
  });

  it("treats one oversized or unserializable event as overflow and retains nothing afterward", () => {
    const barrier = new SessionSyncBarrier();
    barrier.begin("request");
    barrier.establish(snapshot(0));
    expect(barrier.offer(eventWithData("x".repeat(MAX_BUFFERED_SYNC_BYTES + 1)))).toBeUndefined();
    expect(barrier.offer(event(2))).toBeUndefined();
    expect(barrier.commit("request")).toEqual({ events: [], overflowed: true });

    barrier.begin("next-request");
    barrier.establish(snapshot(0));
    const unserializable = eventWithData("") as unknown as { payload: { data: unknown } };
    unserializable.payload.data = BigInt(1);
    expect(barrier.offer(unserializable as any)).toBeUndefined();
    expect(barrier.commit("next-request")).toEqual({ events: [], overflowed: true });
  });

  it("resets byte accounting after commit and abort", () => {
    const barrier = new SessionSyncBarrier();
    const boundary = eventExactlyBytes(MAX_BUFFERED_SYNC_BYTES);
    barrier.begin("first");
    barrier.establish(snapshot(0));
    barrier.offer(boundary);
    expect(barrier.commit("first").overflowed).toBe(false);

    barrier.begin("second");
    barrier.establish(snapshot(0));
    barrier.offer(boundary);
    expect(barrier.abort("second")).toBe(true);
    barrier.begin("third");
    barrier.establish(snapshot(0));
    barrier.offer(boundary);
    expect(barrier.commit("third").overflowed).toBe(false);
  });
});
