import { execFile, spawn } from "node:child_process";
import { constants } from "node:fs";
import { chmod, mkdir, mkdtemp, open, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { afterAll, beforeAll, expect, it } from "vitest";
import { awaitsWithin } from "../../../test-support/wait-for.js";

const gateway = fileURLToPath(new URL("../../..", import.meta.url));
const run = promisify(execFile);

let staged: { root: string; app: string; preparation?: Promise<unknown> } | undefined;
// Copying/validating the real payload is preparation, not offline activation.
// Record ownership before the first fallible step so failed setup is cleaned too.
beforeAll(async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-subagents-staged-"));
  const app = join(root, "app");
  staged = { root, app };
  await mkdir(app);
  staged.preparation = run("bash", [join(gateway, "../mac-app/scripts/stage-gateway-app.sh"), gateway, app], { timeout: 45_000 });
  await staged.preparation;
  await symlink(join(gateway, "node_modules"), join(app, "node_modules"));
}, 60_000);
afterAll(async () => {
  if (!staged) return;
  // Even a runner hook timeout cannot authorize deleting a still-owned copy.
  // Setup reports its own failure; this owner joins before removing its tree.
  await staged.preparation?.catch(() => undefined);
  await rm(staged.root, { recursive: true, force: true });
});

it("activates a real staged Mac app offline without checkout pin or artifact access", async () => {
  const { root, app } = staged!;
  const reportPath = process.env.TRON_SUBAGENTS_PAYLOAD_REPORT ?? join(gateway, "test-results", "managed-subagents.payload.json");
  const report: Record<string, unknown> = { passed: false };
  try {
    // Dependency installation remains the separate npm-ci step. The prepared
    // app shares only that exact SDK tree, never pin/archive/source authority.
    const script = `import net from 'node:net';
      net.Socket.prototype.connect = function () { throw new Error('network denied'); };
      const { ManagedSubagents } = await import('./dist/kernel/delegation/managed-subagents.js');
      const { delegatedArtifactRoot, delegatedProviderEnvironment } = await import('./dist/kernel/delegation/delegated-provider.js');
      delegatedProviderEnvironment(delegatedArtifactRoot(${JSON.stringify(join(root, "home"))}));
      const { SettingsManager } = await import('@earendil-works/pi-coding-agent');
      const managed = ManagedSubagents.activateForStartup(${JSON.stringify(join(root, "home"))});
      console.log(JSON.stringify({ root: managed.verify(), entries: (await managed.loaderOptions(SettingsManager.inMemory())).extensionFactories.map(entry => entry.name) }));`;
    const output = await run(process.execPath, ["--input-type=module", "-e", script], {
      cwd: app, timeout: 15_000, env: { PATH: process.env.PATH!, HOME: root, TMPDIR: root, npm_config_offline: "true", npm_config_cache: join(root, "cache") },
    });
    const activated = JSON.parse(output.stdout);
    expect(activated.entries.length).toBeGreaterThan(0);
    const pin = JSON.parse(await readFile(join(app, "pi-subagents-pin.json"), "utf8"));
    const receipt = JSON.parse(await readFile(join(activated.root, "tron-install-receipt.json"), "utf8"));
    expect(receipt).toEqual({ version: pin.version, forkCommit: pin.fork.commit, sha512: pin.closure.sha512 });
    // The operator installer is a shipped entrypoint too, not a checkout script.
    await run(process.execPath, ["scripts/install-pi-subagents.mjs", join(root, "home")], { cwd: app, timeout: 15_000 });
    await run(process.execPath, ["scripts/check-pi-subagents.mjs"], { cwd: app, timeout: 15_000 });
    const trustedChecker = join(gateway, "scripts/check-pi-subagents.mjs");
    await run(process.execPath, [trustedChecker, "--root", app], { timeout: 15_000 });
    const previousArchive = join(app, pin.previous.closure.path);
    await writeFile(previousArchive, "damaged retained payload closure");
    await expect(run(process.execPath, [trustedChecker, "--root", app], { timeout: 15_000 }))
      .rejects.toMatchObject({ code: 1 });
    report.invalidRetainedClosureRefused = true;
    report.passed = true;
    report.receipt = receipt;
    report.entries = activated.entries.length;
  } finally {
    await mkdir(dirname(reportPath), { recursive: true });
    await writeFile(reportPath, JSON.stringify(report, null, 2) + "\n");
  }
}, 45_000);

it("joins an interrupted staging writer before the caller can remove its tree", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-staging-interrupt-"));
  const app = join(root, "app"), bin = join(root, "bin"), gate = join(root, "copy-gate");
  const reportPath = join(gateway, "test-results", "managed-subagents.staging-interruption.json");
  const witness: Record<string, unknown> = {};
  let gateWriter: Awaited<ReturnType<typeof open>> | undefined;
  let owned: { child: ReturnType<typeof spawn>; exited: Promise<unknown>; closed: Promise<void> } | undefined;
  try {
    await mkdir(bin);
    await run("mkfifo", [gate], { timeout: 15_000 });
    // Keep both FIFO ends open so release cannot race the writer's open or EOF.
    gateWriter = await open(gate, constants.O_RDWR | constants.O_NONBLOCK);
    // Gate the real first copy, not a substitute staging algorithm. On release
    // the same writer execs actual cp with the production script's arguments.
    const copy = join(bin, "cp");
    await writeFile(copy, '#!/bin/bash\nset -e\nexec 3< "$TRON_STAGE_COPY_GATE"\nprintf "writer:%s\\n" "$$"\nIFS= read -r _ <&3\nexec /bin/cp "$@"\n');
    await chmod(copy, 0o755);
    const child = spawn("bash", [join(gateway, "../mac-app/scripts/stage-gateway-app.sh"), gateway, app], {
      env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, TRON_STAGE_COPY_GATE: gate },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const closed = new Promise<void>(resolve => { child.once("close", () => resolve()); });
    const exited = new Promise<{ code: number | null; signal: string | null; error?: Error }>(resolve => {
      child.once("error", error => resolve({ code: null, signal: null, error }));
      child.once("exit", (code, signal) => resolve({ code, signal }));
    });
    const writerReady = new Promise<number>((resolve, reject) => {
      let output = "";
      child.stdout.setEncoding("utf8").on("data", chunk => {
        output += chunk;
        const match = /writer:(\d+)\n/u.exec(output);
        if (match) resolve(Number(match[1]));
      });
      child.once("error", reject);
      child.once("exit", (code, signal) => reject(new Error(`stager exited before copy handoff: ${code}/${signal}`)));
    });
    child.stderr.resume();
    owned = { child, exited, closed };
    const writer = await awaitsWithin(writerReady, "real staging copy entered its gate");
    child.kill("SIGTERM"); // Same signal as execFile's timeout, not a process-tree kill.
    witness.shellExit = await awaitsWithin(exited, "interrupted stager joined its writer");
    let alive = true;
    try { process.kill(writer, 0); } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
      alive = false;
    }
    witness.writerAliveAtShellExit = alive;
    expect(alive, "staging writer must be joined before shell exit").toBe(false);
    expect(witness.shellExit).toEqual({ code: 143, signal: null });
  } finally {
    if (owned && owned.child.exitCode === null && owned.child.signalCode === null) owned.child.kill("SIGTERM");
    // Also release a faulty stager that waits without stopping its writer.
    // This lets the failing old-script control finish its actual copy safely.
    if (gateWriter) {
      try { if (owned) await gateWriter.write("continue\n"); } finally { await gateWriter.close(); }
    }
    if (owned) {
      await awaitsWithin(owned.exited, "owned staging shell exit before fixture cleanup");
      await awaitsWithin(owned.closed, "all staging writer pipes closed before tree removal");
    }
    witness.copyTreePresentAtCleanup = await stat(join(app, "dist", "modules")).then(() => true, error => {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      return false;
    });
    await rm(root, { recursive: true, force: true });
    await mkdir(dirname(reportPath), { recursive: true });
    await writeFile(reportPath, JSON.stringify(witness, null, 2) + "\n");
  }
}, 45_000);
