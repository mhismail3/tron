import { mkdir, mkdtemp, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { afterEach, expect, it } from "vitest";
import { GatewayUpdateService } from "./gateway-update-service.js";
import { IosDeviceInstallService } from "./ios-device-install-service.js";
import { MacReplaceService } from "./mac-replace-service.js";
import { startLockGateway } from "../../test-support/gateway-lock-harness.js";

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
  const sourceRoot = await realpath(resolve(import.meta.dirname, "../../../.."));
  expect((await update.configure({ sourceRoot })).sourceRoot).toBe(sourceRoot);
  expect((await install.configure({ deviceId, sourceRoot })).sourceRoot).toBe(sourceRoot);
  expect((await update.configStatus())?.sourceRoot).toBe(sourceRoot);
  expect((await install.configStatus(deviceId))?.sourceRoot).toBe(sourceRoot);
});

it("all rebuilds share repository identity, preserve invalid-path errors, and reject linked markers", async () => {
  const { root, update, install, mac } = await fixture();
  const sourceRoot = join(root, "checkout");
  // Repository identity is not a promise that every operation's helper exists.
  // Those helpers evolve independently of an already-installed Gateway.
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
    await mkdir(join(gateway.tronHome, "gateway"), { recursive: true });
    await writeFile(join(gateway.tronHome, "gateway/update-config.json"), JSON.stringify({
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
