import { execFile } from "node:child_process";
import { appendFileSync, closeSync, existsSync, mkdirSync, openSync, readFileSync, writeFileSync } from "node:fs";
import { readdir, readFile, rm } from "node:fs/promises";
import os from "node:os";
import { join } from "node:path";

/**
 * A Home task worker's command scope (docs: kernel/run/README.md "Task command scope").
 * While a task is bound to a worker session, every foreground shell that session spawns
 * runs with this scope: its own `TMPDIR`, a recorded process group, and an inherited
 * anchor descriptor. Ownership is the union of (a) members of a recorded group that
 * started after it was recorded, (b) every process still holding the anchor, and (c) the
 * descendants of either. (a) survives re-parenting to launchd; (b) survives `setsid`
 * unless the program closes inherited descriptors; the sweep's adoption of owned group
 * leaders closes most of the remainder. The scope lives on disk so a Gateway restart or
 * runtime rebuild keeps it, and settling the task reaps it.
 */
const SCOPE_ROOT_NAME = "tron-task-commands";
/** Inherited by every shell: high enough that `exec 3>`…`exec 9>` idioms do not replace it. */
export const TASK_SCOPE_ANCHOR_FD = 19;
/** `etime` has one-second resolution; a member may read up to this much older than its group. */
const START_TOLERANCE_SECONDS = 2;
const PROBE_TIMEOUT_MS = 5_000;
const EXIT_WAIT_MS = 2_000;
const TASK_ID_PATTERN = /^[A-Za-z0-9._:-]{1,200}$/u;
const SESSION_ID_PATTERN = /^[A-Za-z0-9._-]{1,200}$/u;

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
  writeFileSync(join(scope.directory, "task"), taskId, { mode: 0o600 });
  return scope;
}

/** The session's bound scope, or none: interactive sessions run commands exactly as before. */
export function boundTaskCommandScope(sessionId: string, root = taskCommandRoot()): TaskCommandScope | undefined {
  if (!SESSION_ID_PATTERN.test(sessionId)) return undefined;
  const scope = scopeAt(join(root, sessionId));
  return existsSync(join(scope.directory, "task")) ? scope : undefined;
}

/** Opens the anchor for one spawn; the caller passes it to the child and closes its own copy,
 * so the Gateway itself never holds the anchor. */
export function openTaskScopeAnchor(scope: TaskCommandScope): number { return openSync(scope.anchor, "r"); }
export function closeTaskScopeAnchor(fd: number): void { try { closeSync(fd); } catch { /* already closed */ } }

/** Recorded synchronously right after spawn, before the shell can run long enough to escape. */
export function recordTaskCommandGroup(scope: TaskCommandScope, pgid: number, startedAtSeconds = Math.floor(Date.now() / 1_000)): void {
  appendFileSync(scope.groups, `${pgid} ${startedAtSeconds}\n`, { mode: 0o600 });
}

interface ProcessRow { pid: number; ppid: number; pgid: number; startedAt: number; cpu: number; command: string }

function run(command: string, args: string[]): Promise<{ code: number; stdout: string }> {
  return new Promise(resolve => {
    execFile(command, args, { encoding: "utf8", timeout: PROBE_TIMEOUT_MS, maxBuffer: 16 * 1_024 * 1_024 }, (error, stdout) => {
      const code = error ? typeof (error as { code?: unknown }).code === "number" ? (error as { code: number }).code : -1 : 0;
      resolve({ code, stdout: typeof stdout === "string" ? stdout : "" });
    });
  });
}

/** `[[dd-]hh:]mm:ss` as seconds. */
function elapsedSeconds(value: string): number | undefined {
  const match = value.match(/^(?:(?:(\d+)-)?(\d+):)?(\d+):(\d+)$/u);
  if (!match) return undefined;
  return Number(match[1] ?? 0) * 86_400 + Number(match[2] ?? 0) * 3_600 + Number(match[3]) * 60 + Number(match[4]);
}

/** One `ps` read of every process; undefined when it cannot be read, so callers refuse rather than guess. */
export async function readProcessTable(): Promise<Map<number, ProcessRow> | undefined> {
  const now = Math.floor(Date.now() / 1_000);
  const result = await run("ps", ["-axo", "pid=,ppid=,pgid=,etime=,pcpu=,comm="]);
  if (result.code !== 0) return undefined;
  const rows = new Map<number, ProcessRow>();
  for (const line of result.stdout.split("\n")) {
    const match = line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+([\d.]+)\s+(.*)$/u);
    if (!match) continue;
    const elapsed = elapsedSeconds(match[4]!);
    if (elapsed === undefined) continue;
    rows.set(Number(match[1]), { pid: Number(match[1]), ppid: Number(match[2]), pgid: Number(match[3]),
      startedAt: now - elapsed, cpu: Number(match[5]), command: match[6]!.split("/").pop() ?? "" });
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

async function recordedGroups(scope: TaskCommandScope): Promise<Map<number, number>> {
  const groups = new Map<number, number>();
  const text = await readFile(scope.groups, "utf8").catch(() => "");
  for (const line of text.split("\n")) {
    const match = line.match(/^(\d+) (\d+)$/u);
    if (match) groups.set(Number(match[1]), Math.min(Number(match[2]), groups.get(Number(match[1])) ?? Infinity));
  }
  return groups;
}

/** The Gateway and its ancestors are never owned, whatever a scope file says. */
function protectedPids(table: Map<number, ProcessRow>): Set<number> {
  const protectedSet = new Set<number>([0, 1, process.pid]);
  for (let pid = process.ppid; pid > 1 && !protectedSet.has(pid); pid = table.get(pid)?.ppid ?? 1) protectedSet.add(pid);
  return protectedSet;
}

function ownedProcesses(table: Map<number, ProcessRow>, groups: Map<number, number>, holders: readonly number[]): Set<number> {
  const blocked = protectedPids(table);
  const owned = new Set<number>();
  for (const row of table.values()) {
    const recorded = groups.get(row.pgid);
    if (recorded !== undefined && row.startedAt >= recorded - START_TOLERANCE_SECONDS) owned.add(row.pid);
  }
  for (const pid of holders) if (table.has(pid)) owned.add(pid);
  const children = new Map<number, number[]>();
  for (const row of table.values()) children.set(row.ppid, [...(children.get(row.ppid) ?? []), row.pid]);
  const pending = [...owned];
  while (pending.length > 0) {
    for (const child of children.get(pending.pop()!) ?? []) if (!owned.has(child)) { owned.add(child); pending.push(child); }
  }
  for (const pid of blocked) owned.delete(pid);
  return owned;
}

export type TaskScopeProbe = { state: "read"; owned: Set<number>; table: Map<number, ProcessRow> } | { state: "unreadable" };

async function probe(scope: TaskCommandScope, table?: Map<number, ProcessRow>): Promise<TaskScopeProbe> {
  const [current, holders] = await Promise.all([table ? Promise.resolve(table) : readProcessTable(), anchorHolders(scope)]);
  if (!current || !holders) return { state: "unreadable" };
  return { state: "read", owned: ownedProcesses(current, await recordedGroups(scope), holders), table: current };
}

/** While the task runs: records owned group leaders not yet recorded, so a descendant that
 * left the shell's group and closed the anchor stays owned after it re-parents. Returns the
 * owned set for the host-load attribution. */
export async function adoptTaskCommandGroups(scope: TaskCommandScope, table?: Map<number, ProcessRow>): Promise<Set<number> | undefined> {
  const read = await probe(scope, table);
  if (read.state !== "read") return undefined;
  const groups = await recordedGroups(scope);
  for (const pid of read.owned) {
    const row = read.table.get(pid)!;
    if (row.pgid === pid && !groups.has(pid)) recordTaskCommandGroup(scope, pid, row.startedAt);
  }
  return read.owned;
}

export type TaskScopeReap =
  | { outcome: "reaped"; processes: number; survivors: number; tmpRemoved: true }
  | { outcome: "refused"; reason: "process-table-unreadable" | "survivors"; processes: number; survivors: number; tmpRemoved: false };

/**
 * Kills everything the scope owns and removes the scope, temp files included. Owned processes
 * are frozen before the kill and the ownership is read again, so one forking between the two
 * reads is still caught, as the foreground owner does. A scope whose processes cannot be read
 * or that still has survivors stays on disk for the next sweep: nothing is removed on a guess.
 */
export async function reapTaskCommandScope(scope: TaskCommandScope): Promise<TaskScopeReap> {
  const first = await probe(scope);
  if (first.state !== "read") return { outcome: "refused", reason: "process-table-unreadable", processes: 0, survivors: 0, tmpRemoved: false };
  const signal = (pids: Iterable<number>, name: NodeJS.Signals) => { for (const pid of pids) { try { process.kill(pid, name); } catch { /* exited */ } } };
  let owned = first.owned;
  if (owned.size > 0) {
    signal(owned, "SIGSTOP");
    const second = await probe(scope);
    if (second.state === "read") { owned = new Set([...owned, ...second.owned]); signal(second.owned, "SIGSTOP"); }
    signal(owned, "SIGKILL");
  }
  const running = () => [...owned].filter(pid => { try { process.kill(pid, 0); return true; } catch { return false; } });
  // A killed process remains a zombie until its parent (often launchd) reaps it; the zombie
  // runs nothing, so only the live process table settles survivors.
  for (const deadline = Date.now() + EXIT_WAIT_MS; running().length > 0 && Date.now() < deadline;) await new Promise(resolve => setTimeout(resolve, 50));
  const after = owned.size === 0 ? undefined : await readLiveTable();
  const survivors = after ? [...owned].filter(pid => after.has(pid)).length : 0;
  if (survivors > 0) return { outcome: "refused", reason: "survivors", processes: owned.size, survivors, tmpRemoved: false };
  await rm(scope.directory, { recursive: true, force: true, maxRetries: 2 });
  return { outcome: "reaped", processes: owned.size, survivors: 0, tmpRemoved: true };
}

/** Live (non-zombie) processes only. */
async function readLiveTable(): Promise<Set<number> | undefined> {
  const result = await run("ps", ["-axo", "pid=,stat="]);
  if (result.code !== 0) return undefined;
  const live = new Set<number>();
  for (const line of result.stdout.split("\n")) {
    const match = line.trim().match(/^(\d+)\s+(\S+)$/u);
    if (match && !match[2]!.startsWith("Z")) live.add(Number(match[1]));
  }
  return live;
}

/** Every scope on disk, with the task it was last bound to (undefined when unreadable). */
export async function listTaskCommandScopes(root = taskCommandRoot()): Promise<Array<{ sessionId: string; taskId: string | undefined; scope: TaskCommandScope }>> {
  const entries = await readdir(root, { withFileTypes: true }).catch(() => []);
  const scopes = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || !SESSION_ID_PATTERN.test(entry.name)) continue;
    const scope = scopeAt(join(root, entry.name));
    const taskId = (await readFile(join(scope.directory, "task"), "utf8").catch(() => undefined))?.trim();
    scopes.push({ sessionId: entry.name, taskId: taskId && TASK_ID_PATTERN.test(taskId) ? taskId : undefined, scope });
  }
  return scopes;
}

/** Re-reads the binding just before a sweep reaps, so a successor bound meanwhile is never reaped as its predecessor. */
export function taskCommandScopeBinding(scope: TaskCommandScope): string | undefined {
  try { return readFileSync(join(scope.directory, "task"), "utf8").trim(); } catch { return undefined; }
}

