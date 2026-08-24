import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { GatewayService, type ClientContext } from "../transport/gateway-service.js";

const client = (isLocal = false): ClientContext => ({
  id: "connection", identity: isLocal ? "local-wrapper" : "device_abcdefgh", isLocal,
  beginSynchronization: () => "sync", establishSynchronization() {}, completeSynchronization() {}, unsubscribe: () => true,
  attachTerminal() {}, detachTerminal() {}, ownsTerminal: () => false,
});

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-push-rpc-"));
  const calls: any[] = [];
  const notifications = {
    async upsertGrant(input: unknown) { calls.push(["upsert", input]); return { registered: true }; },
    async removeDevice(id: string) { calls.push(["remove", id]); return true; },
    async status(id?: string) { calls.push(["status", id]); return { registered: true }; },
  };
  const devices = { revoke: vi.fn(async () => true) };
  const service = new GatewayService({
    config: { tronHome: root }, notifications, devices,
    receipts: { execute: async (_identity: string, _method: string, _command: string, operation: () => Promise<unknown>) => operation() },
    deviceRevoked() {},
  } as any);
  return { service, calls, devices };
}

describe("Gateway push registration RPC", () => {
  it("binds an exact registration to the authenticated mobile device", async () => {
    const { service, calls } = await fixture();
    await service.invoke(client(), "push.registration.upsert", {
      commandId: "command-1", installationId: "install_abcdefgh", grantId: "grant_abcdefgh",
      secret: Buffer.alloc(32, 1).toString("base64url"), environment: "sandbox", previewsEnabled: false,
    });
    expect(calls[0][1]).toMatchObject({ deviceId: "device_abcdefgh", grantId: "grant_abcdefgh", previewsEnabled: false });
    await expect(service.invoke(client(), "push.registration.upsert", {
      commandId: "command-2", deviceId: "forged-device", installationId: "install_abcdefgh", grantId: "grant_abcdefgh",
      secret: Buffer.alloc(32, 1).toString("base64url"), environment: "sandbox", previewsEnabled: false,
    })).rejects.toMatchObject({ code: "invalid_request" });
  });

  it("denies local-wrapper registration and scopes status/removal to the remote identity", async () => {
    const { service, calls } = await fixture();
    await expect(service.invoke(client(true), "push.registration.upsert", { commandId: "command-1" })).rejects.toMatchObject({ code: "auth_required" });
    await service.invoke(client(), "push.registration.status", {});
    await service.invoke(client(), "push.registration.remove", { commandId: "command-2" });
    expect(calls).toEqual([["status", "device_abcdefgh"], ["remove", "device_abcdefgh"]]);
  });

  it("disables push before revoking the paired bearer", async () => {
    const { service, calls, devices } = await fixture();
    await service.invoke(client(true), "device.revoke", { commandId: "command-3", deviceId: "device_abcdefgh" });
    expect(calls[0]).toEqual(["remove", "device_abcdefgh"]);
    expect(devices.revoke).toHaveBeenCalledWith("device_abcdefgh");
  });
});
