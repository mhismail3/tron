import { execFile } from "node:child_process";
import { freemem, totalmem } from "node:os";
import { PerformanceObserver, performance, type EventLoopUtilization } from "node:perf_hooks";

/*
 * Evidence for why the event loop stalled, attached to
 * `gateway.event-loop-delay`. Each heartbeat closes one window: garbage
 * collection pauses and event-loop utilization are measured over exactly the
 * delayed interval. Reading them: GC pause time close to the delay points at
 * garbage collection; utilization near 1 with little GC points at the
 * Gateway's own synchronous work; a delay with low utilization and heavy swap
 * or memory pressure points at the host not running the process. `swapTotalBytes`
 * and `hostMemoryAvailablePercent` are what make `swapUsedBytes` and `freeBytes`
 * readable, and `hostSampleAgeMs` says whether the sample is the one at the drop.
 * These are observations, not attribution.
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
  swapTotalBytes?: number;
  /** macOS `kern.memorystatus_vm_pressure_level`. */
  pressure?: "normal" | "warn" | "critical";
  /**
   * macOS `kern.memorystatus_level`: percent of memory available, the number
   * `memory_pressure` prints as its free percentage. `freeBytes` alone reads as
   * pressure on a healthy Mac, because `os.freemem` counts free pages only.
   */
  memoryAvailablePercent?: number;
}

/** What one kernel probe adds to Node's process-memory facts. */
export type HostKernelFacts = Omit<HostMemory, "freeBytes" | "totalBytes">;

/** The latest host sample together with the age of the cache it came from. */
export interface HostSample {
  memory: HostMemory;
  /** Age of the cached sample when it was read; 0 for a probe taken for this record. */
  ageMs: number;
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

/**
 * Every kernel fact this module logs, read by one `sysctl -n` per probe, so a
 * heartbeat's probe count does not grow with the field list.
 */
const HOST_SYSCTL_NAMES = ["vm.swapusage", "kern.memorystatus_vm_pressure_level", "kern.memorystatus_level"] as const;

function observeGcPauses(onPause: (durationMs: number) => void): () => void {
  const observer = new PerformanceObserver((list) => {
    for (const entry of list.getEntries()) onPause(entry.duration);
  });
  observer.observe({ entryTypes: ["gc"] });
  return () => observer.disconnect();
}

const SIZE_SCALE = { K: 1_024, M: 1_024 ** 2, G: 1_024 ** 3, T: 1_024 ** 4 } as const;

/** Reads one `label = 12.34M` field of `sysctl -n vm.swapusage`. */
function parseSize(text: string, label: string): number | undefined {
  const match = new RegExp(`${label} = ([\\d.]+)([KMGT])`, "u").exec(text);
  if (!match) return undefined;
  const value = Number(match[1]);
  return Number.isFinite(value) ? Math.round(value * SIZE_SCALE[match[2] as keyof typeof SIZE_SCALE]) : undefined;
}

function parseMemoryPressure(text: string): HostMemory["pressure"] {
  switch (text.trim()) {
    case "1": return "normal";
    case "2": return "warn";
    case "4": return "critical";
    default: return undefined;
  }
}

/** `kern.memorystatus_level`, a percentage of memory available. */
function parseMemoryAvailablePercent(text: string): number | undefined {
  if (!/^\d+$/u.test(text.trim())) return undefined;
  const value = Number(text.trim());
  return value <= 100 ? value : undefined;
}

/**
 * One `sysctl -n vm.swapusage kern.memorystatus_vm_pressure_level
 * kern.memorystatus_level` output. `sysctl -n` prints one line per requested
 * name in argument order and nothing at all for a name the kernel does not
 * know, so the swap line is recognized by its `total =` text and the pressure
 * level and available percentage follow it. Each value is validated against
 * its own domain rather than trusted by its position.
 */
export function parseHostSysctl(text: string): HostKernelFacts {
  const lines = text.split("\n").map((line) => line.trim()).filter((line) => line.length > 0);
  const swapIndex = lines.findIndex((line) => line.includes("total ="));
  const swap = swapIndex < 0 ? "" : lines[swapIndex]!;
  const values = lines.filter((_, index) => index !== swapIndex);
  const swapTotalBytes = parseSize(swap, "total");
  const swapUsedBytes = parseSize(swap, "used");
  const pressure = parseMemoryPressure(values[0] ?? "");
  const memoryAvailablePercent = parseMemoryAvailablePercent(values[1] ?? "");
  return {
    ...(swapTotalBytes === undefined ? {} : { swapTotalBytes }),
    ...(swapUsedBytes === undefined ? {} : { swapUsedBytes }),
    ...(pressure === undefined ? {} : { pressure }),
    ...(memoryAvailablePercent === undefined ? {} : { memoryAvailablePercent }),
  };
}

function sysctl(names: readonly string[]): Promise<string | undefined> {
  return new Promise((resolve) => {
    execFile("/usr/sbin/sysctl", ["-n", ...names], { timeout: HOST_SAMPLE_TIMEOUT_MS, maxBuffer: 4_096 }, (error, stdout) => {
      // An unknown name exits non-zero while still printing the names it knows;
      // one missing key must not blank the whole sample. Parsing validates each
      // value against its own domain.
      resolve(error && stdout.length === 0 ? undefined : stdout);
    });
  });
}

/**
 * The kernel half of one host probe. The runner is injectable so a test can pin
 * the probe count: one invocation carries every name.
 */
export async function probeHostKernel(
  run: (names: readonly string[]) => Promise<string | undefined> = sysctl,
): Promise<HostKernelFacts> {
  const text = await run(HOST_SYSCTL_NAMES);
  return text === undefined ? {} : parseHostSysctl(text);
}

async function sampleHostMemory(): Promise<HostMemory> {
  const base = { freeBytes: freemem(), totalBytes: totalmem() };
  if (process.platform !== "darwin") return base;
  return { ...base, ...await probeHostKernel() };
}

/**
 * Host memory as one bounded field list, shared by the stall and connection
 * records so an operator reads the same names in both. `hostSampleAgeMs` is the
 * age of the cache the other fields came from: a probe that loses its race is
 * discarded, so the heartbeat tick bounds the probe rate, not the staleness.
 */
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
   * Host memory for one stall record, bounded by HOST_SAMPLE_TIMEOUT_MS, and
   * the latest sample the connection records read. Only one probe runs at a
   * time; an overlapping caller reports it unavailable. The returned sample is
   * the one taken for this record, so its age is 0.
   */
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

  /**
   * Keeps the connection records' host sample current. The transport calls
   * this on every heartbeat, so the 25 s tick is the probe rate: a phone drop
   * or reconnect reads {@link hostSample} synchronously and never waits on, or
   * adds, a `sysctl` of its own. A probe that loses its 1 s race is discarded
   * and the previous sample stays, so the tick does not bound staleness — the
   * record's `hostSampleAgeMs` does.
   */
  refreshHostSample(): void {
    void this.hostMemory();
  }

  /** Latest host sample with its age; undefined until a probe lands. */
  hostSample(): HostSample | undefined {
    if (this.cachedHost === undefined || this.cachedHostAt === undefined) return undefined;
    return { memory: this.cachedHost, ageMs: Math.max(0, Math.round(performance.now() - this.cachedHostAt)) };
  }

  dispose(): void {
    this.disposeGc();
  }
}
