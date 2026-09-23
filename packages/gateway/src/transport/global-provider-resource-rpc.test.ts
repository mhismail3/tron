import { describe, expect, it, vi } from "vitest";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "./gateway-service.js";

const client: ClientContext = {
  id: "dashboard", identity: "device:dashboard", isLocal: false, signal: undefined,
  beginSynchronization: () => "sync", establishSynchronization: () => {}, completeSynchronization: () => {},
  setPresentationVisibility: () => ({ visible: true, revision: 1 }), unsubscribe: () => false,
  attachTerminal: () => {}, detachTerminal: () => {}, ownsTerminal: () => false,
  isSubscribed: () => true, isRevoked: () => false, revokeDevice: () => {},
};

function service() {
  const requestReload = vi.fn();
  const settings = { update: vi.fn(async () => ({ updated: true })) };
  const packages = { mutate: vi.fn(async () => ({ operationId: "operation" })) };
  const trust = {
    canonicalDirectory: async (cwd: string) => cwd,
    requireResolved: async (cwd: string) => ({ cwd, trusted: true }),
  };
  const instance = new GatewayService({
    config: { machineId: "machine", machineName: "Mac", tronHome: "/tmp/tron-provider-resources" },
    modelRuntime: {}, settings, packages, trust,
    globalProviderResources: { requestReload },
    sessions: { refreshCompactionPolicies: vi.fn() },
    receipts: { execute: async (_owner: string, _method: string, _commandId: string, operation: () => Promise<unknown>) => operation() },
    broadcast: vi.fn(),
  } as unknown as GatewayServiceDependencies);
  return { instance, requestReload, settings, packages };
}

describe("global provider resource invalidation RPC", () => {
  it("reloads the global provider runtime after global resource settings change only", async () => {
    const f = service();
    await f.instance.invoke(client, "settings.update", {
      commandId: "settings-global-1", scope: "global", cwd: "/tmp/project", patch: { packages: ["npm:provider"] },
    });
    expect(f.requestReload).toHaveBeenCalledTimes(1);

    await f.instance.invoke(client, "settings.update", {
      commandId: "settings-project-1", scope: "project", cwd: "/tmp/project", patch: { packages: ["npm:project-provider"] },
    });
    expect(f.requestReload).toHaveBeenCalledTimes(1);
  });

  it("reloads after user package mutations but keeps project package installs isolated", async () => {
    const f = service();
    await f.instance.invoke(client, "packages.install", {
      commandId: "packages-global-1", cwd: "/tmp/project", source: "npm:provider", local: false,
    });
    expect(f.requestReload).toHaveBeenCalledTimes(1);

    await f.instance.invoke(client, "packages.install", {
      commandId: "packages-project-1", cwd: "/tmp/project", source: "npm:project-provider", local: true,
    });
    expect(f.requestReload).toHaveBeenCalledTimes(1);
  });
});
