import { ChildProcess, spawnSync } from "node:child_process";
import { appendFileSync } from "node:fs";

const enabled = Boolean(process.env.TRON_TEST_PROCESS_OWNER);
const children = [];
const nativeSpawn = ChildProcess.prototype.spawn;
const nativeExit = process.exit.bind(process);
let disposal;
const attemptedSignals = [];
const ownedPids = new Set();
const ownedGroups = new Set();

function processes() {
  const result = spawnSync("ps", ["-axo", "pid=,ppid=,pgid=,stat="], { encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
  if (result.status !== 0) {
    throw new Error(`fixture process owner could not inspect process trees: status ${result.status}, `
      + `signal ${result.signal}, ${result.error?.message ?? result.stderr.trim()}`);
  }
  return result.stdout.split("\n").flatMap(line => {
    const match = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)/u.exec(line);
    return match ? [{ pid: Number(match[1]), parent: Number(match[2]), group: Number(match[3]), state: match[4] }] : [];
  });
}

const live = row => !row.state.startsWith("Z");

function signal(pid, value, group = false) {
  try { process.kill(group ? -pid : pid, value); }
  catch (error) {
    if (error.code === "ESRCH") return;
    if (error.code === "EPERM") {
      const target = processes().filter(row => group ? row.group === pid : row.pid === pid);
      if (!target.some(live)) return;
    }
    throw error;
  }
}

export function disposeFixtureProcesses() {
  if (!enabled) return Promise.resolve();
  return disposal ??= (async () => {
    const table = processes();
    const owned = ownedPids;
    for (const child of children) if (!child.exited) owned.add(child.pid);
    for (let pass = 0; pass < table.length; pass++) {
      let changed = false;
      for (const row of table) if (owned.has(row.parent) && !owned.has(row.pid)) { owned.add(row.pid); changed = true; }
      if (!changed) break;
    }
    const groups = ownedGroups;
    for (const child of children) if (child.group === child.pid) groups.add(child.group);
    for (const row of table) if (owned.has(row.pid) && owned.has(row.group)) groups.add(row.group);
    const send = value => {
      attemptedSignals.push(value);
      const table = processes().filter(live);
      for (const group of groups) if (table.some(row => row.group === group)) signal(group, value, true);
      for (const row of table) if (owned.has(row.pid) && !groups.has(row.group)) signal(row.pid, value);
    };
    const remaining = () => processes().filter(row => live(row) && (owned.has(row.pid) || groups.has(row.group)));
    send("SIGTERM");
    const deadline = Date.now() + 5_000;
    const escalateAt = Date.now() + 1_000;
    let escalated = false;
    let escalationError;
    while (remaining().length || children.some(child => !child.exited)) {
      if (!escalated && Date.now() >= escalateAt) {
        escalated = true;
        try { send("SIGKILL"); }
        catch (error) {
          if (error.code !== "EPERM") throw error;
          escalationError = error;
        }
      }
      if (Date.now() >= deadline) throw escalationError ?? new Error(`fixture process owner failed to join PIDs: ${remaining().map(row => row.pid).join(",")}`);
      await new Promise(resolve => setTimeout(resolve, 20));
    }
  })().catch(error => {
    let pids = children.filter(child => !child.exited).map(child => child.pid);
    try { pids = processes().filter(row => live(row) && (ownedPids.has(row.pid) || ownedGroups.has(row.group))).map(row => row.pid); } catch {}
    appendFileSync(process.env.TRON_TEST_PROCESS_OWNER_FAILURE, `${JSON.stringify({ pids, attemptedSignals, error: error.message })}\n`);
    throw error;
  });
}

if (enabled) {
  const parentGroup = processes().find(row => row.pid === process.pid)?.group;
  ChildProcess.prototype.spawn = function(options) {
    if (disposal) throw new Error("fixture process owner is disposed; cannot spawn");
    const result = nativeSpawn.call(this, options);
    if (this.pid !== undefined) {
      const record = { handle: this, pid: this.pid, group: options.detached ? this.pid : parentGroup, exited: false };
      children.push(record);
      this.once("exit", () => { record.exited = true; });
      this.once("error", () => { record.exited = true; });
    }
    return result;
  };
  const exitAfterJoin = code => {
    disposeFixtureProcesses().then(() => nativeExit(code), error => {
      console.error(error);
      nativeExit(1);
    });
  };
  process.exit = code => { exitAfterJoin(code ?? process.exitCode ?? 0); };
  process.once("beforeExit", () => { exitAfterJoin(process.exitCode ?? 0); });
  for (const [name, code] of [["SIGTERM", 143], ["SIGINT", 130]]) process.on(name, () => { exitAfterJoin(code); });
}
