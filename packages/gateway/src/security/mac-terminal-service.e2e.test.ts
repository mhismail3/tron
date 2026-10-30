import { execFile, spawn, type ChildProcess } from "node:child_process";
import { randomBytes } from "node:crypto";
import { createServer } from "node:net";
import { mkdir, mkdtemp, readFile, realpath, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir, userInfo } from "node:os";
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
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-private-sshd-")));
  roots.push(root);
  const service = new MacTerminalService(root, { port: await freePort(), launchAgentDirectory: join(root, "agents") });
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
  return (await run("/usr/sbin/netstat", ["-anl", "-p", "tcp"])).split("\n").map(line => line.trim().split(/\s+/u))
    .filter(fields => fields[5] === "LISTEN" && fields[3]?.split(".").at(-1) === String(port))
    .map(fields => `${fields[0]} ${fields[3]}`);
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
    // Test-only known-bad control: actual native sshd, not canned socket output.
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
  expect(status.enrolled).toBe(false); // Enable has not published a phone key.
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
  // The companion Gateway/native-client case independently proves from=
  // denial after TCP/auth on a loopback control using this production store.
  // Binding a LAN source to this Mac’s utun destination fails in routing and
  // is deliberately NOT accepted as an authorization-denial oracle.
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
  process.kill(pid, "SIGTERM"); // Exactly the fixture-owned native process.
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
  await rename(service.hostKeyPath, `${service.hostKeyPath}.saved`);
  try {
    expect((await service.status()).serviceState).toBe("failed");
    await expect(service.setEnabled(true)).rejects.toThrow(/automatic rotation is forbidden/u);
    await expect(service.recover()).rejects.toThrow(/automatic rotation is forbidden/u);
  } finally { await rename(`${service.hostKeyPath}.saved`, service.hostKeyPath); }
  expect((await readFile(service.hostKeyPath)).equals(key)).toBe(true);
  await service.set("fixture-phone", null);
  expect(await service.read()).toEqual({});
  expect(await service.enabled()).toBe(false);
  await expect(phone.ssh("printf MUST_NOT_RUN")).rejects.toThrow();
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
