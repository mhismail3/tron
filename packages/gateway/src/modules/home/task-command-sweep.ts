import { createHash } from "node:crypto";
import {
  bindTaskCommandScope, listTaskCommandScopes, readProcessTable, reapTaskCommandScope, settleTaskCommandScope,
  taskCommandProcesses, taskCommandScopeOf, type ProcessTable, type TaskScopeReap,
} from "../../kernel/run/task-command-scope.js";
import { busyShare, readCpuTicks, type CpuTicks } from "./host-pressure.js";

const TASK_COMMAND_SWEEP_INTERVAL_MS = 60_000;
const RUNAWAY_CPU_BUSY = 0.9;
const LOAD_FLAG_INTERVAL_MS = 10 * 60_000;
const LOAD_TOP_PROCESSES = 5;

const hash = (value: string) => createHash("sha256").update(value).digest("hex").slice(0, 16);

export type TaskCommandDiagnostic =
  | { event: "home.task.command-reap"; taskHash: string; action: "settle" | "sweep"; outcome: TaskScopeReap["outcome"];
    reason?: string; counts: { processes: number; survivors: number } }
  | { event: "home.task.command-scope-refused"; reason: "unbound-scope" | "unknown-task" | "bind-failed" }
  | { event: "host.load.non-task"; counts: { cpuBusyPercent: number; taskCpuPercent: number; nonTaskCpuPercent: number; orphanCpuPercent: number }; stages: string };

export class TaskCommandSweep {
  private timer: NodeJS.Timeout | undefined;
  private sweeping: Promise<void> | undefined;
  private readonly refused = new Set<string>();
  private lastLoadFlagAt = -Infinity;
  private cpuMark: readonly CpuTicks[] = readCpuTicks();

  constructor(private readonly tasks: {
    running: (taskId: string) => boolean;
    record: (taskId: string) => Promise<{ terminal: boolean; sessionId: string | null } | undefined>;
  }, private readonly diagnostic: ((record: TaskCommandDiagnostic) => void) | undefined) {}

  start(): void {
    if (this.timer || process.platform === "win32") return;
    this.timer = setInterval(() => void this.sweep(), TASK_COMMAND_SWEEP_INTERVAL_MS);
    this.timer.unref();
  }

  async dispose(): Promise<void> {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
    await this.sweeping;
  }

  bind(sessionId: string, taskId: string): void {
    if (process.platform === "win32") return;
    try { bindTaskCommandScope(sessionId, taskId); }
    catch { this.diagnostic?.({ event: "home.task.command-scope-refused", reason: "bind-failed" }); }
  }

  async settle(sessionId: string, taskId: string): Promise<void> {
    const scope = taskCommandScopeOf(sessionId);
    if (!scope || !settleTaskCommandScope(scope, taskId)) return;
    await this.reap(scope, taskId, "settle");
  }

  sweep(): Promise<void> {
    return this.sweeping ??= this.sweepOnce().catch(() => {}).finally(() => { this.sweeping = undefined; });
  }

  private async reap(scope: NonNullable<ReturnType<typeof taskCommandScopeOf>>, taskId: string, action: "settle" | "sweep"): Promise<void> {
    const result = await reapTaskCommandScope(scope, taskId).catch((): TaskScopeReap =>
      ({ outcome: "refused", reason: "process-table-unreadable", processes: 0, survivors: 0 }));
    if (action === "settle" || result.outcome === "refused" || result.processes > 0) {
      this.diagnostic?.({ event: "home.task.command-reap", taskHash: hash(taskId), action, outcome: result.outcome,
        ...(result.outcome === "refused" ? { reason: result.reason } : {}), counts: { processes: result.processes, survivors: result.survivors } });
    }
  }

  private async sweepOnce(): Promise<void> {
    const table = await readProcessTable();
    if (!table) return;
    const owned = new Set<number>();
    for (const { sessionId, bound, settled, scope } of await listTaskCommandScopes()) {
      const taskId = bound ?? settled;
      if (!taskId) { this.refuse(sessionId, "unbound-scope"); continue; }
      if (!this.tasks.running(taskId)) {
        const record = await this.tasks.record(taskId).catch(() => undefined);
        if (!record || record.sessionId !== sessionId) { this.refuse(sessionId, "unknown-task"); continue; }
        if (record.terminal) {
          if (bound) settleTaskCommandScope(scope, taskId);
          await this.reap(scope, taskId, "sweep");
          continue;
        }
      }
      for (const pid of await taskCommandProcesses(scope, table) ?? []) owned.add(pid);
    }
    this.flagHostLoad(table, owned);
  }

  private refuse(sessionId: string, reason: "unbound-scope" | "unknown-task"): void {
    if (this.refused.has(sessionId)) return;
    this.refused.add(sessionId);
    this.diagnostic?.({ event: "home.task.command-scope-refused", reason });
  }

  private flagHostLoad(table: ProcessTable, owned: ReadonlySet<number>): void {
    const cpus = readCpuTicks();
    const busy = busyShare(this.cpuMark, cpus);
    this.cpuMark = cpus;
    if (busy < RUNAWAY_CPU_BUSY || Date.now() - this.lastLoadFlagAt < LOAD_FLAG_INTERVAL_MS) return;
    let taskCpu = 0, nonTaskCpu = 0, orphanCpu = 0;
    const nonTask = [];
    for (const row of table.values()) {
      if (owned.has(row.pid)) { taskCpu += row.cpu; continue; }
      if (row.pid === process.pid) continue;
      nonTaskCpu += row.cpu;
      if (row.ppid === 1) orphanCpu += row.cpu;
      nonTask.push(row);
    }
    if (nonTaskCpu <= taskCpu) return;
    this.lastLoadFlagAt = Date.now();
    const top = nonTask.sort((left, right) => right.cpu - left.cpu).slice(0, LOAD_TOP_PROCESSES);
    this.diagnostic?.({ event: "host.load.non-task",
      counts: { cpuBusyPercent: Math.round(busy * 100), taskCpuPercent: Math.round(taskCpu),
        nonTaskCpuPercent: Math.round(nonTaskCpu), orphanCpuPercent: Math.round(orphanCpu) },
      stages: top.map(row => `${row.command} pid=${row.pid} ppid=${row.ppid} cpu=${Math.round(row.cpu)}%`).join("; ") });
  }
}
