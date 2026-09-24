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
