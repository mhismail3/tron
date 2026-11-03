import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import { dispatch, disposeFixtures, fixture, reportCall } from "../../../test-support/home-task-fixture.js";
import { taskCommandRoot } from "../../kernel/run/task-command-scope.js";

/** Absent, or exited and awaiting launchd's reap (`Z`): either runs nothing. */
function processTerminal(pid: number): boolean {
  const state = spawnSync("ps", ["-p", String(pid), "-o", "stat="], { encoding: "utf8", timeout: 2_000 }).stdout.trim();
  return state === "" || state.startsWith("Z");
}

const started: number[] = [];
afterEach(async () => {
  // Whatever the outcome, the test never leaves its adversaries running on the shared Mac.
  for (const pid of started.splice(0)) { try { process.kill(pid, "SIGKILL"); } catch { /* exited */ } }
  await disposeFixtures();
});

describe("Home task command scope", () => {
  it("settling a task kills the detached descendants its commands left and removes their temp files (#2209)", async () => {
    const f = await fixture();
    const backgroundPid = join(f.cwd, "background.pid");
    const escapedPid = join(f.cwd, "escaped.pid");
    const temporary = join(f.cwd, "temporary.path");
    // One command that returns while leaving: a background child that re-parents to launchd
    // in the shell's group, a double-forked grandchild in its own session (`setsid`), and a
    // temp directory made the way repository scripts make them (macOS `mktemp` without a
    // template ignores TMPDIR).
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
    // The task's settlement reaped them before it published: no wait.
    expect(pids.map(pid => processTerminal(pid))).toEqual([true, true]);
    expect(existsSync(temporaryPath)).toBe(false);
    expect(existsSync(join(taskCommandRoot(), run.sessionId))).toBe(false);
    expect(f.signals).toContainEqual(expect.objectContaining({ event: "home.task.command-reap", action: "settle", outcome: "reaped",
      counts: expect.objectContaining({ survivors: 0 }) }));
    const reap = f.signals.find(record => record.event === "home.task.command-reap") as { counts: { processes: number } };
    expect(reap.counts.processes).toBeGreaterThanOrEqual(2);
  }, 30_000);
});
