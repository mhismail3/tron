import { createHash } from "node:crypto";
import {
  bindTaskCommandScope, listTaskCommandScopes, readProcessArgs, readProcessTable, reapTaskCommandScope, settleTaskCommandScope,
  taskCommandProcesses, taskCommandScopeOf, type ProcessTable, type TaskScopeReap,
} from "../../kernel/run/task-command-scope.js";
import { sampleHostMemory } from "../../foundation/host-memory.js";
import { busyShare, readCpuTicks, type CpuTicks } from "./host-pressure.js";

const TASK_COMMAND_SWEEP_INTERVAL_MS = 60_000;
const RUNAWAY_CPU_BUSY = 0.9;
const LOAD_FLAG_INTERVAL_MS = 10 * 60_000;
const LOAD_TOP_PROCESSES = 5;

const hash = (value: string) => createHash("sha256").update(value).digest("hex").slice(0, 16);

const HEAVY_PROCESS_KINDS = ["xcodebuild", "xctest", "simulator", "vitest", "verify"] as const;
export type HeavyProcessKind = typeof HEAVY_PROCESS_KINDS[number];
const LAUNCHER = /^(?:node|python[\d.]*|bash|sh|zsh|env|xcrun)$/iu;

function heavyProcessKind(args: string): HeavyProcessKind | undefined {
  const tokens = args.trim().split(/\s+/u);
  const base = (token: string) => token.slice(token.lastIndexOf("/") + 1);
  let index = 0;
  while (index < tokens.length && LAUNCHER.test(base(tokens[index]!))) {
    index += 1;
    while (index < tokens.length && tokens[index]!.startsWith("-")) index += 1;
  }
  const target = tokens[index] ?? "";
  const name = base(target);
  if (name === "xcodebuild" || name === "xctest") return name;
  if (name === "simctl" || name === "Simulator") return "simulator";
  if (/^vitest(?:\.m?js)?$/u.test(name) || target.includes("/node_modules/vitest/")) return "vitest";
  if (name === "verify.py") return "verify";
  return undefined;
}

export interface HostReading {
  sampledAt: string;
  cpuBusy: number | undefined;
  memoryFreePercent: number | undefined;
  simulatorsBooted: number | undefined;
  heavy: ReadonlyMap<string, readonly HeavyProcessKind[] | undefined>;
}

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
  private last: HostReading | undefined;

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

  reading(): HostReading | undefined { return this.last; }

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
    const sampledAt = new Date().toISOString();
    const cpus = readCpuTicks();
    const cpuBusy = busyShare(this.cpuMark, cpus);
    this.cpuMark = cpus;
    const [table, memory] = await Promise.all([readProcessTable(), sampleHostMemory().catch(() => undefined)]);
    const running = table ? await this.walk(table, cpuBusy) : new Map<string, Set<number> | undefined>();
    this.last = { sampledAt, cpuBusy, memoryFreePercent: memory?.memoryAvailablePercent,
      simulatorsBooted: table ? [...table.values()].filter(row => row.command === "launchd_sim").length : undefined,
      heavy: await this.heavyKinds(running) };
  }

  private async walk(table: ProcessTable, cpuBusy: number | undefined): Promise<Map<string, Set<number> | undefined>> {
    const owned = new Set<number>();
    const running = new Map<string, Set<number> | undefined>();
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
      const processes = await taskCommandProcesses(scope, table);
      if (this.tasks.running(taskId)) running.set(taskId, processes);
      for (const pid of processes ?? []) owned.add(pid);
    }
    if (cpuBusy !== undefined) this.flagHostLoad(table, owned, cpuBusy);
    return running;
  }

  private async heavyKinds(running: ReadonlyMap<string, ReadonlySet<number> | undefined>): Promise<Map<string, HeavyProcessKind[] | undefined>> {
    const args = await readProcessArgs([...new Set([...running.values()].flatMap(pids => [...pids ?? []]))]);
    return new Map([...running].map(([taskId, pids]) => {
      if (!pids || !args || (pids.size > 0 && ![...pids].some(pid => args.has(pid)))) return [taskId, undefined];
      const kinds = new Set([...pids].map(pid => heavyProcessKind(args.get(pid) ?? "")));
      return [taskId, HEAVY_PROCESS_KINDS.filter(kind => kinds.has(kind))];
    }));
  }

  private refuse(sessionId: string, reason: "unbound-scope" | "unknown-task"): void {
    if (this.refused.has(sessionId)) return;
    this.refused.add(sessionId);
    this.diagnostic?.({ event: "home.task.command-scope-refused", reason });
  }

  private flagHostLoad(table: ProcessTable, owned: ReadonlySet<number>, busy: number): void {
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
