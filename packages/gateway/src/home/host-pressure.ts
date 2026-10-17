import os from "node:os";
import { performance, type EventLoopUtilization } from "node:perf_hooks";

/** Host pressure as one level (#915, docs/host-load.md). It informs Home status and the
 * Gateway log; it never holds a Home worker back. */
export type HostPressureLevel = "normal" | "elevated" | "critical";

export interface HostPressureSample {
  level: HostPressureLevel;
  /** 1-minute load average divided by the CPU count. Displayed only: load average does
   * not track busy CPUs on this Mac, so it never sets the level (#1096). */
  load1PerCpu: number;
  /** Event-loop utilisation since the previous window, 0..1. */
  eventLoopUtilization: number;
  sampledAt: string;
}

/** In the Gateway log's field vocabulary (transport/logger.ts keeps only known fields,
 * and its own `level` is the log level), so the record survives the writer: `state` is
 * the new level, `transition` the previous one, and `counts` carries load per CPU, busy
 * CPU and event-loop utilisation as percentages (#1103, #1096). */
export interface HostPressureDiagnostic {
  event: "host.pressure";
  state: HostPressureLevel;
  transition: HostPressureLevel;
  counts: { loadPerCpuPercent: number; cpuBusyPercent: number; eventLoopUtilizationPercent: number };
}

/** Busy share of all CPUs, banded like event-loop utilisation. */
const ELEVATED_CPU_BUSY = 0.7;
const CRITICAL_CPU_BUSY = 0.95;
const ELEVATED_UTILIZATION = 0.7;
const CRITICAL_UTILIZATION = 0.95;
/** Reads closer together than this reuse the previous sample, so a burst of status
 * reads measures one window instead of many empty ones. It is also the shortest
 * window utilisation and CPU busy are measured over: a window of a few milliseconds is
 * mostly the reading tick itself and reads 0.94 to 0.96 on an idle process, which held a
 * fresh Gateway's first Home worker back as `critical` (#1000). */
const SAMPLE_REUSE_MS = 2_000;

/** One CPU's cumulative kernel ticks since boot, as `os.cpus()` reports them. */
interface CpuTicks { busy: number; total: number }

function readCpuTicks(): CpuTicks[] {
  return os.cpus().map(({ times }) => {
    const busy = times.user + times.nice + times.sys + times.irq;
    return { busy, total: busy + times.idle };
  });
}

/** Busy share of all CPUs between two tick readings, 0..1. A window that cannot be
 * measured reads 0 rather than inventing pressure: the CPU count changed (hotplug),
 * a counter went backwards (reset), or no tick advanced. */
function busyShare(previous: readonly CpuTicks[], current: readonly CpuTicks[]): number {
  if (current.length === 0 || previous.length !== current.length) return 0;
  let busy = 0;
  let total = 0;
  for (let index = 0; index < current.length; index += 1) {
    const busyDelta = current[index]!.busy - previous[index]!.busy;
    const totalDelta = current[index]!.total - previous[index]!.total;
    if (!(busyDelta >= 0 && totalDelta >= 0)) return 0;
    busy += busyDelta;
    total += totalDelta;
  }
  return total > 0 ? Math.min(1, busy / total) : 0;
}

/** One process-wide sampler, read on demand by Home status. It owns no timer: a level
 * transition is logged when a read sees it. */
export class HostPressure {
  private mark: { at: number; utilization: EventLoopUtilization; cpus: readonly CpuTicks[] } = {
    at: performance.now(), utilization: performance.eventLoopUtilization(), cpus: readCpuTicks(),
  };
  private last: { at: number; sample: HostPressureSample; cpuBusy: number } | undefined;

  constructor(private readonly diagnostic?: (record: HostPressureDiagnostic) => void) {}

  sample(): HostPressureSample {
    const now = performance.now();
    if (this.last && now - this.last.at < SAMPLE_REUSE_MS) return this.last.sample;
    // Until the window since the mark is long enough to measure, utilisation and busy CPU
    // keep their last measured value (none yet: 0) and the window keeps growing.
    let utilization = this.last?.sample.eventLoopUtilization ?? 0;
    let cpuBusy = this.last?.cpuBusy ?? 0;
    const cpus = readCpuTicks();
    if (now - this.mark.at >= SAMPLE_REUSE_MS) {
      const current = performance.eventLoopUtilization();
      utilization = performance.eventLoopUtilization(current, this.mark.utilization).utilization;
      cpuBusy = busyShare(this.mark.cpus, cpus);
      this.mark = { at: now, utilization: current, cpus };
    }
    const load1PerCpu = os.loadavg()[0]! / Math.max(1, cpus.length);
    const level: HostPressureLevel = cpuBusy >= CRITICAL_CPU_BUSY || utilization >= CRITICAL_UTILIZATION ? "critical"
      : cpuBusy >= ELEVATED_CPU_BUSY || utilization >= ELEVATED_UTILIZATION ? "elevated" : "normal";
    const sample = { level, load1PerCpu: Math.round(load1PerCpu * 100) / 100,
      eventLoopUtilization: Math.round(utilization * 100) / 100, sampledAt: new Date().toISOString() };
    const previous = this.last?.sample.level ?? "normal";
    if (level !== previous) this.diagnostic?.({ event: "host.pressure", state: level, transition: previous,
      counts: { loadPerCpuPercent: Math.round(load1PerCpu * 100), cpuBusyPercent: Math.round(cpuBusy * 100),
        eventLoopUtilizationPercent: Math.round(utilization * 100) } });
    this.last = { at: now, sample, cpuBusy };
    return sample;
  }
}
