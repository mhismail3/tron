import { randomUUID } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { SettingsManager } from "@earendil-works/pi-coding-agent";
import { DirectBashProcessOwner } from "./direct-bash-process-owner.js";
import { awaitsWithin, waitFor } from "../../test-support/wait-for.js";

const roots: string[] = [];
/** Markers carried by every process a timeout test spawns. Cleanup kills by
 * marker, independently of the code under test, so a failing implementation or
 * a partial fixture start cannot leak a busy loop past the test. */
const markers: string[] = [];
const testSessionId = process.env.PI_SESSION_ID ?? "test-session";
function markedPids(marker: string): number[] {
  const listing = spawnSync("ps", ["-axo", "pid=,command="], { encoding: "utf8" }).stdout ?? "";
  return listing.split("\n").flatMap((line) => {
    const match = /^\s*(\d+)\s+(.*)$/u.exec(line);
    return match && match[2]!.includes(marker) && Number(match[1]) !== process.pid ? [Number(match[1])] : [];
  });
}
afterEach(async () => {
  for (const marker of markers.splice(0)) {
    for (const pid of markedPids(marker)) { try { process.kill(pid, "SIGKILL"); } catch {} }
  }
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

function processExists(pid: number): boolean {
  try { process.kill(pid, 0); return true; }
  catch { return false; }
}

describe("DirectBashProcessOwner", () => {
  it.skipIf(process.platform === "win32")(
    "aborts the foreground shell and descendants that create another process group",
    async () => {
      const root = await mkdtemp(join(tmpdir(), "tron-direct-bash-owner-"));
      roots.push(root);
      const agentDir = join(root, "agent");
      const settings = SettingsManager.create(root, agentDir);
      const owner = new DirectBashProcessOwner(settings, testSessionId);
      const pidFile = join(root, "detached.pid");

      const unrelated = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], {
        detached: true,
        stdio: "ignore",
      });
      const unrelatedPid = unrelated.pid!;
      // Marked so afterEach kills the detached process even when an assertion fails.
      const marker = `tron-636-${randomUUID()}`;
      markers.push(marker);
      const childProgram = `/*${marker}*/ setInterval(() => {}, 1000)`;
      const pidTempFile = `${pidFile}.tmp`;
      const parentProgram = [
        `/*${marker}*/ const { spawn } = require('node:child_process');`,
        "const { writeFileSync, renameSync } = require('node:fs');",
        `const child = spawn(${JSON.stringify(process.execPath)}, ['-e', ${JSON.stringify(childProgram)}], { detached: true, stdio: 'ignore' });`,
        // Renamed into place, so the reader sees the whole pid or no file.
        `writeFileSync(${JSON.stringify(pidTempFile)}, String(child.pid)); renameSync(${JSON.stringify(pidTempFile)}, ${JSON.stringify(pidFile)});`,
        "setInterval(() => {}, 1000);",
      ].join(" ");
      const command = `${JSON.stringify(process.execPath)} -e ${JSON.stringify(parentProgram)}`;
      const controller = new AbortController();
      const execution = owner.toolDefinition(root).execute(
        "direct-bash",
        { command },
        controller.signal,
        undefined,
        undefined,
      );

      // An empty or missing file is not a process id: Number("") is 0, which would
      // otherwise be probed as the process group 0.
      const detachedPid = await waitFor(async () => {
        try {
          const pid = Number(await readFile(pidFile, "utf8"));
          return Number.isSafeInteger(pid) && pid > 0 ? pid : false;
        } catch { return false; }
      }, "the detached process id file");
      expect(processExists(detachedPid)).toBe(true);
      expect(owner.hasActiveProcesses).toBe(true);

      try {
        await owner.abortAll();
        await expect(execution).rejects.toThrow("Command aborted");
        await waitFor(async () => !processExists(detachedPid), "the detached process to exit");
        expect(owner.hasActiveProcesses).toBe(false);
        expect(processExists(unrelatedPid)).toBe(true);
      } finally {
        try { process.kill(-unrelatedPid, "SIGKILL"); }
        catch { try { process.kill(unrelatedPid, "SIGKILL"); } catch {} }
      }
    },
  );

  // #499 T1-T3: the tool's timeout is enforced. Observed: a call with timeout 900
  // ran for 57 minutes until the user aborted it.
  it.skipIf(process.platform === "win32")(
    "times out a command, kills its whole tree and keeps the output it wrote",
    async () => {
      const root = await mkdtemp(join(tmpdir(), "tron-direct-bash-timeout-"));
      roots.push(root);
      const owner = new DirectBashProcessOwner(SettingsManager.create(root, join(root, "agent")), testSessionId);
      const marker = `tron-499-${randomUUID()}`;
      markers.push(marker);
      // A busy loop in its own process group, and a grandchild that inherits and
      // holds the output pipe: neither may outlive the timeout.
      const busy = `/*${marker}*/ while (true) {}`;
      const hold = `/*${marker}*/ setInterval(() => {}, 1000)`;
      const parent = [
        `/*${marker}*/ const { spawn } = require('node:child_process');`,
        `spawn(${JSON.stringify(process.execPath)}, ['-e', ${JSON.stringify(busy)}], { detached: true, stdio: 'ignore' });`,
        `spawn(${JSON.stringify(process.execPath)}, ['-e', ${JSON.stringify(hold)}], { stdio: 'inherit' });`,
        "setInterval(() => {}, 1000);",
      ].join(" ");
      const command = `echo before-timeout; ${JSON.stringify(process.execPath)} -e ${JSON.stringify(parent)}`;
      const started = performance.now();
      const outcome = await owner.toolDefinition(root).execute("direct-bash", { command, timeout: 1 }, undefined, undefined, undefined)
        .then(() => "completed", (error: unknown) => error instanceof Error ? error.message : String(error));
      expect(outcome).toContain("before-timeout");
      expect(outcome).toMatch(/Command timed out after 1 seconds/u);
      // Not killed early: the command ran for its timeout.
      expect(performance.now() - started).toBeGreaterThanOrEqual(900);
      await waitFor(async () => markedPids(marker).length === 0, "every process of the tree to be killed");
      expect(owner.hasActiveProcesses).toBe(false);
    },
    20_000,
  );

  // #499 review: a descendant that keeps the inherited output pipe after the shell exits
  // must not hang the call. Pi's rule (pi#5303) releases the call once that pipe has been
  // silent for the post-exit grace. Output written after a longer silence is not read, and
  // no test asserts it: whether a write lands inside the grace window is a load-dependent
  // race (packages/gateway/README.md documents the limit).
  it.skipIf(process.platform === "win32")(
    "settles when a quiet descendant keeps the output pipe after the shell exits",
    async () => {
      const root = await mkdtemp(join(tmpdir(), "tron-direct-bash-timeout-"));
      roots.push(root);
      const owner = new DirectBashProcessOwner(SettingsManager.create(root, join(root, "agent")), testSessionId);
      const marker = `tron-499-${randomUUID()}`;
      markers.push(marker);
      // Detached, holding the inherited stdout/stderr, and silent. The launcher waits for
      // its ready message, so the pipe is provably held when the shell exits.
      const quiet = `/*${marker}*/ process.send('ready'); setInterval(() => {}, 1000)`;
      const launcher = `/*${marker}*/ const child = require('node:child_process').spawn(${JSON.stringify(process.execPath)}, ['-e', ${JSON.stringify(quiet)}], { detached: true, stdio: ['ignore', 'inherit', 'inherit', 'ipc'] }); child.once('message', () => { child.disconnect(); child.unref(); });`;
      const command = `${JSON.stringify(process.execPath)} -e ${JSON.stringify(launcher)}; echo started`;
      const result = await awaitsWithin(
        owner.toolDefinition(root).execute("quiet-descendant", { command }, undefined, undefined, undefined),
        "the call to settle while a quiet descendant holds its output pipe",
      );
      const text = result.content.flatMap(part => part.type === "text" ? [part.text] : []).join("");
      expect(text).toContain("started");
      expect(owner.hasActiveProcesses).toBe(false);
    },
    20_000,
  );

  // #499 review: timeout aborts a running command, while Stop settles an escaped writer
  // only after its shell has exited and the writer still holds the inherited pipe open.
  it.skipIf(process.platform === "win32")(
    "times out a running command and stops an escaped writer after the shell exits",
    async () => {
      const root = await mkdtemp(join(tmpdir(), "tron-direct-bash-timeout-"));
      roots.push(root);
      const owner = new DirectBashProcessOwner(SettingsManager.create(root, join(root, "agent")), testSessionId);
      const tool = owner.toolDefinition(root);
      const marker = `tron-499-${randomUUID()}`;
      markers.push(marker);
      const failure = (promise: Promise<unknown>) =>
        promise.then(() => "completed", (error: unknown) => error instanceof Error ? error.message : String(error));
      const fixture = (name: string) => {
        const readyFile = join(root, `${name}-writer-ready`);
        const shellPidFile = join(root, `${name}-shell.pid`);
        const shellExitFile = join(root, `${name}-shell-exited`);
        // The same 150 ms delayed first write crosses the owner's 100 ms idle grace.
        // Keep the launcher (and therefore its shell) alive until that write is flushed.
        const writer = `/*${marker}*/ const fs = require('node:fs'); setTimeout(() => { process.stdout.write('tick\\n', () => { fs.writeFileSync(${JSON.stringify(readyFile)}, 'ready'); process.send('ready'); }); setInterval(() => process.stdout.write('tick\\n'), 20); }, 150)`;
        const launcher = `/*${marker}*/ const fs = require('node:fs'); const { spawn } = require('node:child_process'); const child = spawn(${JSON.stringify(process.execPath)}, ['-e', ${JSON.stringify(writer)}], { detached: true, stdio: ['ignore', 'inherit', 'inherit', 'ipc'] }); child.on('message', () => { fs.writeFileSync(${JSON.stringify(readyFile)}, 'ready'); child.disconnect(); child.unref(); child.channel?.unref(); process.stdout.write('started\\n'); }); child.once('error', () => process.exit(1)); child.unref();`;
        const command = `printf '%s' "$$" > ${JSON.stringify(shellPidFile)}; ${JSON.stringify(process.execPath)} -e ${JSON.stringify(launcher)}; printf '%s' exited > ${JSON.stringify(shellExitFile)}`;
        return { command, readyFile, shellPidFile, shellExitFile };
      };
      const waitForFixture = async (setup: ReturnType<typeof fixture>, label: string) => {
        await waitFor(async () => {
          try { return (await readFile(setup.readyFile, "utf8")) === "ready"; }
          catch { return false; }
        }, `${label} writer to flush output`);
        await waitFor(async () => {
          try { return (await readFile(setup.shellExitFile, "utf8")) === "exited"; }
          catch { return false; }
        }, `${label} shell to finish its command`);
        await waitFor(async () => {
          try {
            const pid = Number(await readFile(setup.shellPidFile, "utf8"));
            return Number.isSafeInteger(pid) && pid > 0 && !processExists(pid);
          } catch { return false; }
        }, `${label} shell to exit`);
      };

      const timeoutWriter = `/*${marker}*/ setInterval(() => process.stdout.write('tick\\n'), 20)`;
      const timedOut = await failure(tool.execute(
        "direct-timeout",
        { command: `${JSON.stringify(process.execPath)} -e ${JSON.stringify(timeoutWriter)}`, timeout: 1 },
        undefined,
        undefined,
        undefined,
      ));
      expect(timedOut).toContain("tick");
      expect(timedOut).toMatch(/Command timed out after 1 seconds/u);
      expect(owner.hasActiveProcesses).toBe(false);

      const stopFixture = fixture("stop");
      const stop = new AbortController();
      const stoppedExecution = failure(tool.execute("escaped-stop", { command: stopFixture.command }, stop.signal, undefined, undefined));
      await waitForFixture(stopFixture, "escaped stop");
      stop.abort();
      expect(await stoppedExecution).toMatch(/Command aborted/u);
      expect(owner.hasActiveProcesses).toBe(false);
    },
    20_000,
  );

  // #499 T4-T6.
  it.skipIf(process.platform === "win32")(
    "leaves commands that finish in time alone, applies no default, and refuses an invalid timeout",
    async () => {
      const root = await mkdtemp(join(tmpdir(), "tron-direct-bash-timeout-"));
      roots.push(root);
      const owner = new DirectBashProcessOwner(SettingsManager.create(root, join(root, "agent")), testSessionId);
      const tool = owner.toolDefinition(root);
      const text = (result: { content: Array<{ type: string; text?: string }> }) =>
        result.content.flatMap(part => part.type === "text" && part.text ? [part.text] : []).join("");
      expect(text(await tool.execute("in-time", { command: "echo done", timeout: 5 }, undefined, undefined, undefined))).toContain("done");
      const started = performance.now();
      expect(text(await tool.execute("no-timeout", { command: "sleep 2; echo late" }, undefined, undefined, undefined))).toContain("late");
      expect(performance.now() - started).toBeGreaterThanOrEqual(1_900);
      await expect(tool.execute("invalid", { command: "echo never", timeout: 0 }, undefined, undefined, undefined))
        .rejects.toThrow(/Invalid timeout/u);
      // Validated before the abort check, as Pi orders them.
      const aborted = new AbortController();
      aborted.abort();
      await expect(tool.execute("invalid-aborted", { command: "echo never", timeout: 0 }, aborted.signal, undefined, undefined))
        .rejects.toThrow(/Invalid timeout/u);
    },
    20_000,
  );

  it("does not pass Gateway-private paths or supervision identity to shell commands, but preserves the work session id", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-direct-bash-env-"));
    roots.push(root);
    const owner = new DirectBashProcessOwner(SettingsManager.create(root, join(root, "agent")), "opaque-session-561");
    const names = ["PI_SUBAGENTS_TEMP_ROOT", "PI_CODING_AGENT_DIR", "PI_SESSION_FILE", "PI_SESSION_ID", "PI_SUBAGENT_PARENT_SESSION", "TRON_GATEWAY_SUPERVISED", "TRON_GATEWAY_PAYLOAD_ROOT", "TRON_DATA_DIR", "TRON_HOME_NAME"] as const;
    const previous = new Map(names.map(name => [name, process.env[name]]));
    process.env.PI_SUBAGENTS_TEMP_ROOT = join(root, "tron", "internal", "subagents");
    process.env.PI_CODING_AGENT_DIR = join(root, "tron", "agent");
    process.env.PI_SESSION_FILE = join(root, "tron", "sessions", "session.jsonl");
    process.env.PI_SESSION_ID = "opaque-session-561";
    process.env.PI_SUBAGENT_PARENT_SESSION = "supervision-parent";
    process.env.TRON_GATEWAY_SUPERVISED = "1";
    process.env.TRON_GATEWAY_PAYLOAD_ROOT = join(root, "tron", "payload");
    process.env.TRON_DATA_DIR = join(root, "overridden-live-home");
    process.env.TRON_HOME_NAME = "alternate-live-home";
    const previousPath = process.env.PATH;
    const agentBin = join(root, "overridden-live-home", "agent", "bin");
    await mkdir(agentBin, { recursive: true });
    await writeFile(join(agentBin, "tron-agent-tool"), "#!/bin/sh\nprintf agent-tool-available\n", { mode: 0o755 });
    process.env.PATH = `${agentBin}${delimiter}${previousPath ?? ""}`;
    try {
      const result = await owner.toolDefinition(root).execute(
        "environment", { command: "tron-agent-tool; env | sort" }, undefined, undefined, undefined,
      );
      const output = result.content.flatMap(part => part.type === "text" ? [part.text] : []).join("");
      expect(output).toContain("agent-tool-available");
      expect(output).toContain("PI_SESSION_ID=opaque-session-561");
      for (const name of names.filter(name => name !== "PI_SESSION_ID")) {
        expect(output).not.toContain(`${name}=`);
      }
      expect(output).toContain(agentBin);
      expect(output).not.toContain("alternate-live-home");
    } finally {
      if (previousPath === undefined) delete process.env.PATH;
      else process.env.PATH = previousPath;
      for (const [name, value] of previous) {
        if (value === undefined) delete process.env[name];
        else process.env[name] = value;
      }
    }
  });
});
