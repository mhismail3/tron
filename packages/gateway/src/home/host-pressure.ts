import os from "node:os";
import { performance, type EventLoopUtilization } from "node:perf_hooks";

/** Host pressure as one level (#915, docs/host-load.md). Home workers do not start
 * while it is `critical`; interactive work is never gated by it. */
export type HostPressureLevel = "normal" | "elevated" | "critical";

export interface HostPressureSample {
  level: HostPressureLevel;
  /** 1-minute load average divided by the CPU count. */
  load1PerCpu: number;
  /** Event-loop utilisation since the previous sample, 0..1. */
  eventLoopUtilization: number;
  sampledAt: string;
}

/** In the Gateway log's field vocabulary (transport/logger.ts keeps only known fields,
 * and its own `level` is the log level), so the record survives the writer: `state` is
 * the new level, `transition` the previous one, and `counts` carries load per CPU and
 * event-loop utilisation as percentages (#1103). */
export interface HostPressureDiagnostic {
  event: "host.pressure";
  state: HostPressureLevel;
  transition: HostPressureLevel;
  counts: { loadPerCpuPercent: number; eventLoopUtilizationPercent: number };
}

const ELEVATED_LOAD_PER_CPU = 1;
const CRITICAL_LOAD_PER_CPU = 3;
const ELEVATED_UTILIZATION = 0.7;
const CRITICAL_UTILIZATION = 0.95;
/** Reads closer together than this reuse the previous sample, so a burst of status
 * reads measures one window instead of many empty ones. It is also the shortest
 * window utilisation is measured over: a window of a few milliseconds is mostly the
 * reading tick itself and reads 0.94 to 0.96 on an idle process, which held a fresh
 * Gateway's first Home worker back as `critical` (#1000). */
const SAMPLE_REUSE_MS = 2_000;

/** One process-wide sampler, read on demand by its owners (Home status and the
 * worker budget). It owns no timer: a level transition is logged when a read sees it. */
export class HostPressure {
  private mark: { at: number; utilization: EventLoopUtilization } = { at: performance.now(), utilization: performance.eventLoopUtilization() };
  private last: { at: number; sample: HostPressureSample } | undefined;

  constructor(private readonly diagnostic?: (record: HostPressureDiagnostic) => void) {}

  sample(): HostPressureSample {
    const now = performance.now();
    if (this.last && now - this.last.at < SAMPLE_REUSE_MS) return this.last.sample;
    // Until the window since the mark is long enough to measure, utilisation keeps its
    // last measured value (none yet: 0) and the window keeps growing; load still counts.
    let utilization = this.last?.sample.eventLoopUtilization ?? 0;
    if (now - this.mark.at >= SAMPLE_REUSE_MS) {
      const current = performance.eventLoopUtilization();
      utilization = performance.eventLoopUtilization(current, this.mark.utilization).utilization;
      this.mark = { at: now, utilization: current };
    }
    const load1PerCpu = os.loadavg()[0]! / Math.max(1, os.cpus().length);
    const level: HostPressureLevel = load1PerCpu >= CRITICAL_LOAD_PER_CPU || utilization >= CRITICAL_UTILIZATION ? "critical"
      : load1PerCpu >= ELEVATED_LOAD_PER_CPU || utilization >= ELEVATED_UTILIZATION ? "elevated" : "normal";
    const sample = { level, load1PerCpu: Math.round(load1PerCpu * 100) / 100,
      eventLoopUtilization: Math.round(utilization * 100) / 100, sampledAt: new Date().toISOString() };
    const previous = this.last?.sample.level ?? "normal";
    if (level !== previous) this.diagnostic?.({ event: "host.pressure", state: level, transition: previous,
      counts: { loadPerCpuPercent: Math.round(load1PerCpu * 100), eventLoopUtilizationPercent: Math.round(utilization * 100) } });
    this.last = { at: now, sample };
    return sample;
  }
}
