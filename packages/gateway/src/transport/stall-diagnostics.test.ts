import type { EventLoopUtilization } from "node:perf_hooks";
import WebSocket from "ws";
import { afterEach, describe, expect, it, vi } from "vitest";
import { GATEWAY_CONNECTION_POLICY } from "./connection-policy.js";
import { GatewayServer } from "./server.js";
import { formatStallEvidence, formatResourceSample, parseMemoryPressure, parseSwapUsedBytes, resourceSampleLevel, ResourceSampler, EVENT_LOOP_DELAY_RESOLUTION_MS, HEAP_USED_INFO_STEP_BYTES, RESOURCE_SAMPLE_INTERVAL_MS, StallSampler, type HostMemory, type ResourceRuntimeEntry } from "./stall-diagnostics.js";

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
// (3) the histogram's own sampling period is reported as delay, so an idle loop
// looks like it is over the exit target; (4) the heap share is computed against
// a wrong limit, so the warning never fires; (5) a named step crossing does not
// promote the level, so it stays in the memory-only debug buffer; (6) unbounded
// topics or runtimes grow the record past one line; (7) a non-finite measurement
// (an empty histogram, a failed probe) is written as NaN; (8) a runtime loaded
// and evicted inside one window is invisible to a comparison of live sets; (9)
// the memory-growth step only compares each minute with the one before it, so
// slow drift over a day never reaches disk.
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
    sampler.recordCatalogWalk(9, 4, true);
    sampler.recordOutboundBytes(700);
    sampler.recordSnapshotBuild(1);
    sampler.recordSnapshotBuild(0);
    sampler.recordRuntimeLoaded();
    sampler.recordRuntimeEvicted();
    const first = await sampler.sample();
    expect(first.topics.get("session.progress")).toEqual({ frames: 2, bytes: 5_000, subscribers: 2 });
    expect(first).toMatchObject({
      catalogWalks: 2, requestPathCatalogWalks: 1, catalogWalkMs: 129.4, catalogWalkFiles: 3_004, outboundBytes: 700,
      snapshotBuilds: 2, unaudiencedSnapshotBuilds: 1, durableWrites: 3, durableWriteMs: 12,
      runtimesLoaded: 1, runtimesEvicted: 1,
    });
    const second = await sampler.sample();
    expect(second.topics.size).toBe(0);
    expect(second).toMatchObject({
      catalogWalks: 0, requestPathCatalogWalks: 0, catalogWalkMs: 0, catalogWalkFiles: 0, outboundBytes: 0, snapshotBuilds: 0,
      unaudiencedSnapshotBuilds: 0, runtimesLoaded: 0, runtimesEvicted: 0,
    });
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

  it("promotes a window to info when a named step moves, not when it repeats", async () => {
    let delay = { p50Ms: 1, p99Ms: 1, maxMs: 2 };
    let heapUsed = 1_000;
    let rss = 200_000;
    const sampler = resourceSampler({
      eventLoopDelay: () => delay,
      memoryUsage: () => ({ heapUsed, rss }),
      heapLimitBytes: () => 4_000_000_000,
    });
    // The first window has nothing to change from, and repeating it is not a change.
    expect(sampler.level(await sampler.sample())).toEqual({ level: "debug" });
    expect(sampler.level(await sampler.sample())).toEqual({ level: "debug" });
    delay = { p50Ms: 1, p99Ms: 25, maxMs: 40 };
    expect(sampler.level(await sampler.sample())).toMatchObject({ level: "info" });
    // The step already reached the log, so the next minute in the same band does not.
    expect(sampler.level(await sampler.sample())).toEqual({ level: "debug" });
    // One stalled turn past the exit bound is its own step, whatever the p99 was.
    delay = { p50Ms: 1, p99Ms: 25, maxMs: 260 };
    expect(sampler.level(await sampler.sample())).toMatchObject({
      level: "info", reason: "eventLoopDelayMaxMs=260 entering band 1",
    });
    rss = 240_000;
    expect(sampler.level(await sampler.sample())).toMatchObject({ level: "info" });
    heapUsed = HEAP_USED_INFO_STEP_BYTES + 1_000;
    expect(sampler.level(await sampler.sample())).toMatchObject({
      level: "info", reason: `heapUsedBytes=${HEAP_USED_INFO_STEP_BYTES + 1_000} entering band 1`,
    });
    // A heap that grows within its band, like an RSS that moves 10% from the
    // last window written, is not a change.
    heapUsed = HEAP_USED_INFO_STEP_BYTES + 2_000;
    rss = 240_000;
    expect(sampler.level(await sampler.sample())).toEqual({ level: "debug" });
  });

  it("promotes slow RSS growth once it accumulates past the anchored step", async () => {
    // About 0.02% a minute, 22% over a simulated day: no single minute reaches
    // `RSS_INFO_STEP_SHARE`, so only an anchor that outlives the debug-only
    // minutes turns the growth into records.
    let rss = 1_000_000_000;
    const sampler = resourceSampler({ memoryUsage: () => ({ heapUsed: 1_000, rss }) });
    expect(sampler.level(await sampler.sample())).toEqual({ level: "debug" });
    const promotions: string[] = [];
    for (let minute = 0; minute < 1_000; minute += 1) {
      rss = Math.round(rss * 1.0002);
      const decision = sampler.level(await sampler.sample());
      if (decision.level !== "debug") promotions.push(decision.reason!);
    }
    expect(promotions).toHaveLength(2);
    expect(promotions[0]).toContain("moved 10% from");
  });

  it("reads the real histogram so an idle loop reads zero and a blocked one reads the block", async () => {
    const sampler = new ResourceSampler({
      readRuntimes: async () => [],
      durableWrites: () => ({ count: 0, ms: 0 }),
      memoryUsage: () => ({ heapUsed: 1_000, rss: 2_000 }),
      heapLimitBytes: () => 10_000,
    });
    try {
      // Idle: the sampling period is not delay, so a window with no blocking
      // work reads well under the period. The wall clock itself is not asserted:
      // a shared, paging Mac can schedule this process late.
      await new Promise((resolve) => setTimeout(resolve, 80));
      expect((await sampler.sample()).eventLoopDelayP50Ms)
        .toBeLessThan(EVENT_LOOP_DELAY_RESOLUTION_MS / 2);
      // A read restarts the histogram and its first interval is discarded, so
      // let it run a few periods before blocking the loop.
      await new Promise((resolve) => setTimeout(resolve, 60));
      const startedAt = performance.now();
      while (performance.now() - startedAt < 150) { /* block the loop */ }
      await new Promise((resolve) => setTimeout(resolve, 60));
      const stalled = await sampler.sample();
      // The block is the window's max, without a tight upper bound: the host can
      // add its own lateness to the 150 ms the test blocked for.
      expect(stalled.eventLoopDelayMaxMs).toBeGreaterThanOrEqual(120);
      // The window closed with the sample: the stall is not the next minute's
      // max, and the next window's own max is not the stall's.
      await new Promise((resolve) => setTimeout(resolve, 120));
      const next = await sampler.sample();
      expect(next.eventLoopDelayMaxMs).toBeLessThan(stalled.eventLoopDelayMaxMs / 2);
    } finally {
      sampler.dispose();
    }
  });

  it("reports a runtime load or eviction counted where the transition happened", async () => {
    const runtimes: ResourceRuntimeEntry[] = [{ sessionId: "s1", bytes: 1_024, subscribers: 1 }];
    const sampler = resourceSampler({ readRuntimes: async () => runtimes });
    sampler.recordRuntimeLoaded();
    const loaded = await sampler.sample();
    expect(loaded).toMatchObject({ runtimesLoaded: 1, runtimesEvicted: 0, runtimeBytes: 1_024 });
    expect(sampler.level(loaded)).toEqual({ level: "info", reason: "runtimes=1 loaded=1 evicted=0" });
    expect(formatResourceSample(loaded)).toContain("runtimes=s1:1KB/1");
    sampler.recordRuntimeEvicted();
    runtimes.length = 0;
    const evicted = await sampler.sample();
    expect(evicted).toMatchObject({ runtimesLoaded: 0, runtimesEvicted: 1 });
    expect(sampler.level(evicted)).toEqual({ level: "info", reason: "runtimes=0 loaded=0 evicted=1" });
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

  it("keeps the unaudienced snapshot count in the record, not a second line", async () => {
    const sampler = resourceSampler();
    sampler.recordSnapshotBuild(0);
    sampler.recordSnapshotBuild(2);
    const message = formatResourceSample(await sampler.sample());
    expect(message).toContain("snapshotBuilds=2");
    expect(message).toContain("unaudiencedSnapshotBuilds=1");
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

/** The least a connection has to be for `broadcastSession` to deliver a frame
 * and for shutdown to retire it. */
function subscribedClient(sessionId: string | undefined) {
  return {
    id: "client-1",
    ready: true,
    closeInitiated: false,
    workRetired: false,
    revoked: false,
    socket: { readyState: WebSocket.OPEN, close: vi.fn() },
    inFlight: new Set<string>(),
    requestControllers: new Map(),
    synchronizations: new Map(),
    terminals: new Set<string>(),
    pendingSessionOpens: new Map(),
    rekeyedSessionIds: new Map(),
    subscriptionTokens: new Map(sessionId === undefined ? [] : [[sessionId, "subscription-token"]]),
    outbound: { enqueue: () => true },
  };
}

function resourceServer(log: ReturnType<typeof vi.fn>, sampler: ResourceSampler): GatewayServer {
  return new GatewayServer({
    host: "127.0.0.1", port: 0, maxFrameBytes: 16_384, devices: {} as never, uploads: {} as never,
    sessions: { unsubscribeClient: vi.fn() } as never,
    auth: { detachClient: vi.fn() } as never,
    service: { info: () => ({ protocolVersion: 5 }), releaseClient: vi.fn() } as never,
    logger: { log } as never, resourceSampler: sampler,
  });
}

function recordsWithEvent(log: ReturnType<typeof vi.fn>, event: string): unknown[][] {
  return log.mock.calls.filter((call) => (call[2] as { event?: string } | undefined)?.event === event);
}

// The production wiring: the transport's timer, the sampler's reader, the
// per-topic counters, outbound bytes and the level, all in one window.
it("records the resource window through the transport's timer", async () => {
  vi.useFakeTimers({ toFake: ["setInterval", "clearInterval", "setTimeout", "clearTimeout"] });
  const log = vi.fn();
  let heapUsed = 1_000;
  let holdRuntimes = false;
  let releaseRuntimes: (() => void) | undefined;
  let runtimesReads = 0;
  const sampler = new ResourceSampler({
    readRuntimes: () => {
      runtimesReads += 1;
      if (!holdRuntimes) return Promise.resolve([]);
      return new Promise((resolve) => { releaseRuntimes = () => resolve([]); });
    },
    durableWrites: () => ({ count: 2, ms: 5 }),
    memoryUsage: () => ({ heapUsed, rss: 2_000 }),
    heapLimitBytes: () => 10_000,
    eventLoopDelay: () => ({ p50Ms: 1, p99Ms: 2, maxMs: 3 }),
  });
  const gateway = resourceServer(log, sampler);
  const client = subscribedClient("session-1");
  (gateway as unknown as { clients: Map<string, unknown> }).clients.set("client-1", client);
  // One snapshot build for a subscriber and one for nobody.
  gateway.broadcastSession("session-1", "session.snapshot", { revision: 1 } as never);
  gateway.broadcastSession("session-2", "session.snapshot", { revision: 1 } as never);
  await vi.advanceTimersByTimeAsync(RESOURCE_SAMPLE_INTERVAL_MS);
  const first = recordsWithEvent(log, "gateway.resources")[0]!;
  expect(first[0]).toBe("debug");
  expect(first[1]).toMatch(/windowMs=\d+/u);
  expect(first[1]).toContain("durableWrites=2");
  expect(first[1]).toMatch(/topics=session\.snapshot:2\/\d+B\/1/u);
  expect(Number(/outboundBytes=(\d+)/u.exec(first[1] as string)![1])).toBeGreaterThan(0);
  // The next window crosses the heap bound: the same record promotes to warning.
  heapUsed = 7_000;
  await vi.advanceTimersByTimeAsync(RESOURCE_SAMPLE_INTERVAL_MS);
  const second = recordsWithEvent(log, "gateway.resources")[1]!;
  expect(second[0]).toBe("warning");
  expect(second[1]).toContain("heapShare=0.70");
  expect(second[1]).toContain("(heapShare=0.70 at or above 0.7)");
  // A sample that never returns holds the next window's timer instead of overlapping it.
  holdRuntimes = true;
  await vi.advanceTimersByTimeAsync(RESOURCE_SAMPLE_INTERVAL_MS);
  await vi.advanceTimersByTimeAsync(RESOURCE_SAMPLE_INTERVAL_MS);
  expect(runtimesReads).toBe(3);
  expect(recordsWithEvent(log, "gateway.resources")).toHaveLength(2);
  // The skipped window is not silent, and the run is reported once.
  const skipped = recordsWithEvent(log, "gateway.resources-failed");
  expect(skipped).toHaveLength(1);
  expect(skipped[0]![2]).toMatchObject({ event: "gateway.resources-failed", reason: "previous sample still running" });
  releaseRuntimes?.();
  await vi.advanceTimersByTimeAsync(0);
  // Shutdown retires the client and clears both timers.
  client.closeInitiated = true;
  await gateway.close();
  sampler.dispose();
});

// A sampler fault must be visible once and must never stop the transport.
it("reports one sampler fault per run of failures", async () => {
  vi.useFakeTimers({ toFake: ["setInterval", "clearInterval", "setTimeout", "clearTimeout"] });
  const log = vi.fn();
  let fail = true;
  const sampler = new ResourceSampler({
    readRuntimes: async () => { if (fail) throw new Error("runtime inventory failed"); return []; },
    durableWrites: () => ({ count: 0, ms: 0 }),
    memoryUsage: () => ({ heapUsed: 1_000, rss: 2_000 }),
    heapLimitBytes: () => 10_000,
    eventLoopDelay: () => ({ p50Ms: 1, p99Ms: 2, maxMs: 3 }),
  });
  const gateway = resourceServer(log, sampler);
  await vi.advanceTimersByTimeAsync(RESOURCE_SAMPLE_INTERVAL_MS);
  await vi.advanceTimersByTimeAsync(RESOURCE_SAMPLE_INTERVAL_MS);
  expect(recordsWithEvent(log, "gateway.resources-failed")).toHaveLength(1);
  expect(recordsWithEvent(log, "gateway.resources")).toHaveLength(0);
  fail = false;
  await vi.advanceTimersByTimeAsync(RESOURCE_SAMPLE_INTERVAL_MS);
  expect(recordsWithEvent(log, "gateway.resources")).toHaveLength(1);
  fail = true;
  await vi.advanceTimersByTimeAsync(RESOURCE_SAMPLE_INTERVAL_MS);
  expect(recordsWithEvent(log, "gateway.resources-failed")).toHaveLength(2);
  await gateway.close();
  sampler.dispose();
});
