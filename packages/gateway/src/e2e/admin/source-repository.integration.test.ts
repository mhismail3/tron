import { chmod, copyFile, mkdir, mkdtemp, readFile, realpath, rm, stat, symlink, writeFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { pathToFileURL } from "node:url";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { afterEach, expect, it } from "vitest";
import { drainDurableWriteStats } from "../../foundation/durable-json.js";
import { GatewayUpdateService } from "../../admin/gateway-update-service.js";
import { IosDeviceInstallService } from "../../admin/ios-device-install-service.js";
import { MacReplaceService } from "../../admin/mac-replace-service.js";
import { startLockGateway } from "../../../test-support/gateway-lock-harness.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });
const deviceId = "11111111-1111-4111-8111-111111111111";

async function fixture() {
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-source-repository-")));
  roots.push(root);
  const tronHome = join(root, "home");
  const update = new GatewayUpdateService({ tronHome, environment: {} });
  const install = new IosDeviceInstallService({ tronHome, environment: { TRON_GATEWAY_SUPERVISED: "1" } });
  const mac = new MacReplaceService({ tronHome, channel: "dev", sourceRoot: async () => (await update.configStatus())?.sourceRoot });
  return { root, tronHome, update, install, mac };
}

it("Gateway and iPhone configuration admit the actual checkout without retired implementation markers", async () => {
  const { update, install } = await fixture();
  const sourceRoot = await realpath(resolve(import.meta.dirname, "../../../../.."));
  expect((await update.configure({ sourceRoot })).sourceRoot).toBe(sourceRoot);
  expect((await install.configure({ deviceId, sourceRoot })).sourceRoot).toBe(sourceRoot);
  expect((await update.configStatus())?.sourceRoot).toBe(sourceRoot);
  expect((await install.configStatus(deviceId))?.sourceRoot).toBe(sourceRoot);
});

it("the Gateway update configuration is synchronized before configure returns, as compact owner-only JSON", async () => {
  const { tronHome, update } = await fixture();
  const sourceRoot = await realpath(resolve(import.meta.dirname, "../../../../.."));
  drainDurableWriteStats();
  const config = await update.configure({ sourceRoot });
  expect(drainDurableWriteStats().count).toBe(2);
  const path = join(tronHome, "state", "update-config.json");
  expect(await readFile(path, "utf8")).toBe(`${JSON.stringify(config)}\n`);
  expect((await stat(path)).mode & 0o777).toBe(0o600);
});

it("records an actual updater spawn failure under the canonical channel root", async () => {
  const { root, tronHome } = await fixture();
  const payload = join(root, "payload");
  const helper = join(payload, "helper.mjs");
  const node = join(root, "node");
  const script = join(root, "spawn-failure.mjs");
  await mkdir(payload, { recursive: true });
  await mkdir(tronHome);
  await writeFile(helper, 'throw new Error("fixture helper must never execute");');
  await copyFile(process.execPath, node);
  await chmod(node, 0o700);
  const module = pathToFileURL(resolve(import.meta.dirname, "../../admin/gateway-update-service.ts")).href;
  await writeFile(script, `import { unlink, readFile } from "node:fs/promises";
import { GatewayUpdateService } from ${JSON.stringify(module)};
const service = new GatewayUpdateService({ tronHome: ${JSON.stringify(tronHome)}, runtimeChannel: "dev", environment: {
  TRON_GATEWAY_SUPERVISED: "1", TRON_GATEWAY_UPDATE_HELPER: ${JSON.stringify(helper)}, TRON_GATEWAY_PAYLOAD_ROOT: ${JSON.stringify(payload)}
} });
await unlink(process.execPath);
await service.update({ channel: "dev", mode: "auto", commandId: "fixture-spawn-failure" });
const deadline = Date.now() + 5_000;
for (;;) {
  try { await readFile(${JSON.stringify(join(tronHome, "state/payloads/dev/update-progress.json"))}); break; }
  catch (error) { if (error.code !== "ENOENT" || Date.now() >= deadline) throw error; }
  await new Promise(resolve => setTimeout(resolve, 10));
}
process.stdout.write(JSON.stringify(await service.status("dev")));\n`);
  const { stdout } = await promisify(execFile)(node, ["--experimental-transform-types", "--no-warnings", "--import",
    resolve(import.meta.dirname, "../../../test-support/home-ledger-crash-preload.mjs"), script],
  { timeout: 15_000, env: { PATH: process.env.PATH, HOME: tronHome, TMPDIR: root } });
  expect(JSON.parse(stdout)).toMatchObject({ state: "failure", channel: "dev", commandId: "fixture-spawn-failure", error: expect.stringContaining("ENOENT") });
  expect((await stat(join(tronHome, "state/payloads/dev/update-progress.json"))).mode & 0o777).toBe(0o600);
  await expect(stat(join(tronHome, "gateway"))).rejects.toThrow(/ENOENT/u);
});

it("all rebuilds share repository identity, preserve invalid-path errors, and reject linked markers", async () => {
  const { root, update, install, mac } = await fixture();
  const sourceRoot = join(root, "checkout");
  for (const marker of ["packages/gateway/package.json", "packages/ios-app/project.yml", "scripts/tron"]) {
    await mkdir(dirname(join(sourceRoot, marker)), { recursive: true });
    await writeFile(join(sourceRoot, marker), "identity fixture\n");
  }
  await update.configure({ sourceRoot });
  await install.configure({ deviceId, sourceRoot });
  const marker = join(sourceRoot, "packages/ios-app/project.yml");
  await rm(marker);
  for (const read of [() => update.configStatus(), () => install.configStatus(deviceId), () => mac.plan()]) {
    await expect(read()).rejects.toThrow(sourceRoot);
    await expect(read()).rejects.toThrow("packages/ios-app/project.yml");
  }
  await writeFile(join(root, "linked-project.yml"), "linked\n");
  await symlink(join(root, "linked-project.yml"), marker);
  await expect(update.configStatus()).rejects.toThrow(sourceRoot);
  await expect(install.configStatus(deviceId)).rejects.toThrow(sourceRoot);
  await rm(sourceRoot, { recursive: true });
  await expect(update.configStatus()).rejects.toThrow(sourceRoot);
});

it("Gateway and Mac replacement RPCs return the same invalid repository diagnosis, not missing configuration", async () => {
  const gateway = await startLockGateway("source-repository");
  try {
    const sourceRoot = await realpath(gateway.cwd);
    await mkdir(join(gateway.tronHome, "state"), { recursive: true });
    await writeFile(join(gateway.tronHome, "state", "update-config.json"), JSON.stringify({
      schema: 1, kind: "tron-gateway-update-config", sourceRoot, updatedAt: "2026-10-30T00:00:00.000Z",
    }));
    const phone = await gateway.connect("phone");
    const update = await phone.request("gateway.update.config.status", {});
    const replacement = await phone.request("mac.replace.plan", {});
    expect(update.ok).toBe(false);
    expect(replacement.ok).toBe(false);
    expect(update.error.message).toContain(sourceRoot);
    expect(update.error.message).toContain("packages/gateway/package.json");
    expect(replacement.error).toEqual(update.error);
  } finally {
    await gateway.dispose();
  }
});
