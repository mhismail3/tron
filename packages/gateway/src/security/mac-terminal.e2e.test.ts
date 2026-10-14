import { execFile, execFileSync, spawn } from "node:child_process";
import { Socket, createServer } from "node:net";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir, userInfo } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { SettingsApprovals } from "../admin/settings-approvals.js";
import { SettingsChangePath, SettingsModel } from "../admin/settings-model.js";
import { SettingsChangeRecord } from "../admin/settings-record.js";
import { TrustService } from "../admin/trust-service.js";
import { DeviceStore } from "./device-store.js";
import { MAC_TERMINAL_SOURCES, MacTerminalHost, MacTerminalKeys, type MacTerminalStatus } from "./mac-terminal.js";
import { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";

/**
 * Mac Terminal end to end (README "Mac Terminal"): a real Gateway enrolls a
 * paired iPhone's key through the logged settings path into an
 * `authorized_keys` file that a real OpenSSH sshd reads, and the iPhone app's
 * own SSH client (`MacTerminalSSH`, built here as `mac-terminal-probe`) logs in
 * over this Mac's Tailscale address. It covers authentication success with a
 * PTY and resize, connecting with the Gateway gone, the host-key pin, the
 * `from=` tailnet restriction, revocation from the iPhone and by revoking the
 * paired device, and Remote Login off.
 *
 * It needs this Mac on its tailnet (Tailscale's own CLI answers with an IPv4
 * address) and a Swift 6.2 toolchain; it fails loudly otherwise. Run it with
 * `npm run test:mac-terminal`; the transcript is `test-results/mac-terminal.json`.
 */
const HERE = dirname(fileURLToPath(import.meta.url));
const ARTIFACT = join(HERE, "../../test-results/mac-terminal.json");
const PACKAGE = join(HERE, "../../../ios-app/MacTerminalSSH");
const transcript: Array<{ case: string; detail: unknown }> = [];
const registries: RuntimeRegistry[] = [];
let probe = "";
let root = "";
let tailnetIPv4 = "";

interface ProbeResult { outcome: "ok" | "error"; output?: string; exitStatus?: number | null; error?: string; message?: string }

function run(command: string, args: string[], input?: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = execFile(command, args, { timeout: 60_000, maxBuffer: 8 * 1024 * 1024 }, (error, stdout, stderr) => {
      if (error) reject(new Error(`${command} ${args.join(" ")} failed: ${stderr || error.message}`));
      else resolve(stdout);
    });
    if (input !== undefined) child.stdin!.end(input);
  });
}

async function connect(endpoint: { hosts: string[]; port: number; username: string; hostKeys: string[] }, privateKeyPEM: string,
  input = "echo TRON_MAC_TERMINAL_$((40+2)); stty size; exit\n"): Promise<ProbeResult> {
  return JSON.parse(await run(probe, ["connect"], JSON.stringify({ endpoint, privateKeyPEM, input, resize: [100, 30] }))) as ProbeResult;
}

async function freePort(): Promise<number> {
  const server = createServer();
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as { port: number }).port;
  await new Promise<void>(resolve => server.close(() => resolve()));
  return port;
}

/** A real OpenSSH sshd as this user: its own host key, the fixture's
 * authorized_keys, public-key authentication only, and Apple's crypto policy. */
async function startSshd(directory: string, sshDirectory: string, port: number) {
  await mkdir(directory, { recursive: true });
  execFileSync("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "fixture-host", "-f", join(directory, "ssh_host_ed25519_key")]);
  const config = join(directory, "sshd_config");
  await writeFile(config, [
    `Port ${port}`, `ListenAddress 127.0.0.1`, `ListenAddress ${tailnetIPv4}`,
    `HostKey ${join(directory, "ssh_host_ed25519_key")}`,
    `AuthorizedKeysFile ${join(sshDirectory, "authorized_keys")}`,
    "PasswordAuthentication no", "KbdInteractiveAuthentication no", "UsePAM no", "StrictModes no",
    `PidFile ${join(directory, "sshd.pid")}`, "Include /etc/ssh/crypto.conf", "",
  ].join("\n"));
  const child = spawn("/usr/sbin/sshd", ["-D", "-f", config, "-E", join(directory, "sshd.log")], { stdio: "ignore" });
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const listening = await new Promise<boolean>(resolve => {
      const socket = new Socket();
      socket.once("connect", () => { socket.destroy(); resolve(true); });
      socket.once("error", () => resolve(false));
      socket.connect(port, "127.0.0.1");
    });
    if (listening) return { child, stop: async () => { child.kill("SIGTERM"); await new Promise(resolve => child.once("exit", resolve)); } };
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  child.kill("SIGKILL");
  throw new Error(`sshd did not listen: ${await readFile(join(directory, "sshd.log"), "utf8").catch(() => "")}`);
}

function client(deviceId: string): ClientContext {
  return { id: deviceId, identity: deviceId, isLocal: false, isSubscribed: () => false, isRevoked: () => false, revokeDevice: () => {} } as unknown as ClientContext;
}

let command = 0;
const commandId = () => `mac-terminal-${String(++command).padStart(4, "0")}`;

/** A Gateway with the production Mac Terminal wiring (gateway-main.ts) over
 * the fixture's ~/.ssh and host keys. */
async function gateway(tronHome: string, sshDirectory: string, hostKeyDirectory: string, port: number) {
  const agentDir = join(tronHome, "agent");
  await mkdir(agentDir, { recursive: true });
  const runtimeFactory = () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
  const modelRuntime = await runtimeFactory();
  const trust = new TrustService(agentDir);
  const sessions = new RuntimeRegistry({
    agentDir, tronHome, idleRuntimeMs: 60_000, modelRuntimeFactory: runtimeFactory, trust,
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
  });
  registries.push(sessions);
  await sessions.initialize();
  const keys = new MacTerminalKeys(sshDirectory);
  const settingsModel = new SettingsModel({ agentDir, tronHome, trust, modelRuntime, macTerminalKeys: keys });
  const settingsChanges = new SettingsChangePath(settingsModel, new SettingsChangeRecord(tronHome), new SettingsApprovals(tronHome), {
    setTrust: async () => { throw new Error("not used"); },
  }, agentDir);
  const devices = new DeviceStore(tronHome, "machine");
  await devices.initialize();
  const pair = async (name: string) => (await devices.pair((await devices.ensureEnrollment()).code, name)).deviceId;
  const service = new GatewayService({
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome, agentDir },
    modelRuntime, trust, settingsModel, settingsChanges, devices, sessions, receipts: new CommandReceiptStore(tronHome),
    macTerminal: new MacTerminalHost(keys, { hostKeyDirectory, port }),
    broadcast: () => {},
    globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
  } as unknown as GatewayServiceDependencies);
  return { service, settingsChanges, pair };
}

beforeAll(async () => {
  const addresses = (await run("/Applications/Tailscale.app/Contents/MacOS/Tailscale", ["ip", "-4"])
    .catch(() => run("tailscale", ["ip", "-4"])).catch(() => "")).trim();
  if (!/^100\.\d+\.\d+\.\d+$/u.test(addresses)) {
    throw new Error("Mac Terminal's journey needs this Mac on its tailnet: `tailscale ip -4` gave no address");
  }
  tailnetIPv4 = addresses;
  await run("swift", ["build", "--package-path", PACKAGE, "--product", "mac-terminal-probe"]);
  probe = join((await run("swift", ["build", "--package-path", PACKAGE, "--show-bin-path"])).trim(), "mac-terminal-probe");
  root = await mkdtemp(join(tmpdir(), "tron-mac-terminal-"));
}, 600_000);

afterAll(async () => {
  await Promise.all(registries.splice(0).map(registry => registry.dispose().catch(() => {})));
  if (root) await rm(root, { recursive: true, force: true });
  await mkdir(dirname(ARTIFACT), { recursive: true });
  await writeFile(ARTIFACT, `${JSON.stringify(transcript, null, 2)}\n`);
});

describe("Mac Terminal", () => {
  it("enrolls through the logged path, logs in over Tailscale, survives the Gateway, and fails loudly on every refusal", async () => {
    const sshDirectory = join(root, "home", ".ssh");
    const hostDirectory = join(root, "sshd");
    await mkdir(sshDirectory, { recursive: true });
    // A key the user added by hand: every Tron write must leave it exactly.
    const own = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOwnUserKeyOwnUserKeyOwnUserKeyOwnUser00 user@laptop";
    await writeFile(join(sshDirectory, "authorized_keys"), `# hand-written\n${own}\n`);
    const port = await freePort();
    const sshd = await startSshd(hostDirectory, sshDirectory, port);
    try {
      const tronHome = join(root, "tron");
      let { service, pair } = await gateway(tronHome, sshDirectory, hostDirectory, port);
      const phone = await pair("Mohsin's iPhone");
      const key = JSON.parse(await run(probe, ["keygen"])) as { privateKeyPEM: string; publicKey: string };

      // Before enrollment: the Gateway reports what the iPhone pins and dials.
      const before = await service.invoke(client(phone), "macTerminal.status", {}) as unknown as MacTerminalStatus;
      expect(before).toMatchObject({ username: userInfo().username, port, remoteLogin: "on", enrolled: false });
      expect(before.hosts).toContain(tailnetIPv4);
      expect(before.hosts[0]).toMatch(/\.ts\.net$/u);
      expect(before.hostKeys).toEqual([(await readFile(join(hostDirectory, "ssh_host_ed25519_key.pub"), "utf8")).split(" ").slice(0, 2).join(" ")]);
      transcript.push({ case: "status-before-enrollment", detail: { ...before, hosts: before.hosts.length } });
      const endpoint = { hosts: before.hosts, port, username: before.username, hostKeys: before.hostKeys };
      expect(await connect(endpoint, key.privateKeyPEM)).toMatchObject({ outcome: "error", error: "authenticationRefused" });

      // Enrollment is the maintainer's tap through settings.change: applied at
      // its approve tier and recorded.
      const enrolled = await service.invoke(client(phone), "settings.change", {
        commandId: commandId(), target: { kind: "mac" },
        changes: [{ key: "permissions.macTerminalKey", qualifiers: { device: phone }, layer: "mac", op: "set", value: key.publicKey }],
      }) as unknown as { status: string; changes: Array<{ tier: string; status: string }> };
      expect(enrolled).toMatchObject({ status: "applied", changes: [{ status: "applied", tier: "approve" }] });
      const file = await readFile(join(sshDirectory, "authorized_keys"), "utf8");
      expect(file.startsWith(`# hand-written\n${own}\n`)).toBe(true);
      const line = file.split("\n")[2]!;
      expect(line).toBe(`from="${MAC_TERMINAL_SOURCES}",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc ${key.publicKey} tron-mac-terminal:${phone} Tron Mac Terminal key for one paired iPhone; delete this line to revoke it`);
      const history = await service.invoke(client(phone), "settings.history", { limit: 10 }) as unknown as { entries: Array<Record<string, unknown>> };
      expect(history.entries[0]).toMatchObject({ key: "permissions.macTerminalKey", qualifiers: { device: phone }, status: "applied", tier: "approve", actor: { kind: "ui", id: phone } });
      expect((await service.invoke(client(phone), "macTerminal.status", {}))).toMatchObject({ enrolled: true, enrolledKey: key.publicKey });
      transcript.push({ case: "enrolled", detail: { line, record: history.entries[0] } });

      // Login over the tailnet: a PTY at the requested size after resize.
      const login = await connect(endpoint, key.privateKeyPEM);
      expect(login).toMatchObject({ outcome: "ok", exitStatus: 0 });
      expect(login.output).toContain("TRON_MAC_TERMINAL_42");
      expect(login.output).toContain("30 100");
      transcript.push({ case: "login", detail: { exitStatus: login.exitStatus } });

      // The from= restriction: the same key from the loopback is refused.
      expect(await connect({ ...endpoint, hosts: ["127.0.0.1"] }, key.privateKeyPEM))
        .toMatchObject({ outcome: "error", error: "authenticationRefused" });

      // The Gateway gone: nothing in the connection path needs it.
      service = undefined as never;
      const offline = await connect(endpoint, key.privateKeyPEM);
      expect(offline).toMatchObject({ outcome: "ok", exitStatus: 0 });
      expect(offline.output).toContain("TRON_MAC_TERMINAL_42");
      transcript.push({ case: "gateway-down-login", detail: { exitStatus: offline.exitStatus } });

      // A host key that is not the pinned one never gets an authentication attempt.
      execFileSync("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", join(root, "other")]);
      const other = (await readFile(join(root, "other.pub"), "utf8")).split(" ").slice(0, 2).join(" ");
      const mismatch = await connect({ ...endpoint, hostKeys: [other] }, key.privateKeyPEM);
      expect(mismatch).toMatchObject({ outcome: "error", error: "hostKeyMismatch" });
      expect(mismatch.message).toContain(execFileSync("ssh-keygen", ["-lf", join(hostDirectory, "ssh_host_ed25519_key.pub")]).toString().split(" ")[1]);
      transcript.push({ case: "host-key-mismatch", detail: mismatch });

      // Revocation from the iPhone: the key unset through the same path.
      ({ service } = await gateway(tronHome, sshDirectory, hostDirectory, port));
      const revoked = await service.invoke(client(phone), "settings.change", {
        commandId: commandId(), target: { kind: "mac" },
        changes: [{ key: "permissions.macTerminalKey", qualifiers: { device: phone }, layer: "mac", op: "unset" }],
      }) as unknown as { status: string; changes: Array<{ tier: string }> };
      expect(revoked).toMatchObject({ status: "applied", changes: [{ tier: "notify" }] });
      expect(await readFile(join(sshDirectory, "authorized_keys"), "utf8")).toBe(`# hand-written\n${own}\n`);
      const refused = await connect(endpoint, key.privateKeyPEM);
      expect(refused).toMatchObject({ outcome: "error", error: "authenticationRefused" });
      transcript.push({ case: "revoked-from-iphone", detail: refused });

      // Revoking the paired device removes its key as a logged change.
      ({ service } = await gateway(tronHome, sshDirectory, hostDirectory, port));
      await service.invoke(client(phone), "settings.change", {
        commandId: commandId(), target: { kind: "mac" },
        changes: [{ key: "permissions.macTerminalKey", qualifiers: { device: phone }, layer: "mac", op: "set", value: key.publicKey }],
      });
      expect((await connect(endpoint, key.privateKeyPEM)).outcome).toBe("ok");
      const otherPhone = await pair("Second iPhone");
      await service.invoke(client(otherPhone), "device.revoke", { commandId: commandId(), deviceId: phone });
      expect(await readFile(join(sshDirectory, "authorized_keys"), "utf8")).toBe(`# hand-written\n${own}\n`);
      expect(await connect(endpoint, key.privateKeyPEM)).toMatchObject({ outcome: "error", error: "authenticationRefused" });
      const deviceHistory = await service.invoke(client(otherPhone), "settings.history", { limit: 1 }) as unknown as { entries: Array<Record<string, unknown>> };
      expect(deviceHistory.entries[0]).toMatchObject({ key: "permissions.macTerminalKey", status: "applied", reason: "The paired device was revoked" });
      transcript.push({ case: "revoked-with-device", detail: deviceHistory.entries[0] });
    } finally {
      await sshd.stop();
    }

    // Remote Login off: the Gateway says so, and the client names it.
    const { service } = await gateway(join(root, "tron-off"), sshDirectory, hostDirectory, port);
    const phone = "11111111-2222-3333-4444-555555555555";
    expect(await service.invoke(client(phone), "macTerminal.status", {})).toMatchObject({ remoteLogin: "off" });
    const key = JSON.parse(await run(probe, ["keygen"])) as { privateKeyPEM: string };
    const off = await connect({ hosts: [tailnetIPv4], port, username: userInfo().username,
      hostKeys: [(await readFile(join(hostDirectory, "ssh_host_ed25519_key.pub"), "utf8")).trim()] }, key.privateKeyPEM);
    expect(off).toMatchObject({ outcome: "error", error: "remoteLoginOff" });
    transcript.push({ case: "remote-login-off", detail: off });
  }, 180_000);
});
