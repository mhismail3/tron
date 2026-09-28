import { execFile } from "node:child_process";
import { freemem, totalmem } from "node:os";
import { monitorEventLoopDelay, PerformanceObserver, performance, type EventLoopUtilization, type IntervalHistogram } from "node:perf_hooks";
import { getHeapStatistics } from "node:v8";
import { drainDurableWriteStats } from "../util/durable-json.js";

/*
 * Evidence for why the event loop stalled, attached to
 * `gateway.event-loop-delay`. Each heartbeat closes one window: garbage
 * collection pauses and event-loop utilization are measured over exactly the
 * delayed interval. Reading them: GC pause time close to the delay points at
 * garbage collection; utilization near 1 with little GC points at the
 * Gateway's own synchronous work; a delay with low utilization and heavy swap
 * or memory pressure points at the host not running the process. These are
 * observations, not attribution.
 */

export interface StallWindow {
  gcCount: number;
  gcPauseMs: number;
  gcMaxPauseMs: number;
  /** Event-loop utilization over the window, 0–1. */
  utilization: number;
}

export interface HostMemory {
  freeBytes: number;
  totalBytes: number;
  swapUsedBytes?: number;
  /** macOS `kern.memorystatus_vm_pressure_level`. */
  pressure?: "normal" | "warn" | "critical";
}

export interface StallSamplerDependencies {
  /** `performance.eventLoopUtilization`: with two marks, the delta between them. */
  eventLoopUtilization?: (current?: EventLoopUtilization, previous?: EventLoopUtilization) => EventLoopUtilization;
  /** Installs a GC observer; returns its disposer. */
  observeGc?: (onPause: (durationMs: number) => void) => () => void;
  sampleHost?: () => Promise<HostMemory>;
}

/** Bounds the host probe; a record is never held longer than this for it. */
const HOST_SAMPLE_TIMEOUT_MS = 1_000;

function observeGcPauses(onPause: (durationMs: number) => void): () => void {
  const observer = new PerformanceObserver((list) => {
    for (const entry of list.getEntries()) onPause(entry.duration);
  });
  observer.observe({ entryTypes: ["gc"] });
  return () => observer.disconnect();
}

/** Parses `sysctl -n vm.swapusage` ("total = 2048.00M  used = 1536.25M  free = …"). */
export function parseSwapUsedBytes(text: string): number | undefined {
  const match = /used = ([\d.]+)([KMGT])/u.exec(text);
  if (!match) return undefined;
  const scale = { K: 1_024, M: 1_024 ** 2, G: 1_024 ** 3, T: 1_024 ** 4 }[match[2] as "K" | "M" | "G" | "T"];
  const value = Number(match[1]);
  return Number.isFinite(value) ? Math.round(value * scale) : undefined;
}

export function parseMemoryPressure(text: string): HostMemory["pressure"] {
  switch (text.trim()) {
    case "1": return "normal";
    case "2": return "warn";
    case "4": return "critical";
    default: return undefined;
  }
}

function sysctl(name: string): Promise<string | undefined> {
  return new Promise((resolve) => {
    execFile("/usr/sbin/sysctl", ["-n", name], { timeout: HOST_SAMPLE_TIMEOUT_MS, maxBuffer: 4_096 }, (error, stdout) => {
      resolve(error ? undefined : stdout);
    });
  });
}

async function sampleHostMemory(): Promise<HostMemory> {
  const base = { freeBytes: freemem(), totalBytes: totalmem() };
  if (process.platform !== "darwin") return base;
  const [swap, pressure] = await Promise.all([sysctl("vm.swapusage"), sysctl("kern.memorystatus_vm_pressure_level")]);
  const swapUsedBytes = swap === undefined ? undefined : parseSwapUsedBytes(swap);
  const level = pressure === undefined ? undefined : parseMemoryPressure(pressure);
  return {
    ...base,
    ...(swapUsedBytes === undefined ? {} : { swapUsedBytes }),
    ...(level === undefined ? {} : { pressure: level }),
  };
}

/** One resource record a minute. A faster timer would only add wakeups on a
 * shared Mac without adding evidence to a minute's picture. */
export const RESOURCE_SAMPLE_INTERVAL_MS = 60_000;

/** `monitorEventLoopDelay` samples at this period and records the whole interval
 * between its own ticks, so every reading carries this period as its floor. */
export const EVENT_LOOP_DELAY_RESOLUTION_MS = 20;

/** The exit target for event-loop delay p99. A window that moves to another
 * band of this size is a change the day's records have to show. */
export const EVENT_LOOP_P99_INFO_STEP_MS = 20;

/** The exit criterion's bound for one stalled turn. A window whose max moves to
 * another band of this size is a change the day's records have to show whatever
 * its p99 was, so the day's `max ≤ 250 ms` check has a persisted value to read. */
export const EVENT_LOOP_MAX_INFO_STEP_MS = 250;

/** Heap above this share of the V8 heap limit is the pressure the shedding work
 * has to bound. */
export const HEAP_WARNING_SHARE = 0.7;

/** Heap used moved this many absolute bytes from the last window written at
 * info or above: a growth step no share of a multi-gigabyte limit would round
 * away, measured from an anchor so a heap that swings tens of megabytes between
 * garbage collections does not write a record every minute. */
export const HEAP_USED_INFO_STEP_BYTES = 256 * 1_024 * 1_024;

/** RSS moved this share away from the last window written at info or above,
 * which is the memory-growth criterion's own resolution. A slower growth has to
 * accumulate across the debug-only minutes between records, so it still reaches
 * disk eventually instead of never. */
export const RSS_INFO_STEP_SHARE = 0.1;

/** An event-loop p99 over this bound in one minute misses the exit criterion. */
export const EVENT_LOOP_P99_WARNING_MS = 100;

/** Named entries in the message's topic and runtime detail; the rest are
 * counted, so the record stays one readable line. */
const MAX_RESOURCE_DETAIL = 8;

/** One live runtime in the sample: its canonical transcript size is the byte
 * estimate of what it holds until runtime residency is measured directly. */
export interface ResourceRuntimeEntry {
  sessionId: string;
  bytes: number;
  subscribers: number;
}

/** One topic's traffic over the sample window. `subscribers` is the highest
 * recipient count a frame on that topic had; a topic whose recipients left is
 * still visible by its frames and bytes. */
export interface ResourceTopicTraffic {
  frames: number;
  bytes: number;
  subscribers: number;
}

export interface ResourceSample {
  /** The closed window's length; an in-flight sample that skipped a tick makes
   * it longer than `RESOURCE_SAMPLE_INTERVAL_MS`, and a rate reader has to know
   * that. */
  windowMs: number;
  heapUsedBytes: number;
  heapLimitBytes: number;
  rssBytes: number;
  /** `monitorEventLoopDelay` percentiles over the closed window, in ms. */
  eventLoopDelayP50Ms: number;
  eventLoopDelayP99Ms: number;
  eventLoopDelayMaxMs: number;
  eventLoopUtilization: number;
  runtimes: readonly ResourceRuntimeEntry[];
  runtimeBytes: number;
  runtimesLoaded: number;
  runtimesEvicted: number;
  /** Snapshot builds, and the part of them with no subscriber at build time. */
  snapshotBuilds: number;
  unaudiencedSnapshotBuilds: number;
  topics: ReadonlyMap<string, ResourceTopicTraffic>;
  catalogWalks: number;
  /** The part of `catalogWalks` a request was waiting on; the request path's
   * criterion is zero of them. */
  requestPathCatalogWalks: number;
  catalogWalkMs: number;
  catalogWalkFiles: number;
  /** Durable fsyncs completed in the window and the time they took. */
  durableWrites: number;
  durableWriteMs: number;
  outboundBytes: number;
}

/**
 * What the owners of measurable work report to the sampler. Each call counts
 * one occurrence at the site that already knows it; the sampler never scans to
 * discover what happened.
 */
export interface ResourceRecorder {
  /** One snapshot projected for a session, with its subscriber count. */
  recordSnapshotBuild(subscribers: number): void;
  /** One serialized frame offered on a topic, and the recipients it had. */
  recordTopicFrame(topic: string, bytes: number, subscribers: number): void;
  /** One catalog walk, with the time it took, the files it read, and whether a
   * request was waiting on it. */
  recordCatalogWalk(durationMs: number, files: number, requestPath?: boolean): void;
  recordOutboundBytes(bytes: number): void;
  /** One runtime that became live, counted where it is published: a load and an
   * eviction inside one window are otherwise invisible to a set comparison. */
  recordRuntimeLoaded(): void;
  /** One published runtime that was disposed, counted at its disposal; a start
   * that was retired before it was ever live is not an eviction. */
  recordRuntimeEvicted(): void;
}

export interface ResourceSamplerDependencies {
  readRuntimes?: () => Promise<readonly ResourceRuntimeEntry[]>;
  durableWrites?: () => { count: number; ms: number };
  memoryUsage?: () => { heapUsed: number; rss: number };
  heapLimitBytes?: () => number;
  eventLoopDelay?: () => { p50Ms: number; p99Ms: number; maxMs: number };
  eventLoopUtilization?: (current?: EventLoopUtilization, previous?: EventLoopUtilization) => EventLoopUtilization;
}

/** The event-loop delay histogram, read once per sample and reset with it, so a
 * percentile covers one minute and a momentary stall is not a permanent max.
 * Every reading carries the sampling period (see
 * `EVENT_LOOP_DELAY_RESOLUTION_MS`); subtracting it leaves the lateness the
 * exit criterion bounds, so an idle loop reads 0 instead of the period. */
function eventLoopDelayReader(): { read: () => { p50Ms: number; p99Ms: number; maxMs: number }; dispose: () => void } {
  const histogram: IntervalHistogram = monitorEventLoopDelay({ resolution: EVENT_LOOP_DELAY_RESOLUTION_MS });
  histogram.enable();
  return {
    read: () => {
      const delayMs = (value: number) => Number.isFinite(value)
        ? Math.max(0, value / 1e6 - EVENT_LOOP_DELAY_RESOLUTION_MS)
        : 0;
      const delay = {
        p50Ms: delayMs(histogram.percentile(50)),
        p99Ms: delayMs(histogram.percentile(99)),
        maxMs: delayMs(histogram.max),
      };
      histogram.reset();
      return delay;
    },
    dispose: () => histogram.disable(),
  };
}

/**
 * Owns the `gateway.resources` picture: what the Gateway spends memory, CPU and
 * I/O on, one window at a time. Owners report their own work (see
 * `ResourceRecorder`); this class only closes windows, states thresholds and
 * places values in named steps (`level`).
 */
export class ResourceSampler implements ResourceRecorder {
  private readonly readRuntimes: () => Promise<readonly ResourceRuntimeEntry[]>;
  private readonly readDurableWrites: () => { count: number; ms: number };
  private readonly readMemory: () => { heapUsed: number; rss: number };
  private readonly readHeapLimitBytes: () => number;
  private readonly delay: { read: () => { p50Ms: number; p99Ms: number; maxMs: number }; dispose: () => void };
  private readonly eventLoopUtilization: (current?: EventLoopUtilization, previous?: EventLoopUtilization) => EventLoopUtilization;
  private utilizationMark: EventLoopUtilization;
  private readonly topics = new Map<string, ResourceTopicTraffic>();
  private snapshotBuilds = 0;
  private unaudiencedSnapshotBuilds = 0;
  private catalogWalks = 0;
  private requestPathCatalogWalks = 0;
  private catalogWalkMs = 0;
  private catalogWalkFiles = 0;
  private outboundBytes = 0;
  private loadedRuntimes = 0;
  private evictedRuntimes = 0;
  /** The steps of the previous window; a step counts as a change only against
   * the window before it, so a value that repeats does not reach disk. */
  private steps?: ResourceSteps;
  /** The RSS of the last window written at info or above, or of the first window
   * this sampler closed; the memory-growth step is measured against it, so slow
   * drift over many debug-only minutes still promotes one record. */
  private anchoredRssBytes?: number;
  /** The heap used by the last window written at info or above, or by the first
   * window this sampler closed; the heap step is measured against it, the same
   * way the RSS step is, so a heap oscillating around a band edge writes
   * nothing while a real step of `HEAP_USED_INFO_STEP_BYTES` does. */
  private anchoredHeapUsedBytes?: number;
  /** When the current window opened; the closed window reports its length. */
  private windowStartedAt = performance.now();

  constructor(dependencies: ResourceSamplerDependencies = {}) {
    this.readRuntimes = dependencies.readRuntimes ?? (async () => []);
    this.readDurableWrites = dependencies.durableWrites ?? drainDurableWriteStats;
    this.readMemory = dependencies.memoryUsage ?? (() => process.memoryUsage());
    this.readHeapLimitBytes = dependencies.heapLimitBytes ?? (() => getHeapStatistics().heap_size_limit);
    this.delay = dependencies.eventLoopDelay === undefined
      ? eventLoopDelayReader()
      : { read: dependencies.eventLoopDelay, dispose: () => {} };
    this.eventLoopUtilization = dependencies.eventLoopUtilization
      ?? ((current, previous) => performance.eventLoopUtilization(current, previous));
    this.utilizationMark = this.eventLoopUtilization();
  }

  recordSnapshotBuild(subscribers: number): void {
    this.snapshotBuilds += 1;
    if (!(subscribers > 0)) this.unaudiencedSnapshotBuilds += 1;
  }

  recordTopicFrame(topic: string, bytes: number, subscribers: number): void {
    const traffic = this.topics.get(topic) ?? { frames: 0, bytes: 0, subscribers: 0 };
    traffic.frames += 1;
    if (Number.isFinite(bytes) && bytes > 0) traffic.bytes += bytes;
    if (Number.isFinite(subscribers) && subscribers > traffic.subscribers) traffic.subscribers = subscribers;
    this.topics.set(topic, traffic);
  }

  recordCatalogWalk(durationMs: number, files: number, requestPath = false): void {
    this.catalogWalks += 1;
    if (requestPath) this.requestPathCatalogWalks += 1;
    if (Number.isFinite(durationMs) && durationMs > 0) this.catalogWalkMs += durationMs;
    if (Number.isFinite(files) && files > 0) this.catalogWalkFiles += files;
  }

  recordOutboundBytes(bytes: number): void {
    if (Number.isFinite(bytes) && bytes > 0) this.outboundBytes += bytes;
  }

  recordRuntimeLoaded(): void {
    this.loadedRuntimes += 1;
  }

  recordRuntimeEvicted(): void {
    this.evictedRuntimes += 1;
  }

  /** The level this window is recorded at, and why. The band comparison is
   * against the previous window, so a step change is written once, where it
   * happens; the memory anchors move only when the window is written at info or
   * above (and the first window starts them). */
  level(sample: ResourceSample): { level: "debug" | "info" | "warning"; reason?: string } {
    const previous = this.steps;
    this.steps = resourceSteps(sample);
    const decision = resourceSampleLevel(sample, previous, this.anchoredRssBytes, this.anchoredHeapUsedBytes);
    if (decision.level !== "debug" || this.anchoredRssBytes === undefined) {
      this.anchoredRssBytes = sample.rssBytes;
      this.anchoredHeapUsedBytes = sample.heapUsedBytes;
    }
    return decision;
  }

  /** Closes the window and starts the next. Counters are drained, not re-read,
   * so one occurrence is reported exactly once. */
  async sample(): Promise<ResourceSample> {
    const closedAt = performance.now();
    const windowMs = Math.max(0, closedAt - this.windowStartedAt);
    this.windowStartedAt = closedAt;
    const memory = this.readMemory();
    const delay = this.delay.read();
    const current = this.eventLoopUtilization();
    const utilization = this.eventLoopUtilization(current, this.utilizationMark).utilization;
    this.utilizationMark = current;
    // Every counter closes at `closedAt`, before the runtime inventory is
    // awaited: a hung inventory read would otherwise report the work done while
    // it hung inside this window, whose `windowMs` was already fixed here, and
    // a rate read from that pair would be wrong exactly then. A sample that
    // fails after this point has already consumed its counters, so the window it
    // would have reported is dropped rather than folded into the next one — the
    // same rule the histogram and `windowStartedAt` already follow.
    const counters = this.drainWindowCounters();
    // The runtime set is a current value, not a counter: it is read after the
    // window closed, while every counter above covers the closed window.
    const runtimes = [...await this.readRuntimes()];
    return {
      windowMs,
      heapUsedBytes: nonNegative(memory.heapUsed),
      heapLimitBytes: nonNegative(this.readHeapLimitBytes()),
      rssBytes: nonNegative(memory.rss),
      eventLoopDelayP50Ms: delay.p50Ms,
      eventLoopDelayP99Ms: delay.p99Ms,
      eventLoopDelayMaxMs: delay.maxMs,
      eventLoopUtilization: Number.isFinite(utilization) ? utilization : 0,
      runtimes,
      runtimeBytes: runtimes.reduce((total, runtime) => total + nonNegative(runtime.bytes), 0),
      ...counters,
    };
  }

  /** The closed window's counters, taken and cleared together so every value in
   * one record covers the same span of time. */
  private drainWindowCounters() {
    const durable = this.readDurableWrites();
    const counters = {
      topics: new Map(this.topics),
      runtimesLoaded: this.loadedRuntimes,
      runtimesEvicted: this.evictedRuntimes,
      snapshotBuilds: this.snapshotBuilds,
      unaudiencedSnapshotBuilds: this.unaudiencedSnapshotBuilds,
      catalogWalks: this.catalogWalks,
      requestPathCatalogWalks: this.requestPathCatalogWalks,
      catalogWalkMs: this.catalogWalkMs,
      catalogWalkFiles: this.catalogWalkFiles,
      durableWrites: nonNegative(durable.count),
      durableWriteMs: nonNegative(durable.ms),
      outboundBytes: this.outboundBytes,
    };
    this.topics.clear();
    this.loadedRuntimes = 0;
    this.evictedRuntimes = 0;
    this.snapshotBuilds = 0;
    this.unaudiencedSnapshotBuilds = 0;
    this.catalogWalks = 0;
    this.requestPathCatalogWalks = 0;
    this.catalogWalkMs = 0;
    this.catalogWalkFiles = 0;
    this.outboundBytes = 0;
    return counters;
  }

  dispose(): void {
    this.delay.dispose();
  }
}

/** Where one window's values sit, compared with the window before it. Info is
 * written when a step moves, so a minute that repeats the same steps never
 * reaches disk. */
export interface ResourceSteps {
  /** Event-loop p99 in bands of `EVENT_LOOP_P99_INFO_STEP_MS`. */
  eventLoopP99Band: number;
  /** Event-loop max in bands of `EVENT_LOOP_MAX_INFO_STEP_MS`. */
  eventLoopMaxBand: number;
}

/** The named steps a sample's values are placed in. */
export function resourceSteps(sample: ResourceSample): ResourceSteps {
  return {
    eventLoopP99Band: Math.floor(sample.eventLoopDelayP99Ms / EVENT_LOOP_P99_INFO_STEP_MS),
    eventLoopMaxBand: Math.floor(sample.eventLoopDelayMaxMs / EVENT_LOOP_MAX_INFO_STEP_MS),
  };
}

/**
 * The level a sample is recorded at and why. Warning is a broken bound; info is
 * a named step that moved since `previous` (the window before this one), heap
 * used moved `HEAP_USED_INFO_STEP_BYTES` or RSS moved `RSS_INFO_STEP_SHARE` from
 * the last window written at info or above (`anchoredHeapUsedBytes`,
 * `anchoredRssBytes`; the first window starts both anchors), or a runtime
 * load/eviction in this window. That is what makes
 * a minute readable without writing every minute to disk; debug otherwise.
 * `undefined` `previous` is the first window, which is never a band change, and
 * an undefined anchor has no memory-growth baseline yet, which is never a step.
 */
export function resourceSampleLevel(
  sample: ResourceSample,
  previous?: ResourceSteps,
  anchoredRssBytes?: number,
  anchoredHeapUsedBytes?: number,
): { level: "debug" | "info" | "warning"; reason?: string } {
  const heapShare = heapShareOf(sample);
  if (heapShare >= HEAP_WARNING_SHARE) {
    return { level: "warning", reason: `heapShare=${heapShare.toFixed(2)} at or above ${HEAP_WARNING_SHARE}` };
  }
  if (sample.eventLoopDelayP99Ms >= EVENT_LOOP_P99_WARNING_MS) {
    return { level: "warning", reason: `eventLoopDelayP99Ms=${Math.round(sample.eventLoopDelayP99Ms)} at or above ${EVENT_LOOP_P99_WARNING_MS}` };
  }
  if (previous !== undefined) {
    const steps = resourceSteps(sample);
    if (steps.eventLoopP99Band !== previous.eventLoopP99Band) {
      return { level: "info", reason: `eventLoopDelayP99Ms=${Math.round(sample.eventLoopDelayP99Ms)} entering band ${steps.eventLoopP99Band}` };
    }
    if (steps.eventLoopMaxBand !== previous.eventLoopMaxBand) {
      return { level: "info", reason: `eventLoopDelayMaxMs=${Math.round(sample.eventLoopDelayMaxMs)} entering band ${steps.eventLoopMaxBand}` };
    }
    const heapMove = anchoredHeapUsedBytes === undefined
      ? 0
      : Math.abs(sample.heapUsedBytes - anchoredHeapUsedBytes);
    if (heapMove >= HEAP_USED_INFO_STEP_BYTES) {
      return { level: "info", reason: `heapUsedBytes=${sample.heapUsedBytes} moved ${Math.round(heapMove / 1_048_576)} MiB from ${anchoredHeapUsedBytes}` };
    }
    const move = anchoredRssBytes !== undefined && anchoredRssBytes > 0
      ? Math.abs(sample.rssBytes - anchoredRssBytes) / anchoredRssBytes
      : 0;
    if (move >= RSS_INFO_STEP_SHARE) {
      return { level: "info", reason: `rssBytes=${sample.rssBytes} moved ${Math.round(move * 100)}% from ${anchoredRssBytes}` };
    }
  }
  if (sample.runtimesLoaded + sample.runtimesEvicted > 0) {
    return { level: "info", reason: `runtimes=${sample.runtimes.length} loaded=${sample.runtimesLoaded} evicted=${sample.runtimesEvicted}` };
  }
  return { level: "debug" };
}

function heapShareOf(sample: ResourceSample): number {
  return sample.heapLimitBytes > 0 ? sample.heapUsedBytes / sample.heapLimitBytes : 0;
}

/** One `gateway.resources` line: every number, then the per-topic and
 * per-runtime detail, most expensive first and bounded. */
export function formatResourceSample(sample: ResourceSample): string {
  const heapShare = heapShareOf(sample);
  const fields = [
    `windowMs=${roundMs(sample.windowMs)}`,
    `heapUsedBytes=${sample.heapUsedBytes}`,
    `heapLimitBytes=${sample.heapLimitBytes}`,
    `heapShare=${heapShare.toFixed(2)}`,
    `rssBytes=${sample.rssBytes}`,
    `eventLoopDelayP50Ms=${roundMs(sample.eventLoopDelayP50Ms)}`,
    `eventLoopDelayP99Ms=${roundMs(sample.eventLoopDelayP99Ms)}`,
    `eventLoopDelayMaxMs=${roundMs(sample.eventLoopDelayMaxMs)}`,
    `eventLoopUtilization=${sample.eventLoopUtilization.toFixed(2)}`,
    `liveRuntimes=${sample.runtimes.length}`,
    `runtimeBytes=${sample.runtimeBytes}`,
    `runtimesLoaded=${sample.runtimesLoaded}`,
    `runtimesEvicted=${sample.runtimesEvicted}`,
    `snapshotBuilds=${sample.snapshotBuilds}`,
    `unaudiencedSnapshotBuilds=${sample.unaudiencedSnapshotBuilds}`,
    `catalogWalks=${sample.catalogWalks}`,
    `requestPathCatalogWalks=${sample.requestPathCatalogWalks}`,
    `catalogWalkMs=${roundMs(sample.catalogWalkMs)}`,
    `catalogWalkFiles=${sample.catalogWalkFiles}`,
    `durableWrites=${sample.durableWrites}`,
    `durableWriteMs=${roundMs(sample.durableWriteMs)}`,
    `outboundBytes=${sample.outboundBytes}`,
    `topics=${formatTopics(sample.topics)}`,
    `runtimes=${formatRuntimes(sample.runtimes)}`,
  ];
  return `Gateway resources ${fields.join(" ")}`;
}

function formatTopics(topics: ReadonlyMap<string, ResourceTopicTraffic>): string {
  const ordered = [...topics.entries()].sort((left, right) => right[1].bytes - left[1].bytes || left[0].localeCompare(right[0]));
  const named = ordered.slice(0, MAX_RESOURCE_DETAIL)
    .map(([topic, traffic]) => `${topic}:${traffic.frames}/${traffic.bytes}B/${traffic.subscribers}`);
  if (ordered.length > named.length) named.push(`+${ordered.length - named.length}`);
  return named.length === 0 ? "none" : named.join(",");
}

function formatRuntimes(runtimes: readonly ResourceRuntimeEntry[]): string {
  const ordered = [...runtimes].sort((left, right) => right.bytes - left.bytes || left.sessionId.localeCompare(right.sessionId));
  const named = ordered.slice(0, MAX_RESOURCE_DETAIL)
    .map((runtime) => `${runtime.sessionId}:${Math.round(runtime.bytes / 1_024)}KB/${runtime.subscribers}`);
  if (ordered.length > named.length) named.push(`+${ordered.length - named.length}`);
  return named.length === 0 ? "none" : named.join(",");
}

function roundMs(value: number): number {
  return Number.isFinite(value) ? Math.max(0, Math.round(value)) : 0;
}

function nonNegative(value: number): number {
  return Number.isFinite(value) && value > 0 ? Math.round(value) : 0;
}

export function formatStallEvidence(window: StallWindow, host: HostMemory | undefined): string {
  const fields = [
    `gcCount=${window.gcCount}`,
    `gcPauseMs=${Math.round(window.gcPauseMs)}`,
    `gcMaxPauseMs=${Math.round(window.gcMaxPauseMs)}`,
    `eventLoopUtilization=${window.utilization.toFixed(2)}`,
  ];
  if (host) {
    fields.push(`hostFreeBytes=${host.freeBytes}`, `hostTotalBytes=${host.totalBytes}`);
    if (host.swapUsedBytes !== undefined) fields.push(`swapUsedBytes=${host.swapUsedBytes}`);
    if (host.pressure !== undefined) fields.push(`memoryPressure=${host.pressure}`);
  } else {
    fields.push("host=unavailable");
  }
  return fields.join(" ");
}

export class StallSampler {
  private readonly eventLoopUtilization: (current?: EventLoopUtilization, previous?: EventLoopUtilization) => EventLoopUtilization;
  private readonly sampleHost: () => Promise<HostMemory>;
  private readonly disposeGc: () => void;
  private utilizationMark: EventLoopUtilization;
  private gcCount = 0;
  private gcPauseMs = 0;
  private gcMaxPauseMs = 0;
  private hostSampleInFlight = false;

  constructor(dependencies: StallSamplerDependencies = {}) {
    this.eventLoopUtilization = dependencies.eventLoopUtilization
      ?? ((current, previous) => performance.eventLoopUtilization(current, previous));
    this.sampleHost = dependencies.sampleHost ?? sampleHostMemory;
    this.utilizationMark = this.eventLoopUtilization();
    this.disposeGc = (dependencies.observeGc ?? observeGcPauses)((durationMs) => {
      this.gcCount += 1;
      this.gcPauseMs += durationMs;
      this.gcMaxPauseMs = Math.max(this.gcMaxPauseMs, durationMs);
    });
  }

  /** Closes the current window and starts the next. Called every heartbeat. */
  closeWindow(): StallWindow {
    const current = this.eventLoopUtilization();
    const window = {
      gcCount: this.gcCount,
      gcPauseMs: this.gcPauseMs,
      gcMaxPauseMs: this.gcMaxPauseMs,
      utilization: this.eventLoopUtilization(current, this.utilizationMark).utilization,
    };
    this.utilizationMark = current;
    this.gcCount = 0;
    this.gcPauseMs = 0;
    this.gcMaxPauseMs = 0;
    return window;
  }

  /**
   * Host memory for one stall record, bounded by HOST_SAMPLE_TIMEOUT_MS. Only
   * one probe runs at a time; an overlapping stall reports it unavailable.
   */
  async hostMemory(): Promise<HostMemory | undefined> {
    if (this.hostSampleInFlight) return undefined;
    this.hostSampleInFlight = true;
    let timer: NodeJS.Timeout | undefined;
    try {
      return await Promise.race([
        this.sampleHost(),
        new Promise<undefined>((resolve) => { timer = setTimeout(() => resolve(undefined), HOST_SAMPLE_TIMEOUT_MS); }),
      ]);
    } catch {
      return undefined;
    } finally {
      if (timer) clearTimeout(timer);
      this.hostSampleInFlight = false;
    }
  }

  dispose(): void {
    this.disposeGc();
  }
}
