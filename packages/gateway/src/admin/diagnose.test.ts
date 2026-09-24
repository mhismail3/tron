import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { collectDiagnosticBundle, type BoundedCommand, type BoundedCommandResult, type HealthReader } from "./diagnose.js";

const roots: string[] = [];
afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

const LAUNCHD_LOG_LINE = '2026-09-24 05:27:54.996 Df launchd[1:22b8ea] [gui/501 [100002]:] service inactive: com.tron.server';
const MAGICSOCK_LOG_LINE = "2026-09-24 05:46:26.851 Df io.tailscale.ipn.macsys.network-extension[3443:48f5] magicsock: disco: node [6wPGm] d:8767 now using 192.0.2.23:41641 mtu=1360";
const EXTENSION_NOISE_LINE = "2026-09-24 05:46:26.850 Df io.tailscale.ipn.macsys.network-extension[3443:48f5] activating connection: mach=false";
const TAILSCALE_STATUS = JSON.stringify({
  BackendState: "Running",
  Self: { TailscaleIPs: ["100.64.0.10", "fd7a:115c:a1e0::10"] },
  Peer: {
    node1: {
      HostName: "localhost",
      DNSName: "fixtures-iphone.tailnet.example.ts.net.",
      Online: true,
      CurAddr: "",
      Relay: "sea",
      LastSeen: "2026-09-24T10:50:28.1Z",
    },
  },
});

interface Harness {
  readonly home: string;
  readonly out: string;
  readonly commands: readonly string[];
  readonly healthUrls: readonly string[];
  readonly runCommand: BoundedCommand;
  readonly readHealth: HealthReader;
  readonly now: Date;
}

async function root(): Promise<string> {
  const value = await mkdtemp(join(tmpdir(), "tron-diagnose-"));
  roots.push(value);
  return value;
}

/** Fixture home plus stubbed external commands, so one run is hermetic. */
async function harness(options: { logs?: boolean } = {}): Promise<Harness> {
  const home = await root();
  const out = join(home, "bundle.txt");
  const now = new Date();
  const at = (offsetMs: number): string => new Date(now.getTime() + offsetMs).toISOString();
  if (options.logs !== false) {
    await mkdir(join(home, "logs", "device-exports"), { recursive: true });
    await writeFile(join(home, "logs", "gateway.jsonl"), [
      JSON.stringify({ timestamp: at(-60 * 60_000), level: "info", event: "gateway.bound", message: "in-window-marker api_key: planted-bundle-token" }),
      JSON.stringify({ timestamp: at(-4 * 60 * 60_000), level: "info", event: "gateway.started", message: "out-of-window-marker" }),
      JSON.stringify({ timestamp: at(-60 * 60_000), level: "warning", event: "gateway.event-loop-delay", message: "Bearer planted-access-token" }),
      "",
    ].join("\n"));
    await writeFile(join(home, "logs", "gateway.jsonl.1"), `${JSON.stringify({ timestamp: at(-50 * 60_000), level: "info", event: "gateway.listening", message: "rotated-segment-marker" })}\n`);
    await writeFile(join(home, "logs", "gateway-stderr.log"), "stderr-marker: launcher fallback\n");
    await writeFile(join(home, "logs", "device-exports", "phone-export.jsonl"), '{"marker":"device-export-marker"}\n');
  }
  await mkdir(join(home, "gateway", "payloads", "stable"), { recursive: true });
  await writeFile(join(home, "gateway", "payloads", "stable", "current.json"), '{"schema":1,"kind":"tron-gateway-selection","channel":"stable","version":"0.1.0-test"}\n');
  await writeFile(join(home, "gateway", "payloads", "stable", "deployment-state.json"), '{"schema":1,"state":"ready","sourceRevision":"abc1234","runtimeEpoch":"epoch-test"}\n');
  await writeFile(join(home, "gateway", "payloads", "stable", "update-progress.json"), '{"schema":1,"state":"ready","commandId":"CMD-TEST"}\n');
  await writeFile(join(home, "gateway", "devices.json"), `${JSON.stringify({
    version: 1,
    devices: [{ id: "device-id-1", name: "iPhone", observedName: "Fixture's iPhone", tokenHash: "planted-device-token-hash", createdAt: "2026-09-19T00:49:32.548Z" }],
  })}\n`);
  const commands: string[] = [];
  const healthUrls: string[] = [];
  const payloadRoot = join(home, "gateway", "payloads", "stable", "versions", "0.1.0-test");
  const runCommand: BoundedCommand = async (tool, args): Promise<BoundedCommandResult> => {
    const key = `${tool} ${args.join(" ")}`;
    commands.push(key);
    const output = (text: string): BoundedCommandResult => ({ code: 0, timedOut: false, output: text });
    if (tool === "/bin/ps") {
      return output([
        `  4242 01:02:03 ${payloadRoot}/runtime/node-arm64 ${payloadRoot}/app/dist/index.js --host tailscale --port 9847`,
        "  4243 00:10:00 /Applications/Tron.app/Contents/MacOS/Tron",
        `  4244 00:00:05 node ${home}/agent/bin/pi --prompt planted-prompt-text`,
        "",
      ].join("\n"));
    }
    if (args[0] === "show") {
      if (key.includes("com.tron.server")) return output(`${LAUNCHD_LOG_LINE}\n`);
      return output(`${EXTENSION_NOISE_LINE}\n${MAGICSOCK_LOG_LINE}\n`);
    }
    if (args[0] === "mac") return output("PASS  installed app exists\n");
    if (args[0] === "status") return output(TAILSCALE_STATUS);
    throw new Error(`unexpected command in the diagnostic bundle test: ${key}`);
  };
  const readHealth: HealthReader = async (url) => {
    healthUrls.push(url);
    return { status: 200, body: '{"status":"ok","gatewayVersion":"0.1.0-test"}' };
  };
  return { home, out, commands, healthUrls, runCommand, readHealth, now };
}

async function run(fixture: Harness): Promise<string> {
  const result = await collectDiagnosticBundle({
    tronHome: fixture.home,
    out: fixture.out,
    now: fixture.now,
    runCommand: fixture.runCommand,
    readHealth: fixture.readHealth,
  });
  expect(result.path).toBe(fixture.out);
  return readFile(fixture.out, "utf8");
}

describe("scripts/tron diagnose", () => {
  it("writes every required section for a fixture home and redacts a planted token", async () => {
    const fixture = await harness();
    const bundle = await run(fixture);
    for (const section of ["logs", "device-exports", "payload-selection", "processes", "launchd", "tailscale", "health", "mac-verify"]) {
      expect(bundle).toContain(`## ${section}`);
    }
    expect(bundle).toContain("in-window-marker");
    expect(bundle).toContain("api_key: [REDACTED]");
    expect(bundle).toContain("Bearer [REDACTED]");
    expect(bundle).not.toContain("planted-bundle-token");
    expect(bundle).not.toContain("planted-access-token");
    expect(bundle).toContain("rotated-segment-marker");
    expect(bundle).toContain("stderr-marker");
    expect(bundle).toContain("device-export-marker");
    expect(bundle).toContain("0.1.0-test");
    expect(bundle).toContain("abc1234");
    expect(bundle).toContain("CMD-TEST");
    expect(bundle).toContain("previous.json — missing");
    expect((await stat(fixture.out)).mode & 0o777).toBe(0o600);
  });

  it("keeps only records inside --since and reads rotated segments", async () => {
    const fixture = await harness();
    const bundle = await run(fixture);
    expect(bundle).toContain("in-window-marker");
    expect(bundle).toContain("rotated-segment-marker");
    expect(bundle).not.toContain("out-of-window-marker");
    expect(bundle).toContain("since: 2h");
  });

  // Privacy: device credentials, device names and agent prompts never reach a bundle.
  it("never writes a paired device's token hash or name, or an agent process's arguments", async () => {
    const fixture = await harness();
    const bundle = await run(fixture);
    expect(bundle).not.toContain("planted-device-token-hash");
    expect(bundle).not.toContain("Fixture's iPhone");
    expect(bundle).toMatch(/deviceIdHash=[0-9a-f]{12} peer=/u);
    expect(bundle).not.toContain("planted-prompt-text");
  });

  it("names the running Gateway's payload version and probes /health on its own host and port", async () => {
    const fixture = await harness();
    const bundle = await run(fixture);
    expect(bundle).toContain("channel=stable payloadVersion=0.1.0-test");
    expect(bundle).toContain("/Applications/Tron.app/Contents/MacOS/Tron");
    expect(fixture.healthUrls).toEqual(["http://100.64.0.10:9847/health"]);
    expect(bundle).toContain("status: 200");
  });

  it("reports each paired peer's Tailscale path and only path-change extension lines", async () => {
    const fixture = await harness();
    const bundle = await run(fixture);
    expect(bundle).toContain("path=relay endpoint=sea");
    expect(bundle).toContain("magicsock: disco");
    expect(bundle).not.toContain(EXTENSION_NOISE_LINE);
    expect(bundle).toContain("self: 100.64.0.10");
  });

  it("calls /usr/bin/log explicitly and records launchd's com.tron.server records", async () => {
    const fixture = await harness();
    const bundle = await run(fixture);
    expect(bundle).toContain(`$ /usr/bin/log show --style compact --last 2h --predicate process == "launchd" AND eventMessage CONTAINS "com.tron.server"`);
    expect(bundle).toContain("service inactive: com.tron.server");
    expect(fixture.commands.filter((command) => command.startsWith("/usr/bin/log")).length).toBe(2);
  });

  it("refuses to overwrite an existing output", async () => {
    const fixture = await harness();
    await writeFile(fixture.out, "existing\n");
    await expect(collectDiagnosticBundle({
      tronHome: fixture.home,
      out: fixture.out,
      now: fixture.now,
      runCommand: fixture.runCommand,
      readHealth: fixture.readHealth,
    })).rejects.toThrow(`output already exists: ${fixture.out}`);
    expect(await readFile(fixture.out, "utf8")).toBe("existing\n");
  });

  it("says plainly when a stream directory is absent", async () => {
    const fixture = await harness({ logs: false });
    const bundle = await run(fixture);
    expect(bundle).toContain("## logs");
    expect(bundle).toContain("no log directory at");
    expect(bundle).toContain("## device-exports");
    expect(bundle).toContain("no device export directory at");
  });
});
