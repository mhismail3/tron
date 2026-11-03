import { createHash } from "node:crypto";
import {
  adoptTaskCommandGroups, boundTaskCommandScope, listTaskCommandScopes, readProcessTable, reapTaskCommandScope,
  taskCommandScopeBinding, type TaskScopeReap,
} from "../../kernel/run/task-command-scope.js";
import { busyShare, readCpuTicks, type CpuTicks } from "./host-pressure.js";

/** Cheap: one `ps` plus one `lsof` per live scope. */
export const TASK_COMMAND_SWEEP_INTERVAL_MS = 60_000;
/** Busy share of all CPUs over one sweep window at which the sweep attributes host CPU. Load
 * average does not track busy CPUs on this Mac (host-load.md), so it is reported, not used. */
const RUNAWAY_CPU_BUSY = 0.9;
const LOAD_FLAG_INTERVAL_MS = 10 * 60_000;
const LOAD_TOP_PROCESSES = 5;

const hash = (value: string) => createHash("sha256").update(value).digest("hex").slice(0, 16);

export type TaskCommandDiagnostic =
  | { event: "home.task.command-reap"; taskHash: string; action: "settle" | "sweep"; outcome: TaskScopeReap["outcome"];
    reason?: string; counts: { processes: number; survivors: number } }
  | { event: "home.task.command-scope-refused"; reason: "unbound-scope" | "unknown-task" }
  /** `stages` names the busiest processes outside every live task scope as
   * `name pid=… ppid=… cpu=…%`; `ppid=1` marks an orphan or a launchd job. */
  | { event: "host.load.non-task"; counts: { cpuBusyPercent: number; taskCpuPercent: number; nonTaskCpuPercent: number; orphanCpuPercent: number }; stages: string };

/**
 * Owns task command scopes after their commands return (kernel/run/task-command-scope.ts):
 * reaps a scope when its task settles, and periodically reaps scopes whose task is settled
 * (a Gateway restart or a failed settle reap), adopts escaped group leaders of running tasks,
 * and flags host load that task scopes do not explain. It refuses and logs, never guesses:
 * a scope without a readable task, or with a task this Home's store does not know, is left alone.
 */
export class TaskCommandSweep {
  private timer: NodeJS.Timeout | undefined;
  private sweeping: Promise<void> | undefined;
  private readonly refused = new Set<string>();
  private lastLoadFlagAt = -Infinity;
  private cpuMark: readonly CpuTicks[] = readCpuTicks();

  constructor(private readonly tasks: {
    running: (taskId: string) => boolean;
    lifecycle: (taskId: string) => Promise<"terminal" | "open" | undefined>;
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

  /** The settling task's own reap. A failure leaves the scope for the sweep. */
  async reap(sessionId: string, taskId: string, action: "settle" | "sweep"): Promise<void> {
    const scope = boundTaskCommandScope(sessionId);
    if (!scope || taskCommandScopeBinding(scope) !== taskId) return;
    const result = await reapTaskCommandScope(scope).catch((): TaskScopeReap =>
      ({ outcome: "refused", reason: "process-table-unreadable", processes: 0, survivors: 0, tmpRemoved: false }));
    if (action === "settle" || result.outcome === "refused" || result.processes > 0) {
      this.diagnostic?.({ event: "home.task.command-reap", taskHash: hash(taskId), action, outcome: result.outcome,
        ...(result.outcome === "refused" ? { reason: result.reason } : {}), counts: { processes: result.processes, survivors: result.survivors } });
    }
  }

  sweep(): Promise<void> {
    return this.sweeping ??= this.sweepOnce().catch(() => {}).finally(() => { this.sweeping = undefined; });
  }

  private async sweepOnce(): Promise<void> {
    const table = await readProcessTable();
    if (!table) return;
    const owned = new Set<number>();
    for (const { sessionId, taskId, scope } of await listTaskCommandScopes()) {
      if (!taskId) { this.refuse(sessionId, "unbound-scope"); continue; }
      const state = this.tasks.running(taskId) ? "open" : await this.tasks.lifecycle(taskId);
      if (state === "terminal") { await this.reap(sessionId, taskId, "sweep"); continue; }
      if (state === undefined) this.refuse(sessionId, "unknown-task");
      for (const pid of await adoptTaskCommandGroups(scope, table) ?? []) owned.add(pid);
    }
    this.flagHostLoad(table, owned);
  }

  private refuse(sessionId: string, reason: "unbound-scope" | "unknown-task"): void {
    if (this.refused.has(sessionId)) return;
    this.refused.add(sessionId);
    this.diagnostic?.({ event: "home.task.command-scope-refused", reason });
  }

  private flagHostLoad(table: NonNullable<Awaited<ReturnType<typeof readProcessTable>>>, owned: ReadonlySet<number>): void {
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
