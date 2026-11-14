import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { chmod, mkdir, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { dispatch, disposeFixtures, fixture, reportCall } from "../../../../test-support/home-task-fixture.js";
import { bindTaskCommandScope, readProcessTable, reapTaskCommandScope, recordTaskCommandGroup, settleTaskCommandScope, taskCommandProcesses, taskCommandRoot } from "../../../kernel/run/task-command-scope.js";

function processTerminal(pid: number): boolean {
  const state = spawnSync("ps", ["-p", String(pid), "-o", "stat="], { encoding: "utf8", timeout: 2_000 }).stdout.trim();
  return state === "" || state.startsWith("Z");
}

const started: number[] = [];
afterEach(async () => {
  for (const pid of started.splice(0)) { try { process.kill(pid, "SIGKILL"); } catch { } }
  await disposeFixtures();
});

describe("Home task command scope", () => {
  it("settling a task kills the detached descendants its commands left and removes their temp files (#2209)", async () => {
    const f = await fixture();
    const backgroundPid = join(f.cwd, "background.pid");
    const escapedPid = join(f.cwd, "escaped.pid");
    const temporary = join(f.cwd, "temporary.path");
    const command = [
      `mktemp -d "$TMPDIR/probe.XXXXXX" > ${JSON.stringify(temporary)}`,
      `sleep 300 >/dev/null 2>&1 & echo $! > ${JSON.stringify(backgroundPid)}`,
      `perl -MPOSIX -e 'fork and exit; POSIX::setsid(); fork and exit; open(my $f, ">", $ARGV[0]) or die; print $f $$; close $f; open(STDIN, "<", "/dev/null"); open(STDOUT, ">", "/dev/null"); open(STDERR, ">", "/dev/null"); exec "sleep", "300"' ${JSON.stringify(escapedPid)}`,
      `while [ ! -s ${JSON.stringify(escapedPid)} ]; do sleep 0.05; done`,
    ].join("; ");
    f.faux.setResponses([
      fauxAssistantMessage([fauxToolCall("bash", { command }, { id: "leave-work" })], { stopReason: "toolUse" }),
      fauxAssistantMessage([reportCall()], { stopReason: "toolUse" }),
    ]);
    const run = await dispatch(f);
    const result = await run.completion;
    expect(result.terminalEvidence).toMatchObject({ reason: "explicit-report" });

    const pids = [Number(await readFile(backgroundPid, "utf8")), Number(await readFile(escapedPid, "utf8"))];
    started.push(...pids);
    const temporaryPath = (await readFile(temporary, "utf8")).trim();
    expect(pids.every(pid => Number.isSafeInteger(pid) && pid > 1)).toBe(true);
    expect(temporaryPath).not.toBe("");
    expect(pids.map(pid => processTerminal(pid))).toEqual([true, true]);
    expect(existsSync(temporaryPath)).toBe(false);
    expect(existsSync(join(taskCommandRoot(), run.sessionId))).toBe(false);
    expect(f.signals).toContainEqual(expect.objectContaining({ event: "home.task.command-reap", action: "settle", outcome: "reaped",
      counts: expect.objectContaining({ survivors: 0 }) }));
    const reap = f.signals.find(record => record.event === "home.task.command-reap") as { counts: { processes: number } };
    expect(reap.counts.processes).toBeGreaterThanOrEqual(2);
  }, 30_000);

  it("never reaps a process whose group ID only matches a stale record", async () => {
    await fixture();
    const unrelated = spawn("sleep", ["30"], { detached: true, stdio: "ignore" });
    started.push(unrelated.pid!);
    const scope = bindTaskCommandScope("stale-session", "stale-task");
    recordTaskCommandGroup(scope, unrelated.pid!, Date.now() - 60_000);
    expect(settleTaskCommandScope(scope, "stale-task")).toBe(true);
    expect(await reapTaskCommandScope(scope, "stale-task")).toEqual({ outcome: "reaped", processes: 0, survivors: 0 });
    expect(processTerminal(unrelated.pid!)).toBe(false);
    expect(existsSync(join(taskCommandRoot(), "stale-session"))).toBe(false);
  });

  it("gives a worker's commands a short TMPDIR that the reap removes (#2260)", async () => {
    await fixture();
    const sessionId = "01a1a5a6-4d9f-708a-85fa-e01383b0117b";
    const scope = bindTaskCommandScope(sessionId, "short-task");
    expect(scope.tmp.length - tmpdir().length).toBeLessThanOrEqual(20);
    expect(existsSync(scope.tmp)).toBe(true);
    expect(settleTaskCommandScope(scope, "short-task")).toBe(true);
    expect(await reapTaskCommandScope(scope, "short-task")).toEqual({ outcome: "reaped", processes: 0, survivors: 0 });
    expect(existsSync(scope.tmp)).toBe(false);
    expect(existsSync(join(taskCommandRoot(), sessionId))).toBe(false);
  });

  it("reaps read-only fixture directories without changing symlink targets outside its tmp (#2527)", async () => {
    const f = await fixture();
    const scope = bindTaskCommandScope("readonly-session", "readonly-task");
    const locked = join(scope.tmp, "invalid-fixture");
    const nested = join(locked, "nested");
    const outside = join(f.cwd, "outside");
    const sentinel = join(outside, "sentinel");
    await mkdir(nested, { recursive: true });
    await mkdir(outside);
    await writeFile(join(nested, "fixture"), "fixture");
    await writeFile(sentinel, "untouched", { mode: 0o400 });
    await symlink(outside, join(locked, "outside-directory"));
    await symlink(sentinel, join(locked, "outside-file"));
    await symlink(scope.tmp, join(locked, "cycle"));
    await symlink(join(f.cwd, "missing"), join(locked, "dangling"));
    await chmod(outside, 0o500);
    await chmod(nested, 0o400);
    await chmod(locked, 0o500);
    try {
      expect(settleTaskCommandScope(scope, "readonly-task")).toBe(true);
      expect(await reapTaskCommandScope(scope, "readonly-task")).toEqual({ outcome: "reaped", processes: 0, survivors: 0 });
      expect(existsSync(scope.tmp)).toBe(false);
      expect(existsSync(scope.directory)).toBe(false);
      expect((await stat(outside)).mode & 0o777).toBe(0o500);
      expect((await stat(sentinel)).mode & 0o777).toBe(0o400);
      expect(await readFile(sentinel, "utf8")).toBe("untouched");
    } finally {
      if (existsSync(locked)) await chmod(locked, 0o700);
      if (existsSync(nested)) await chmod(nested, 0o700);
      await chmod(outside, 0o700);
      await rm(scope.tmp, { recursive: true, force: true });
    }
  });

  it("keeps a group recorded after the process table it prunes against", async () => {
    await fixture();
    const scope = bindTaskCommandScope("fresh-session", "fresh-task");
    const table = (await readProcessTable())!;
    const shell = spawn("sleep", ["30"], { detached: true, stdio: "ignore" });
    started.push(shell.pid!);
    recordTaskCommandGroup(scope, shell.pid!);
    expect(table.has(shell.pid!)).toBe(false);
    await taskCommandProcesses(scope, table);
    expect(readFileSync(scope.groups, "utf8")).toContain(`${shell.pid} `);
    expect(settleTaskCommandScope(scope, "fresh-task")).toBe(true);
    expect(await reapTaskCommandScope(scope, "fresh-task")).toMatchObject({ outcome: "reaped", processes: 1 });
    expect(processTerminal(shell.pid!)).toBe(true);
  });
});
