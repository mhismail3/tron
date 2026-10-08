import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const preload = new URL("../test-support/fixture-process-owner.mjs", import.meta.url).pathname;
const exists = pid => { try { process.kill(pid, 0); return true; } catch (error) { if (error.code === "ESRCH") return false; throw error; } };
async function waitFor(check) {
  const deadline = Date.now() + 8_000;
  while (!await check()) {
    if (Date.now() >= deadline) throw new Error("fixture handshake timed out");
    await new Promise(resolve => setTimeout(resolve, 20));
  }
}

for (const exit of ["normal", "failure", "signal"]) test(`joins a detached grandchild writer before root removal on ${exit}`, { timeout: 15_000 }, async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-fixture-process-owner-"));
  const pidFile = join(root, "writer.pid");
  const runnerFile = join(root, "runner.pid");
  const writer = `const fs = require('node:fs');
    // Refuse TERM to exercise escalation as well as joining.
    process.removeAllListeners('SIGTERM'); process.on('SIGTERM', () => {});
    fs.writeFileSync(${JSON.stringify(pidFile)}, String(process.pid));
    setInterval(() => { fs.mkdirSync(${JSON.stringify(join(root, "writes"))}, {recursive:true}); fs.writeFileSync(${JSON.stringify(join(root, "writes", "live"))}, String(Date.now())); }, 1);`;
  const runner = `require('node:child_process').spawn(process.execPath, ['-e', ${JSON.stringify(writer)}], {detached:true, stdio:'ignore'}).unref(); setInterval(() => {}, 1000);`;
  // Two detached boundaries: joining only the direct runner leaves a writer.
  const host = spawn(process.execPath, ["--import", preload, "-e", `
    const child = require('node:child_process').spawn(process.execPath, ['-e', ${JSON.stringify(runner)}], {detached:true,stdio:'ignore'}); child.unref();
    const fs = require('node:fs'); fs.writeFileSync(${JSON.stringify(runnerFile)}, String(child.pid));
    const timer = setInterval(() => {
      if (!fs.existsSync(${JSON.stringify(pidFile)})) return;
      clearInterval(timer);
      ${exit === "signal" ? "setInterval(() => {}, 1000); process.kill(process.pid, 'SIGTERM')" : `process.exit(${exit === "failure" ? 7 : 0})`};
    }, 10);`], { env: { ...process.env, TRON_TEST_PROCESS_OWNER: root, TRON_TEST_PROCESS_OWNER_FAILURE: join(root, "process-owner-failure.jsonl"), NODE_OPTIONS: `--import=${preload}` }, stdio: "ignore" });
  const closed = once(host, "close");
  let writerPid;
  try {
    await waitFor(async () => { try { writerPid = Number(await readFile(pidFile, "utf8")); return writerPid > 0; } catch (error) { if (error.code === "ENOENT") return false; throw error; } });
    const [code] = await closed;
    assert.equal(exists(writerPid), false, "detached writer is joined before removing its root");
    assert.equal(code, exit === "normal" ? 0 : exit === "failure" ? 7 : 143);
  } finally {
    if (exists(host.pid)) host.kill("SIGKILL");
    await closed;
    const runnerPid = Number(await readFile(runnerFile, "utf8"));
    for (const pid of [runnerPid, writerPid].filter(Boolean)) {
      if (exists(pid)) { process.kill(-pid, "SIGKILL"); await waitFor(() => !exists(pid)); }
    }
    await rm(root, { recursive: true }); // exactly one removal, no rmdir retries
  }
});
