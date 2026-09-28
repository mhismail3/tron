import type { EventLoopUtilization } from "node:perf_hooks";
import { afterEach, describe, expect, it, vi } from "vitest";
import { GATEWAY_CONNECTION_POLICY } from "./connection-policy.js";
import { GatewayServer } from "./server.js";
import { formatHostEvidence, formatStallEvidence, parseHostSysctl, probeHostKernel, StallSampler, type HostMemory } from "./stall-diagnostics.js";

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
    await expect(second).resolves.toEqual({ memory: { freeBytes: 1, totalBytes: 2, swapUsedBytes: 3, pressure: "critical" }, ageMs: 0 });
  });

  // Failure mode: the connection records read this cache, so a probe that
  // loses its 1 s race leaves a pre-squeeze sample in place. Without the age,
  // a record hours later reads as a healthy Mac at the moment of the drop, and
  // "at most one tick old" is an assumption the code does not enforce.
  it("reports the age of a cached sample that a lost probe race left in place", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    let now = 1_000;
    vi.spyOn(performance, "now").mockImplementation(() => now);
    let probes = 0;
    const squeezed: HostMemory = { freeBytes: 1, totalBytes: 2, swapUsedBytes: 3, swapTotalBytes: 4, pressure: "critical", memoryAvailablePercent: 4 };
    const sampler = new StallSampler({
      ...fakeUtilization(), observeGc: fakeGc().observeGc,
      sampleHost: () => { probes += 1; return probes === 1 ? Promise.resolve(squeezed) : new Promise<HostMemory>(() => {}); },
    });
    await expect(sampler.hostMemory()).resolves.toEqual({ memory: squeezed, ageMs: 0 });
    now += 60_000;
    sampler.refreshHostSample();
    await vi.advanceTimersByTimeAsync(1_000);
    expect(sampler.hostSample()).toEqual({ memory: squeezed, ageMs: 60_000 });
    expect(formatHostEvidence(sampler.hostSample())).toContain("hostSampleAgeMs=60000");
    sampler.dispose();
  });

  // Failure mode: connection-resilience.md sends an operator to the swap total
  // to judge `swapUsedBytes`, and to the kernel's memory level to judge an
  // idle Mac whose `os.freemem` is small; neither number was in the record.
  it("parses one sysctl probe into the swap total and used bytes, pressure and the kernel's memory level", () => {
    expect(parseHostSysctl([
      "total = 20480.00M  used = 19800.00M  free = 680.00M  (encrypted)",
      "4",
      "8",
    ].join("\n"))).toEqual({
      swapTotalBytes: Math.round(20_480 * 1_024 ** 2),
      swapUsedBytes: Math.round(19_800 * 1_024 ** 2),
      pressure: "critical",
      memoryAvailablePercent: 8,
    });
    expect(parseHostSysctl("total = 2048.00M  used = 991.75M  free = 1056.25M  (encrypted)\n1\n58\n")).toEqual({
      swapTotalBytes: Math.round(2_048 * 1_024 ** 2),
      swapUsedBytes: Math.round(991.75 * 1_024 ** 2),
      pressure: "normal",
      memoryAvailablePercent: 58,
    });
    // A name the kernel does not know prints no line, and a value is only
    // accepted in its own domain, not by its position.
    expect(parseHostSysctl("unexpected")).toEqual({});
    expect(parseHostSysctl("total = 0.00M  used = 0.00M  free = 0.00M  (encrypted)\n3\n101")).toEqual({ swapTotalBytes: 0, swapUsedBytes: 0 });
    expect(parseHostSysctl("4\n8")).toEqual({ pressure: "critical", memoryAvailablePercent: 8 });
  });

  // Failure mode: the level arrives as a second `sysctl` invocation, so every
  // heartbeat pays one process per fact and the probe count stops being bounded.
  it("reads every kernel fact with one sysctl invocation", async () => {
    const run = vi.fn(async () => "total = 2048.00M  used = 991.75M  free = 1056.25M  (encrypted)\n1\n58\n");
    await expect(probeHostKernel(run)).resolves.toEqual({
      swapTotalBytes: Math.round(2_048 * 1_024 ** 2),
      swapUsedBytes: Math.round(991.75 * 1_024 ** 2),
      pressure: "normal",
      memoryAvailablePercent: 58,
    });
    expect(run).toHaveBeenCalledTimes(1);
    expect(run.mock.calls[0]![0]).toContain("kern.memorystatus_level");
  });

  it("formats every host fact with the sample's age", () => {
    expect(formatStallEvidence({ gcCount: 1, gcPauseMs: 2.6, gcMaxPauseMs: 2.6, utilization: 0.456 }, undefined))
      .toBe("gcCount=1 gcPauseMs=3 gcMaxPauseMs=3 eventLoopUtilization=0.46 host=unavailable");
    expect(formatHostEvidence(undefined)).toBe("host=unavailable");
    expect(formatHostEvidence({ memory: { freeBytes: 1, totalBytes: 2 }, ageMs: 0 })).toBe("hostFreeBytes=1 hostTotalBytes=2 hostSampleAgeMs=0");
    expect(formatHostEvidence({
      memory: { freeBytes: 1_000, totalBytes: 8_000, swapUsedBytes: 7_000, swapTotalBytes: 8_000, pressure: "warn", memoryAvailablePercent: 9 },
      ageMs: 25_000,
    })).toBe("hostFreeBytes=1000 hostTotalBytes=8000 swapUsedBytes=7000 swapTotalBytes=8000 memoryPressure=warn hostMemoryAvailablePercent=9 hostSampleAgeMs=25000");
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
    sampleHost: async () => ({ freeBytes: 1_000, totalBytes: 8_000, swapUsedBytes: 7_000, swapTotalBytes: 8_000, pressure: "warn", memoryAvailablePercent: 9 }),
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
  expect(message).toContain("hostFreeBytes=1000 hostTotalBytes=8000 swapUsedBytes=7000 swapTotalBytes=8000 memoryPressure=warn hostMemoryAvailablePercent=9 hostSampleAgeMs=0");
  expect(message).toContain("connections=0");
  await gateway.close();
  expect(gc.disposed()).toBe(true);
});
