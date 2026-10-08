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
  isSubscribed: () => true, isRevoked: () => false, revokeDevice: () => {},
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
  const inbox = [{
    version: 1, id: "notification_abcdefgh", kind: "agent_finished", createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z", title: "Finished", message: "The agent finished responding.",
    sessionId: "session_abcdefgh", isUnread: true, outcome: "accepted_by_apns",
  }];
  const notifications = {
    async inbox(input: { filter?: string; cursor?: string; limit?: number }) {
      calls.push(["inbox", input]);
      const filtered = input.filter === "unread" ? inbox.filter((item) => item.isUnread) : inbox;
      return {
        notifications: filtered.slice(0, input.limit),
        revision: "revision-abcdefgh",
        unreadCount: inbox.filter((item) => item.isUnread).length,
      };
    },
    async markInboxRead(input: { id?: string; requestId?: string }) {
      calls.push(["read", input]);
      const item = inbox.find((candidate) => candidate.id === input.id);
      if (item) item.isUnread = false;
      return { changed: item !== undefined, ...(item ? { id: item.id } : {}) };
    },
    async markAllInboxRead(input: { through: string }) {
      const changed = inbox.filter((item) => item.isUnread).length;
      inbox.forEach((item) => { item.isUnread = false; });
      calls.push(["readAll", input.through]);
      return { changed };
    },
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
    // The real service answers this from its stored grant; the stub keeps the
    // default `false` so every existing case exercises the durable path, and a
    // case that cares about the receipt-free answer overrides it.
    async registrationIsCurrent() { return false; },
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
  const receipts = { execute: vi.fn(async (_identity: string, _method: string, _command: string, operation: () => Promise<unknown>) => operation()) };
  const service = new GatewayService({
    config: { tronHome: root }, notifications, devices,
    sessions: { isAdministrativeDrainStarted: false },
    receipts,
  } as any);
  return { service, calls, devices, notifications, registered, upserts, receipts };
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

  it("lists and marks canonical inbox entries through bounded idempotent RPCs", async () => {
    const { service, calls } = await fixture();
    await expect(service.invoke(client(), "notification.inbox.list", { limit: 25, filter: "unread" })).resolves.toMatchObject({
      revision: "revision-abcdefgh",
      unreadCount: 1,
      notifications: [expect.objectContaining({ id: "notification_abcdefgh", isUnread: true })],
    });
    await expect(service.invoke(client(), "notification.inbox.read", {
      commandId: "command_read_01", id: "notification_abcdefgh",
    })).resolves.toEqual({ changed: true, id: "notification_abcdefgh" });
    const through = `${Date.parse("2026-01-01T00:00:00.000Z")}.notification_abcdefgh`;
    await expect(service.invoke(client(), "notification.inbox.readAll", {
      commandId: "command_read_all_01", through,
    })).resolves.toEqual({ changed: 0 });
    expect(calls).toEqual([
      ["inbox", { filter: "unread", limit: 25 }],
      ["read", { id: "notification_abcdefgh" }],
      ["readAll", through],
    ]);
    await expect(service.invoke(client(), "notification.inbox.read", {
      commandId: "command_read_bad", id: "notification_abcdefgh", requestId: "request_abcdefgh",
    })).rejects.toMatchObject({ code: "invalid_request" });
  });

  it("rejects unknown inbox list keys and an unknown filter without reaching the owner", async () => {
    const { service, calls } = await fixture();
    for (const params of [
      { filter: "unread", offset: 50 },
      { filter: "read" },
      { limit: 51 },
      { cursor: "" },
    ]) {
      await expect(service.invoke(client(), "notification.inbox.list", params)).rejects.toMatchObject({ code: "invalid_request" });
    }
    expect(calls).toEqual([]);
    await expect(service.invoke(client(), "notification.inbox.list", {})).resolves.toMatchObject({ revision: "revision-abcdefgh" });
    expect(calls).toEqual([["inbox", { limit: 50 }]]);
  });

  it("requires the read-all cut and rejects any other read-all key", async () => {
    const { service, calls } = await fixture();
    await expect(service.invoke(client(), "notification.inbox.readAll", { commandId: "command_read_all_missing" }))
      .rejects.toMatchObject({ code: "invalid_request" });
    await expect(service.invoke(client(), "notification.inbox.readAll", {
      commandId: "command_read_all_keyed", through: "1.notification_abcdefgh", revision: "revision-abcdefgh",
    })).rejects.toMatchObject({ code: "invalid_request" });
    expect(calls).toEqual([]);
  });

  it("answers an identical registration without opening a command receipt", async () => {
    const { service, calls, notifications, receipts, upserts } = await fixture();
    const request = pushFixture.gatewayUpsert.request;
    await expect(service.invoke(client(), "push.registration.upsert", request)).resolves.toMatchObject({ deviceRegistered: true });
    expect(receipts.execute).toHaveBeenCalledTimes(1);
    receipts.execute.mockClear();
    calls.length = 0;
    upserts.length = 0;

    // The reconnect re-sends the same registration. It writes nothing at all,
    // so it is answered before the receipt owner opens one.
    vi.spyOn(notifications, "registrationIsCurrent").mockResolvedValue(true);
    const answer = await service.invoke(client(), "push.registration.upsert", request);
    expect(answer).toEqual(pushFixture.gatewayUpsert.expectedStatus);
    expect(receipts.execute).not.toHaveBeenCalled();
    expect(upserts).toHaveLength(0);
    expect(calls).toEqual([["status", "device_abcdefgh"]]);

    // A retried request repeats the command identity; the answer is the stored
    // grant's same status, so the reply is idempotent without a receipt.
    const retried = await service.invoke(client(), "push.registration.upsert", request);
    expect(retried).toEqual(answer);
    expect(receipts.execute).not.toHaveBeenCalled();
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
