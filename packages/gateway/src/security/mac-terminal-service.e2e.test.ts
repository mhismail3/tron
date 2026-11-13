import { execFile, execFileSync, spawn, type ChildProcess } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { createServer } from "node:net";
import { chmod, lstat, mkdir, mkdtemp, readFile, readdir, realpath, rename, rm, rmdir, writeFile } from "node:fs/promises";
import { userInfo } from "node:os";
import { join } from "node:path";
import { afterAll, expect, it } from "vitest";
import { MacTerminalService } from "./mac-terminal-service.js";

const roots: string[] = [];
const services: MacTerminalService[] = [];
const children: ChildProcess[] = [];
const sessions: string[] = [];
function run(tool: string, args: string[], input?: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = execFile(tool, args, { timeout: 20_000, maxBuffer: 1024 * 1024 }, (error, stdout, stderr) => {
      if (error) reject(new Error(`${tool}: ${stderr || error.message}`)); else resolve(stdout);
    });
    if (input !== undefined) child.stdin!.end(input);
  });
}
async function until(predicate: () => Promise<boolean>): Promise<void> {
  const deadline = Date.now() + 25_000;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error("Native SSH fixture did not reach its expected kernel state");
}
async function freePort(): Promise<number> {
  const server = createServer();
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as { port: number }).port;
  await new Promise<void>(resolve => server.close(() => resolve()));
  return port;
}
async function fixture() {
  const root = await realpath(await mkdtemp(join(execFileSync("/usr/bin/getconf", ["DARWIN_USER_TEMP_DIR"], { encoding: "utf8" }).trim(), "tron-private-sshd-")));
  roots.push(root);
  const service = new MacTerminalService({ root: join(root, "state/mac-terminal"), port: await freePort(), launchAgentDirectory: join(root, "agents") });
  services.push(service);
  return { root, service };
}
async function tcp(address: string, port: number): Promise<boolean> {
  return run("/usr/bin/nc", ["-z", "-G", "1", address, String(port)]).then(() => true, () => false);
}
async function lanAddress(): Promise<string> {
  const text = await run("/sbin/ifconfig", ["-a"]);
  let ethernet = false;
  for (const line of text.split("\n")) {
    if (/^\S/u.test(line)) ethernet = /^en\d+:/u.test(line);
    const ip = line.trim().split(/\s+/u);
    if (ethernet && ip[0] === "inet" && !ip[1]!.startsWith("169.254.")) return ip[1]!;
  }
  throw new Error("Exposure proof needs a real non-Tailnet LAN interface");
}
async function listeners(port: number): Promise<string[]> {
  const kernel = (await run("/usr/sbin/netstat", ["-anl", "-p", "tcp"])).split("\n").map(line => line.trim().split(/\s+/u))
    .filter(fields => fields[5] === "LISTEN" && fields[3]?.split(".").at(-1) === String(port))
    .map(fields => `${fields[0]} ${fields[3]}`);
  const files = await new Promise<string>((resolve, reject) => {
    execFile("/usr/sbin/lsof", ["-nP", `-iTCP:${port}`, "-sTCP:LISTEN", "-Ftn"], (error, stdout, stderr) => {
      if (error && !(error.code === 1 && !stdout.trim())) reject(new Error(`/usr/sbin/lsof: ${stderr || error.message}`));
      else resolve(stdout);
    });
  });
  const owned: string[] = [];
  let family = "";
  for (const line of files.split("\n")) {
    if (line.startsWith("p") || line.startsWith("f")) family = "";
    if (line.startsWith("t")) family = line === "tIPv4" ? "tcp4" : "tcp6";
    if (line.startsWith("n")) owned.push(`${family} ${line.slice(1, line.lastIndexOf(":")).replace(/^\[|\]$/gu, "")}.${line.slice(line.lastIndexOf(":") + 1)}`);
  }
  return [...new Set([...kernel, ...owned])];
}
async function client(root: string, service: MacTerminalService) {
  const path = join(root, "client");
  await run("/usr/bin/ssh-keygen", ["-q", "-t", "ecdsa", "-b", "256", "-N", "", "-f", path]);
  const status = await service.status("fixture-phone");
  const known = join(root, "known_hosts");
  await writeFile(known, `[${status.hosts[0]}]:${service.port} ${status.hostKeys[0]}\n`, { mode: 0o600 });
  const args = ["-F", "/dev/null", "-p", String(service.port), "-i", path, "-o", "IdentityAgent=none",
    "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", `UserKnownHostsFile=${known}`];
  const target = `${userInfo().username}@${status.hosts[0]}`;
  return { publicKey: (await readFile(`${path}.pub`, "utf8")).trim().split(/\s+/u).slice(0, 2).join(" "),
    ssh: (command: string, extra: string[] = []) => run("/usr/bin/ssh", [...args, ...extra, target, command], "") };
}
afterAll(async () => {
  for (const session of sessions) await run("/usr/bin/env", ["PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "tmux", "-L", "tron-mobile", "kill-session", "-t", session]).catch(() => {});
  for (const child of children) {
    if (child.exitCode === null && child.signalCode === null) { child.kill("SIGTERM"); await new Promise(resolve => child.once("exit", resolve)); }
  }
  for (const service of services) await service.setEnabled(false);
  for (const root of roots) await rm(root, { recursive: true, force: true });
});

it("accepts only the assigned Tailnet IPv4, never LAN, loopback, wildcard or IPv6", async () => {
  const { root, service } = await fixture();
  const initial = await service.status();
  expect(initial.serviceState).toBe("unconfigured");
  expect(initial.hostKeys).toEqual([]);
  expect(initial.enrolled).toBe(false);
  expect(await service.enabled()).toBe(false);
  const ip = initial.hosts[0]!;
  expect(ip).toMatch(/^100\./u);
  if (process.env.TRON_MAC_TERMINAL_EXPOSURE_CONTROL === "wildcard") {
    const key = join(root, "wildcard-host");
    await run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key]);
    const config = join(root, "wildcard.conf");
    await writeFile(config, `AddressFamily inet\nPort ${service.port}\nListenAddress 0.0.0.0\nHostKey ${key}\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nPidFile ${root}/wildcard.pid\n`);
    const child = spawn("/usr/sbin/sshd", ["-D", "-f", config], { stdio: "ignore" });
    children.push(child);
    await until(() => tcp(ip, service.port));
  } else {
    await service.setEnabled(true);
  }
  expect(await tcp(ip, service.port)).toBe(true);
  expect(await tcp(await lanAddress(), service.port)).toBe(false);
  expect(await tcp("127.0.0.1", service.port)).toBe(false);
  expect(await listeners(service.port)).toEqual([`tcp4 ${ip}.${service.port}`]);
  const status = await service.status("fixture-phone");
  expect(status.serviceState).toBe("running");
  expect(status.enrolled).toBe(false);
  expect(status.hostKeys).toHaveLength(1);
  expect(status.hostFingerprint).toMatch(/^SHA256:/u);
});

it("owns authorization and launchd recovery while preserving host identity and the tmux shell", async () => {
  const { root, service } = await fixture();
  await service.setEnabled(true);
  const phone = await client(root, service);
  for (let read = 0; read < 24; read += 1) expect((await service.status()).serviceState).toBe("running");
  await expect(phone.ssh("printf MUST_NOT_RUN")).rejects.toThrow(/Permission denied \(publickey\)/u);
  await service.set("fixture-phone", phone.publicKey);
  expect(await phone.ssh("test -t 0 && test -t 1 && printf PRIVATE_PTY_42 && tty", ["-tt"])).toContain("PRIVATE_PTY_42/dev/ttys");
  const key = await readFile(service.hostKeyPath);
  const host = (await service.status()).hostKeys;
  const name = `tron-private-${randomBytes(6).toString("hex")}`;
  sessions.push(name);
  const tmux = "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin; export PATH; tmux -L tron-mobile -f /dev/null";
  await phone.ssh(`${tmux} new-session -d -s ${name}`);
  const shell = (await phone.ssh(`${tmux} display-message -p -t ${name} '#{pane_pid}'`)).trim();
  expect(Number(shell)).toBeGreaterThan(0);
  await service.setEnabled(false);
  expect(await service.enabled()).toBe(false);
  expect((await service.status()).serviceState).toBe("stopped");
  expect(await tcp((await service.status()).hosts[0]!, service.port)).toBe(false);
  await service.setEnabled(true);
  expect((await phone.ssh(`${tmux} display-message -p -t ${name} '#{pane_pid}'`)).trim()).toBe(shell);
  const job = await run("/bin/launchctl", ["print", `gui/${process.getuid!()}/${service.label}`]);
  const pid = Number(job.match(/^\s*pid = (\d+)/mu)?.[1]);
  expect(pid).toBeGreaterThan(0);
  process.kill(pid, "SIGTERM");
  await until(async () => (await service.status()).serviceState === "running"
    && !(await run("/bin/launchctl", ["print", `gui/${process.getuid!()}/${service.label}`])).includes(`pid = ${pid}\n`));
  expect((await phone.ssh(`${tmux} display-message -p -t ${name} '#{pane_pid}'`)).trim()).toBe(shell);
  await service.setEnabled(false);
  const config = await readFile(service.configPath, "utf8");
  await writeFile(service.configPath, config.replace(/ListenAddress [^\n]+/u, "ListenAddress 100.127.255.254"), { mode: 0o600 });
  expect((await service.status()).serviceState).toBe("stale");
  await expect(service.setEnabled(true)).rejects.toThrow(/explicit recovery/u);
  await service.recover();
  expect((await readFile(service.hostKeyPath)).equals(key)).toBe(true);
  expect((await service.status()).hostKeys).toEqual(host);
  expect((await phone.ssh(`${tmux} display-message -p -t ${name} '#{pane_pid}'`)).trim()).toBe(shell);
  const enabledPlist = await readFile(service.plistPath);
  await rename(service.hostKeyPath, `${service.hostKeyPath}.saved`);
  try {
    await expect(service.restore()).rejects.toThrow(/automatic rotation is forbidden/u);
    expect(await service.enabled()).toBe(true);
    expect(await readFile(service.plistPath)).toEqual(enabledPlist);
    expect(await service.status()).toMatchObject({ serviceState: "failed", detail: expect.stringContaining("automatic rotation is forbidden") });
    await expect(lstat(service.hostKeyPath)).rejects.toThrow(/ENOENT/u);
    await expect(service.setEnabled(true)).rejects.toThrow(/automatic rotation is forbidden/u);
    await expect(service.recover()).rejects.toThrow(/automatic rotation is forbidden/u);
  } finally { await rename(`${service.hostKeyPath}.saved`, service.hostKeyPath); }
  expect((await readFile(service.hostKeyPath)).equals(key)).toBe(true);
  await service.set("fixture-phone", null);
  expect(await service.read()).toEqual({});
  expect(await service.enabled()).toBe(false);
  await expect(phone.ssh("printf MUST_NOT_RUN")).rejects.toThrow();
});

for (const enabled of [true, false]) it(`restores previously ${enabled ? "enabled" : "disabled"} SSH intent across migration and inverse without rotating keys`, async () => {
  const { root } = await fixture();
  const user = join(root, "user");
  const home = join(user, ".tron");
  const agents = join(user, "Library/LaunchAgents");
  await mkdir(join(home, "gateway"), { recursive: true, mode: 0o700 });
  await writeFile(join(home, "gateway/gateway.json"), "{}", { mode: 0o600 });
  const options = { port: await freePort(), launchAgentDirectory: agents };
  const old = new MacTerminalService({ root: join(home, "mac-terminal"), ...options });
  const next = new MacTerminalService({ root: join(home, "state/mac-terminal"), ...options });
  const migrate = async (direction: "--apply" | "--rollback", crash = false) => new Promise<string>((resolve, reject) => {
    const program = `import sys,os\nsys.path.insert(0,${JSON.stringify(join(process.cwd(), "../../tools/home-layout"))})\nimport home_layout,runtime_layout\noriginal=runtime_layout.terminal_layout.retire\ndef retire(*args):\n original(*args)\n os._exit(93)\n${crash ? "runtime_layout.terminal_layout.retire=retire" : ""}\nraise SystemExit(home_layout.main(sys.argv[1:]))`;
    execFile("/usr/bin/python3", ["-B", "-c", program, "migrate", "--home", home, direction], { cwd: process.cwd(), env: { ...process.env, HOME: user, PYTHONDONTWRITEBYTECODE: "1" }, timeout: 30_000, maxBuffer: 1024 * 1024 }, (error, stdout, stderr) => error ? reject(new Error(`exit=${error.code}\n${stdout}${stderr}`)) : resolve(stdout));
  });
  const absent = async (service: MacTerminalService) => {
    try { await run("/bin/launchctl", ["print", `gui/${process.getuid!()}/${service.label}`]); return false; }
    catch (error) { if (String(error).includes("Could not find service")) return true; throw error; }
  };
  const digest = async (path: string) => createHash("sha256").update(await readFile(path)).digest("hex");
  try {
    if (enabled) await old.setEnabled(true);
    else {
      await mkdir(old.root, { recursive: true, mode: 0o700 });
      await run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", old.hostKeyPath]);
      await chmod(`${old.hostKeyPath}.pub`, 0o600);
    }
    const key = await digest(old.hostKeyPath);
    const inode = (await lstat(old.hostKeyPath)).ino;
    const plist = enabled ? await digest(old.plistPath) : undefined;
    const config = enabled ? await digest(old.configPath) : undefined;
    if (enabled) {
      await expect(migrate("--apply", true)).rejects.toThrow(/exit=93/u);
      expect(await absent(old)).toBe(true);
      for (const path of [join(home, "agent/.tron-gateway-runtime.lock.lock"), join(user, ".tron-dev/agent/.tron-gateway-runtime.lock.lock"), `${old.root}.lock`, join(home, "gateway/mac-terminal.lock")]) await rmdir(path);
      await migrate("--rollback");
      await until(async () => (await old.status()).serviceState === "running");
      expect(await digest(old.hostKeyPath)).toBe(key);
      expect((await lstat(old.hostKeyPath)).ino).toBe(inode);
    }
    await migrate("--apply");
    expect(await absent(old)).toBe(true);
    if (enabled) {
      const directory = join(user, ".tron-maintenance/backups");
      const hashes: string[] = [];
      for (const name of await readdir(directory, { recursive: true })) {
        const path = join(directory, name);
        if ((await lstat(path)).isFile()) hashes.push(await digest(path));
      }
      expect(hashes).toContain(plist);
      expect(hashes).toContain(config);
    }
    await next.restore();
    expect(await next.enabled()).toBe(enabled);
    if (enabled) expect((await next.status()).serviceState).toBe("running");
    expect(await digest(next.hostKeyPath)).toBe(key);
    expect((await lstat(next.hostKeyPath)).ino).toBe(inode);
    await migrate("--rollback");
    expect(await old.enabled()).toBe(enabled);
    if (enabled) await until(async () => (await old.status()).serviceState === "running");
    expect(await digest(old.hostKeyPath)).toBe(key);
    expect((await lstat(old.hostKeyPath)).ino).toBe(inode);
  } finally {
    for (const service of [old, next]) {
      let job: string;
      try { job = await run("/bin/launchctl", ["print", `gui/${process.getuid!()}/${service.label}`]); }
      catch (error) { if (String(error).includes("Could not find service")) continue; throw error; }
      expect(job.includes(service.plistPath) && job.includes(service.configPath)).toBe(true);
      await run("/bin/launchctl", ["bootout", `gui/${process.getuid!()}/${service.label}`]);
    }
  }
});

it("refuses an occupied port without stopping its owner or selecting a fallback", async () => {
  const { service } = await fixture();
  const other = createServer(socket => socket.end("OTHER_OWNER\n"));
  await new Promise<void>(resolve => other.listen(service.port, "127.0.0.1", resolve));
  try {
    await expect(service.setEnabled(true)).rejects.toThrow(/port is occupied/u);
    expect(await service.enabled()).toBe(false);
    expect(await run("/usr/bin/nc", ["-G", "1", "127.0.0.1", String(service.port)], "")).toBe("OTHER_OWNER\n");
    expect((await listeners(service.port))).toEqual([`tcp4 127.0.0.1.${service.port}`]);
  } finally { await new Promise<void>(resolve => other.close(() => resolve())); }
});
