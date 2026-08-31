import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { SettingsManager } from "@earendil-works/pi-coding-agent";
import { DirectBashProcessOwner } from "./direct-bash-process-owner.js";

const roots: string[] = [];
afterEach(async () => {
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

async function waitUntil(predicate: () => Promise<boolean>, timeoutMs = 5_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  throw new Error("condition not reached");
}

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

      await waitUntil(async () => {
        try { return Number.isSafeInteger(Number(await readFile(pidFile, "utf8"))); }
        catch { return false; }
      });
      const detachedPid = Number(await readFile(pidFile, "utf8"));
      expect(processExists(detachedPid)).toBe(true);
      expect(owner.hasActiveProcesses).toBe(true);

      try {
        await owner.abortAll();
        await expect(execution).rejects.toThrow("Command aborted");
        await waitUntil(async () => !processExists(detachedPid));
        expect(owner.hasActiveProcesses).toBe(false);
        expect(processExists(unrelatedPid)).toBe(true);
      } finally {
        try { process.kill(-unrelatedPid, "SIGKILL"); }
        catch { try { process.kill(unrelatedPid, "SIGKILL"); } catch {} }
      }
    },
  );
});
