import { execFile } from "node:child_process";
import { appendFileSync, closeSync, existsSync, mkdirSync, openSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { readdir, rm } from "node:fs/promises";
import os from "node:os";
import { join } from "node:path";

/**
 * A Home task worker's command scope (kernel/run/README.md, docs/host-load.md). While a task
 * is bound to its worker session, every foreground shell that session spawns runs with the
 * scope's `TMPDIR`, a recorded process group and an inherited anchor descriptor. Ownership
 * is the union of (a) members of a recorded group that started after it was recorded, (b)
 * every process holding the anchor, and (c) live descendants of either. (a) survives
 * re-parenting to launchd; (b) survives `setsid` unless the program also closes inherited
 * descriptors, which is the deliberate way to detach a shared service (`scripts/tron dev
 * start`). The scope lives on disk so a Gateway restart or runtime rebuild keeps it.
 */
const SCOPE_ROOT_NAME = "tron-task-commands";
/** Inherited by every shell: high enough that `exec 3>`…`exec 9>` idioms do not replace it. */
export const TASK_SCOPE_ANCHOR_FD = 19;
/** `lstart` has one-second resolution. */
const START_TOLERANCE_MS = 2_000;
const PROBE_TIMEOUT_MS = 5_000;
const EXIT_WAIT_MS = 2_000;
const TASK_ID_PATTERN = /^[A-Za-z0-9._:-]{1,200}$/u;
const SESSION_ID_PATTERN = /^[A-Za-z0-9._-]{1,200}$/u;
/** Bound while the task runs; renamed to `SETTLED` when it settles, so later commands are unscoped. */
const BOUND = "task";
const SETTLED = "settled";

export interface TaskCommandScope { readonly directory: string; readonly tmp: string; readonly anchor: string; readonly groups: string }

/** Read when called, so an isolated `TMPDIR` (tests, verify) isolates the root too. */
export function taskCommandRoot(): string { return join(os.tmpdir(), SCOPE_ROOT_NAME); }

function scopeAt(directory: string): TaskCommandScope {
  return { directory, tmp: join(directory, "tmp"), anchor: join(directory, "anchor"), groups: join(directory, "groups") };
}

/** Binds the worker session's next commands to the task. A resumed task rebinds the same session. */
export function bindTaskCommandScope(sessionId: string, taskId: string, root = taskCommandRoot()): TaskCommandScope {
  if (!SESSION_ID_PATTERN.test(sessionId) || !TASK_ID_PATTERN.test(taskId)) throw new Error("Invalid task command scope identity");
  const scope = scopeAt(join(root, sessionId));
  mkdirSync(scope.tmp, { recursive: true, mode: 0o700 });
  if (!existsSync(scope.anchor)) writeFileSync(scope.anchor, "", { mode: 0o600 });
  writeFileSync(join(scope.directory, BOUND), taskId, { mode: 0o600 });
  return scope;
}

/** The session's bound scope, or none: interactive sessions and settled tasks run commands unscoped. */
export function boundTaskCommandScope(sessionId: string, root = taskCommandRoot()): TaskCommandScope | undefined {
  if (!SESSION_ID_PATTERN.test(sessionId)) return undefined;
  const scope = scopeAt(join(root, sessionId));
  return existsSync(join(scope.directory, BOUND)) ? scope : undefined;
}

export function taskCommandScopeOf(sessionId: string, root = taskCommandRoot()): TaskCommandScope | undefined {
  return SESSION_ID_PATTERN.test(sessionId) ? scopeAt(join(root, sessionId)) : undefined;
}

function readMarker(scope: TaskCommandScope, name: string): string | undefined {
  try {
    const value = readFileSync(join(scope.directory, name), "utf8").trim();
    return TASK_ID_PATTERN.test(value) ? value : undefined;
  } catch { return undefined; }
}

/** The task the scope is bound to now, if any. */
export function taskCommandScopeBinding(scope: TaskCommandScope): string | undefined { return readMarker(scope, BOUND); }

/** Ends the binding when its task settles, whatever the reap's outcome, so the session's later
 * commands are not scoped to a settled task. A successor's binding is left alone. */
export function settleTaskCommandScope(scope: TaskCommandScope, taskId: string): boolean {
  if (taskCommandScopeBinding(scope) !== taskId) return false;
  try { renameSync(join(scope.directory, BOUND), join(scope.directory, SETTLED)); return true; } catch { return false; }
}

/** Opens the anchor for one spawn; the caller passes it to the child and closes its own copy,
 * so the Gateway itself never holds the anchor. */
export function openTaskScopeAnchor(scope: TaskCommandScope): number { return openSync(scope.anchor, "r"); }
export function closeTaskScopeAnchor(fd: number): void { try { closeSync(fd); } catch { /* already closed */ } }

/** Recorded synchronously right after spawn, before the shell can run long enough to escape. */
export function recordTaskCommandGroup(scope: TaskCommandScope, pgid: number, recordedAtMs = Date.now()): void {
  appendFileSync(scope.groups, `${pgid} ${recordedAtMs}\n`, { mode: 0o600 });
}

export interface ProcessRow { pid: number; ppid: number; pgid: number; startedAtMs: number; cpu: number; command: string }
export type ProcessTable = Map<number, ProcessRow>;

function run(command: string, args: string[]): Promise<{ code: number; stdout: string }> {
  return new Promise(resolve => {
    execFile(command, args, { encoding: "utf8", timeout: PROBE_TIMEOUT_MS, maxBuffer: 16 * 1_024 * 1_024, env: { ...process.env, LC_ALL: "C" } }, (error, stdout) => {
      const code = error ? typeof (error as { code?: unknown }).code === "number" ? (error as { code: number }).code : -1 : 0;
      resolve({ code, stdout: typeof stdout === "string" ? stdout : "" });
    });
  });
}

/** One `ps` read of every live (non-zombie) process with its absolute start time; undefined when
 * it cannot be read, so callers refuse rather than guess. */
export async function readProcessTable(): Promise<ProcessTable | undefined> {
  const result = await run("ps", ["-axo", "pid=,ppid=,pgid=,stat=,lstart=,pcpu=,comm="]);
  if (result.code !== 0) return undefined;
  const rows: ProcessTable = new Map();
  for (const line of result.stdout.split("\n")) {
    const match = line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\w{3}\s+\w{3}\s+\d+\s+[\d:]+\s+\d{4})\s+([\d.]+)\s+(.*)$/u);
    if (!match || match[4]!.startsWith("Z")) continue;
    const startedAtMs = Date.parse(match[5]!);
    if (!Number.isFinite(startedAtMs)) continue;
    rows.set(Number(match[1]), { pid: Number(match[1]), ppid: Number(match[2]), pgid: Number(match[3]),
      startedAtMs, cpu: Number(match[6]), command: match[7]!.split("/").pop() ?? "" });
  }
  return rows;
}

async function anchorHolders(scope: TaskCommandScope): Promise<number[] | undefined> {
  if (!existsSync(scope.anchor)) return [];
  const result = await run("lsof", ["-t", "--", scope.anchor]);
  // lsof exits 1 with no output when nobody holds the file.
  if (result.code !== 0 && !(result.code === 1 && result.stdout.trim() === "")) return undefined;
  return result.stdout.split("\n").map(Number).filter(pid => Number.isSafeInteger(pid) && pid > 0);
}

/**
 * The recorded groups that are still this scope's, pruned in the same synchronous step that
 * reads them (an exec appends synchronously too, so no record is lost). A record is dropped
 * once no member is alive: its ID may then be reused. A live leader that started after the
 * record is a reused ID, never ours.
 */
function liveRecordedGroups(scope: TaskCommandScope, table: ProcessTable): Map<number, number> {
  let text = "";
  try { text = readFileSync(scope.groups, "utf8"); } catch { return new Map(); }
  const members = new Set<number>();
  for (const row of table.values()) members.add(row.pgid);
  const groups = new Map<number, number>();
  for (const line of text.split("\n")) {
    const match = line.match(/^(\d+) (\d+)$/u);
    if (!match) continue;
    const pgid = Number(match[1]);
    const recordedAt = Number(match[2]);
    const leader = table.get(pgid);
    if (!members.has(pgid) || (leader && leader.startedAtMs > recordedAt + START_TOLERANCE_MS)) continue;
    groups.set(pgid, Math.max(recordedAt, groups.get(pgid) ?? 0));
  }
  writeFileSync(scope.groups, [...groups].map(([pgid, at]) => `${pgid} ${at}\n`).join(""), { mode: 0o600 });
  return groups;
}

/** The Gateway and its ancestors are never owned, whatever a scope file says. */
function protectedPids(table: ProcessTable): Set<number> {
  const protectedSet = new Set<number>([0, 1, process.pid]);
  for (let pid = process.ppid; pid > 1 && !protectedSet.has(pid); pid = table.get(pid)?.ppid ?? 1) protectedSet.add(pid);
  return protectedSet;
}

function ownedProcesses(table: ProcessTable, groups: Map<number, number>, holders: readonly number[]): Set<number> {
  const owned = new Set<number>();
  for (const row of table.values()) {
    const recorded = groups.get(row.pgid);
    if (recorded !== undefined && row.startedAtMs >= recorded - START_TOLERANCE_MS) owned.add(row.pid);
  }
  for (const pid of holders) if (table.has(pid)) owned.add(pid);
  const children = new Map<number, number[]>();
  for (const row of table.values()) children.set(row.ppid, [...(children.get(row.ppid) ?? []), row.pid]);
  const pending = [...owned];
  while (pending.length > 0) {
    for (const child of children.get(pending.pop()!) ?? []) if (!owned.has(child)) { owned.add(child); pending.push(child); }
  }
  for (const pid of protectedPids(table)) owned.delete(pid);
  return owned;
}

/** What the scope owns now, or undefined when processes cannot be read. */
export async function taskCommandProcesses(scope: TaskCommandScope, table?: ProcessTable): Promise<Set<number> | undefined> {
  const [current, holders] = await Promise.all([table ? Promise.resolve(table) : readProcessTable(), anchorHolders(scope)]);
  if (!current || !holders) return undefined;
  return ownedProcesses(current, liveRecordedGroups(scope, current), holders);
}

export type TaskScopeReap =
  | { outcome: "reaped"; processes: number; survivors: 0 }
  | { outcome: "refused"; reason: "process-table-unreadable" | "survivors" | "rebound" | "remove-failed"; processes: number; survivors: number };

/**
 * Kills everything a settled scope owns, then removes it, temp files included. Owned processes
 * are frozen, ownership is read again (one forking in between is still caught, as the
 * foreground owner does), and the scope must still be settled for `taskId` before the kill and
 * before the removal: a successor bound meanwhile is never reaped. Anything uncertain leaves
 * the scope on disk for the next sweep.
 */
export async function reapTaskCommandScope(scope: TaskCommandScope, taskId: string): Promise<TaskScopeReap> {
  const settled = () => taskCommandScopeBinding(scope) === undefined && readMarker(scope, SETTLED) === taskId;
  if (!settled()) return { outcome: "refused", reason: "rebound", processes: 0, survivors: 0 };
  const first = await taskCommandProcesses(scope);
  if (!first) return { outcome: "refused", reason: "process-table-unreadable", processes: 0, survivors: 0 };
  const signal = (pids: Iterable<number>, name: NodeJS.Signals) => { for (const pid of pids) { try { process.kill(pid, name); } catch { /* exited */ } } };
  let owned = first;
  if (owned.size > 0) {
    signal(owned, "SIGSTOP");
    const second = await taskCommandProcesses(scope);
    if (second) { owned = new Set([...owned, ...second]); signal(second, "SIGSTOP"); }
    if (!settled()) { signal(owned, "SIGCONT"); return { outcome: "refused", reason: "rebound", processes: 0, survivors: 0 }; }
    signal(owned, "SIGKILL");
  }
  const running = () => [...owned].filter(pid => { try { process.kill(pid, 0); return true; } catch { return false; } });
  // A killed process stays a zombie until its parent (often launchd) reaps it; a zombie runs
  // nothing, so the live table, not `kill(pid, 0)`, decides survivors.
  for (const deadline = Date.now() + EXIT_WAIT_MS; running().length > 0 && Date.now() < deadline;) await new Promise(resolve => setTimeout(resolve, 50));
  const after = owned.size === 0 ? new Map() : await readProcessTable();
  const survivors = after ? [...owned].filter(pid => after.has(pid)).length : owned.size;
  if (survivors > 0) return { outcome: "refused", reason: "survivors", processes: owned.size, survivors };
  if (!settled()) return { outcome: "refused", reason: "rebound", processes: owned.size, survivors: 0 };
  try { await rm(scope.directory, { recursive: true, force: true, maxRetries: 2 }); }
  catch { return { outcome: "refused", reason: "remove-failed", processes: owned.size, survivors: 0 }; }
  return { outcome: "reaped", processes: owned.size, survivors: 0 };
}

/** Every scope on disk with its bound or settled task (undefined when neither is readable). */
export async function listTaskCommandScopes(root = taskCommandRoot()): Promise<Array<{ sessionId: string; bound: string | undefined; settled: string | undefined; scope: TaskCommandScope }>> {
  const entries = await readdir(root, { withFileTypes: true }).catch(() => []);
  return entries.filter(entry => entry.isDirectory() && SESSION_ID_PATTERN.test(entry.name)).map(entry => {
    const scope = scopeAt(join(root, entry.name));
    return { sessionId: entry.name, bound: readMarker(scope, BOUND), settled: readMarker(scope, SETTLED), scope };
  });
}
