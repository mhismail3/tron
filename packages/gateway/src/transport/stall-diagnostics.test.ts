import type { EventLoopUtilization } from "node:perf_hooks";
import { afterEach, describe, expect, it, vi } from "vitest";
import { GATEWAY_CONNECTION_POLICY } from "./connection-policy.js";
import { GatewayServer } from "./server.js";
import { formatStallEvidence, formatResourceSample, formatUnaudiencedWork, parseMemoryPressure, parseSwapUsedBytes, resourceSampleLevel, ResourceSampler, StallSampler, type HostMemory, type ResourceRuntimeEntry } from "./stall-diagnostics.js";

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

// Failure modes these cases cover, written before the sampler existed: (1) a
// window's counters are dropped or reported twice; (2) the event-loop delay
// window is not closed per sample, so a momentary stall is a permanent max;
// (3) the heap share is computed against a wrong limit, so the warning never
// fires; (4) a threshold crossing does not promote the level, so it stays in
// the memory-only debug buffer; (5) unaudienced snapshot work is folded into
// the normal count and never gets its own record; (6) unbounded topics or
// runtimes grow the record past one line; (7) a non-finite measurement (an
// empty histogram, a failed probe) is written as NaN.
function resourceSampler(dependencies: ConstructorParameters<typeof ResourceSampler>[0] = {}) {
  return new ResourceSampler({
    readRuntimes: async () => [],
    durableWrites: () => ({ count: 3, ms: 12 }),
    memoryUsage: () => ({ heapUsed: 1_000, rss: 2_000 }),
    heapLimitBytes: () => 10_000,
    eventLoopDelay: () => ({ p50Ms: 1, p99Ms: 2, maxMs: 9 }),
    ...dependencies,
  });
}

describe("ResourceSampler", () => {
  it("reports each window's work once and starts the next window at zero", async () => {
    const sampler = resourceSampler();
    sampler.recordTopicFrame("session.progress", 2_000, 2);
    sampler.recordTopicFrame("session.progress", 3_000, 1);
    sampler.recordCatalogWalk(120.4, 3_000);
    sampler.recordOutboundBytes(700);
    sampler.recordSnapshotBuild(1);
    sampler.recordSnapshotBuild(0);
    const first = await sampler.sample();
    expect(first.topics.get("session.progress")).toEqual({ frames: 2, bytes: 5_000, subscribers: 2 });
    expect(first).toMatchObject({
      catalogWalks: 1, catalogWalkMs: 120.4, catalogWalkFiles: 3_000, outboundBytes: 700,
      snapshotBuilds: 2, unaudiencedSnapshotBuilds: 1, durableWrites: 3, durableWriteMs: 12,
    });
    const second = await sampler.sample();
    expect(second.topics.size).toBe(0);
    expect(second).toMatchObject({ catalogWalks: 0, catalogWalkMs: 0, catalogWalkFiles: 0, outboundBytes: 0, snapshotBuilds: 0, unaudiencedSnapshotBuilds: 0 });
  });

  it("reads the event-loop delay window once per sample and never reports a non-finite value", async () => {
    const reads = vi.fn(() => ({ p50Ms: 1, p99Ms: 2, maxMs: 9 }));
    const sampler = resourceSampler({
      eventLoopDelay: reads,
      memoryUsage: () => ({ heapUsed: Number.NaN, rss: Number.POSITIVE_INFINITY }),
      heapLimitBytes: () => 0,
    });
    const sample = await sampler.sample();
    expect(reads).toHaveBeenCalledTimes(1);
    expect(sample).toMatchObject({ eventLoopDelayP50Ms: 1, eventLoopDelayP99Ms: 2, eventLoopDelayMaxMs: 9, heapUsedBytes: 0, rssBytes: 0 });
    expect(Number.isFinite(sample.eventLoopUtilization)).toBe(true);
    expect(formatResourceSample(sample)).toContain("heapShare=0.00");
    await sampler.sample();
    expect(reads).toHaveBeenCalledTimes(2);
  });

  it("promotes a sample past the heap or event-loop bound to warning", async () => {
    expect(resourceSampleLevel(await resourceSampler().sample())).toEqual({ level: "debug" });
    const loaded = await resourceSampler({ memoryUsage: () => ({ heapUsed: 7_000, rss: 1 }), heapLimitBytes: () => 10_000 }).sample();
    expect(resourceSampleLevel(loaded)).toEqual({ level: "warning", reason: "heapShare=0.70 at or above 0.7" });
    const delayed = await resourceSampler({ eventLoopDelay: () => ({ p50Ms: 1, p99Ms: 100, maxMs: 200 }) }).sample();
    expect(resourceSampleLevel(delayed)).toEqual({ level: "warning", reason: "eventLoopDelayP99Ms=100 at or above 100" });
  });

  it("reports a runtime load or eviction as the window's transition", async () => {
    const runtimes: ResourceRuntimeEntry[] = [];
    const sampler = resourceSampler({ readRuntimes: async () => runtimes });
    expect(resourceSampleLevel(await sampler.sample())).toEqual({ level: "debug" });
    runtimes.push({ sessionId: "s1", bytes: 1_024, subscribers: 1 });
    const loaded = await sampler.sample();
    expect(loaded).toMatchObject({ runtimesLoaded: 1, runtimesEvicted: 0, runtimeBytes: 1_024 });
    expect(resourceSampleLevel(loaded)).toEqual({ level: "info", reason: "runtimes=1" });
    expect(formatResourceSample(loaded)).toContain("runtimes=s1:1KB/1");
    runtimes.length = 0;
    const evicted = await sampler.sample();
    expect(evicted).toMatchObject({ runtimesLoaded: 0, runtimesEvicted: 1 });
    expect(resourceSampleLevel(evicted)).toEqual({ level: "info", reason: "runtimes=0" });
  });

  it("names at most eight topics and runtimes and counts the rest", async () => {
    const runtimes = Array.from({ length: 10 }, (_, index): ResourceRuntimeEntry => ({ sessionId: `session-${index}`, bytes: index + 1, subscribers: 0 }));
    const sampler = resourceSampler({ readRuntimes: async () => runtimes });
    for (let index = 0; index < 10; index += 1) sampler.recordTopicFrame(`topic.${index}`, index + 1, 1);
    const message = formatResourceSample(await sampler.sample());
    expect(message.match(/topic\.\d/gu)).toHaveLength(8);
    expect(message.match(/session-\d/gu)).toHaveLength(8);
    expect(message.match(/\+2/gu)).toHaveLength(2);
  });

  it("gives snapshot work with no audience its own record line", async () => {
    const sampler = resourceSampler();
    sampler.recordSnapshotBuild(0);
    sampler.recordSnapshotBuild(2);
    const line = formatUnaudiencedWork(await sampler.sample());
    expect(line).toContain("built 1 snapshot(s) with no audience");
    expect(line).toContain("snapshotBuilds=2");
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
