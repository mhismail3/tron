// Read execution-host CPU idle and free memory for the native test reporters.
import { cpus, freemem, hostname, totalmem } from 'node:os';

export function hostSampler() {
  const ticks = () => cpus().reduce((sum, cpu) => ({ total: sum.total + Object.values(cpu.times).reduce((a, b) => a + b, 0), idle: sum.idle + cpu.times.idle }), { total: 0, idle: 0 });
  let previous = ticks();
  let idle = Number(process.env.TRON_TEST_LEDGER_CPU_IDLE);
  return () => {
    const current = ticks();
    if (current.total > previous.total) idle = 100 * (current.idle - previous.idle) / (current.total - previous.total);
    previous = current;
    return { host: hostname(), cpuIdlePercent: Number.isFinite(idle) ? idle : null, memoryFreePercent: 100 * freemem() / totalmem(), measuredAt: new Date().toISOString() };
  };
}
