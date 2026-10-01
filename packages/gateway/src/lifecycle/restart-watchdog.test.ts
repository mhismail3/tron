import { spawn, execFileSync, type ChildProcess } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, statSync } from "node:fs";
import { once } from "node:events";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { afterEach, describe, expect, it, vi } from "vitest";
import { spawnOwnedProcess } from "./owned-process.js";
import { PROCESS_OWNER_ENV } from "./process-lease-host.js";
import { nativeFixtureDirectory as root, nativeFixtureExecutable } from "../../test-fixtures/terminal-owner.js";
import { armRestartWatchdog, startRestartWatchdog } from "./restart-watchdog.js";

// Exercise the shipped helper client, not a second numeric-signal fixture.
const { armNativeRestart } = await import(pathToFileURL(join(process.cwd(), "../../scripts/gateway-payload-deploy.mjs")).href);
const processes: ChildProcess[] = [];
const updaterPids: number[] = [];
let serial = 0;
const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(predicate: () => boolean, timeout = 8000) {
  const deadline = Date.now() + timeout;
  while (!predicate()) { if (Date.now() > deadline) throw new Error("fixture timed out"); await delay(20); }
}
function dead(pid: number) {
  try { return /^Z/u.test(execFileSync("/bin/ps", ["-p", String(pid), "-o", "stat="], { encoding: "utf8" }).trim()); }
  catch { return true; }
}
async function origin(mode = "responsive") {
  const directory = join(root, `origin-${++serial}`);
  mkdirSync(directory);
  const child = spawn(process.execPath, ["test-fixtures/owned-origin.mjs", directory, nativeFixtureExecutable, mode], { stdio: ["ignore", "ignore", "pipe", "ipc"] });
  let stderr = "";
  child.stderr!.on("data", (chunk) => { stderr += chunk; });
  processes.push(child);
  await until(() => { if (child.exitCode !== null) throw new Error(stderr); return existsSync(join(directory, "ready")); });
  if (mode === "sync") await until(() => existsSync(join(directory, "hook.pid")));
  const updater = Number(readFileSync(join(directory, "updater-owner.pid"), "utf8"));
  updaterPids.push(updater);
  const environment = JSON.parse(readFileSync(join(directory, "capability.json"), "utf8"));
  return { child, directory, capability: JSON.parse(environment.TRON_RESTART_OWNER), environment };
}
afterEach(async () => {
  vi.unstubAllEnvs();
  for (const child of processes.splice(0)) if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
  for (const pid of updaterPids.splice(0)) { try { process.kill(pid, "SIGKILL"); } catch {} }
});
async function assertStopped(directory: string) {
  for (const name of ["writer", "bash", ...(existsSync(join(directory, "hook.pid")) ? ["hook"] : [])]) {
    const pid = Number(readFileSync(join(directory, `${name}.pid`), "utf8"));
    await until(() => dead(pid));
    const size = statSync(join(directory, name)).size;
    await delay(120);
    expect(statSync(join(directory, name)).size).toBe(size);
  }
  const bytes = statSync(join(directory, "updater")).size;
  await delay(100);
  expect(statSync(join(directory, "updater")).size).toBeGreaterThan(bytes);
}

describe("native restart guardian", () => {
  it("acknowledges once before blocked receipt/controller loops and stops separate bash/writer sessions", async () => {
    const value = await origin();
    const exit = once(value.child, "exit");
    const started = Date.now();
    value.child.send("restart");
    await until(() => existsSync(join(value.directory, "accepted")));
    const accepted = Number(readFileSync(join(value.directory, "accepted"), "utf8"));
    expect(await armRestartWatchdog(value.capability, Date.now() + 15_000)).toBe(accepted);
    await assertStopped(value.directory);
    expect(value.child.exitCode).toBeNull();
    expect(value.child.signalCode).toBeNull();
    await exit;
    expect(Date.now() - started).toBeLessThan(7500);
    // Replacement readiness is a supervisor fixture, not a relaunch by guardian.
    const replacement = spawn(process.execPath, ["-e", "console.log('ready')"], { stdio: ["ignore", "pipe", "ignore"] });
    processes.push(replacement);
    expect((await once(replacement.stdout!, "data"))[0].toString()).toContain("ready");
  }, 12_000);

  it.each(["blocked", "sync"])("updater arms independent authority while origin is blocked by %s before any restart RPC", async (mode) => {
    const value = await origin(mode);
    const exit = once(value.child, "exit");
    const started = Date.now();
    const accepted = await armNativeRestart(value.capability, { pid: value.child.pid }, Date.now() + 7000);
    expect(accepted).toBeGreaterThan(started);
    await assertStopped(value.directory);
    expect(value.child.exitCode).toBeNull();
    expect(value.child.signalCode).toBeNull();
    await exit;
    expect(Date.now() - started).toBeLessThan(7500);
  }, 12_000);

  it("separates child lease authority from restart and freezes native admission before responsive JS can grant a late launch", async () => {
    const value = await origin();
    const cap = JSON.parse(value.environment[PROCESS_OWNER_ENV]);
    await expect(armRestartWatchdog({ socket: cap.guardianSocket, nonce: cap.guardianNonce, originPid: value.child.pid! }, Date.now() + 7000)).rejects.toThrow();
    const before = statSync(join(value.directory, "writer")).size;
    await delay(100);
    expect(statSync(join(value.directory, "writer")).size).toBeGreaterThan(before);
    await armRestartWatchdog(value.capability, Date.now() + 7000);
    vi.stubEnv(PROCESS_OWNER_ENV, value.environment[PROCESS_OWNER_ENV]);
    const marker = join(value.directory, "late-user-code");
    const late = spawnOwnedProcess(process.execPath, ["-e", `require('fs').writeFileSync(${JSON.stringify(marker)},'executed')`], { stdio: "ignore" });
    await expect(late.ready).rejects.toThrow();
    await late.cleanup;
    expect(existsSync(marker)).toBe(false);
    await assertStopped(value.directory);
  }, 12_000);

  it("rejects missing executable, wrong origin and failed native acknowledgement without callbacks", async () => {
    await expect(startRestartWatchdog(join(root, "missing"))).rejects.toThrow();
    await expect(armNativeRestart({ socket: "unused", nonce: "unused", originPid: 10 }, { pid: 11 })).rejects.toThrow("does not belong");
    await expect(armRestartWatchdog({ socket: join(root, "missing-socket"), nonce: "x", originPid: process.pid }, Date.now() + 5000)).rejects.toThrow();
  });
});
