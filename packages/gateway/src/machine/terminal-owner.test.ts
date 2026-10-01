import { execFileSync, spawn as spawnProcess, type ChildProcess } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { createServer, type Socket } from "node:net";
import { join } from "node:path";
import { createRequire } from "node:module";
import { spawn } from "node-pty";
import { afterEach, describe, expect, it, vi } from "vitest";
import { nativeFixtureDirectory as root, nativeFixtureExecutable, nativeOwnerSource } from "../../test-fixtures/terminal-owner.js";
import { TerminalService } from "./terminal-service.js";
import { isUncertainOutcome } from "../errors.js";

vi.mock("node:url", async (importOriginal) => {
  const original = await importOriginal<typeof import("node:url")>();
  const fixture = await import("../../test-fixtures/terminal-owner.js");
  return { ...original, fileURLToPath: (url: URL | string) => String(url).endsWith("/native/terminal-owner")
    ? fixture.nativeFixtureExecutable : original.fileURLToPath(url) };
});

const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(predicate: () => boolean, timeout = 4000) {
  const deadline = Date.now() + timeout;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("fixture condition did not become true before deadline");
    await delay(20);
  }
}
const job = join(root, "job.py");
const shell = join(root, "shell");
writeFileSync(shell, "#!/bin/sh\nexec /bin/bash --noprofile --norc -i\n", { mode: 0o755 });
writeFileSync(job, `import json,os,signal,sys,time
signal.signal(signal.SIGHUP,signal.SIG_IGN)
signal.signal(signal.SIGTERM,signal.SIG_IGN)
name=sys.argv[1]
with open(name+'.ready','w') as f: json.dump(dict(pid=os.getpid(),sid=os.getsid(0),group=os.getpgrp()),f)
end=time.monotonic()+float(sys.argv[2])
while time.monotonic()<end:
 with open(name+'.beat','a') as f: f.write('x')
 time.sleep(.02)
`);
let serial = 0;
function tag(name: string) { return join(root, `${name}-${++serial}`); }
function command(name: string, seconds = 10) { return `/usr/bin/python3 ${job} ${name} ${seconds}`; }
function ready(name: string) { return existsSync(`${name}.ready`) && existsSync(`${name}.beat`); }
function identity(name: string): { pid: number; sid: number; group: number } { return JSON.parse(readFileSync(`${name}.ready`, "utf8")); }
function bytes(name: string) { return statSync(`${name}.beat`).size; }
function dead(pid: number) {
  try { return /^Z/u.test(execFileSync("/bin/ps", ["-p", String(pid), "-o", "stat="], { encoding: "utf8" }).trim()); }
  catch { return true; }
}
async function stopped(name: string) {
  await until(() => dead(identity(name).pid));
  const size = bytes(name);
  await delay(120);
  expect(bytes(name)).toBe(size);
}
const services: TerminalService[] = [];
const processes: ChildProcess[] = [];
const controls: Socket[] = [];
const directExits: Promise<unknown>[] = [];
function service() {
  vi.stubEnv("SHELL", shell);
  const value = new TerminalService(64_000, () => {});
  services.push(value);
  return value;
}
afterEach(async () => {
  for (const control of controls.splice(0)) control.destroy();
  for (const value of services.splice(0)) {
    await Promise.all(value.activeTerminalIds().map((id) => value.terminate(id).catch(() => {})));
    value.dispose();
  }
  for (const process of processes.splice(0)) {
    if (process.exitCode === null && process.signalCode === null) process.kill("SIGKILL");
  }
  await Promise.all(directExits.splice(0));
  vi.unstubAllEnvs();
});

async function direct(executable = nativeFixtureExecutable) {
  const directory = tag("control");
  mkdirSync(directory, { mode: 0o700 });
  const path = join(directory, "socket");
  const server = createServer();
  const connected = new Promise<Socket>((resolve) => server.once("connection", resolve));
  server.listen(path);
  const pty = spawn(executable, [path, "fixture-nonce", "/bin/bash", "--noprofile", "--norc", "-i"], {
    cwd: root, cols: 80, rows: 24, env: { PATH: "/usr/bin:/bin", HOME: root },
  });
  pty.onData(() => {});
  const exited = new Promise<{ exitCode: number }>((resolve) => pty.onExit(resolve));
  directExits.push(exited);
  const control = await connected;
  controls.push(control);
  let receipts = "";
  control.setEncoding("utf8");
  control.on("data", (data) => { receipts += data; });
  control.on("error", () => {});
  await until(() => receipts.includes("fixture-nonce\n"));
  server.close();
  // Match production: the rendezvous disappears before any user shell runs.
  const { rmSync } = await import("node:fs");
  rmSync(directory, { recursive: true, force: true });
  control.write("S");
  return { pty, control, exited, receipts: () => receipts, directory };
}

function start(value: TerminalService, terminalId: string, text: string) {
  value.write(terminalId, String(++serial), `${text}\r`);
}

describe("native terminal session owner", () => {
  it("kills real foreground/background resistant groups within one bound, including an uncooperative shell", async () => {
    const value = service();
    const terminal = value.open("owned", root);
    const background = tag("background"), foreground = tag("foreground");
    start(value, terminal.id, `trap '' HUP TERM; ${command(background)} & ${command(foreground)}`);
    await until(() => ready(background) && ready(foreground));
    expect(identity(background).sid).toBe(identity(foreground).sid);
    expect(identity(background).group).not.toBe(identity(foreground).group);
    const begun = Date.now();
    await Promise.all([value.terminate(terminal.id), value.terminate(terminal.id)]);
    expect(Date.now() - begun).toBeLessThan(3200);
    await stopped(background);
    await stopped(foreground);
    await until(() => dead(identity(background).sid));
    value.dispose();
    value.dispose();
  });

  it("continues real cleanup after duplicate disposal without inventing a Quit receipt", async () => {
    const value = service();
    const terminal = value.open("disposed", root);
    const background = tag("disposed");
    start(value, terminal.id, `${command(background)} &`);
    await until(() => ready(background));
    const quit = value.terminate(terminal.id).then(() => "terminated", (error: unknown) => error);
    value.dispose();
    value.dispose();
    expect(isUncertainOutcome(await quit)).toBe(true);
    await stopped(background);
    await until(() => dead(identity(background).sid));
  });

  it("retains session ownership after shell exits first and preserves its exit status", async () => {
    const value = service();
    const terminal = value.open("owned", root);
    const background = tag("shell-exit");
    start(value, terminal.id, `${command(background)} &`);
    await until(() => ready(background));
    start(value, terminal.id, "exit 7");
    await until(() => value.list("owned")[0]?.exitedAt !== undefined);
    expect(value.list("owned")[0]?.exitCode).toBe(7);
    await stopped(background);
    await until(() => dead(identity(background).sid));
  });

  it("reaps the exact nonzero shell status across repeated fast exits during cleanup", async () => {
    for (let iteration = 0; iteration < 24; iteration++) {
      const fixture = await direct();
      const armed = tag("exit-status");
      fixture.pty.write(`trap 'exit 17' TERM; printf ready > ${armed}; while :; do :; done\r`);
      await until(() => existsSync(armed));
      fixture.control.write("T");
      expect((await fixture.exited).exitCode).toBe(17);
      expect(fixture.receipts()).toContain("E17\n");
    }
  });

  it("preserves foreground Ctrl-C, background jobs, interactive stdio and resize", async () => {
    const value = service();
    const terminal = value.open("interactive", root);
    const background = tag("interactive-bg"), foreground = tag("interactive-fg"), dimensions = tag("dimensions");
    start(value, terminal.id, `${command(background)} & ${command(foreground)}`);
    await until(() => ready(background) && ready(foreground));
    value.write(terminal.id, "interrupt", "\x03");
    await stopped(foreground);
    const before = bytes(background);
    value.resize(terminal.id, 101, 41);
    start(value, terminal.id, `stty size > ${dimensions}`);
    await until(() => existsSync(dimensions) && readFileSync(dimensions, "utf8").trim() === "41 101");
    await until(() => bytes(background) > before);
    await value.terminate(terminal.id);
    await stopped(background);
  });

  it("does not touch another PTY or an updater-like non-PTY process", async () => {
    const value = service();
    const own = value.open("owned", root), other = value.open("other", root);
    const ownedJob = tag("owned"), otherJob = tag("other"), updater = tag("updater");
    const process = spawnProcess("/usr/bin/python3", [job, updater, "10"], { stdio: "ignore" });
    processes.push(process);
    start(value, own.id, command(ownedJob));
    start(value, other.id, command(otherJob));
    await until(() => ready(ownedJob) && ready(otherJob) && ready(updater));
    expect(identity(otherJob).sid).not.toBe(identity(ownedJob).sid);
    await value.terminate(own.id);
    await stopped(ownedJob);
    const a = bytes(otherJob), b = bytes(updater);
    await until(() => bytes(otherJob) > a && bytes(updater) > b);
    expect(process.exitCode).toBeNull();
    await value.terminate(other.id);
    await stopped(otherJob);
  });

  it("cleans independently on control EOF while the PTY master remains open", async () => {
    const fixture = await direct();
    const background = tag("control-eof");
    fixture.pty.write(`${command(background)} &\r`);
    await until(() => ready(background));
    fixture.control.destroy();
    await fixture.exited;
    await stopped(background);
    expect(existsSync(fixture.directory)).toBe(false);
  });

  it("cleans after the actual Gateway-like parent is forcibly lost", async () => {
    const parentScript = join(root, "parent.cjs");
    const background = tag("parent-loss");
    const ptyModule = createRequire(import.meta.url).resolve("node-pty");
    writeFileSync(parentScript, `const net=require('node:net'),fs=require('node:fs'),pty=require(${JSON.stringify(ptyModule)});
const [helper,base,job,name]=process.argv.slice(2);const path=base+'/socket';
const server=net.createServer(socket=>{let data='';socket.on('data',chunk=>{data+=chunk;if(data==='nonce\\n'){server.close();fs.rmSync(base,{recursive:true,force:true});socket.write('S');}});});
server.listen(path);
const terminal=pty.spawn(helper,[path,'nonce','/bin/bash','--noprofile','--norc','-i'],{cwd:'/tmp',cols:80,rows:24,env:{PATH:'/usr/bin:/bin',HOME:'/tmp'}});
terminal.onData(()=>{});terminal.write('/usr/bin/python3 '+job+' '+name+' 10 &\\r');
`);
    const directory = tag("parent-control");
    mkdirSync(directory, { mode: 0o700 });
    const parent = spawnProcess(process.execPath, [parentScript, nativeFixtureExecutable, directory, job, background], { stdio: "ignore" });
    processes.push(parent);
    await until(() => ready(background));
    const ownerPid = identity(background).sid;
    const exited = new Promise((resolve) => parent.once("exit", resolve));
    parent.kill("SIGKILL"); // Exact unreaped test child only; never a production PID.
    await exited;
    await stopped(background);
    await until(() => dead(ownerPid));
    expect(existsSync(directory)).toBe(false);
  });

  it("refuses stale audit tokens in the kernel and accepts only the exact fixture incarnation", () => {
    const source = join(root, "stale.c"), binary = join(root, "stale");
    writeFileSync(source, `#define main terminal_owner_main\n#include ${JSON.stringify(nativeOwnerSource)}\n#undef main
int main(void) {
 int ready[2]; if(pipe(ready))return 1;
 pid_t child=fork(); if(child==0){close(ready[0]);write(ready[1],"R",1);sleep(2);_exit(0);} if(child<0)return 1;
 close(ready[1]); char byte; read(ready[0],&byte,1); close(ready[0]);
 audit_token_t token; if(!audit_identity(child,&token)){waitpid(child,NULL,0);return 2;}
 audit_token_t stale=token; stale.val[7]++;
 int result=proc_signal_with_audittoken(&stale,SIGKILL); int error=errno;
 int status; bool alive=waitpid(child,&status,WNOHANG)==0;
 int exact=proc_signal_with_audittoken(&token,SIGKILL); waitpid(child,&status,0);
 printf("stale=%d errno=%d alive=%d exact=%d\\n",result,error,alive,exact);
 return result==ESRCH && alive && exact==0 ? 0:3;
}
`);
    execFileSync("xcrun", ["clang", "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=15.0", source, "-o", binary]);
    execFileSync(binary);
  });

  it("reports unknown at the total deadline on signal refusal and retires only after eventual quiescence", async () => {
    // Controlled ablation: no signal can succeed. This is NOT a production hook.
    // The same heartbeat oracle stays live, unlike the positive termination test.
    const source = join(root, "refused.c"), binary = join(root, "refused");
    writeFileSync(source, readFileSync(nativeOwnerSource, "utf8").replace(
      "(void)proc_signal_with_audittoken(&after, sig)", "(void)sig",
    ).replace("(void)proc_signal_with_audittoken(&owned->identity, sig)", "(void)sig"));
    execFileSync("xcrun", ["clang", "-O2", "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=15.0", source, "-o", binary]);
    const fixture = await direct(binary);
    const survivor = tag("refused");
    fixture.pty.write(`exec ${command(survivor, 4)}\r`);
    await until(() => ready(survivor));
    const begun = Date.now();
    fixture.control.write("TTT"); // Duplicate requests must not reset the deadline.
    await until(() => fixture.receipts().includes("U\n"), 3200);
    expect(Date.now() - begun).toBeLessThan(3100);
    expect(fixture.receipts()).not.toMatch(/E\d+\n/u);
    expect(dead(identity(survivor).sid)).toBe(false);
    const size = bytes(survivor);
    await until(() => bytes(survivor) > size);
    await fixture.exited;
    await stopped(survivor);
    await until(() => dead(identity(survivor).sid));
    expect(existsSync(fixture.directory)).toBe(false);
    expect(fixture.receipts()).not.toMatch(/E\d+\n/u);
  });

  it("fails clearly rather than falling back when the native owner is not executable", () => {
    chmodSync(nativeFixtureExecutable, 0o644);
    try { expect(() => service().open("missing", root)).toThrow(/Native terminal owner is missing/u); }
    finally { chmodSync(nativeFixtureExecutable, 0o755); }
  });
});
