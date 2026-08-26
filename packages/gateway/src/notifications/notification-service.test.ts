import { chmod, mkdir, mkdtemp, readFile, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { NotificationGrantStore, notificationHash } from "./grant-store.js";
import { NotificationService } from "./notification-service.js";
import type { PushRelayClient, RelayNotificationOutcome } from "./relay-client.js";

const grant = {
  deviceId: "device_abcdefgh", installationId: "install_abcdefgh", grantId: "grant_abcdefgh",
  secret: Buffer.alloc(32, 9).toString("base64url") as const,
  previewsEnabled: false,
};

function fakeRelay(outcomes: RelayNotificationOutcome[] = ["accepted_by_apns"]) {
  const sent: any[] = [];
  const revoked: string[] = [];
  return {
    sent, revoked,
    client: {
      available: true,
      async send(input: unknown) { sent.push(input); return outcomes.shift() ?? "accepted_by_apns"; },
      async revoke(grantId: string) { revoked.push(grantId); return "revoked" as const; },
    } as unknown as PushRelayClient,
  };
}

async function fixture(
  outcomes?: RelayNotificationOutcome[],
  now: () => number = Date.now,
  rateLimits?: { dailyIntents: number; sessionHourlyIntents: number; targetDailyIntents: number },
) {
  const root = await mkdtemp(join(tmpdir(), "tron-notifications-"));
  const store = new NotificationGrantStore(root);
  await store.initialize();
  const relay = fakeRelay(outcomes);
  const service = new NotificationService(store, relay.client, now, rateLimits);
  return { root, store, service, relay };
}

describe("NotificationGrantStore and NotificationService", () => {
  it("persists only the bounded grant capability, admits durably, redacts previews, and deduplicates tool calls", async () => {
    const { root, store, service, relay } = await fixture();
    await service.upsertGrant({ ...grant, notifyWhenAskPresented: true });
    await expect(service.enqueue({ sessionId: "session-one", sourceId: "tool-one", kind: "explicit", message: "sensitive text" })).resolves.toBe("queued");
    await vi.waitFor(() => expect(relay.sent).toHaveLength(1));
    expect(relay.sent[0].message).toBe("Tron has an update. Open Tron to view it.");
    await expect(service.enqueue({ sessionId: "session-one", sourceId: "tool-one", kind: "explicit", message: "changed" })).resolves.toBe("suppressed");
    const persisted = await readFile(join(root, "gateway", "notifications.json"), "utf8");
    expect(persisted).not.toContain("sensitive text");
    expect(persisted).not.toContain("apnsToken");
    expect((await store.snapshot()).receipts[0]?.result).toBe("accepted_by_apns");
  });

  it("uses agent text only for a grant whose user enabled previews", async () => {
    const { service, relay } = await fixture();
    await service.upsertGrant({ ...grant, previewsEnabled: true });
    await service.enqueue({ sessionId: "session-one", sourceId: "tool-two", kind: "explicit", message: "Build finished" });
    await vi.waitFor(() => expect(relay.sent).toHaveLength(1));
    expect(relay.sent[0].message).toBe("Build finished");
  });

  it("durably carries the session title and exact chat route for a settled agent", async () => {
    const { service, relay } = await fixture();
    await service.upsertGrant(grant);
    await service.enqueue({
      sessionId: "session-finished",
      sourceId: "assistant-entry",
      kind: "agent_finished",
      message: "The agent finished responding.",
      title: "Release audit",
      route: { sessionId: "session-finished", machineId: "machine-abcdefgh" },
    });
    await vi.waitFor(() => expect(relay.sent).toHaveLength(1));
    expect(relay.sent[0]).toMatchObject({
      title: "Release audit",
      sessionId: "session-finished",
      machineId: "machine-abcdefgh",
      message: "The agent finished responding.",
    });
    await expect(service.enqueue({
      sessionId: "session-finished",
      sourceId: "assistant-entry",
      kind: "agent_finished",
      message: "The agent finished responding.",
      title: "Changed title",
      route: { sessionId: "session-finished", machineId: "machine-abcdefgh" },
    })).resolves.toBe("suppressed");
  });

  it("disables invalid APNs grants and retains no future audience", async () => {
    const { service, relay } = await fixture(["invalid_token"]);
    await service.upsertGrant(grant);
    await service.enqueue({ sessionId: "session-one", sourceId: "tool-three", kind: "explicit", message: "hello" });
    await vi.waitFor(async () => expect((await service.status(grant.deviceId)).deviceRegistered).toBe(false));
    await expect(service.enqueue({ sessionId: "session-one", sourceId: "tool-four", kind: "explicit", message: "hello" })).resolves.toBe("unavailable");
    expect(relay.sent).toHaveLength(1);
  });

  it("removes local authority first and drains a durable revocation tombstone", async () => {
    const { service, relay, store } = await fixture();
    await service.upsertGrant(grant);
    await expect(service.removeDevice(grant.deviceId)).resolves.toBe(true);
    expect((await service.status(grant.deviceId)).deviceRegistered).toBe(false);
    await service.drain();
    await vi.waitFor(() => expect(relay.revoked).toEqual([grant.grantId]));
    expect((await store.snapshot()).revocations).toEqual([]);
  });

  it("retains a failed revocation indefinitely with bounded retry state", async () => {
    let clock = Date.parse("2026-01-01T00:00:00.000Z");
    const root = await mkdtemp(join(tmpdir(), "tron-notifications-revoke-"));
    const store = new NotificationGrantStore(root);
    await store.initialize();
    const relay = {
      available: true,
      async send() { return "accepted_by_apns" as const; },
      async revoke() { return "retryable" as const; },
    } as unknown as PushRelayClient;
    const service = new NotificationService(store, relay, () => clock);
    await service.upsertGrant(grant);
    await service.removeDevice(grant.deviceId);
    await vi.waitFor(async () => expect((await store.snapshot()).revocations[0]?.attempts).toBeGreaterThan(0));
    clock += 365 * 24 * 60 * 60_000;
    await service.drain();
    const tombstone = (await store.snapshot()).revocations[0];
    expect(tombstone?.grantId).toBe(grant.grantId);
    expect(tombstone?.attempts).toBeLessThanOrEqual(32);
  });

  it("rotates grants by retaining and draining a revocation tombstone for the previous capability", async () => {
    const { service, relay } = await fixture();
    await service.upsertGrant(grant);
    await service.upsertGrant({ ...grant, grantId: "grant_ijklmnop", secret: Buffer.alloc(32, 8).toString("base64url") });
    await vi.waitFor(() => expect(relay.revoked).toContain(grant.grantId));
    expect((await service.status(grant.deviceId)).enabledDeviceCount).toBe(1);
  });

  it("never reactivates a capability while its durable revocation can still cross", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-notifications-revocation-race-"));
    const store = new NotificationGrantStore(root);
    await store.initialize();
    const relay = {
      available: true,
      async send() { return "accepted_by_apns" as const; },
      async revoke() { return "retryable" as const; },
    } as unknown as PushRelayClient;
    const service = new NotificationService(store, relay);
    await service.upsertGrant(grant);
    await service.removeDevice(grant.deviceId);
    await expect(service.upsertGrant(grant)).rejects.toMatchObject({ code: "conflict" });

    const replacement = {
      ...grant,
      grantId: "grant_replacement",
      secret: Buffer.alloc(32, 7).toString("base64url"),
    };
    await service.upsertGrant(replacement);
    const snapshot = await store.snapshot();
    expect(snapshot.grants.map((item) => item.grantId)).toEqual([replacement.grantId]);
    expect(snapshot.revocations.map((item) => item.grantId)).toEqual([grant.grantId]);
    const revoking = new Set(snapshot.revocations.map((item) => item.grantId));
    expect(snapshot.grants.every((item) => !revoking.has(item.grantId))).toBe(true);
  });

  it("retires a legacy active grant when restart finds revocation authority for the same capability", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-notifications-revocation-repair-"));
    const store = new NotificationGrantStore(root);
    await store.initialize();
    const now = new Date().toISOString();
    await store.update((document) => {
      document.grants.push({ ...grant, active: true, createdAt: now, updatedAt: now });
      document.revocations.push({
        grantId: grant.grantId,
        secret: grant.secret,
        requestId: notificationHash(`revoke\0${grant.grantId}`),
        createdAt: now,
        attempts: 0,
        nextAttemptAt: now,
      });
      return document;
    });
    const relay = { available: false } as PushRelayClient;
    const service = new NotificationService(store, relay);
    await service.initialize();
    service.dispose();
    const snapshot = await store.snapshot();
    expect(snapshot.grants).toEqual([]);
    expect(snapshot.revocations.map((item) => item.grantId)).toEqual([grant.grantId]);
  });

  it("enforces the durable per-session hourly quota", async () => {
    const { service } = await fixture(undefined, Date.now, {
      dailyIntents: 10,
      sessionHourlyIntents: 2,
      targetDailyIntents: 10,
    });
    await service.upsertGrant(grant);
    for (let index = 0; index < 2; index += 1) {
      await expect(service.enqueue({ sessionId: "session-quota", sourceId: `tool-${index}`, kind: "explicit", message: "hello" })).resolves.toBe("queued");
    }
    await expect(service.enqueue({ sessionId: "session-quota", sourceId: "tool-over-limit", kind: "explicit", message: "hello" })).resolves.toBe("rate_limited");
  });

  it("does not persist rate-limited attempts or let them consume another session's quota", async () => {
    const { service, store } = await fixture(undefined, Date.now, {
      dailyIntents: 3,
      sessionHourlyIntents: 2,
      targetDailyIntents: 3,
    });
    await service.upsertGrant(grant);
    await expect(service.enqueue({ sessionId: "session-quota-a", sourceId: "tool-a1", kind: "explicit", message: "hello" })).resolves.toBe("queued");
    await expect(service.enqueue({ sessionId: "session-quota-a", sourceId: "tool-a2", kind: "explicit", message: "hello" })).resolves.toBe("queued");
    await expect(service.enqueue({ sessionId: "session-quota-a", sourceId: "tool-a3", kind: "explicit", message: "hello" })).resolves.toBe("rate_limited");
    expect((await store.snapshot()).receipts).toHaveLength(2);
    await expect(service.enqueue({ sessionId: "session-quota-b", sourceId: "tool-b1", kind: "explicit", message: "hello" })).resolves.toBe("queued");
  });

  it("recovers a retryable pending intent with the same request identity after restart", async () => {
    let clock = Date.parse("2026-01-01T00:00:00.000Z");
    const { store, service, relay } = await fixture(["retryable"], () => clock);
    await service.upsertGrant(grant);
    await service.enqueue({ sessionId: "session-restart", sourceId: "tool-restart", kind: "explicit", message: "hello" });
    await vi.waitFor(() => expect(relay.sent).toHaveLength(1));
    const requestId = relay.sent[0].requestId;
    clock += 6_000;
    const recoveredRelay = fakeRelay(["accepted_by_apns"]);
    const recovered = new NotificationService(store, recoveredRelay.client, () => clock);
    await recovered.drain();
    expect(recoveredRelay.sent[0].requestId).toBe(requestId);
    expect((await store.snapshot()).pending).toEqual([]);
  });

  it("does not notify for Ask when its typed persistent policy is disabled", async () => {
    const { service, relay } = await fixture();
    await service.upsertGrant({ ...grant, notifyWhenAskPresented: false });
    await service.askPresented("session-one", "ask-one");
    expect(relay.sent).toEqual([]);
    expect((await service.status(grant.deviceId)).notifyWhenAskPresented).toBe(false);
  });

  it("reserves revocation capacity for every active grant at saturation", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-notifications-reserve-"));
    const store = new NotificationGrantStore(root);
    await store.initialize();
    const now = new Date().toISOString();
    await store.update((document) => {
      document.revocations = Array.from({ length: 191 }, (_, index) => ({
        grantId: `oldgrant_${index.toString().padStart(4, "0")}`,
        secret: Buffer.alloc(32, index % 255).toString("base64url"),
        requestId: `oldrequest_${index.toString().padStart(4, "0")}`,
        createdAt: now,
        attempts: 0,
        nextAttemptAt: now,
      }));
      return document;
    });
    const relay = { available: false } as PushRelayClient;
    const service = new NotificationService(store, relay);
    await service.upsertGrant(grant);
    await expect(service.upsertGrant({
      ...grant,
      deviceId: "device_ijklmnop",
      installationId: "install_ijklmnop",
      grantId: "grant_ijklmnop",
      secret: Buffer.alloc(32, 7).toString("base64url"),
    })).rejects.toMatchObject({ code: "busy" });
    await expect(service.removeDevice(grant.deviceId)).resolves.toBe(true);
    const snapshot = await store.snapshot();
    expect(snapshot.grants).toEqual([]);
    expect(snapshot.revocations).toHaveLength(192);
  });

  it("rejects permissive and symlinked credential parents before writing secrets", async () => {
    const permissiveRoot = await mkdtemp(join(tmpdir(), "tron-notifications-parent-"));
    await mkdir(join(permissiveRoot, "gateway"), { mode: 0o755 });
    await expect(new NotificationGrantStore(permissiveRoot).initialize()).rejects.toMatchObject({ code: "conflict" });

    const symlinkRoot = await mkdtemp(join(tmpdir(), "tron-notifications-symlink-"));
    const target = await mkdtemp(join(tmpdir(), "tron-notifications-target-"));
    await symlink(target, join(symlinkRoot, "gateway"));
    await expect(new NotificationGrantStore(symlinkRoot).initialize()).rejects.toMatchObject({ code: "conflict" });
  });

  it("fails closed for permissive or malformed owner state", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-notifications-unsafe-"));
    const store = new NotificationGrantStore(root);
    await store.initialize();
    const path = join(root, "gateway", "notifications.json");
    await chmod(path, 0o644);
    await expect(store.snapshot()).rejects.toMatchObject({ code: "conflict" });
    await chmod(path, 0o600);
    await writeFile(path, JSON.stringify({ version: 1, policy: { notifyWhenAskPresented: true }, grants: [{ token: "raw" }], pending: [], receipts: [], revocations: [] }));
    await expect(store.snapshot()).rejects.toMatchObject({ code: "conflict" });
  });
});
