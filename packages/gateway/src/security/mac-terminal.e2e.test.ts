import { TEST_SETTINGS_SCHEMA } from "../../test-support/settings-schema.js";
import { displayOwnerOf, createTestRegistry } from "../../test-support/gateway-registry.js";
import { execFile, execFileSync, spawn } from "node:child_process";
import { Socket, createServer } from "node:net";
import { mkdir, mkdtemp, readFile, realpath, rename, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir, userInfo } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { maintainerChange } from "../../test-support/native-change.js";
import { SettingsStoreAdapter } from "../admin/settings-model.js";
import { SettingsChangePath } from "../kernel/settings/settings-change.js";
import { SettingsModel } from "../kernel/settings/settings-model.js";
import { SettingsChangeRecord } from "../kernel/settings/settings-record.js";
import { TrustService } from "../kernel/resources/trust-service.js";
import { DeviceStore } from "./device-store.js";
import { MAC_TERMINAL_SOURCES, MacTerminalKeys } from "./mac-terminal.js";
import { MacTerminalService, type MacTerminalStatus } from "./mac-terminal-service.js";
import { RuntimeRegistry } from "../kernel/session/runtime-registry.js";
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
const sessionName = `tron-fixture-${process.pid}`;
const registries: RuntimeRegistry[] = [];
let probe = "";
let root = "";
let tailnetIPv4 = "";

async function until(condition: () => boolean | Promise<boolean>, what: string): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (await condition()) return;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  throw new Error(`timed out waiting for ${what}`);
}

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
  const result = JSON.parse(await run(probe, ["connect"], JSON.stringify({ endpoint, privateKeyPEM, sessionName, input, resize: [100, 30] }))) as ProbeResult;
  if (result.error === "resizeTimeout") throw new Error(result.message);
  return result;
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
async function startSshd(directory: string, sshDirectory: string, port: number, withoutTmux = false) {
  await mkdir(directory, { recursive: true });
  execFileSync("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "fixture-host", "-f", join(directory, "ssh_host_ed25519_key")]);
  const config = join(directory, "sshd_config");
  const policy = '(version 1) (allow default) (deny file-read* (literal "/opt/homebrew/bin/tmux") (subpath "/opt/homebrew/Cellar/tmux") (literal "/usr/local/bin/tmux") (subpath "/usr/local/Cellar/tmux"))';
  await writeFile(config, [
    `Port ${port}`, `ListenAddress 127.0.0.1`, `ListenAddress ${tailnetIPv4}`,
    `HostKey ${join(directory, "ssh_host_ed25519_key")}`,
    `AuthorizedKeysFile ${join(sshDirectory, "authorized_keys")}`,
    "PasswordAuthentication no", "KbdInteractiveAuthentication no", "UsePAM no", "StrictModes no",
    `PidFile ${join(directory, "sshd.pid")}`, "Include /etc/ssh/crypto.conf",
    ...(withoutTmux ? [`ForceCommand /usr/bin/sandbox-exec -p '${policy}' /bin/sh -c "$SSH_ORIGINAL_COMMAND"`] : []), "",
  ].join("\n"));
  const args = ["-D", "-f", config, "-E", join(directory, "sshd.log")];
  // Sandbox only the post-auth shell for the missing-binary case. It executes
  // SSH_ORIGINAL_COMMAND unchanged; there is no canned response or host change.
  const child = spawn("/usr/sbin/sshd", args, { stdio: "ignore" });
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
async function gateway(tronHome: string, port: number) {
  const agentDir = join(tronHome, "agent");
  await mkdir(agentDir, { recursive: true });
  const runtimeFactory = () => ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
  const modelRuntime = await runtimeFactory();
  const trust = new TrustService(agentDir);
  const sessions = await createTestRegistry({
    agentDir, tronHome, idleRuntimeMs: 60_000, modelRuntimeFactory: runtimeFactory, trust,
    broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
  });
  registries.push(sessions);
  await sessions.initialize();
  const keys = new MacTerminalService(tronHome, { port, launchAgentDirectory: join(root, "agents") });
  const settingsModel = new SettingsModel(new SettingsStoreAdapter({ schema: TEST_SETTINGS_SCHEMA, agentDir, tronHome, trust, modelRuntime, macTerminalKeys: keys }));
  const settingsChanges = new SettingsChangePath(settingsModel, new SettingsChangeRecord(tronHome), {
    setTrust: async () => { throw new Error("not used"); },
  });
  const devices = new DeviceStore(tronHome, "machine");
  await devices.initialize();
  const pair = async (name: string) => (await devices.pair((await devices.ensureEnrollment()).code, name)).deviceId;
  const service = new GatewayService({ display: displayOwnerOf(sessions),
    config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome, agentDir },
    modelRuntime, trust, settingsModel, settingsChanges, devices, sessions, receipts: new CommandReceiptStore(tronHome),
    macTerminal: keys,
    broadcast: () => {},
    globalProviderResources: { withStableSnapshot: async (operation: () => Promise<unknown>) => operation(), requestReload: () => {} },
  } as unknown as GatewayServiceDependencies);
  return { service, settingsChanges, pair, devices };
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
  root = await realpath(await mkdtemp(join(tmpdir(), "tron-mac-terminal-")));
}, 600_000);

afterAll(async () => {
  await Promise.all(registries.splice(0).map(registry => registry.dispose().catch(() => {})));
  if (root) await rm(root, { recursive: true, force: true });
  await mkdir(dirname(ARTIFACT), { recursive: true });
  await writeFile(ARTIFACT, `${JSON.stringify(transcript, null, 2)}\n`);
});

describe("Mac Terminal", () => {
  it("enrolls through the logged path, logs in over Tailscale, survives the Gateway, and fails loudly on every refusal", async () => {
    const tronHome = join(root, "tron");
    const sshDirectory = join(tronHome, "mac-terminal");
    const hostDirectory = sshDirectory;
    await mkdir(sshDirectory, { recursive: true, mode: 0o700 });
    // A key the user added by hand, with a comment that is not UTF-8: every
    // Tron write must leave those bytes exactly.
    const own = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOwnUserKeyOwnUserKeyOwnUserKeyOwnUser00 user@laptop";
    const handWritten = Buffer.concat([Buffer.from("# hand-written caf"), Buffer.from([0xe9]), Buffer.from(`\n${own}\n`)]);
    const authorizedKeys = join(sshDirectory, "authorized_keys");
    await writeFile(authorizedKeys, handWritten, { mode: 0o600 });
    const port = await freePort();
    const native = new MacTerminalService(tronHome, { port, launchAgentDirectory: join(root, "agents") });
    try {
      let { service, pair, devices } = await gateway(tronHome, port);
      const phone = await pair("Fixture iPhone");
      const key = JSON.parse(await run(probe, ["keygen"])) as { privateKeyPEM: string; publicKey: string };

      expect(await service.invoke(client(phone), "macTerminal.status", {})).toMatchObject({ serviceState: "unconfigured", hostKeys: [], enrolled: false });
      const enabled = await maintainerChange(service, client(phone), "settings.change", {
        commandId: commandId(), target: { kind: "global" },
        changes: [{ key: "permissions.macTerminalServer", layer: "global", op: "set", value: true }],
      }) as unknown as { changes: Array<{ changeId: string }> };
      expect(enabled).toMatchObject({ status: "applied", changes: [{ status: "applied" }] });
      // Enable has prepared a host identity, but has not published a phone key.
      const before = await service.invoke(client(phone), "macTerminal.status", {}) as unknown as MacTerminalStatus;
      expect(before).toMatchObject({ username: userInfo().username, port, serviceState: "running", enrolled: false });
      expect(before.hosts).toContain(tailnetIPv4);
      expect(before.hosts).toEqual([tailnetIPv4]);
      expect(before.hostKeys).toEqual([(await readFile(join(hostDirectory, "ssh_host_ed25519_key.pub"), "utf8")).split(" ").slice(0, 2).join(" ")]);
      transcript.push({ case: "status-before-enrollment", detail: { ...before, hosts: before.hosts.length } });
      const endpoint = { hosts: before.hosts, port, username: before.username, hostKeys: before.hostKeys };
      expect(await connect(endpoint, key.privateKeyPEM)).toMatchObject({ outcome: "error", error: "authenticationRefused" });

      // Enrollment is the maintainer's tap through settings.change: applied at
      // its approve tier and recorded.
      const enrolled = await maintainerChange(service, client(phone), "settings.change", {
        commandId: commandId(), target: { kind: "global" },
        changes: [{ key: "permissions.macTerminalKey", qualifiers: { device: phone }, layer: "global", op: "set", value: key.publicKey }],
      }) as unknown as { status: string; changes: Array<{ status: string }> };
      expect(enrolled).toMatchObject({ status: "applied", changes: [{ status: "applied" }] });
      const bytes = await readFile(authorizedKeys);
      expect(bytes.subarray(0, handWritten.length).equals(handWritten)).toBe(true);
      const line = bytes.subarray(handWritten.length).toString("utf8").trimEnd();
      expect(line).toBe(`from="${MAC_TERMINAL_SOURCES}",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc ${key.publicKey} tron-mac-terminal:${phone} Tron Mac Terminal key for one paired iPhone; delete this line to revoke it`);
      const history = await service.invoke(client(phone), "settings.history", { limit: 10 }) as unknown as { entries: Array<Record<string, unknown>> };
      expect(history.entries[0]).toMatchObject({ key: "permissions.macTerminalKey", qualifiers: { device: phone }, status: "applied", actor: { kind: "ui", id: phone } });
      expect((await service.invoke(client(phone), "macTerminal.status", {}))).toMatchObject({ enrolled: true, enrolledKey: key.publicKey });
      transcript.push({ case: "enrolled", detail: { line, record: history.entries[0] } });

      // Login over the tailnet: a PTY at the requested size after resize.
      const login = await connect(endpoint, key.privateKeyPEM);
      expect(login).toMatchObject({ outcome: "ok", exitStatus: 0 });
      expect(login.output).toContain("TRON_MAC_TERMINAL_42");
      expect(login.output).toContain("30 100");
      transcript.push({ case: "login", detail: { exitStatus: login.exitStatus } });

      // Preserve the server-side source restriction oracle separately: the
      // app now rejects loopback before dialing, so it cannot prove this boundary.
      const identity = join(root, "source-restriction-key.pem");
      const knownHosts = join(root, "source-restriction-known-hosts");
      // A separate test-only loopback sshd proves the from= authorization
      // boundary using the production owner’s actual authorized_keys. The
      // private production listener itself correctly refuses loopback TCP.
      const sourcePort = await freePort();
      const sourceDirectory = join(root, "source-restriction-sshd");
      const sourcePeer = await startSshd(sourceDirectory, sshDirectory, sourcePort);
      await writeFile(identity, key.privateKeyPEM, { mode: 0o600 });
      await writeFile(knownHosts, [tailnetIPv4, "127.0.0.1"].map(host =>
        `[${host}]:${port} ${before.hostKeys[0]}\n`).join(""));
      const ssh = ["-F", "/dev/null", "-p", String(port), "-i", identity,
        "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=yes", "-o", `UserKnownHostsFile=${knownHosts}`];
      expect(await run("/usr/bin/ssh", [...ssh, "-b", tailnetIPv4,
        `${before.username}@${tailnetIPv4}`, "printf SOURCE_ALLOWED_42"])).toBe("SOURCE_ALLOWED_42");
      try {
        await writeFile(knownHosts, `[127.0.0.1]:${sourcePort} ${(await readFile(join(sourceDirectory, "ssh_host_ed25519_key.pub"), "utf8")).trim()}\n`, { flag: "a" });
        await expect(run("/usr/bin/ssh", [...ssh.map((value, index) => index === 3 ? String(sourcePort) : value),
          `${before.username}@127.0.0.1`, "printf MUST_NOT_RUN"])).rejects.toThrow(/Permission denied \(publickey\)/);
      } finally { await sourcePeer.stop(); }
      transcript.push({ case: "real-sshd-source-restriction", detail: { tailnet: "allowed", loopback: "refused" } });

      // The client refuses a non-tailnet destination before dialing it.
      expect(await connect({ ...endpoint, hosts: ["127.0.0.1"] }, key.privateKeyPEM))
        .toMatchObject({ outcome: "error", error: "invalidEndpoint" });

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

      ({ service } = await gateway(tronHome, port));
      // Keep a second phone authorized so revoke is proved by actual public-key
      // denial after TCP/auth, not merely by the last-key service shutdown.
      const keeper = await pair("Keeper iPhone");
      const keeperKey = JSON.parse(await run(probe, ["keygen"])) as { publicKey: string };
      await maintainerChange(service, client(keeper), "settings.change", {
        commandId: commandId(), target: { kind: "global" },
        changes: [{ key: "permissions.macTerminalKey", qualifiers: { device: keeper }, layer: "global", op: "set", value: keeperKey.publicKey }],
      });
      const surviving = Buffer.concat([handWritten, Buffer.from(`from="${MAC_TERMINAL_SOURCES}",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc ${keeperKey.publicKey} tron-mac-terminal:${keeper} Tron Mac Terminal key for one paired iPhone; delete this line to revoke it\n`)]);
      // The native replacement/undo oracle covers the hardware-owned rows
      // that cannot be mutated by the generic hosted/Linux settings journey.
      const replacement = JSON.parse(await run(probe, ["keygen"])) as { privateKeyPEM: string; publicKey: string };
      const replaced = await maintainerChange(service, client(phone), "settings.change", {
        commandId: commandId(), target: { kind: "global" },
        changes: [{ key: "permissions.macTerminalKey", qualifiers: { device: phone }, layer: "global", op: "set", value: replacement.publicKey }],
      }) as unknown as { changes: Array<{ changeId: string }> };
      // Independent auth-negative scenarios must not inherit native source
      // penalties. Explicit fixture recovery preserves keys/shells; no throttle
      // is disabled and no assertion is retried.
      await native.recover();
      expect(await connect(endpoint, key.privateKeyPEM)).toMatchObject({ outcome: "error", error: "authenticationRefused" });
      expect(await connect(endpoint, replacement.privateKeyPEM)).toMatchObject({ outcome: "ok" });
      await maintainerChange(service, client(phone), "settings.undo", { commandId: commandId(), changeId: replaced.changes[0]!.changeId });
      expect(await connect(endpoint, key.privateKeyPEM)).toMatchObject({ outcome: "ok" });
      expect(await connect(endpoint, replacement.privateKeyPEM)).toMatchObject({ outcome: "error", error: "authenticationRefused" });
      transcript.push({ case: "native-key-replacement-undo", detail: { restored: true } });
      await native.recover();
      // Revocation from the iPhone: the key unset through the same path.
      ({ service } = await gateway(tronHome, port));
      const revoked = await maintainerChange(service, client(phone), "settings.change", {
        commandId: commandId(), target: { kind: "global" },
        changes: [{ key: "permissions.macTerminalKey", qualifiers: { device: phone }, layer: "global", op: "unset" }],
      }) as unknown as { status: string; changes: Array<{ status: string }> };
      expect(revoked).toMatchObject({ status: "applied", changes: [{ status: "applied" }] });
      expect((await readFile(authorizedKeys)).equals(surviving)).toBe(true);
      const refused = await connect(endpoint, key.privateKeyPEM);
      expect(refused).toMatchObject({ outcome: "error", error: "authenticationRefused" });
      transcript.push({ case: "revoked-from-iphone", detail: refused });

      // Revoking the paired device removes its key as a logged change.
      ({ service, devices } = await gateway(tronHome, port));
      await maintainerChange(service, client(phone), "settings.change", {
        commandId: commandId(), target: { kind: "global" },
        changes: [{ key: "permissions.macTerminalKey", qualifiers: { device: phone }, layer: "global", op: "set", value: key.publicKey }],
      });
      expect((await connect(endpoint, key.privateKeyPEM)).outcome).toBe("ok");
      const otherPhone = await pair("Second iPhone");
      // An iPhone enrolls only its own key, so a device revoke always finds it.
      await expect(maintainerChange(service, client(otherPhone), "settings.change", {
        commandId: commandId(), target: { kind: "global" },
        changes: [{ key: "permissions.macTerminalKey", qualifiers: { device: phone }, layer: "global", op: "set", value: key.publicKey }],
      })).rejects.toMatchObject({ code: "invalid_request" });
      // A key that cannot be removed (authorized_keys made a symlink) fails the
      // revoke and leaves the device paired, so it can be retried; a revoked
      // iPhone never keeps a working key.
      await rename(authorizedKeys, `${authorizedKeys}.real`);
      await symlink(`${authorizedKeys}.real`, authorizedKeys);
      await expect(service.invoke(client(otherPhone), "device.revoke", { commandId: commandId(), deviceId: phone }))
        .rejects.toMatchObject({ code: "conflict" });
      expect((await devices.listDevices()).map(device => device.id)).toContain(phone);
      await rm(authorizedKeys);
      await rename(`${authorizedKeys}.real`, authorizedKeys);
      await service.invoke(client(otherPhone), "device.revoke", { commandId: commandId(), deviceId: phone });
      expect((await devices.listDevices()).map(device => device.id)).not.toContain(phone);
      expect((await readFile(authorizedKeys)).equals(surviving)).toBe(true);
      expect(await connect(endpoint, key.privateKeyPEM)).toMatchObject({ outcome: "error", error: "authenticationRefused" });
      const deviceHistory = await service.invoke(client(otherPhone), "settings.history", { limit: 1 }) as unknown as { entries: Array<Record<string, unknown>> };
      expect(deviceHistory.entries[0]).toMatchObject({ key: "permissions.macTerminalKey", status: "applied", reason: "The paired device was revoked" });
      transcript.push({ case: "revoked-with-device", detail: deviceHistory.entries[0] });
      await maintainerChange(service, client(otherPhone), "settings.undo", { commandId: commandId(), changeId: enabled.changes[0]!.changeId });
      expect(await native.enabled()).toBe(false);
      expect((await native.status()).serviceState).toBe("stopped");
      expect(await native.read()).toEqual({ [keeper]: keeperKey.publicKey });
      await maintainerChange(service, client(otherPhone), "settings.change", {
        commandId: commandId(), target: { kind: "global" },
        changes: [{ key: "permissions.macTerminalServer", layer: "global", op: "set", value: true }],
      });
      expect((await native.status()).serviceState).toBe("running");
      transcript.push({ case: "native-server-enable-undo", detail: { restored: true } });
    } finally {
      await native.setEnabled(false);
    }

    // Owned service stopped: the Gateway says so, and the client names it.
    const { service } = await gateway(tronHome, port);
    const phone = "11111111-2222-3333-4444-555555555555";
    expect(await service.invoke(client(phone), "macTerminal.status", {})).toMatchObject({ serviceState: "stopped" });
    const key = JSON.parse(await run(probe, ["keygen"])) as { privateKeyPEM: string };
    const off = await connect({ hosts: [tailnetIPv4], port, username: userInfo().username,
      hostKeys: [(await readFile(join(hostDirectory, "ssh_host_ed25519_key.pub"), "utf8")).trim()] }, key.privateKeyPEM);
    expect(off).toMatchObject({ outcome: "error", error: "serviceStopped" });
    transcript.push({ case: "private-service-stopped", detail: off });
  }, 180_000);

  it("reattaches the same shell after a deliberate background transport close", async () => {
    const sshDirectory = join(root, "persistent-home", ".ssh");
    const hostDirectory = join(root, "persistent-sshd");
    await mkdir(sshDirectory, { recursive: true });
    const key = JSON.parse(await run(probe, ["keygen"])) as { privateKeyPEM: string; publicKey: string };
    await new MacTerminalKeys(sshDirectory).set("persistent-phone", key.publicKey);
    const port = await freePort();
    const sshd = await startSshd(hostDirectory, sshDirectory, port);
    const endpoint = { hosts: [tailnetIPv4], port, username: userInfo().username,
      hostKeys: [(await readFile(join(hostDirectory, "ssh_host_ed25519_key.pub"), "utf8")).trim()] };
    const marker = join(root, "shell-pids");
    const link = async (label: string) => JSON.parse(await run(probe, ["connect"], JSON.stringify({
      endpoint, privateKeyPEM: key.privateKeyPEM, sessionName,
      input: `echo "${label}=$$" >> ${marker}; echo READY_${label}_$((6*7))\n`, detachWhen: `READY_${label}_42`,
    }))) as ProbeResult;
    try {
      expect((await link("before")).outcome).toBe("ok");
      expect((await link("foreground")).outcome).toBe("ok");
      const pids = (await readFile(marker, "utf8")).trim().split("\n").map(line => Number(line.split("=")[1]));
      expect(pids).toHaveLength(2);
      expect(pids[0]).toBeGreaterThan(1);
      expect(pids[1]).toBe(pids[0]);
      transcript.push({ case: "same-shell-after-transport-close", detail: { pids } });
    } finally {
      execFileSync("/opt/homebrew/bin/tmux", ["-L", "tron-mobile", "kill-session", "-t", sessionName]);
      await sshd.stop();
    }
  }, 180_000);

  it("refuses a real sshd environment without tmux, with no plain-shell fallback", async () => {
    const directory = join(root, "missing-tmux");
    const sshDirectory = join(directory, ".ssh");
    await mkdir(sshDirectory, { recursive: true });
    const key = JSON.parse(await run(probe, ["keygen"])) as { privateKeyPEM: string; publicKey: string };
    await new MacTerminalKeys(sshDirectory).set("missing-tmux-phone", key.publicKey);
    const port = await freePort();
    const sshd = await startSshd(directory, sshDirectory, port, true);
    try {
      const endpoint = { hosts: [tailnetIPv4], port, username: userInfo().username,
        hostKeys: [(await readFile(join(directory, "ssh_host_ed25519_key.pub"), "utf8")).trim()] };
      const result = JSON.parse(await run(probe, ["connect"], JSON.stringify({
        endpoint, privateKeyPEM: key.privateKeyPEM, sessionName,
        input: "echo MUST_NOT_OPEN_A_PLAIN_SHELL\n",
      }))) as ProbeResult;
      expect(result, JSON.stringify({ result, sshd: await readFile(join(directory, "sshd.log"), "utf8") })).toMatchObject({ outcome: "error", error: "tmuxMissing" });
      transcript.push({ case: "real-sshd-tmux-unavailable", detail: result });
    } finally { await sshd.stop(); }
  }, 180_000);

  it("keeps the shell PID across an abrupt network proxy disconnect", async () => {
    const directory = join(root, "network-drop");
    const sshDirectory = join(directory, ".ssh");
    await mkdir(sshDirectory, { recursive: true });
    const key = JSON.parse(await run(probe, ["keygen"])) as { privateKeyPEM: string; publicKey: string };
    await new MacTerminalKeys(sshDirectory).set("network-drop-phone", key.publicKey);
    const port = await freePort();
    const sshd = await startSshd(directory, sshDirectory, port);
    const sockets = new Set<Socket>();
    const backends = new Set<ReturnType<typeof spawn>>();
    const proxy = createServer(downstream => {
      // Like the Swift client, a fixture-owned process dials this Mac's
      // tailnet. Keep the default Node test network-isolation guard intact.
      const upstream = spawn("/usr/bin/nc", ["-s", tailnetIPv4, tailnetIPv4, String(port)]);
      backends.add(upstream);
      sockets.add(downstream);
      downstream.once("close", () => { sockets.delete(downstream); upstream.kill("SIGTERM"); });
      downstream.on("error", () => upstream.kill("SIGTERM"));
      upstream.on("error", () => downstream.destroy());
      upstream.once("exit", () => { backends.delete(upstream); downstream.destroy(); });
      downstream.pipe(upstream.stdin!);
      upstream.stdout!.pipe(downstream);
      upstream.stderr!.resume();
    });
    await new Promise<void>((resolve, reject) => { proxy.once("error", reject); proxy.listen(0, tailnetIPv4, resolve); });
    const proxyPort = (proxy.address() as { port: number }).port;
    const endpoint = { hosts: [tailnetIPv4], port: proxyPort, username: userInfo().username,
      hostKeys: [(await readFile(join(directory, "ssh_host_ed25519_key.pub"), "utf8")).trim()] };
    const marker = join(directory, "pids");
    let first: Promise<string> | undefined;
    let firstResult: ProbeResult | undefined;
    try {
      first = run(probe, ["connect"], JSON.stringify({
        endpoint, privateKeyPEM: key.privateKeyPEM, sessionName,
        input: `echo "before=$$" > ${marker}\n`,
      })).then(raw => { firstResult = JSON.parse(raw); return raw; });
      await until(async () => {
        if (firstResult) throw new Error(JSON.stringify({ firstResult, sshd: await readFile(join(directory, "sshd.log"), "utf8") }));
        return (await readFile(marker, "utf8").catch(() => "")).startsWith("before=");
      }, "shell PID before network drop");
      // Tear down real TCP streams, not the client's close/detach method.
      for (const socket of sockets) socket.destroy();
      expect(JSON.parse(await first)).toMatchObject({ outcome: "ok" });
      const second = JSON.parse(await run(probe, ["connect"], JSON.stringify({
        endpoint, privateKeyPEM: key.privateKeyPEM, sessionName,
        input: `echo "after=$$" >> ${marker}; echo NETWORK_AFTER_$((6*7))\n`,
        detachWhen: "NETWORK_AFTER_42",
      }))) as ProbeResult;
      expect(second.outcome).toBe("ok");
      const pids = (await readFile(marker, "utf8")).trim().split("\n").map(line => Number(line.split("=")[1]));
      expect(pids).toHaveLength(2);
      expect(pids[0]).toBeGreaterThan(1);
      expect(pids[1]).toBe(pids[0]);
      transcript.push({ case: "same-shell-after-network-drop", detail: { pids } });
    } finally {
      for (const socket of sockets) socket.destroy();
      await Promise.all([...backends].map(child => new Promise<void>(resolve => {
        child.once("exit", () => resolve()); child.kill("SIGTERM");
      })));
      await new Promise<void>(resolve => proxy.close(() => resolve()));
      await first?.catch(() => {});
      try { execFileSync("/opt/homebrew/bin/tmux", ["-L", "tron-mobile", "kill-session", "-t", sessionName], { stdio: "ignore" }); }
      catch (error) { if ((error as { status?: number }).status !== 1) throw error; }
      finally { await sshd.stop(); }
    }
  }, 180_000);
});
