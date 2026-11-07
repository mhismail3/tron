import { createHash } from "node:crypto";
import {
  bindTaskCommandScope, listTaskCommandScopes, readProcessTable, reapTaskCommandScope, settleTaskCommandScope,
  taskCommandProcesses, taskCommandScopeOf, type ProcessTable, type TaskScopeReap,
} from "../../kernel/run/task-command-scope.js";
import { busyShare, readCpuTicks, type CpuTicks } from "./host-pressure.js";

/** Cheap: one `ps` plus one `lsof` per scope. */
const TASK_COMMAND_SWEEP_INTERVAL_MS = 60_000;
/** Busy share of all CPUs over one sweep window at which the sweep attributes host CPU. Load
 * average does not track busy CPUs on this Mac (host-load.md), so it is not used. */
const RUNAWAY_CPU_BUSY = 0.9;
const LOAD_FLAG_INTERVAL_MS = 10 * 60_000;
const LOAD_TOP_PROCESSES = 5;

const hash = (value: string) => createHash("sha256").update(value).digest("hex").slice(0, 16);

export type TaskCommandDiagnostic =
  | { event: "home.task.command-reap"; taskHash: string; action: "settle" | "sweep"; outcome: TaskScopeReap["outcome"];
    reason?: string; counts: { processes: number; survivors: number } }
  | { event: "home.task.command-scope-refused"; reason: "unbound-scope" | "unknown-task" | "bind-failed" }
  /** `stages` names the busiest processes outside every task scope as
   * `name pid=… ppid=… cpu=…%`; `ppid=1` marks an orphan or a launchd job. */
  | { event: "host.load.non-task"; counts: { cpuBusyPercent: number; taskCpuPercent: number; nonTaskCpuPercent: number; orphanCpuPercent: number }; stages: string };

/**
 * Owns Home task command scopes (kernel/run/task-command-scope.ts) for the dispatcher: binds a
 * scope when a task binds its worker, settles and reaps it when the task settles, and every
 * sweep reaps scopes whose task settled without a completed reap (a refused reap, a failed
 * settlement or a Gateway restart) and flags host CPU that task scopes do not explain. It
 * refuses and logs rather than guess: a scope whose task this Home's store does not record
 * for that same worker session is left alone.
 */
export class TaskCommandSweep {
  private timer: NodeJS.Timeout | undefined;
  private sweeping: Promise<void> | undefined;
  private readonly refused = new Set<string>();
  private lastLoadFlagAt = -Infinity;
  private cpuMark: readonly CpuTicks[] = readCpuTicks();

  constructor(private readonly tasks: {
    running: (taskId: string) => boolean;
    /** The task's lifecycle and worker session, undefined when the store has no such task. */
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

  /** A failed bind leaves the worker's commands unscoped, logged; it never refuses the task. */
  bind(sessionId: string, taskId: string): void {
    if (process.platform === "win32") return;
    try { bindTaskCommandScope(sessionId, taskId); }
    catch { this.diagnostic?.({ event: "home.task.command-scope-refused", reason: "bind-failed" }); }
  }

  /** The settling task's own reap. Never throws; a refused reap leaves the settled scope to the sweep. */
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
        // Scopes of another Gateway sharing this temp root name tasks this store lacks.
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
