import { execFile } from "node:child_process";
import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { afterEach, expect, it } from "vitest";
import { waitFor } from "../../test-support/wait-for.js";
import { ShareHostJob } from "./share-host-job.js";

const run = promisify(execFile);
const label = `com.tron.test.share-host.${process.pid}`;
const domain = `gui/${process.getuid!()}`;
const roots: string[] = [];

async function loaded(): Promise<string | undefined> {
  return await run("/bin/launchctl", ["print", `${domain}/${label}`]).then(({ stdout }) => stdout, () => undefined);
}

async function running(): Promise<void> {
  await waitFor(async () => /^\s*state = running$/mu.test(await loaded() ?? ""), "the share host job running");
}

async function fixture(directory: (home: string, root: string) => string) {
  const root = await mkdtemp(join(tmpdir(), "tron-share-host-"));
  roots.push(root);
  const home = join(root, "tron"), agents = join(root, "LaunchAgents");
  await mkdir(agents);
  const plist = join(agents, `${label}.plist`);
  await writeFile(plist, `<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>Label</key><string>${label}</string><key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>exec sleep 600</string><string>${directory(home, root)}</string></array><key>RunAtLoad</key><true/><key>KeepAlive</key><true/></dict></plist>\n`);
  return { home, plist, job: new ShareHostJob(home, label, agents) };
}

afterEach(async () => {
  await run("/bin/launchctl", ["bootout", `${domain}/${label}`]).catch(() => {});
  for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true });
});

it("stops only the share host this Tron home serves, keeps its LaunchAgent, and starts it again", async () => {
  const { plist, job } = await fixture(home => join(home, "workspace/builds/ios-ota"));
  const before = await readFile(plist);
  expect(await job.suspend()).toBe(false);
  expect(await job.restore()).toBe(true);
  await running();
  expect(await job.restore()).toBe(false);
  expect(await job.suspend()).toBe(true);
  expect(await loaded()).toBeUndefined();
  expect(await readFile(plist)).toEqual(before);
  expect(await job.restore()).toBe(true);
  await running();
});

it("leaves a share host that serves another home, or that launchd loaded from another plist, running", async () => {
  const other = await fixture((_home, root) => join(root, "elsewhere/ios-ota"));
  await run("/bin/launchctl", ["bootstrap", domain, other.plist]);
  expect(await other.job.suspend()).toBe(false);
  await running();
  const owned = await fixture(home => join(home, "workspace/builds/ios-ota"));
  expect(await owned.job.suspend()).toBe(false);
  expect(await owned.job.restore()).toBe(false);
  expect(await loaded()).toContain(`path = ${await realpath(other.plist)}`);
});
