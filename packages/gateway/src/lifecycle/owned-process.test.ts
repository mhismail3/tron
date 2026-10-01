import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, statSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { nativeFixtureDirectory as root, nativeFixtureExecutable } from "../../test-fixtures/terminal-owner.js";
import { GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";
import { createProcessLeaseHost, PROCESS_OWNER_ENV } from "./process-lease-host.js";
import { spawnOwnedProcess } from "./owned-process.js";
import { startRestartWatchdog } from "./restart-watchdog.js";

const hosts: Awaited<ReturnType<typeof createProcessLeaseHost>>[] = [];
const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
let serial = 0;
function tag() { return join(root, `process-${++serial}`); }
async function until(predicate: () => boolean) {
  const deadline = Date.now() + 5000;
  while (!predicate()) { if (Date.now() > deadline) throw new Error("fixture timed out"); await delay(20); }
}
async function setup() {
  const registry = new GatewayWorkRegistry();
  const guardian = await startRestartWatchdog(nativeFixtureExecutable);
  const host = await createProcessLeaseHost(registry, guardian.leaseCapability, nativeFixtureExecutable);
  hosts.push(host);
  vi.stubEnv(PROCESS_OWNER_ENV, host.environment[PROCESS_OWNER_ENV]);
  return { host, registry };
}
afterEach(() => { for (const host of hosts.splice(0)) host.close(); vi.unstubAllEnvs(); });
const beat = `const fs=require('fs');process.on('SIGTERM',()=>{});fs.writeFileSync(process.argv[1]+'.pid',String(process.pid));setInterval(()=>fs.appendFileSync(process.argv[1],'x'),20);setTimeout(()=>process.exit(),10000);`;

describe("origin-bound native process leases", () => {
  it("preserves piped stdin/stdout/stderr, cwd/env and actual nonzero status", async () => {
    const { registry } = await setup();
    const owner = spawnOwnedProcess(process.execPath, ["-e", "process.stdin.on('data',b=>process.stdout.write(b));process.stdin.on('end',()=>{console.error(process.cwd()+process.env.FIXTURE);process.exitCode=17})"], { cwd: root, env: { FIXTURE: "value" }, stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "", stderr = "";
    owner.child.stdout!.on("data", (chunk) => { stdout += chunk; });
    owner.child.stderr!.on("data", (chunk) => { stderr += chunk; });
    owner.child.stdin!.end("input");
    await owner.ready;
    expect(await owner.cleanup).toBe("exited");
    expect(owner.child.exitCode).toBe(17);
    expect(stdout).toBe("input");
    expect(stderr).toBe(`${realpathSync(root)}value\n`);
    expect(registry.size).toBe(0);
  });

  it.each([false, true])("stops a resistant writer (separate session: %s) after its TERM-responsive leader exits; duplicate stop is harmless", async (detached) => {
    await setup();
    const file = tag();
    const program = `require('child_process').spawn(process.execPath,['-e',${JSON.stringify(beat)},${JSON.stringify(file)}],{stdio:'ignore',detached:${detached}});setInterval(()=>{},1000);`;
    const owner = spawnOwnedProcess(process.execPath, ["-e", program], { env: process.env, stdio: ["ignore", "ignore", "ignore"] });
    await owner.ready;
    await until(() => existsSync(file));
    owner.terminate(); owner.terminate();
    expect(await owner.cleanup).toBe("exited");
    const bytes = statSync(file).size;
    await delay(100);
    expect(statSync(file).size).toBe(bytes);
    const pid = Number(readFileSync(`${file}.pid`, "utf8"));
    let state = "";
    try { state = execFileSync("/bin/ps", ["-p", String(pid), "-o", "stat="], { encoding: "utf8" }).trim(); }
    catch (error) { expect((error as { status?: number }).status).toBe(1); }
    expect(state === "" || /^Z/u.test(state)).toBe(true);
  });

  it("rejects missing registration and freeze racing new launch before any user bytes execute", async () => {
    const { registry, host } = await setup();
    const file = tag();
    registry.beginDrain();
    const owner = spawnOwnedProcess(process.execPath, ["-e", `require('fs').writeFileSync(${JSON.stringify(file)},'executed')`], { env: process.env });
    await expect(owner.ready).rejects.toThrow("admission failed");
    expect(await owner.cleanup).toBe("unknown");
    expect(existsSync(file)).toBe(false);
    host.close();
    const second = spawnOwnedProcess(process.execPath, ["-e", `require('fs').writeFileSync(${JSON.stringify(file)},'executed')`], { env: process.env });
    await expect(second.ready).rejects.toThrow();
    expect(await second.cleanup).toBe("unknown");
    expect(existsSync(file)).toBe(false);
  });

  it("nested sessions outlive immediate launcher but not their origin lease", async () => {
    const { host, registry } = await setup();
    const file = tag();
    const cap = JSON.parse(process.env[PROCESS_OWNER_ENV]!);
    const childProgram = `const{spawn}=require('child_process');const nested=spawn(${JSON.stringify(nativeFixtureExecutable)},['--guardian',${JSON.stringify(cap.guardianSocket)},${JSON.stringify(cap.guardianNonce)},'${cap.guardianPid}','--process',${JSON.stringify(cap.socket)},${JSON.stringify(cap.nonce)},'${process.pid}',process.execPath,'-e',${JSON.stringify(beat)},${JSON.stringify(file)}],{detached:true,stdio:['ignore','ignore','ignore','pipe']});nested.stdio[3].write('P');nested.unref();setTimeout(()=>process.exit(0),300);`;
    const parent = spawnOwnedProcess(process.execPath, ["-e", childProgram], { env: process.env, stdio: ["ignore", "ignore", "ignore"] });
    await parent.ready;
    await until(() => existsSync(file));
    expect(await parent.cleanup).toBe("exited");
    expect(registry.size).toBe(1);
    const before = statSync(file).size;
    await delay(100);
    expect(statSync(file).size).toBeGreaterThan(before);
    registry.beginDrain();
    host.terminate();
    await registry.waitUntilSettled();
    const after = statSync(file).size;
    await delay(100);
    expect(statSync(file).size).toBe(after);
  });
});
