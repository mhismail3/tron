import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const preload = new URL("../test-support/fixture-process-owner.mjs", import.meta.url).pathname;
async function diagnostics(path, stderr) {
  let record = "";
  try { record = await readFile(path, "utf8"); } catch (error) { if (error.code !== "ENOENT") throw error; }
  return `host stderr: ${stderr}\nprocess-owner failure: ${record || "none"}`;
}
const exists = pid => { try { process.kill(pid, 0); return true; } catch (error) { if (error.code === "ESRCH") return false; throw error; } };
async function waitFor(check) {
  const deadline = Date.now() + 8_000;
  while (!await check()) {
    if (Date.now() >= deadline) throw new Error("fixture handshake timed out");
    await new Promise(resolve => setTimeout(resolve, 20));
  }
}

for (const exit of ["normal", "failure", "signal"]) test(`joins a detached grandchild writer before root removal on ${exit}`, { timeout: 15_000 }, async () => {
  const fixture = await mkdtemp(join(tmpdir(), "tron-fixture-process-owner-"));
  const root = join(fixture, "writer-root");
  await mkdir(root);
  const failureFile = join(fixture, "process-owner-failure.jsonl");
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
    }, 10);`], { env: { ...process.env, TRON_TEST_PROCESS_OWNER: root, TRON_TEST_PROCESS_OWNER_FAILURE: failureFile, NODE_OPTIONS: `--import=${preload}` }, stdio: ["ignore", "ignore", "pipe"] });
  let stderr = "";
  host.stderr.on("data", chunk => { stderr += chunk; });
  const closed = once(host, "close");
  let writerPid;
  try {
    await waitFor(async () => { try { writerPid = Number(await readFile(pidFile, "utf8")); return writerPid > 0; } catch (error) { if (error.code === "ENOENT") return false; throw error; } });
    const [code] = await closed;
    assert.equal(exists(writerPid), false, "detached writer is joined before removing its root");
    assert.equal(code, exit === "normal" ? 0 : exit === "failure" ? 7 : 143, await diagnostics(failureFile, stderr));
  } finally {
    if (exists(host.pid)) host.kill("SIGKILL");
    await closed;
    const runnerPid = Number(await readFile(runnerFile, "utf8"));
    for (const pid of [runnerPid, writerPid].filter(Boolean)) {
      if (exists(pid)) { process.kill(-pid, "SIGKILL"); await waitFor(() => !exists(pid)); }
    }
    await rm(fixture, { recursive: true }); // exactly one removal, no rmdir retries
  }
});

for (const transition of ["already zombie", "zombie during signal", "reaped during signal", "live permission failure"]) {
  test(`joins only non-writing processes: ${transition}`, { timeout: 15_000 }, async () => {
    const fixture = await mkdtemp(join(tmpdir(), "tron-fixture-zombie-"));
    const root = join(fixture, "writer-root");
    await mkdir(root);
    const pidFile = join(root, "child.pid");
    const releaseFile = join(root, "release");
    const readyFile = join(root, "parent-ready");
    const signalFile = join(root, "signal-complete");
    const failureFile = join(fixture, "process-owner-failure.jsonl");
    const proofFile = join(fixture, "joined.json");
    // Python deliberately holds an unreaped, detached child. No host-wide load:
    // TERM lets the parent reap; the signal-race handshake holds the zombie
    // until the actual OS signal completes. The outer owner joins this parent
    // on every failure path.
    const python = `import os, signal, time, faulthandler
faulthandler.enable()
faulthandler.dump_traceback_later(7)
pid = os.fork()
if pid == 0:
 os.setsid()
 with open(${JSON.stringify(pidFile)}, 'w') as out: out.write(str(os.getpid()))
 deadline = time.monotonic() + 8
 while not os.path.exists(${JSON.stringify(releaseFile)}) and time.monotonic() < deadline: time.sleep(.01)
 os._exit(0)
def finish(signum, frame):
 deadline = time.monotonic() + 6
 while ${JSON.stringify(transition)} in ['zombie during signal', 'reaped during signal'] and not os.path.exists(${JSON.stringify(signalFile)}) and time.monotonic() < deadline: time.sleep(.01)
 try: os.kill(pid, signal.SIGKILL)
 except (ProcessLookupError, PermissionError): pass
 os.waitpid(pid, 0)
 os._exit(0)
signal.signal(signal.SIGTERM, finish)
with open(${JSON.stringify(readyFile)}, 'w') as out: out.write('ready')
deadline = time.monotonic() + 9
while time.monotonic() < deadline: time.sleep(.01)
finish(None, None)
`;
    const host = spawn(process.execPath, ["--import", preload, "--input-type=module", "-e", `
      import { spawn, spawnSync } from 'node:child_process';
      import { readFileSync, writeFileSync, existsSync } from 'node:fs';
      import assert from 'node:assert/strict';
      import { disposeFixtureProcesses } from ${JSON.stringify(new URL(`file://${preload}`).href)};
      const parent = spawn('python3', ['-X', 'faulthandler', '-c', ${JSON.stringify(python)}], {detached:true, stdio:['ignore', 'ignore', 'inherit']});
      const nativeKill = process.kill.bind(process);
      let pid;
      try {
      const state = pid => spawnSync('ps', ['-o', 'stat=', '-p', String(pid)], {encoding:'utf8', timeout:2000}).stdout.trim();
      const deadline = Date.now() + 6000;
      while (!existsSync(${JSON.stringify(pidFile)}) || !existsSync(${JSON.stringify(readyFile)})) {
        assert.ok(Date.now() < deadline, 'child handshake');
        await new Promise(resolve => setTimeout(resolve, 10));
      }
      pid = Number(readFileSync(${JSON.stringify(pidFile)}, 'utf8'));
      const makeZombie = () => {
        writeFileSync(${JSON.stringify(releaseFile)}, 'exit');
        while (!state(pid).startsWith('Z')) assert.ok(Date.now() < deadline, 'zombie handshake');
      };
      if (${JSON.stringify(transition)} === 'already zombie') makeZombie();
      process.kill = (target, value) => {
        if (target === -parent.pid && value === 'SIGTERM' && !['zombie during signal', 'reaped during signal'].includes(${JSON.stringify(transition)})) {
          // Delay only this fixture's parent until the synchronous send pass
          // ends, so the child cannot disappear before it is inspected.
          setImmediate(() => {
            if (parent.exitCode !== null) return;
            // The parent group can already be exiting: ESRCH (gone) or EPERM
            // (zombie-only group on macOS) both mean the delayed signal is moot.
            try { nativeKill(target, value); }
            catch (error) { if (error.code !== 'ESRCH' && error.code !== 'EPERM') throw error; }
          });
          return true;
        }
        if (target === -pid && value === 'SIGTERM') {
          if (['zombie during signal', 'reaped during signal'].includes(${JSON.stringify(transition)})) makeZombie();
          if (${JSON.stringify(transition)} === 'live permission failure') {
            const error = new Error('injected live-group permission failure'); error.code = 'EPERM'; throw error;
          }
        }
        try { return nativeKill(target, value); }
        finally {
          if (target === -pid && value === 'SIGTERM' && ['zombie during signal', 'reaped during signal'].includes(${JSON.stringify(transition)})) {
            writeFileSync(${JSON.stringify(signalFile)}, 'complete');
            if (${JSON.stringify(transition)} === 'reaped during signal') {
              // Preserve the actual EPERM, but let the OS/parent finish reaping
              // before the owner's post-signal inspection runs.
              while (state(pid)) assert.ok(Date.now() < deadline, 'reap handshake');
            }
          }
        }
      };
        if (${JSON.stringify(transition)} === 'live permission failure') {
          await assert.rejects(disposeFixtureProcesses(), /injected live-group permission failure/);
          const record = JSON.parse(readFileSync(${JSON.stringify(failureFile)}, 'utf8').trim());
          assert.ok(record.pids.includes(pid), 'live writer PID retained in diagnostic');
          assert.deepEqual(record.attemptedSignals, ['SIGTERM']);
        } else {
          await disposeFixtureProcesses();
          assert.equal(existsSync(${JSON.stringify(failureFile)}), false, 'no join failure');
        }
      } finally {
        // A rejected owner must not strand the live permission-failure fixture.
        process.kill = nativeKill;
        writeFileSync(${JSON.stringify(signalFile)}, 'complete');
        if (parent.exitCode === null) {
          // The parent may already have exited (its reap completes the
          // transition) before Node records exitCode; ESRCH then proves it.
          const exited = new Promise(resolve => parent.once('exit', resolve));
          try { nativeKill(parent.pid, 'SIGTERM'); }
          catch (error) { if (error.code !== 'ESRCH') throw error; }
          await exited;
        }
      }
      writeFileSync(${JSON.stringify(proofFile)}, JSON.stringify({pid, parent:parent.pid}));
      // beforeExit reuses the rejected disposal on the live-error path; the
      // proof record distinguishes expected exit 1 from an assertion failure.
    `], { env: { ...process.env, TRON_TEST_PROCESS_OWNER: root, TRON_TEST_PROCESS_OWNER_FAILURE: failureFile }, stdio: ["ignore", "ignore", "pipe"] });
    let stderr = "";
    host.stderr.on("data", chunk => { stderr += chunk; });
    const closed = once(host, "close");
    try {
      const [code] = await closed;
      assert.equal(code, transition === "live permission failure" ? 1 : 0, await diagnostics(failureFile, stderr));
      let proof;
      try { proof = JSON.parse(await readFile(proofFile, "utf8")); }
      catch { assert.fail(`host did not complete join assertions; ${await diagnostics(failureFile, stderr)}`); }
      assert.equal(exists(proof.pid), false, "child reaped by its Python parent");
      assert.equal(exists(proof.parent), false, "direct parent joined before root removal");
      if (transition === "live permission failure") {
        const record = JSON.parse((await readFile(failureFile, "utf8")).trim());
        assert.match(record.error, /injected live-group permission failure/);
      }
    } finally {
      if (exists(host.pid)) host.kill("SIGTERM");
      await closed;
      await rm(fixture, {recursive:true});
    }
  });
}
