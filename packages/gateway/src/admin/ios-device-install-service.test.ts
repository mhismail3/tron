import { chmod, mkdtemp, mkdir, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  IosDeviceInstallService,
  admitDevicectlTargets,
  iosDeviceInstallHelperEnvironment,
  iosDeviceInstallInvocation,
  projectIosDeviceInstallConfig,
  recordIosDeviceInstallHelperFailure,
  type IosPhysicalDeviceTarget,
} from "./ios-device-install-service.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { GatewayUpdateService } from "./gateway-update-service.js";

const roots: string[] = [];
const target: IosPhysicalDeviceTarget = {
  identifier: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
  name: "Development iPhone",
  deviceType: "iPhone",
  connectionState: "connected",
  developerModeEnabled: true,
};

async function fixture() {
  const tronHome = await mkdtemp(join(tmpdir(), "tron-ios-install-home-"));
  const sourcePath = await mkdtemp(join(tmpdir(), "tron-ios-install-source-"));
  const source = await realpath(sourcePath);
  roots.push(tronHome, source);
  for (const path of [
    "packages/ios-app/project.yml",
    "config/ci-toolchain.env",
    "scripts/tron-ios-device",
    "scripts/validate-ios-artifact.py",
    "scripts/verify-gateway-protocol-contract.py",
  ]) {
    await mkdir(join(source, path, ".."), { recursive: true });
    await writeFile(join(source, path), "fixture\n");
  }
  const launched: Array<{ tronHome: string; deviceId: string; commandId: string }> = [];
  const service = new IosDeviceInstallService({
    tronHome,
    gatewayChannel: "stable",
    discoverer: async () => [target],
    launcher: async (request) => { launched.push(request); },
  });
  return { tronHome, source, service, launched };
}

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("IosDeviceInstallService", () => {
  it("admits only bounded physical iOS discovery fields", () => {
    const parsed = admitDevicectlTargets({
      result: {
        devices: [{
          identifier: target.identifier,
          properties: {
            hardware: { platform: "iOS", reality: "physical", deviceType: "iPhone", serialNumber: "never-project" },
            state: { name: target.name },
            connection: { state: "connected" },
          },
          deviceProperties: { developerModeStatus: "enabled" },
          hardwareProperties: { udid: "never-project" },
        }, {
          identifier: "11111111-2222-3333-4444-555555555555",
          properties: {
            hardware: { platform: "macOS", reality: "physical", deviceType: "Mac" },
            state: { name: "Mac" },
          },
        }],
      },
    });
    expect(parsed).toEqual([target]);
    expect(JSON.stringify(parsed)).not.toContain("never-project");
  });

  it("fixes the repository helper to the ordinary LocalDevice install operation", () => {
    expect(iosDeviceInstallInvocation("/trusted/tron", target.identifier)).toEqual({
      executable: "/bin/bash",
      args: ["/trusted/tron/scripts/tron-ios-device", "install", "--device-id", target.identifier],
      cwd: "/trusted/tron",
    });
  });

  it("keeps CoreDevice identity owner-only while auto-binding the sole eligible device", async () => {
    const { source, service } = await fixture();
    const configured = await service.configure({ deviceId: "device-alpha", sourceRoot: source });
    expect(configured.target).toBeUndefined();

    await service.install("device-alpha", "command-install-1");
    const bound = await service.configStatus("device-alpha");
    expect(bound?.target?.identifier).toBe(target.identifier);
    const projection = projectIosDeviceInstallConfig(bound!);
    expect(projection.target).toEqual(expect.objectContaining({ name: target.name }));
    expect(JSON.stringify(projection)).not.toContain(target.identifier);
  });

  it("fails closed instead of guessing when multiple eligible physical devices exist", async () => {
    const { source, tronHome } = await fixture();
    const other = { ...target, identifier: "11111111-2222-3333-4444-555555555555", name: "Other iPhone" };
    const ambiguous = new IosDeviceInstallService({
      tronHome,
      discoverer: async () => [target, other],
      launcher: async () => {},
    });
    await ambiguous.configure({ deviceId: "device-alpha", sourceRoot: source });
    await expect(ambiguous.install("device-alpha", "command-install-1"))
      .rejects.toMatchObject({ code: "conflict", retryable: true });
  });

  it("admits one detached fixed install and exposes durable requested status", async () => {
    const { source, service, launched, tronHome } = await fixture();
    await service.configure({ deviceId: "device-alpha", sourceRoot: source });

    await expect(service.install("device-alpha", "command-install-1")).resolves.toEqual({
      accepted: true,
      commandId: "command-install-1",
      state: "install-requested",
    });
    expect(launched).toEqual([{ tronHome, deviceId: "device-alpha", commandId: "command-install-1" }]);
    await expect(service.status("device-alpha")).resolves.toEqual(expect.objectContaining({
      state: "requested",
      targetName: target.name,
      commandId: "command-install-1",
    }));
    await expect(service.install("device-alpha", "command-install-2"))
      .rejects.toMatchObject({ code: "busy", retryable: true });
  });

  it("recovers a generated multiline install failure as a bounded projection", async () => {
    const { tronHome, service } = await fixture();
    const statusDirectory = join(tronHome, "gateway", "ios-device-installs", "status");
    await mkdir(statusDirectory, { recursive: true });
    const statusFile = join(statusDirectory, "device-alpha.json");
    await writeFile(statusFile, JSON.stringify({
      schema: 1,
      kind: "tron-ios-device-install-status",
      deviceId: "device-alpha",
      state: "failed",
      commandId: "command-install-1",
      targetName: target.name,
      startedAt: "2026-08-31T00:00:00.000Z",
      updatedAt: "2026-08-31T00:00:01.000Z",
      error: "first build failure\nsecond build failure\twith detail",
    }), { mode: 0o600 });
    await chmod(statusFile, 0o600);

    await expect(service.status("device-alpha")).resolves.toEqual(expect.objectContaining({
      state: "failed",
      error: "first build failure second build failure with detail",
    }));
  });

  it("persists detached helper failures in the status projection's own admission language", async () => {
    const { source, tronHome, service } = await fixture();
    await service.configure({ deviceId: "device-alpha", sourceRoot: source });
    await service.install("device-alpha", "command-install-1");

    await recordIosDeviceInstallHelperFailure(
      tronHome,
      "device-alpha",
      "command-install-1",
      new Error("first helper line\nsecond helper line\twith detail"),
    );

    await expect(service.status("device-alpha")).resolves.toEqual(expect.objectContaining({
      state: "failed",
      error: "first helper line second helper line with detail",
    }));
  });

  it("passes the immutable payload XcodeGen to the detached install helper", async () => {
    const { source, service } = await fixture();
    const config = await service.configure({ deviceId: "device-alpha", sourceRoot: source });
    const toolRoot = await mkdtemp(join(tmpdir(), "tron-ios-install-toolchain-"));
    roots.push(toolRoot);
    const runtime = join(toolRoot, "runtime", "node-arm64");
    const xcodegen = join(toolRoot, "runtime", "xcodegen", "bin", "xcodegen");
    await mkdir(join(toolRoot, "runtime", "xcodegen", "bin"), { recursive: true });
    await writeFile(runtime, "runtime\n");
    await writeFile(xcodegen, "tool\n");
    await chmod(xcodegen, 0o755);

    const environment = iosDeviceInstallHelperEnvironment(
      config,
      { PATH: "/usr/bin:/bin", HOME: "/Users/example", TRON_XCODEGEN: "/untrusted/ambient" },
      runtime,
    );
    expect(environment.TRON_XCODEGEN).toBe(xcodegen);
    expect(environment.PATH).toBe("/usr/bin:/bin");
    expect(environment.TRON_IOS_GATEWAY_PROTOCOL_TARGET).toBe("stable");
  });

  it("projects only opaque targets through paired-device receipt-backed RPC", async () => {
    const { source, service, tronHome } = await fixture();
    const update = vi.fn(async () => ({ accepted: true }));
    const gateway = new GatewayService({
      config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome },
      updateService: new GatewayUpdateService({ tronHome, updater: update }),
      iosDeviceInstallService: service,
      devices: { hasDevice: async (deviceId: string) => deviceId === "device-alpha" },
      receipts: {
        execute: async (_identity: string, _method: string, _commandId: string, operation: () => Promise<unknown>) => operation(),
      },
    } as unknown as GatewayServiceDependencies);
    const client: ClientContext = {
      id: "phone", identity: "device-alpha", isLocal: false,
      beginSynchronization: () => "sync", establishSynchronization: () => {}, completeSynchronization: () => {},
      setPresentationVisibility: () => ({ visible: true, revision: 1 }), unsubscribe: () => true,
      attachTerminal: () => {}, detachTerminal: () => {}, ownsTerminal: () => false,
    };
    expect((gateway.info() as Record<string, unknown>).capabilities).toContain("ios-device-install.v2");
    const configured = await gateway.invoke(client, "device.install.config", {
      commandId: "command-config-1", deviceId: "device-alpha", sourceRoot: source,
    });
    expect(JSON.stringify(configured)).not.toContain(target.identifier);
    await expect(gateway.invoke(client, "device.install", {
      commandId: "command-install-1", deviceId: "device-alpha",
    })).resolves.toMatchObject({ accepted: true, state: "install-requested" });
    await expect(gateway.invoke(client, "device.install.config.status", { deviceId: "unknown-device" }))
      .rejects.toMatchObject({ code: "not_found" });
    await expect(gateway.invoke(client, "gateway.update", {
      commandId: "command-update-1", channel: "stable", mode: "source",
    })).rejects.toMatchObject({ code: "busy", retryable: true });
    expect(update).not.toHaveBeenCalled();
  });

  it("fails closed for incomplete, linked, and unsupervised configuration", async () => {
    const { source, service, tronHome } = await fixture();
    await expect(service.install("device-alpha", "command-install-1"))
      .rejects.toMatchObject({ code: "conflict" });

    const linked = `${source}-link`;
    roots.push(linked);
    await symlink(source, linked);
    await expect(service.configure({ deviceId: "device-alpha", sourceRoot: linked }))
      .rejects.toMatchObject({ code: "conflict" });

    await rm(join(source, "config", "ci-toolchain.env"));
    await expect(service.configure({ deviceId: "device-beta", sourceRoot: source }))
      .rejects.toMatchObject({ code: "conflict" });

    const unsupported = new IosDeviceInstallService({ tronHome, launcher: false, discoverer: vi.fn() });
    await expect(unsupported.configure({ deviceId: "device-alpha", sourceRoot: source }))
      .rejects.toMatchObject({ code: "unsupported" });
  });
});
