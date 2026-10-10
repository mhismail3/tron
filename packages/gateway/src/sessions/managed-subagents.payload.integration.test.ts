import { execFile } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { expect, it } from "vitest";

const gateway = fileURLToPath(new URL("../../", import.meta.url));
const run = promisify(execFile);

it("activates a real staged Mac app offline without checkout pin or artifact access", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-subagents-staged-"));
  const app = join(root, "app");
  const reportPath = process.env.TRON_SUBAGENTS_PAYLOAD_REPORT ?? join(gateway, "test-results", "managed-subagents.payload.json");
  const report: Record<string, unknown> = { passed: false };
  try {
    await mkdir(app);
    await run("bash", [join(gateway, "../mac-app/scripts/stage-gateway-app.sh"), gateway, app], { timeout: 15_000 });
    // Dependency installation is the separate existing npm-ci step. This test
    // shares only that exact SDK tree, never pin/archive/source authority.
    await symlink(join(gateway, "node_modules"), join(app, "node_modules"));
    const script = `import net from 'node:net';
      net.Socket.prototype.connect = function () { throw new Error('network denied'); };
      const { ManagedSubagents } = await import('./dist/sessions/managed-subagents.js');
      const { delegatedArtifactRoot, delegatedProviderEnvironment } = await import('./dist/sessions/delegated-provider.js');
      delegatedProviderEnvironment(delegatedArtifactRoot(${JSON.stringify(join(root, "home"))}));
      const { SettingsManager } = await import('@earendil-works/pi-coding-agent');
      const managed = ManagedSubagents.activateForStartup(${JSON.stringify(join(root, "home"))});
      console.log(JSON.stringify({ root: managed.verify(), entries: (await managed.loaderOptions(SettingsManager.inMemory())).extensionFactories.map(entry => entry.name) }));`;
    const output = await run(process.execPath, ["--input-type=module", "-e", script], {
      cwd: app, timeout: 15_000, env: { PATH: process.env.PATH!, HOME: root, TMPDIR: root, npm_config_offline: "true", npm_config_cache: join(root, "cache") },
    });
    const activated = JSON.parse(output.stdout);
    expect(activated.entries.length).toBeGreaterThan(0);
    const pin = JSON.parse(await readFile(join(app, "pi-subagents-pin.json"), "utf8"));
    const receipt = JSON.parse(await readFile(join(activated.root, "tron-install-receipt.json"), "utf8"));
    expect(receipt).toEqual({ version: pin.version, forkCommit: pin.fork.commit, sha512: pin.closure.sha512 });
    // The operator installer is a shipped entrypoint too, not a checkout script.
    await run(process.execPath, ["scripts/install-pi-subagents.mjs", join(root, "home")], { cwd: app, timeout: 15_000 });
    await run(process.execPath, ["scripts/check-pi-subagents.mjs"], { cwd: app, timeout: 15_000 });
    const trustedChecker = join(gateway, "scripts/check-pi-subagents.mjs");
    await run(process.execPath, [trustedChecker, "--root", app], { timeout: 15_000 });
    const previousArchive = join(app, pin.previous.closure.path);
    await writeFile(previousArchive, "damaged retained payload closure");
    await expect(run(process.execPath, [trustedChecker, "--root", app], { timeout: 15_000 }))
      .rejects.toMatchObject({ code: 1 });
    report.invalidRetainedClosureRefused = true;
    report.passed = true;
    report.receipt = receipt;
    report.entries = activated.entries.length;
  } finally {
    await rm(root, { recursive: true, force: true });
    await mkdir(dirname(reportPath), { recursive: true });
    await writeFile(reportPath, JSON.stringify(report, null, 2) + "\n");
  }
}, 45_000);
