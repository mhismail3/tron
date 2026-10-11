import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { readTailscaleStatus, runBoundedCommand, TailscalePeerPaths } from "./tailscale-peer.js";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

async function tailscaleFixture(contents: string): Promise<{ directory: string; executable: string }> {
  const directory = await mkdtemp(join(tmpdir(), "tron-tailscale-peer-"));
  temporaryDirectories.push(directory);
  const executable = join(directory, "tailscale");
  await writeFile(executable, contents, { mode: 0o700 });
  await chmod(executable, 0o700);
  return { directory, executable };
}

describe("Tailscale peer status subprocess", () => {
  it("reads JSON in a TERM-unset launchd environment using the CLI mode", async () => {
    const fixture = await tailscaleFixture(`#!/bin/sh\n[ "$TAILSCALE_BE_CLI" = 1 ] || { echo 'GUI app cannot start'; exit 0; }\nprintf '%s' '{"Self":{"TailscaleIPs":["100.64.0.1"]},"Peer":{"phone":{"TailscaleIPs":["100.64.0.2"],"Online":true,"CurAddr":"203.0.113.5:41641","LastHandshake":"2026-02-01T00:00:00Z","RxBytes":23,"TxBytes":42}}}'\n`);
    const originalPath = process.env.PATH;
    const originalTerm = process.env.TERM;
    process.env.PATH = `${fixture.directory}:/usr/bin:/bin`;
    delete process.env.TERM;
    try {
      expect(process.env.TERM).toBeUndefined();
      const status = await readTailscaleStatus((_, args, timeoutMs, options) => runBoundedCommand(fixture.executable, args, timeoutMs, options), 1_000);
      expect(status).toMatchObject({
        ok: true,
        status: { peers: [{ Online: true, CurAddr: "203.0.113.5:41641", LastHandshake: "2026-02-01T00:00:00Z", RxBytes: 23, TxBytes: 42 }] },
      });
    } finally {
      if (originalPath === undefined) delete process.env.PATH;
      else process.env.PATH = originalPath;
      if (originalTerm === undefined) delete process.env.TERM;
      else process.env.TERM = originalTerm;
    }
  });

  it("projects path reasons and validated peer health from one reused real status process", async () => {
    const fixture = await tailscaleFixture(`#!/bin/sh
[ "$TAILSCALE_BE_CLI" = 1 ] || { echo 'GUI app cannot start'; exit 0; }
echo read >> "$0.calls"
printf '%s' '{"Peer":{"direct":{"TailscaleIPs":["100.64.0.2"],"Online":true,"CurAddr":"203.0.113.5:41641","LastHandshake":"2026-02-01T00:00:00Z","RxBytes":23,"TxBytes":42},"offline":{"TailscaleIPs":["100.64.0.3"],"Online":false,"LastHandshake":"private-fixture-text","RxBytes":-1,"TxBytes":0.5},"relay":{"TailscaleIPs":["100.64.0.4"],"Online":true,"Relay":"sfo"}}}'
`);
    const paths = new TailscalePeerPaths((_, args, timeout, options) => runBoundedCommand(fixture.executable, args, timeout, options));
    expect(await paths.lookup("100.64.0.2")).toEqual({ peerPath: "direct", peerPathSource: "tailscale-status", peerRelay: "", peerLastHandshake: "2026-02-01T00:00:00.000Z", peerRxBytes: 23, peerTxBytes: 42 });
    expect(await paths.lookup("100.64.0.3")).toEqual({ peerPath: "offline", peerPathSource: "tailscale-status", peerRelay: "" });
    expect(await paths.lookup("100.64.0.4")).toEqual({ peerPath: "relay", peerPathSource: "tailscale-status", peerRelay: "sfo" });
    expect(await paths.lookup("100.64.0.5")).toMatchObject({ peerPath: "unknown", peerPathSource: "not-in-status" });
    expect(await paths.lookup("127.0.0.1")).toMatchObject({ peerPath: "unknown", peerPathSource: "not-tailscale" });
    expect(await readFile(`${fixture.executable}.calls`, "utf8")).toBe("read\n");
  });

  it("retains a real CLI failure category rather than calling a failed read a missing peer", async () => {
    const fixture = await tailscaleFixture("#!/bin/sh\nexit 1\n");
    const paths = new TailscalePeerPaths((_, args, timeout, options) => runBoundedCommand(fixture.executable, args, timeout, options));
    expect(await paths.lookup("100.64.0.2")).toMatchObject({ peerPath: "unknown", peerPathSource: "cli-failed" });
  });

  it("kills a timed-out CLI and reports the bounded timeout reason", async () => {
    const fixture = await tailscaleFixture(`#!/bin/sh\ntrap '' TERM\necho $$ > "$TS_FIXTURE_PID"\nexec /bin/sleep 30\n`);
    const pidFile = join(fixture.directory, "pid");
    const originalPath = process.env.PATH;
    const originalTerm = process.env.TERM;
    const originalPidFile = process.env.TS_FIXTURE_PID;
    process.env.PATH = `${fixture.directory}:/usr/bin:/bin`;
    process.env.TS_FIXTURE_PID = pidFile;
    delete process.env.TERM;
    try {
      const result = await runBoundedCommand(fixture.executable, ["status", "--json"], 500);
      expect(result).toMatchObject({ code: null, timedOut: true });
      const pid = Number(await readFile(pidFile, "utf8"));
      expect(() => process.kill(pid, 0)).toThrow();
    } finally {
      if (originalPath === undefined) delete process.env.PATH;
      else process.env.PATH = originalPath;
      if (originalTerm === undefined) delete process.env.TERM;
      else process.env.TERM = originalTerm;
      if (originalPidFile === undefined) delete process.env.TS_FIXTURE_PID;
      else process.env.TS_FIXTURE_PID = originalPidFile;
    }
  });
});
