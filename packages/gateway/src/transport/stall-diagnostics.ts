import { monitorEventLoopDelay, PerformanceObserver, performance, type EventLoopUtilization } from "node:perf_hooks";
import { getHeapStatistics } from "node:v8";
import { drainDurableWriteStats } from "../foundation/durable-json.js";
import { sampleHostMemory, type HostMemory } from "../foundation/host-memory.js";
import type { ResourceRecorder, ResourceRuntimeEntry } from "../util/resource-recorder.js";

type EventLoopDelayHistogram = ReturnType<typeof monitorEventLoopDelay>;

interface StallWindow {
  gcCount: number;
  gcPauseMs: number;
  gcMaxPauseMs: number;
  utilization: number;
}

interface HostSample {
  memory: HostMemory;
  ageMs: number;
}

interface StallSamplerDependencies {
  eventLoopUtilization?: (current?: EventLoopUtilization, previous?: EventLoopUtilization) => EventLoopUtilization;
  observeGc?: (onPause: (durationMs: number) => void) => () => void;
  sampleHost?: () => Promise<HostMemory>;
}

const HOST_SAMPLE_TIMEOUT_MS = 1_000;

function observeGcPauses(onPause: (durationMs: number) => void): () => void {
  const observer = new PerformanceObserver((list) => {
    for (const entry of list.getEntries()) onPause(entry.duration);
  });
  observer.observe({ entryTypes: ["gc"] });
  return () => observer.disconnect();
}

export const RESOURCE_SAMPLE_INTERVAL_MS = 60_000;

const EVENT_LOOP_DELAY_RESOLUTION_MS = 20;

const EVENT_LOOP_P99_INFO_STEP_MS = 20;

const EVENT_LOOP_MAX_INFO_STEP_MS = 250;

const HEAP_WARNING_SHARE = 0.7;

const HEAP_USED_INFO_STEP_BYTES = 256 * 1_024 * 1_024;

const RSS_INFO_STEP_SHARE = 0.1;

const EVENT_LOOP_P99_WARNING_MS = 100;

const UNAUDIENCED_SNAPSHOT_WARNING = 0;

const MAX_RESOURCE_DETAIL = 8;

interface ResourceTopicTraffic {
  frames: number;
  bytes: number;
  subscribers: number;
}

interface ResourceSample {
  windowMs: number;
  heapUsedBytes: number;
  heapLimitBytes: number;
  rssBytes: number;
  eventLoopDelayP50Ms: number;
  eventLoopDelayP99Ms: number;
  eventLoopDelayMaxMs: number;
  eventLoopUtilization: number;
  runtimes: readonly ResourceRuntimeEntry[];
  runtimeBytes: number;
  runtimesLoaded: number;
  runtimesEvicted: number;
  snapshotBuilds: number;
  unaudiencedSnapshotBuilds: number;
  topics: ReadonlyMap<string, ResourceTopicTraffic>;
  catalogWalks: number;
  requestPathCatalogWalks: number;
  catalogWalkMs: number;
  catalogWalkFiles: number;
  durableWrites: number;
  durableWriteMs: number;
  outboundBytes: number;
  outboundCoalescedFrames: number;
  outboundCoalescedBytes: number;
}

interface ResourceSamplerDependencies {
  readRuntimes?: () => Promise<readonly ResourceRuntimeEntry[]>;
  durableWrites?: () => { count: number; ms: number };
  memoryUsage?: () => { heapUsed: number; rss: number };
  heapLimitBytes?: () => number;
  eventLoopDelay?: () => { p50Ms: number; p99Ms: number; maxMs: number };
  eventLoopUtilization?: (current?: EventLoopUtilization, previous?: EventLoopUtilization) => EventLoopUtilization;
}

function eventLoopDelayLatenessMs(valueNs: number): number {
  return Number.isFinite(valueNs)
    ? Math.max(0, valueNs / 1e6 - EVENT_LOOP_DELAY_RESOLUTION_MS)
    : 0;
}

function eventLoopDelayReader(): { read: () => { p50Ms: number; p99Ms: number; maxMs: number }; dispose: () => void } {
  const histogram: EventLoopDelayHistogram = monitorEventLoopDelay({ resolution: EVENT_LOOP_DELAY_RESOLUTION_MS });
  histogram.enable();
  return {
    read: () => {
      const delay = {
        p50Ms: eventLoopDelayLatenessMs(histogram.percentile(50)),
        p99Ms: eventLoopDelayLatenessMs(histogram.percentile(99)),
        maxMs: eventLoopDelayLatenessMs(histogram.max),
      };
      histogram.reset();
      return delay;
    },
    dispose: () => histogram.disable(),
  };
}

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
  private outboundCoalescedFrames = 0;
  private outboundCoalescedBytes = 0;
  private loadedRuntimes = 0;
  private evictedRuntimes = 0;
  private steps?: ResourceSteps;
  private anchoredRssBytes?: number;
  private anchoredHeapUsedBytes?: number;
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

  recordOutboundCoalesced(bytes: number): void {
    this.outboundCoalescedFrames += 1;
    if (Number.isFinite(bytes) && bytes > 0) this.outboundCoalescedBytes += bytes;
  }

  recordRuntimeLoaded(): void {
    this.loadedRuntimes += 1;
  }

  recordRuntimeEvicted(): void {
    this.evictedRuntimes += 1;
  }

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

  async sample(): Promise<ResourceSample> {
    const closedAt = performance.now();
    const windowMs = Math.max(0, closedAt - this.windowStartedAt);
    this.windowStartedAt = closedAt;
    const memory = this.readMemory();
    const delay = this.delay.read();
    const current = this.eventLoopUtilization();
    const utilization = this.eventLoopUtilization(current, this.utilizationMark).utilization;
    this.utilizationMark = current;
    const counters = this.drainWindowCounters();
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
      outboundCoalescedFrames: this.outboundCoalescedFrames,
      outboundCoalescedBytes: this.outboundCoalescedBytes,
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
    this.outboundCoalescedFrames = 0;
    this.outboundCoalescedBytes = 0;
    return counters;
  }

  dispose(): void {
    this.delay.dispose();
  }
}

interface ResourceSteps {
  eventLoopP99Band: number;
  eventLoopMaxBand: number;
}

function resourceSteps(sample: ResourceSample): ResourceSteps {
  return {
    eventLoopP99Band: Math.floor(sample.eventLoopDelayP99Ms / EVENT_LOOP_P99_INFO_STEP_MS),
    eventLoopMaxBand: Math.floor(sample.eventLoopDelayMaxMs / EVENT_LOOP_MAX_INFO_STEP_MS),
  };
}

function resourceSampleLevel(
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
  if (sample.unaudiencedSnapshotBuilds > UNAUDIENCED_SNAPSHOT_WARNING) {
    return { level: "warning", reason: `unaudiencedSnapshotBuilds=${sample.unaudiencedSnapshotBuilds} with no ready recipient` };
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
    `outboundCoalescedFrames=${sample.outboundCoalescedFrames}`,
    `outboundCoalescedBytes=${sample.outboundCoalescedBytes}`,
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

export function formatHostEvidence(sample: HostSample | undefined): string {
  if (!sample) return "host=unavailable";
  const host = sample.memory;
  const fields = [`hostFreeBytes=${host.freeBytes}`, `hostTotalBytes=${host.totalBytes}`];
  if (host.swapUsedBytes !== undefined) fields.push(`swapUsedBytes=${host.swapUsedBytes}`);
  if (host.swapTotalBytes !== undefined) fields.push(`swapTotalBytes=${host.swapTotalBytes}`);
  if (host.pressure !== undefined) fields.push(`memoryPressure=${host.pressure}`);
  if (host.memoryAvailablePercent !== undefined) fields.push(`hostMemoryAvailablePercent=${host.memoryAvailablePercent}`);
  fields.push(`hostSampleAgeMs=${sample.ageMs}`);
  return fields.join(" ");
}

export function formatStallEvidence(window: StallWindow, host: HostSample | undefined): string {
  return [
    `gcCount=${window.gcCount}`,
    `gcPauseMs=${Math.round(window.gcPauseMs)}`,
    `gcMaxPauseMs=${Math.round(window.gcMaxPauseMs)}`,
    `eventLoopUtilization=${window.utilization.toFixed(2)}`,
    formatHostEvidence(host),
  ].join(" ");
}

export class StallSampler {
  private readonly eventLoopUtilization: (current?: EventLoopUtilization, previous?: EventLoopUtilization) => EventLoopUtilization;
  private readonly sampleHost: () => Promise<HostMemory>;
  private readonly disposeGc: () => void;
  private utilizationMark: EventLoopUtilization;
  private cachedHost: HostMemory | undefined;
  private cachedHostAt: number | undefined;
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

  async hostMemory(): Promise<HostSample | undefined> {
    if (this.hostSampleInFlight) return undefined;
    this.hostSampleInFlight = true;
    let timer: NodeJS.Timeout | undefined;
    try {
      const host = await Promise.race([
        this.sampleHost(),
        new Promise<undefined>((resolve) => { timer = setTimeout(() => resolve(undefined), HOST_SAMPLE_TIMEOUT_MS); }),
      ]);
      if (host === undefined) return undefined;
      this.cachedHost = host;
      this.cachedHostAt = performance.now();
      return { memory: host, ageMs: 0 };
    } catch {
      return undefined;
    } finally {
      if (timer) clearTimeout(timer);
      this.hostSampleInFlight = false;
    }
  }

  refreshHostSample(): void {
    void this.hostMemory();
  }

  hostSample(): HostSample | undefined {
    if (this.cachedHost === undefined || this.cachedHostAt === undefined) return undefined;
    return { memory: this.cachedHost, ageMs: Math.max(0, Math.round(performance.now() - this.cachedHostAt)) };
  }

  dispose(): void {
    this.disposeGc();
  }
}
