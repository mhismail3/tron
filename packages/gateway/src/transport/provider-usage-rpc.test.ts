import { describe, expect, it, vi } from "vitest";
import { GatewayService, type ClientContext, type GatewayServiceDependencies } from "./gateway-service.js";

const client: ClientContext = {
  id: "phone", identity: "device:phone", isLocal: false, signal: undefined,
  beginSynchronization: () => "sync", establishSynchronization: () => {}, completeSynchronization: () => {},
  setPresentationVisibility: () => ({ visible: true, revision: 1 }), unsubscribe: () => false,
  attachTerminal: () => {}, detachTerminal: () => {}, ownsTerminal: () => false,
  isSubscribed: () => true, isRevoked: () => false, revokeDevice: () => {},
};

describe("provider.usage RPC", () => {
  it("advertises the additive capability and passes the selected runtime", async () => {
    const read = vi.fn(async (_runtime: unknown, providerId?: string) => ({ providers: [{ providerId: providerId ?? "openrouter", status: "available", source: "fixture", scope: "key", updatedAt: null, retryAt: null, stale: false, message: null, windows: [], balances: [] }] }));
    const runtime = {};
    const service = new GatewayService({ config: { machineId: "machine", machineName: "Mac", tronHome: "/tmp/tron-usage-rpc" }, modelRuntime: runtime, providerUsage: { read } } as unknown as GatewayServiceDependencies);
    expect((service.info() as { capabilities: string[] }).capabilities).toContain("provider-usage.v1");
    await expect(service.invoke(client, "provider.usage", { providerId: "openrouter" })).resolves.toMatchObject({ providers: [{ providerId: "openrouter" }] });
    expect(read).toHaveBeenCalledWith(runtime, "openrouter", undefined);
  });

  it("rejects unknown fields and requires an open session for session-scoped reads", async () => {
    const read = vi.fn(async () => ({ providers: [] }));
    const service = new GatewayService({ modelRuntime: {}, providerUsage: { read }, sessions: {} } as unknown as GatewayServiceDependencies);
    await expect(service.invoke(client, "provider.usage", { unexpected: true })).rejects.toMatchObject({ code: "invalid_request" });
    await expect(service.invoke({ ...client, isSubscribed: () => false }, "provider.usage", { sessionId: "closed" })).rejects.toMatchObject({ code: "invalid_request" });
    expect(read).not.toHaveBeenCalled();
  });
});
