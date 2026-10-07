import { randomUUID } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { SettingsManager } from "@earendil-works/pi-coding-agent";
import { DirectBashProcessOwner } from "./direct-bash-process-owner.js";
import { waitFor } from "../../test-support/wait-for.js";

const roots: string[] = [];
/** Markers carried by every process a timeout test spawns. Cleanup kills by
 * marker, independently of the code under test, so a failing implementation or
 * a partial fixture start cannot leak a busy loop past the test. */
const markers: string[] = [];
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
      const owner = new DirectBashProcessOwner(settings);
      const pidFile = join(root, "detached.pid");
      await writeFile(join(root, "placeholder"), "ready");

      const unrelated = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], {
        detached: true,
        stdio: "ignore",
      });
      const unrelatedPid = unrelated.pid!;
      const childProgram = "setInterval(() => {}, 1000)";
      const parentProgram = [
        "const { spawn } = require('node:child_process');",
        "const { writeFileSync } = require('node:fs');",
        `const child = spawn(${JSON.stringify(process.execPath)}, ['-e', ${JSON.stringify(childProgram)}], { detached: true, stdio: 'ignore' });`,
        `writeFileSync(${JSON.stringify(pidFile)}, String(child.pid));`,
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

      await waitFor(async () => {
        try { return Number.isSafeInteger(Number(await readFile(pidFile, "utf8"))); }
        catch { return false; }
      }, "the async process id file");
      const detachedPid = Number(await readFile(pidFile, "utf8"));
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
      const owner = new DirectBashProcessOwner(SettingsManager.create(root, join(root, "agent")));
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

  // #499 review: a shell that exits while a descendant keeps writing to the
  // inherited pipe must still settle, with or without a timeout.
  it.skipIf(process.platform === "win32")(
    "settles when the shell exits while a detached descendant keeps writing to its output",
    async () => {
      const root = await mkdtemp(join(tmpdir(), "tron-direct-bash-timeout-"));
      roots.push(root);
      const owner = new DirectBashProcessOwner(SettingsManager.create(root, join(root, "agent")));
      const tool = owner.toolDefinition(root);
      const marker = `tron-499-${randomUUID()}`;
      markers.push(marker);
      const writer = `/*${marker}*/ setInterval(() => process.stdout.write('tick\\n'), 20)`;
      const launcher = `/*${marker}*/ require('node:child_process').spawn(${JSON.stringify(process.execPath)}, ['-e', ${JSON.stringify(writer)}], { detached: true, stdio: ['ignore', 'inherit', 'inherit'] }).unref();`;
      const command = `${JSON.stringify(process.execPath)} -e ${JSON.stringify(launcher)}; echo started`;
      for (const params of [{ command }, { command, timeout: 30 }]) {
        const result = await tool.execute("exited-shell", params, undefined, undefined, undefined);
        expect(result.content.flatMap(part => part.type === "text" ? [part.text] : []).join("")).toContain("started");
        expect(owner.hasActiveProcesses).toBe(false);
      }
    },
    20_000,
  );

  // #499 T4-T6.
  it.skipIf(process.platform === "win32")(
    "leaves commands that finish in time alone, applies no default, and refuses an invalid timeout",
    async () => {
      const root = await mkdtemp(join(tmpdir(), "tron-direct-bash-timeout-"));
      roots.push(root);
      const owner = new DirectBashProcessOwner(SettingsManager.create(root, join(root, "agent")));
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
});
