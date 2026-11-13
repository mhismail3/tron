import os from "node:os";
import { performance, type EventLoopUtilization } from "node:perf_hooks";

export type HostPressureLevel = "normal" | "elevated" | "critical";

export interface HostPressureSample {
  level: HostPressureLevel;
  load1PerCpu: number;
  eventLoopUtilization: number;
  sampledAt: string;
}

export interface HostPressureDiagnostic {
  event: "host.pressure";
  state: HostPressureLevel;
  transition: HostPressureLevel;
  counts: { loadPerCpuPercent: number; cpuBusyPercent: number; eventLoopUtilizationPercent: number };
}

const ELEVATED_CPU_BUSY = 0.7;
const CRITICAL_CPU_BUSY = 0.95;
const ELEVATED_UTILIZATION = 0.7;
const CRITICAL_UTILIZATION = 0.95;
const SAMPLE_REUSE_MS = 2_000;

export interface CpuTicks { busy: number; total: number }

export function readCpuTicks(): CpuTicks[] {
  return os.cpus().map(({ times }) => {
    const busy = times.user + times.nice + times.sys + times.irq;
    return { busy, total: busy + times.idle };
  });
}

export function busyShare(previous: readonly CpuTicks[], current: readonly CpuTicks[]): number | undefined {
  if (current.length === 0 || previous.length !== current.length) return undefined;
  let busy = 0;
  let total = 0;
  for (let index = 0; index < current.length; index += 1) {
    const busyDelta = current[index]!.busy - previous[index]!.busy;
    const totalDelta = current[index]!.total - previous[index]!.total;
    if (!(busyDelta >= 0 && totalDelta >= 0)) return undefined;
    busy += busyDelta;
    total += totalDelta;
  }
  return total > 0 ? Math.min(1, busy / total) : undefined;
}

export class HostPressure {
  private mark: { at: number; utilization: EventLoopUtilization; cpus: readonly CpuTicks[] } = {
    at: performance.now(), utilization: performance.eventLoopUtilization(), cpus: readCpuTicks(),
  };
  private last: { at: number; sample: HostPressureSample; cpuBusy: number } | undefined;

  constructor(private readonly diagnostic?: (record: HostPressureDiagnostic) => void) {}

  sample(): HostPressureSample {
    const now = performance.now();
    if (this.last && now - this.last.at < SAMPLE_REUSE_MS) return this.last.sample;
    let utilization = this.last?.sample.eventLoopUtilization ?? 0;
    let cpuBusy = this.last?.cpuBusy ?? 0;
    const cpus = readCpuTicks();
    if (now - this.mark.at >= SAMPLE_REUSE_MS) {
      const current = performance.eventLoopUtilization();
      utilization = performance.eventLoopUtilization(current, this.mark.utilization).utilization;
      cpuBusy = busyShare(this.mark.cpus, cpus) ?? 0;
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
