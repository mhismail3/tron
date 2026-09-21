import { mkdtemp, mkdir, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DeviceStore } from "../security/device-store.js";
import { IosDeviceInstallService, type IosPhysicalDeviceTarget } from "../admin/ios-device-install-service.js";
import { CommandReceiptStore } from "./command-receipts.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "./gateway-service.js";

const roots: string[] = [];
afterEach(async () => { for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }); });
const phone: IosPhysicalDeviceTarget = {
  identifier: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", name: "Personal Phone",
  deviceType: "iPhone", connectionState: "connected", developerModeEnabled: true,
};
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}
async function fixture() {
  const root = await realpath(await mkdtemp(join(tmpdir(), "tron-device-names-")));
  roots.push(root);
  const source = join(root, "source");
  for (const path of ["packages/ios-app/project.yml", "config/ci-toolchain.env", "scripts/tron-ios-device",
    "scripts/validate-ios-artifact.py", "scripts/verify-gateway-protocol-contract.py"]) {
    await mkdir(join(source, path, ".."), { recursive: true });
    await writeFile(join(source, path), "fixture");
  }
  const devices = new DeviceStore(root, "machine");
  await devices.initialize();
  const paired = await devices.pair((await devices.ensureEnrollment()).code, "iPhone");
  const discoverer = vi.fn(async () => [{ ...phone }]);
  const launcher = vi.fn(async () => {});
  const install = new IosDeviceInstallService({ tronHome: root, discoverer, launcher });
  await install.configure({ deviceId: paired.deviceId, sourceRoot: source });
  const broadcast = vi.fn();
  const service = new GatewayService({ config: { tronHome: root }, devices,
    sessions: {}, receipts: new CommandReceiptStore(root), iosDeviceInstallService: install, broadcast,
  } as unknown as GatewayServiceDependencies);
  const client: ClientContext = {
    id: "phone", identity: paired.deviceId, isLocal: false,
    beginSynchronization: () => "sync", establishSynchronization() {}, completeSynchronization() {},
    setPresentationVisibility: (_session, _token, revision, visible) => ({ revision, visible }),
    unsubscribe: () => true, attachTerminal() {}, detachTerminal() {}, ownsTerminal: () => false,
    isSubscribed: () => true, isRevoked: () => false, revokeDevice() {},
  };
  const local = { ...client, id: "local", identity: "local-wrapper", isLocal: true };
  let next = 0;
  const bind = (identifier = phone.identifier) => service.invoke(local, "device.install.target.bind", {
    commandId: `bind-command-${++next}`, deviceId: paired.deviceId, targetIdentifier: identifier,
  });
  const runInstall = () => service.invoke(client, "device.install", {
    commandId: `install-command-${++next}`, deviceId: paired.deviceId, buildMode: "optimized",
  });
  return { devices, paired, discoverer, launcher, install, broadcast, service, client, local, bind, runInstall };
}

describe("authorized device naming", () => {
  it("keeps identity private and stable through binding, labels, reset, and duplicate receipts", async () => {
    const f = await fixture();
    const before = await f.devices.authenticateAndAdmit(f.paired.token, (identity) => identity);
    const bound = await f.bind();
    expect(JSON.stringify(bound)).not.toContain(phone.identifier);
    expect(await f.devices.listDevices()).toEqual([expect.objectContaining({ name: phone.name })]);
    const request = { commandId: "custom-label-command", deviceId: f.paired.deviceId, label: " Work phone " };
    await expect(f.service.invoke(f.client, "device.label", request)).resolves.toMatchObject({ name: "Work phone", customLabel: "Work phone" });
    const count = f.broadcast.mock.calls.length;
    await f.service.invoke(f.client, "device.label", request);
    expect(f.broadcast).toHaveBeenCalledTimes(count);
    f.discoverer.mockResolvedValue([{ ...phone, name: "Renamed Phone" }]);
    await f.runInstall();
    expect((await f.devices.listDevices())[0]?.name).toBe("Work phone");
    await expect(f.service.invoke(f.client, "device.label", {
      commandId: "reset-label-command", deviceId: f.paired.deviceId, label: null,
    })).resolves.toMatchObject({ name: "Renamed Phone" });
    expect(await f.devices.authenticateAndAdmit(f.paired.token, (identity) => identity)).toEqual(before);
    expect((await f.install.configStatus(f.paired.deviceId))?.target?.identifier).toBe(phone.identifier);
    const projection = JSON.stringify(await f.devices.listDevices());
    expect(projection).not.toContain("tokenHash");
    expect(projection).not.toContain(phone.identifier);
    expect(f.broadcast.mock.calls.every(([topic]) => topic === "devices.changed")).toBe(true);
  });

  it("retains the last observed name offline and never matches a same-named replacement", async () => {
    const f = await fixture();
    await f.bind();
    f.discoverer.mockResolvedValue([{ ...phone, connectionState: "disconnected", name: "Stale Offline Name" }]);
    await expect(f.runInstall()).rejects.toMatchObject({ code: "not_found" });
    f.discoverer.mockResolvedValue([{ ...phone, identifier: "11111111-2222-3333-4444-555555555555" }]);
    await expect(f.runInstall()).rejects.toMatchObject({ code: "not_found" });
    expect((await f.devices.listDevices())[0]?.name).toBe(phone.name);
    expect(f.launcher).not.toHaveBeenCalled();
  });

  it.each(["", "   ", "bad\u0000name", "\u0085", "\u200b", "界".repeat(107)])("rejects malformed labels: %j", async (label) => {
    const f = await fixture();
    await expect(f.service.invoke(f.client, "device.label", {
      commandId: "invalid-label-command", deviceId: f.paired.deviceId, label,
    })).rejects.toMatchObject({ code: "invalid_request" });
    expect((await f.devices.listDevices())[0]?.name).toBe("iPhone");
    expect(f.broadcast).not.toHaveBeenCalled();
  });

  it("serializes competing bindings so delayed discovery cannot overwrite the newer name", async () => {
    const f = await fixture();
    const entered = deferred<void>();
    const discovery = deferred<IosPhysicalDeviceTarget[]>();
    const other = { ...phone, identifier: "11111111-2222-3333-4444-555555555555", name: "Other Phone" };
    f.discoverer.mockImplementationOnce(() => { entered.resolve(); return discovery.promise; });
    const first = f.bind();
    await entered.promise;
    f.discoverer.mockResolvedValue([other]);
    const second = f.bind(other.identifier);
    discovery.resolve([phone]);
    await Promise.all([first, second]);
    expect((await f.devices.listDevices())[0]?.name).toBe(other.name);
    expect((await f.install.configStatus(f.paired.deviceId))?.target?.identifier).toBe(other.identifier);
  });

  it("serializes revocation after in-flight discovery and cannot resurrect naming or binding", async () => {
    const f = await fixture();
    const entered = deferred<void>();
    const discovery = deferred<IosPhysicalDeviceTarget[]>();
    f.discoverer.mockImplementationOnce(() => { entered.resolve(); return discovery.promise; });
    const binding = f.bind();
    await entered.promise;
    const revocation = f.service.invoke(f.local, "device.revoke", {
      commandId: "revoke-name-command", deviceId: f.paired.deviceId,
    });
    discovery.resolve([phone]);
    await binding;
    await revocation;
    expect(await f.devices.listDevices()).toEqual([]);
    expect(await f.install.configStatus(f.paired.deviceId)).toBeNull();
    expect(await f.devices.updateObservedName(f.paired.deviceId, "Late Phone")).toBe(false);
    await expect(f.bind()).rejects.toMatchObject({ code: "not_found" });
  });
});
