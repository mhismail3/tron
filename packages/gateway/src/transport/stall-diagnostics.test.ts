import type { EventLoopUtilization } from "node:perf_hooks";
import { afterEach, describe, expect, it, vi } from "vitest";
import { GATEWAY_CONNECTION_POLICY } from "./connection-policy.js";
import { GatewayServer } from "./server.js";
import { formatStallEvidence, parseMemoryPressure, parseSwapUsedBytes, StallSampler, type HostMemory } from "./stall-diagnostics.js";

/** Cumulative busy/idle clock; two marks give their delta like Node's API. */
function fakeUtilization() {
  const clock = { active: 0, idle: 0 };
  const mark = (): EventLoopUtilization => ({ active: clock.active, idle: clock.idle, utilization: 0 });
  const eventLoopUtilization = (current?: EventLoopUtilization, previous?: EventLoopUtilization): EventLoopUtilization => {
    if (!current) return mark();
    if (!previous) return current;
    const active = current.active - previous.active;
    const idle = current.idle - previous.idle;
    return { active, idle, utilization: active + idle === 0 ? 0 : active / (active + idle) };
  };
  return { clock, eventLoopUtilization };
}

function fakeGc() {
  let emit!: (durationMs: number) => void;
  let disposed = false;
  return {
    observeGc: (onPause: (durationMs: number) => void) => { emit = onPause; return () => { disposed = true; }; },
    pause: (durationMs: number) => emit(durationMs),
    disposed: () => disposed,
  };
}

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe("StallSampler", () => {
  it("measures GC pauses and utilization over exactly one heartbeat window", () => {
    const utilization = fakeUtilization();
    const gc = fakeGc();
    const sampler = new StallSampler({ ...utilization, observeGc: gc.observeGc, sampleHost: async () => ({ freeBytes: 0, totalBytes: 0 }) });
    gc.pause(120); gc.pause(480.4);
    utilization.clock.active += 900; utilization.clock.idle += 100;
    expect(sampler.closeWindow()).toEqual({ gcCount: 2, gcPauseMs: 600.4, gcMaxPauseMs: 480.4, utilization: 0.9 });
    utilization.clock.idle += 1_000;
    expect(sampler.closeWindow()).toEqual({ gcCount: 0, gcPauseMs: 0, gcMaxPauseMs: 0, utilization: 0 });
    sampler.dispose();
    expect(gc.disposed()).toBe(true);
  });

  it("bounds the host probe and runs one at a time", async () => {
    vi.useFakeTimers();
    let resolve!: (value: HostMemory) => void;
    const sampler = new StallSampler({
      ...fakeUtilization(), observeGc: fakeGc().observeGc,
      sampleHost: () => new Promise((next) => { resolve = next; }),
    });
    const first = sampler.hostMemory();
    await expect(sampler.hostMemory()).resolves.toBeUndefined();
    await vi.advanceTimersByTimeAsync(1_000);
    await expect(first).resolves.toBeUndefined();
    const second = sampler.hostMemory();
    resolve({ freeBytes: 1, totalBytes: 2, swapUsedBytes: 3, pressure: "critical" });
    await expect(second).resolves.toEqual({ freeBytes: 1, totalBytes: 2, swapUsedBytes: 3, pressure: "critical" });
  });

  it("parses macOS swap usage and memory pressure", () => {
    expect(parseSwapUsedBytes("total = 23552.00M  used = 22886.40M  free = 665.60M  (encrypted)")).toBe(Math.round(22886.4 * 1_024 ** 2));
    expect(parseSwapUsedBytes("total = 0.00M  used = 0.00M  free = 0.00M  (encrypted)")).toBe(0);
    expect(parseSwapUsedBytes("unexpected")).toBeUndefined();
    expect(["1\n", "2", "4", "3"].map(parseMemoryPressure)).toEqual(["normal", "warn", "critical", undefined]);
    expect(formatStallEvidence({ gcCount: 1, gcPauseMs: 2.6, gcMaxPauseMs: 2.6, utilization: 0.456 }, undefined))
      .toBe("gcCount=1 gcPauseMs=3 gcMaxPauseMs=3 eventLoopUtilization=0.46 host=unavailable");
  });
});

// Regression: 6–36 s stalls on 2026-09-23 could not be attributed to GC,
// host paging, or the Gateway's own work.
it("attaches stall evidence to a delayed-heartbeat record", async () => {
  vi.useFakeTimers({ toFake: ["setInterval", "clearInterval", "setTimeout", "clearTimeout"] });
  let now = 10_000;
  vi.spyOn(performance, "now").mockImplementation(() => now);
  const utilization = fakeUtilization();
  const gc = fakeGc();
  const sampler = new StallSampler({
    ...utilization, observeGc: gc.observeGc,
    sampleHost: async () => ({ freeBytes: 1_000, totalBytes: 8_000, swapUsedBytes: 7_000, pressure: "warn" }),
  });
  const log = vi.fn();
  const gateway = new GatewayServer({
    host: "127.0.0.1", port: 0, maxFrameBytes: 16_384, devices: {} as never, uploads: {} as never, sessions: {} as never,
    auth: {} as never, service: { info: () => ({ protocolVersion: 5 }) } as never, logger: { log } as never, stallSampler: sampler,
  });
  const interval = GATEWAY_CONNECTION_POLICY.heartbeatIntervalMs;
  // An on-time heartbeat closes a window without a record.
  now += interval;
  await vi.advanceTimersByTimeAsync(interval);
  expect(log.mock.calls.filter((call) => call[2]?.event === "gateway.event-loop-delay")).toEqual([]);
  // The next window stalls: a 6.2 s GC pause inside a mostly busy loop.
  gc.pause(6_200);
  utilization.clock.active += 7_000; utilization.clock.idle += 3_000;
  now += interval + 7_000;
  await vi.advanceTimersByTimeAsync(interval);
  await vi.waitFor(() => expect(log.mock.calls.some((call) => call[2]?.event === "gateway.event-loop-delay")).toBe(true));
  const [level, message, metadata] = log.mock.calls.find((call) => call[2]?.event === "gateway.event-loop-delay")!;
  expect(level).toBe("warning");
  expect(metadata).toMatchObject({ event: "gateway.event-loop-delay", source: "transport", durationMs: 7_000 });
  expect(message).toContain("delayed heartbeat by 7000ms");
  expect(message).toContain("gcCount=1 gcPauseMs=6200 gcMaxPauseMs=6200 eventLoopUtilization=0.70");
  expect(message).toContain("hostFreeBytes=1000 hostTotalBytes=8000 swapUsedBytes=7000 memoryPressure=warn");
  expect(message).toContain("connections=0");
  await gateway.close();
  expect(gc.disposed()).toBe(true);
});
