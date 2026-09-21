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
  const launched: Array<{ tronHome: string; deviceId: string; commandId: string; buildMode: "fast-debug" | "optimized" }> = [];
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
    expect(iosDeviceInstallInvocation("/trusted/tron", target.identifier, "optimized")).toEqual({
      executable: "/bin/bash",
      args: ["/trusted/tron/scripts/tron-ios-device", "install", "--device-id", target.identifier],
      cwd: "/trusted/tron",
    });
    expect(iosDeviceInstallInvocation("/trusted/tron", target.identifier, "fast-debug").args)
      .toEqual(["/trusted/tron/scripts/tron-ios-device", "install", "--device-id", target.identifier, "--fast-debug"]);
  });

  it("keeps CoreDevice identity owner-only while requiring an explicit Mac-local binding", async () => {
    const { source, service } = await fixture();
    const configured = await service.configure({ deviceId: "device-alpha", sourceRoot: source });
    expect(configured.target).toBeUndefined();
    await expect(service.install("device-alpha", "command-install-1", "optimized"))
      .rejects.toMatchObject({ code: "conflict", retryable: true });

    const bound = await service.bindTarget("device-alpha", target.identifier);
    expect(bound.target?.identifier).toBe(target.identifier);
    await service.install("device-alpha", "command-install-1", "optimized");
    const projection = projectIosDeviceInstallConfig(bound);
    expect(projection.target).toEqual(expect.objectContaining({ name: target.name }));
    expect(JSON.stringify(projection)).not.toContain(target.identifier);
  });

  it("rejects an explicit binding when the requested device is unavailable", async () => {
    const { source, service, tronHome } = await fixture();
    await service.configure({ deviceId: "device-alpha", sourceRoot: source });
    const disconnected = { ...target, connectionState: "disconnected" };
    const unavailable = new IosDeviceInstallService({
      tronHome,
      discoverer: async () => [disconnected],
      launcher: async () => {},
    });
    await expect(unavailable.bindTarget("device-alpha", target.identifier))
      .rejects.toMatchObject({ code: "not_found", retryable: true });
  });

  it("never substitutes a newly discovered device for a missing binding", async () => {
    const { source, service, tronHome } = await fixture();
    await service.configure({ deviceId: "device-alpha", sourceRoot: source });
    await service.bindTarget("device-alpha", target.identifier);
    const replacement = { ...target, identifier: "11111111-2222-3333-4444-555555555555", name: "Replacement iPhone" };
    const unavailable = new IosDeviceInstallService({
      tronHome,
      discoverer: async () => [replacement],
      launcher: async () => {},
    });
    await expect(unavailable.install("device-alpha", "command-install-1", "optimized"))
      .rejects.toMatchObject({ code: "not_found", retryable: true });
  });

  it("admits one detached fixed install and exposes durable requested status", async () => {
    const { source, service, launched, tronHome } = await fixture();
    await service.configure({ deviceId: "device-alpha", sourceRoot: source });

    await service.bindTarget("device-alpha", target.identifier);
    await expect(service.install("device-alpha", "command-install-1", "optimized")).resolves.toEqual({
      accepted: true,
      commandId: "command-install-1",
      state: "install-requested",
      buildMode: "optimized",
    });
    expect(launched).toEqual([{ tronHome, deviceId: "device-alpha", commandId: "command-install-1", buildMode: "optimized" }]);
    await expect(service.status("device-alpha")).resolves.toEqual(expect.objectContaining({
      state: "requested",
      targetName: target.name,
      commandId: "command-install-1",
    }));
    await expect(service.install("device-alpha", "command-install-2", "optimized"))
      .rejects.toMatchObject({ code: "busy", retryable: true });
  });

  it("selects the explicit target among multiple devices and preserves it across source configuration", async () => {
    const { source, tronHome } = await fixture();
    const other = { ...target, identifier: "11111111-2222-3333-4444-555555555555" };
    const launched = vi.fn(async () => {});
    const service = new IosDeviceInstallService({ tronHome, discoverer: async () => [other, target], launcher: launched });
    await service.configure({ deviceId: "device-alpha", sourceRoot: source });
    await service.bindTarget("device-alpha", target.identifier);
    const configured = await service.configure({ deviceId: "device-alpha", sourceRoot: source });
    expect(configured.target?.identifier).toBe(target.identifier);
    await service.install("device-alpha", "command-install-1", "optimized");
    expect(launched).toHaveBeenCalledOnce();
    await expect(service.bindTarget("device-alpha", other.identifier)).rejects.toMatchObject({ code: "busy" });
    expect((await service.configStatus("device-alpha"))?.target?.identifier).toBe(target.identifier);
    await service.removeDevice("device-alpha");
    expect(await service.configStatus("device-alpha")).toBeNull();
  });

  it.each([
    { connectionState: "disconnected", developerModeEnabled: true },
    { connectionState: "connected", developerModeEnabled: false },
  ])("rejects unavailable bound targets without launching: %j", async (state) => {
    const { source, tronHome, service } = await fixture();
    await service.configure({ deviceId: "device-alpha", sourceRoot: source });
    await service.bindTarget("device-alpha", target.identifier);
    const launched = vi.fn(async () => {});
    const unavailable = new IosDeviceInstallService({
      tronHome, discoverer: async () => [{ ...target, ...state }], launcher: launched,
    });
    await expect(unavailable.install("device-alpha", "command-install-1", "optimized"))
      .rejects.toMatchObject({ code: "not_found" });
    expect(launched).not.toHaveBeenCalled();
    expect((await unavailable.configStatus("device-alpha"))?.target?.identifier).toBe(target.identifier);
  });

  it("round-trips each build mode through requested status and active ownership", async () => {
    for (const buildMode of ["fast-debug", "optimized"] as const) {
      const { source, service } = await fixture();
      await service.configure({ deviceId: "device-alpha", sourceRoot: source });
      await service.bindTarget("device-alpha", target.identifier);
      await service.install("device-alpha", `command-${buildMode}`, buildMode);
      await expect(service.status("device-alpha")).resolves.toEqual(expect.objectContaining({
        schema: 2,
        buildMode,
        state: "requested",
        commandId: `command-${buildMode}`,
      }));
      await expect(service.activeStatus()).resolves.toEqual(expect.objectContaining({
        buildMode,
        commandId: `command-${buildMode}`,
      }));
    }
  });

  it("recovers a generated multiline install failure as a bounded projection", async () => {
    const { tronHome, service } = await fixture();
    const statusDirectory = join(tronHome, "gateway", "ios-device-installs", "status");
    await mkdir(statusDirectory, { recursive: true });
    const statusFile = join(statusDirectory, "device-alpha.json");
    await writeFile(statusFile, JSON.stringify({
      schema: 2,
      kind: "tron-ios-device-install-status",
      deviceId: "device-alpha",
      buildMode: "optimized",
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
    await service.bindTarget("device-alpha", target.identifier);
    await service.install("device-alpha", "command-install-1", "optimized");

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
    expect(() => iosDeviceInstallHelperEnvironment(
      config,
      { PATH: "/ambient/bin", TRON_XCODEGEN: "/ambient/bin/xcodegen" },
      join(toolRoot, "ambient-node"),
    )).toThrowError("The supervised Gateway payload is missing its pinned XcodeGen executable");
  });

  it("projects only opaque targets through paired-device receipt-backed RPC", async () => {
    const { source, service, tronHome } = await fixture();
    const update = vi.fn(async () => ({ accepted: true }));
    const gateway = new GatewayService({
      config: { machineId: "machine", machineGroupID: "group", machineName: "Mac", tronHome },
      updateService: new GatewayUpdateService({ tronHome, updater: update }),
      iosDeviceInstallService: service,
      devices: {
        hasDevice: async (deviceId: string) => deviceId === "device-alpha",
        updateObservedName: async () => undefined,
      },
      receipts: {
        execute: async (_identity: string, _method: string, _commandId: string, operation: () => Promise<unknown>) => operation(),
      },
      broadcast: () => {},
    } as unknown as GatewayServiceDependencies);
    const client: ClientContext = {
      id: "phone", identity: "device-alpha", isLocal: false,
      beginSynchronization: () => "sync", establishSynchronization: () => {}, completeSynchronization: () => {},
      setPresentationVisibility: () => ({ visible: true, revision: 1 }), unsubscribe: () => true,
      attachTerminal: () => {}, detachTerminal: () => {}, ownsTerminal: () => false,
      isSubscribed: () => true, isRevoked: () => false, revokeDevice: () => {},
    };
    expect((gateway.info() as Record<string, unknown>).capabilities).toContain("ios-device-install.v3");
    const configured = await gateway.invoke(client, "device.install.config", {
      commandId: "command-config-1", deviceId: "device-alpha", sourceRoot: source,
    });
    expect(JSON.stringify(configured)).not.toContain(target.identifier);
    await expect(gateway.invoke(client, "device.install.target.bind", {
      commandId: "command-bind-1", deviceId: "device-alpha", targetIdentifier: target.identifier,
    })).rejects.toMatchObject({ code: "auth_required" });
    const localClient = { ...client, id: "local", identity: "local-wrapper", isLocal: true };
    const bound = await gateway.invoke(localClient, "device.install.target.bind", {
      commandId: "command-bind-1", deviceId: "device-alpha", targetIdentifier: target.identifier,
    });
    expect(JSON.stringify(bound)).not.toContain(target.identifier);
    await expect(gateway.invoke(client, "device.install", {
      commandId: "command-install-1", deviceId: "device-alpha", buildMode: "optimized",
    })).resolves.toMatchObject({ accepted: true, state: "install-requested", buildMode: "optimized" });
    await expect(gateway.invoke(client, "device.install.config.status", { deviceId: "unknown-device" }))
      .rejects.toMatchObject({ code: "not_found" });
    await expect(gateway.invoke(client, "gateway.update", {
      commandId: "command-update-1", channel: "stable", mode: "source",
    })).rejects.toMatchObject({ code: "busy", retryable: true });
    expect(update).not.toHaveBeenCalled();
  });

  it("fails closed for incomplete, linked, and unsupervised configuration", async () => {
    const { source, service, tronHome } = await fixture();
    await expect(service.install("device-alpha", "command-install-1", "optimized"))
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
