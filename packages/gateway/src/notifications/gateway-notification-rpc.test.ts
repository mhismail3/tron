import { readFileSync } from "node:fs";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { GatewayService, type ClientContext } from "../transport/gateway-service.js";

const pushFixture = JSON.parse(readFileSync(new URL("../../../protocol-fixtures/push-v3.json", import.meta.url), "utf8")) as {
  gatewayUpsert: { request: Record<string, unknown>; expectedStatus: Record<string, unknown> };
};

const client = (isLocal = false, identity = "device_abcdefgh"): ClientContext => ({
  id: `connection-${identity}`, identity: isLocal ? "local-wrapper" : identity, isLocal,
  beginSynchronization: () => "sync", establishSynchronization() {}, completeSynchronization() {}, unsubscribe: () => true,
  attachTerminal() {}, detachTerminal() {}, ownsTerminal: () => false,
});

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((completion) => { resolve = completion; });
  return { promise, resolve };
}

async function nextTurn(): Promise<void> {
  await new Promise<void>((resolve) => setImmediate(resolve));
}

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-push-rpc-"));
  const calls: any[] = [];
  const upserts: Array<Record<string, unknown> & { deviceId: string }> = [];
  const registered = new Set<string>();
  const paired = new Set(["device_abcdefgh", "device_other"]);
  const status = (deviceId?: string) => ({
    ...structuredClone(pushFixture.gatewayUpsert.expectedStatus),
    registered: registered.size > 0,
    deviceRegistered: deviceId === undefined ? false : registered.has(deviceId),
    enabledDeviceCount: registered.size,
  });
  const notifications = {
    async upsertGrant(input: Record<string, unknown> & { deviceId: string }) {
      calls.push(["upsert", input.deviceId]);
      upserts.push(structuredClone(input));
      registered.add(input.deviceId);
      return status(input.deviceId);
    },
    async removeDevice(id: string) {
      calls.push(["remove", id]);
      return registered.delete(id);
    },
    async status(id?: string) {
      calls.push(["status", id]);
      return status(id);
    },
  };
  const devices = {
    hasDevice: vi.fn(async (deviceId: string) => paired.has(deviceId)),
    revoke: vi.fn(async (deviceId: string) => {
      calls.push(["revoke", deviceId]);
      return paired.delete(deviceId);
    }),
  };
  const service = new GatewayService({
    config: { tronHome: root }, notifications, devices,
    receipts: { execute: async (_identity: string, _method: string, _command: string, operation: () => Promise<unknown>) => operation() },
    deviceRevoked() {},
  } as any);
  return { service, calls, devices, notifications, registered, upserts };
}

describe("Gateway push registration RPC", () => {
  it("binds an exact registration to the authenticated mobile device", async () => {
    const { service, upserts } = await fixture();
    const result = await service.invoke(client(), "push.registration.upsert", pushFixture.gatewayUpsert.request);
    expect(result).toEqual(pushFixture.gatewayUpsert.expectedStatus);
    expect(Object.keys(result as object).sort()).toEqual(Object.keys(pushFixture.gatewayUpsert.expectedStatus).sort());
    expect(upserts[0]).toMatchObject({
      deviceId: "device_abcdefgh",
      grantId: pushFixture.gatewayUpsert.request.grantId,
      previewsEnabled: false,
    });
    await expect(service.invoke(client(), "push.registration.upsert", {
      commandId: "command-2", deviceId: "forged-device", installationId: "install_abcdefgh", grantId: "grant_abcdefgh",
      secret: Buffer.alloc(32, 1).toString("base64url"), previewsEnabled: false,
    })).rejects.toMatchObject({ code: "invalid_request" });
  });

  it("defaults lock-screen previews off when the iOS DTO omits the optional preference", async () => {
    const { service, notifications } = await fixture();
    const upsert = vi.spyOn(notifications, "upsertGrant");
    const request = { ...pushFixture.gatewayUpsert.request };
    delete request.previewsEnabled;
    await service.invoke(client(), "push.registration.upsert", request);
    expect(upsert).toHaveBeenCalledWith(expect.objectContaining({ previewsEnabled: false }));
  });

  it("denies local-wrapper registration and scopes status/removal to the remote identity", async () => {
    const { service, calls } = await fixture();
    await expect(service.invoke(client(true), "push.registration.upsert", { commandId: "command-1" })).rejects.toMatchObject({ code: "auth_required" });
    await service.invoke(client(), "push.registration.status", {});
    await service.invoke(client(), "push.registration.remove", { commandId: "command-2" });
    expect(calls).toEqual([["status", "device_abcdefgh"], ["remove", "device_abcdefgh"]]);
  });

  it("orders upsert then remove for one mobile identity before releasing the lane", async () => {
    const { service, calls, notifications, registered } = await fixture();
    const entered = deferred();
    const release = deferred();
    const originalUpsert = notifications.upsertGrant.bind(notifications);
    vi.spyOn(notifications, "upsertGrant").mockImplementation(async (input) => {
      entered.resolve();
      await release.promise;
      return originalUpsert(input);
    });
    const remove = vi.spyOn(notifications, "removeDevice");

    const upsertResult = service.invoke(client(), "push.registration.upsert", pushFixture.gatewayUpsert.request);
    await entered.promise;
    let removeSettled = false;
    const removeResult = service.invoke(client(), "push.registration.remove", { commandId: "command_remove_01" })
      .finally(() => { removeSettled = true; });
    await nextTurn();

    expect(remove).not.toHaveBeenCalled();
    expect(removeSettled).toBe(false);
    release.resolve();
    await expect(upsertResult).resolves.toMatchObject({ deviceRegistered: true });
    await expect(removeResult).resolves.toEqual({ removed: true });

    expect(calls).toEqual([
      ["upsert", "device_abcdefgh"],
      ["remove", "device_abcdefgh"],
    ]);
    expect(registered.size).toBe(0);
    await expect(service.invoke(client(), "push.registration.status", {})).resolves.toMatchObject({
      deviceRegistered: false,
      enabledDeviceCount: 0,
    });
  });

  it("keeps push admission for different mobile identities concurrent", async () => {
    const { service, notifications } = await fixture();
    const entered = deferred();
    const release = deferred();
    const originalUpsert = notifications.upsertGrant.bind(notifications);
    vi.spyOn(notifications, "upsertGrant").mockImplementation(async (input) => {
      if (input.deviceId === "device_abcdefgh") {
        entered.resolve();
        await release.promise;
      }
      return originalUpsert(input);
    });

    const first = service.invoke(client(), "push.registration.upsert", pushFixture.gatewayUpsert.request);
    await entered.promise;
    const second = service.invoke(client(false, "device_other"), "push.registration.upsert", {
      ...pushFixture.gatewayUpsert.request,
      commandId: "command_other_01",
    });

    await expect(second).resolves.toMatchObject({ deviceRegistered: true });
    release.resolve();
    await expect(first).resolves.toMatchObject({ deviceRegistered: true });
  });

  it("orders device revocation before a queued upsert and rejects the revoked identity", async () => {
    const { service, calls, devices, notifications, registered } = await fixture();
    await service.invoke(client(), "push.registration.upsert", pushFixture.gatewayUpsert.request);
    calls.length = 0;

    const removeEntered = deferred();
    const releaseRemove = deferred();
    const originalRemove = notifications.removeDevice.bind(notifications);
    vi.spyOn(notifications, "removeDevice").mockImplementation(async (deviceId) => {
      removeEntered.resolve();
      await releaseRemove.promise;
      return originalRemove(deviceId);
    });
    const upsert = vi.spyOn(notifications, "upsertGrant");
    upsert.mockClear();

    const revokeResult = service.invoke(client(true), "device.revoke", {
      commandId: "command_revoke_01",
      deviceId: "device_abcdefgh",
    });
    await removeEntered.promise;
    const queuedUpsert = service.invoke(client(), "push.registration.upsert", {
      ...pushFixture.gatewayUpsert.request,
      commandId: "command_after_revoke_01",
    });
    await nextTurn();

    expect(devices.revoke).not.toHaveBeenCalled();
    expect(upsert).not.toHaveBeenCalled();
    releaseRemove.resolve();
    await expect(revokeResult).resolves.toEqual({ revoked: true });
    await expect(queuedUpsert).rejects.toMatchObject({
      code: "unauthenticated",
      message: "The authenticated mobile device is no longer paired",
    });

    expect(calls).toEqual([
      ["remove", "device_abcdefgh"],
      ["revoke", "device_abcdefgh"],
    ]);
    expect(registered.size).toBe(0);
    expect(upsert).not.toHaveBeenCalled();
  });
});
