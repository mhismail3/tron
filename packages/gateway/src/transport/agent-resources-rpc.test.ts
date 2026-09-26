import { describe, expect, it, vi } from "vitest";
import { TRON_MODULES } from "../extensions/tron-modules.js";
import type { HookRegistrationProjection } from "../sessions/hook-projection.js";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "./gateway-service.js";

const client: ClientContext = {
  id: "settings", identity: "device:settings", isLocal: false, signal: undefined,
  beginSynchronization: () => "sync", establishSynchronization: () => {}, completeSynchronization: () => {},
  setPresentationVisibility: () => ({ visible: true, revision: 1 }), unsubscribe: () => false,
  attachTerminal: () => {}, detachTerminal: () => {}, ownsTerminal: () => false,
  isSubscribed: () => true, isRevoked: () => false, revokeDevice: () => {},
};

function mcpInstance(id: string, overrides: Record<string, unknown> = {}) {
  return {
    id, definitionId: "mcp.remote-http", implementation: "mcp", providerAccountId: id,
    policy: { enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0 },
    health: "ready", createdAt: "2026-09-25T00:00:00.000Z", updatedAt: "2026-09-25T00:00:00.000Z",
    setupRevision: 1, credentialConfigured: false, credentialAvailability: "unknown", providerIdentity: "unknown",
    ...overrides,
  };
}

const emptyHooks: HookRegistrationProjection = {
  extensions: [],
  extensionLoadErrors: [],
  hookInventory: {
    extensions: { total: 0, retained: 0, omitted: 0 },
    handlerEvents: { total: 0, retained: 0, omitted: 0 },
    loadErrors: { total: 0, retained: 0, omitted: 0 },
    textFieldsOmitted: 0,
    encodedBytes: 24,
    encodedBytesLimit: 256 * 1_024,
  },
};

function service() {
  const openSession = vi.fn(async () => { throw new Error("Agent resource reads must not open a session"); });
  const connectionSnapshot = vi.fn(async () => ({
    definitions: [], setupOperations: [], capabilities: [], stateRevision: 1,
    instances: [
      mcpInstance("mcp-a"),
      mcpInstance("mcp-disabled", { policy: { enabled: false, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0 } }),
      mcpInstance("mcp-disconnected", { health: "disconnected" }),
      mcpInstance("raindrop-a", { definitionId: "knowledge.raindrop", implementation: "knowledge-connector" }),
    ],
  }));
  const listHooks = vi.fn(async () => emptyHooks);
  const dependencies = {
    config: { machineId: "machine", machineName: "Mac", tronHome: "/tmp/tron-agent-resources-rpc" },
    updateService: { channel: "stable", isUsable: false },
    iosDeviceInstallService: { isUsable: false },
    sessions: { acquire: openSession },
    connections: { snapshot: connectionSnapshot },
    hookResources: { list: listHooks },
  } as unknown as GatewayServiceDependencies;
  return { instance: new GatewayService(dependencies), connectionSnapshot, openSession, listHooks };
}

describe("Tron module listing RPC", () => {
  it("reports the one Tron module definition as read-only Settings data", async () => {
    const fixture = service();
    const result = (await fixture.instance.invoke(client, "modules.list", {})) as any;
    expect(result.modules).toEqual(TRON_MODULES.map((tronModule) => ({
      name: tronModule.name,
      purpose: tronModule.purpose,
      tools: [...tronModule.tools],
      commands: [...tronModule.commands],
    })));
    expect(result.modules).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "tron-core", tools: ["knowledge", "connections", "jev"], commands: [] }),
      // A module may own only hooks: it is still listed, with no tools.
      expect.objectContaining({ name: "tron-context-window", tools: [], commands: [] }),
    ]));
    for (const listed of result.modules) {
      expect(listed.purpose.length).toBeGreaterThan(0);
      expect(listed.commands).toEqual([]);
    }
    expect(fixture.openSession).not.toHaveBeenCalled();
  });

  it("lists the MCP instances a session would admit, and nothing else", async () => {
    const fixture = service();
    const result = (await fixture.instance.invoke(client, "modules.list", {})) as any;
    expect(result.connections).toEqual([{ id: "mcp-a", definitionId: "mcp.remote-http", health: "ready" }]);
    expect(fixture.connectionSnapshot).toHaveBeenCalledTimes(1);
    expect(fixture.openSession).not.toHaveBeenCalled();
  });

  it("reports no tool source when the connections owner is unconfigured", async () => {
    const instance = new GatewayService({
      config: { machineId: "machine", machineName: "Mac", tronHome: "/tmp/tron-agent-resources-rpc" },
      updateService: { channel: "stable", isUsable: false },
      iosDeviceInstallService: { isUsable: false },
    } as unknown as GatewayServiceDependencies);
    await expect(instance.invoke(client, "modules.list", {})).resolves.toMatchObject({ connections: [] });
  });

  it("advertises both listing capabilities under the existing additive naming", () => {
    const capabilities = (service().instance.info() as any).capabilities as string[];
    expect(capabilities).toContain("modules.v1");
    expect(capabilities).toContain("hooks.v1");
  });

  it("rejects parameters it does not define", async () => {
    await expect(service().instance.invoke(client, "modules.list", { cwd: "/tmp/project" }))
      .rejects.toMatchObject({ code: "invalid_request" });
  });
});

describe("session-free hook listing RPC", () => {
  it("passes the requested scope to the hook owner and returns its projection unchanged", async () => {
    const fixture = service();
    await expect(fixture.instance.invoke(client, "hooks.list", {})).resolves.toEqual(emptyHooks);
    expect(fixture.listHooks).toHaveBeenLastCalledWith(undefined);
    await expect(fixture.instance.invoke(client, "hooks.list", { cwd: "/tmp/project" })).resolves.toEqual(emptyHooks);
    expect(fixture.listHooks).toHaveBeenLastCalledWith("/tmp/project");
    expect(fixture.openSession).not.toHaveBeenCalled();
  });

  it("rejects unknown, missing and oversized scope parameters without loading hooks", async () => {
    const fixture = service();
    await expect(fixture.instance.invoke(client, "hooks.list", { scope: "global" }))
      .rejects.toMatchObject({ code: "invalid_request" });
    await expect(fixture.instance.invoke(client, "hooks.list", { cwd: 4 }))
      .rejects.toMatchObject({ code: "invalid_request" });
    await expect(fixture.instance.invoke(client, "hooks.list", { cwd: "x".repeat(5_000) }))
      .rejects.toMatchObject({ code: "invalid_request" });
    expect(fixture.listHooks).not.toHaveBeenCalled();
  });
});
