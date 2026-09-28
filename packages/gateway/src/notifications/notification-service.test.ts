import { chmod, mkdir, mkdtemp, readFile, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { MAXIMUM_NOTIFICATION_INBOX_ENTRIES, NotificationGrantStore, notificationHash, type NotificationInboxEntry } from "./grant-store.js";
import { NotificationService } from "./notification-service.js";
import type { PushRelayClient, RelayNotificationOutcome } from "./relay-client.js";

const grant = {
  deviceId: "device_abcdefgh", installationId: "install_abcdefgh", grantId: "grant_abcdefgh",
  secret: Buffer.alloc(32, 9).toString("base64url") as const,
  previewsEnabled: false,
  relayOrigin: "https://push.example.test",
};

function fakeRelay(outcomes: RelayNotificationOutcome[] = ["accepted_by_apns"]) {
  const sent: any[] = [];
  const revoked: string[] = [];
  return {
    sent, revoked,
    client: {
      available: true,
      relayOrigin: "https://push.example.test",
      async send(input: unknown) { sent.push(input); return outcomes.shift() ?? "accepted_by_apns"; },
      async revoke(grantId: string) { revoked.push(grantId); return "revoked" as const; },
    } as unknown as PushRelayClient,
  };
}

async function fixture(
  outcomes?: RelayNotificationOutcome[],
  now: () => number = Date.now,
  rateLimits?: { dailyIntents: number; sessionHourlyIntents: number; targetDailyIntents: number },
  inboxChanged: (payload: { revision: string; unreadCount: number }) => void = () => {},
) {
  const root = await mkdtemp(join(tmpdir(), "tron-notifications-"));
  const store = new NotificationGrantStore(root);
  await store.initialize();
  const relay = fakeRelay(outcomes);
  const service = new NotificationService(store, relay.client, now, rateLimits, inboxChanged);
  return { root, store, service, relay };
}

/** One canonical inbox row with an explicit position and read state. */
function seededEntry(
  index: number,
  options: { createdAt: string; readAt?: string; sessionId?: string; dedupeKey?: string; outcome?: NotificationInboxEntry["outcome"] } = { createdAt: "2026-01-01T00:00:00.000Z" },
): NotificationInboxEntry {
  const ordinal = index.toString().padStart(6, "0");
  return {
    id: `notification-${ordinal}`,
    dedupeKey: options.dedupeKey ?? notificationHash(`seeded-${ordinal}`),
    requestIds: [`request-${ordinal}`],
    kind: "explicit",
    createdAt: options.createdAt,
    updatedAt: options.createdAt,
    title: "Alert",
    message: "An update",
    sessionId: options.sessionId ?? "session-inbox",
    outcome: options.outcome ?? "accepted_by_apns",
    ...(options.readAt === undefined ? {} : { readAt: options.readAt }),
  };
}

/** The keyset key a client derives from the newest row it has displayed. */
function keyOf(item: { createdAt: string; id: string }): string { return `${Date.parse(item.createdAt)}.${item.id}`; }

function ascending(index: number): string { return new Date(Date.parse("2025-12-01T00:00:00.000Z") + index * 1_000).toISOString(); }

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
    expect((await service.inbox()).notifications[0]).toMatchObject({
      title: "Tron",
      message: "Tron has an update. Open Tron to view it.",
      isUnread: true,
      outcome: "accepted_by_apns",
    });
  });

  it("answers an identical registration without rewriting the credential document", async () => {
    const { root, store, service } = await fixture();
    await service.upsertGrant({ ...grant, notifyWhenAskPresented: true });
    const path = join(root, "gateway", "notifications.json");
    const admitted = await readFile(path, "utf8");

    // The phone re-registers on every reconnect; an identical registration is
    // neither a grant rewrite nor a receipt/revocation overlay write.
    const status = await service.upsertGrant({ ...grant, notifyWhenAskPresented: true });
    expect(status.deviceRegistered).toBe(true);
    expect(await readFile(path, "utf8")).toBe(admitted);

    // A changed registration is still admitted durably.
    await service.upsertGrant({ ...grant, previewsEnabled: true, notifyWhenAskPresented: true });
    expect(await readFile(path, "utf8")).not.toBe(admitted);
    expect((await store.snapshot()).grants[0]?.previewsEnabled).toBe(true);
  });

  it("advertises a changed registration revision when the relay disables a grant", async () => {
    const { service } = await fixture(["invalid_token"]);
    await service.upsertGrant({ ...grant, notifyWhenAskPresented: true });
    const acknowledged = service.registrationRevision;
    expect(await service.registrationIsCurrent({ ...grant, notifyWhenAskPresented: true })).toBe(true);

    // The relay rejects the delivery on this same runtime and the Gateway
    // disables the grant. Nothing else announces that, so the revision the
    // phone compares against is what makes the next registration re-send.
    await expect(service.enqueue({ sessionId: "session-one", sourceId: "tool-one", kind: "explicit", message: "text" })).resolves.toBe("queued");
    await vi.waitFor(async () => expect((await service.status(grant.deviceId)).deviceRegistered).toBe(false));
    expect(service.registrationRevision).not.toBe(acknowledged);
    expect(await service.registrationIsCurrent({ ...grant, notifyWhenAskPresented: true })).toBe(false);

    // The re-sent registration is admitted and answers the rotation
    // requirement the phone must act on; the disabled grant stays disabled
    // until the phone transfers a replacement capability.
    const readmitted = await service.upsertGrant({ ...grant, notifyWhenAskPresented: true });
    expect(readmitted.requiresGrantRotation).toBe(true);
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

  it("durably suppresses an observed completion without relay or inbox work", async () => {
    const { service, relay, store } = await fixture();
    await service.upsertGrant(grant);
    const completion = {
      sessionId: "session-observed",
      sourceId: "assistant-observed",
    };

    await expect(service.suppressAutomatic({ ...completion, kind: "agent_finished" })).resolves.toBe("suppressed");
    expect(relay.sent).toEqual([]);
    expect((await service.inbox()).notifications).toEqual([]);
    expect((await store.snapshot()).receipts).toEqual([
      expect.objectContaining({ result: "suppressed", grantIds: [] }),
    ]);

    await expect(service.enqueue({
      ...completion,
      kind: "agent_finished",
      message: "The agent finished responding.",
    })).resolves.toBe("suppressed");
    expect(relay.sent).toEqual([]);
  });

  it("does not charge a presentation-suppressed completion against delivery quota", async () => {
    const { service, relay } = await fixture(undefined, Date.now, {
      dailyIntents: 1,
      sessionHourlyIntents: 1,
      targetDailyIntents: 1,
    });
    await service.upsertGrant(grant);
    await service.suppressAutomatic({
      sessionId: "session-observed",
      sourceId: "assistant-observed",
      kind: "agent_finished",
    });

    await expect(service.enqueue({
      sessionId: "session-observed",
      sourceId: "explicit-after-observed",
      kind: "explicit",
      message: "Explicit update",
    })).resolves.toBe("queued");
    await vi.waitFor(() => expect(relay.sent).toHaveLength(1));
  });

  it("keeps inbox invalidation callbacks outside canonical notification admission", async () => {
    let invoked = false;
    const { service } = await fixture(undefined, Date.now, undefined, () => {
      invoked = true;
      throw new Error("presentation failed");
    });
    await service.upsertGrant(grant);
    await expect(service.enqueue({
      sessionId: "session-callback", sourceId: "source-callback", kind: "agent_finished",
      title: "Finished", message: "The agent finished responding.",
    })).resolves.toBe("queued");
    expect((await service.inbox()).notifications).toHaveLength(1);
    // A throwing presentation owner is swallowed once the debounced broadcast
    // runs; it never owns canonical admission either way.
    await vi.waitFor(() => expect(invoked).toBe(true));
  });

  it("pages canonical inbox rows and owns idempotent read state by notification or APNs request identity", async () => {
    const changed = vi.fn();
    let clock = Date.parse("2026-01-01T00:00:00.000Z");
    const { service, relay, store } = await fixture(undefined, () => clock++, undefined, changed);
    const drains = vi.spyOn(service, "drain");
    await service.upsertGrant({ ...grant, previewsEnabled: true });
    for (let index = 0; index < 3; index += 1) {
      await service.enqueue({
        sessionId: "session-inbox",
        sourceId: `source-${index}`,
        kind: "explicit",
        title: `Title ${index}`,
        message: `Message ${index}`,
        route: { sessionId: "session-inbox", machineId: "machine-abcdefgh" },
      });
    }
    // Join admitted delivery, then drain any rows queued after its snapshot.
    // A particular intermediate pending count depends on filesystem scheduling.
    await Promise.all(drains.mock.results.map((result) => result.value));
    await service.drain();
    expect(relay.sent).toHaveLength(3);
    expect((await store.snapshot()).pending).toHaveLength(0);
    const first = await service.inbox({ limit: 2 });
    expect(first.notifications.map((item) => item.title)).toEqual(["Title 2", "Title 1"]);
    expect(first.unreadCount).toBe(3);
    expect(first.nextCursor).toBeDefined();
    const second = await service.inbox({ cursor: first.nextCursor, limit: 2 });
    expect(second.notifications.map((item) => item.title)).toEqual(["Title 0"]);
    expect(second.nextCursor).toBeUndefined();
    const newest = relay.sent.find((item) => item.title === "Title 2")!;
    const newestRow = (await store.snapshot()).inbox.find((entry) => entry.requestIds.includes(newest.requestId));
    expect(newestRow?.id).toBe(first.notifications[0]!.id);

    await expect(service.markInboxRead({ requestId: newest.requestId })).resolves.toMatchObject({ changed: true });
    await expect(service.markInboxRead({ id: first.notifications[0]!.id })).resolves.toMatchObject({ changed: false });
    expect((await service.inbox()).unreadCount).toBe(2);
    // "Title 2" is already read, so only the two rows at or older than the cut
    // change and the read-all response counts exactly those.
    await expect(service.markAllInboxRead({ through: keyOf(first.notifications[1]!) })).resolves.toEqual({ changed: 2 });
    await expect(service.markAllInboxRead({ through: keyOf(first.notifications[1]!) })).resolves.toEqual({ changed: 0 });
    expect((await service.inbox()).unreadCount).toBe(0);
    await vi.waitFor(() => expect(changed.mock.calls.at(-1)?.[0]).toMatchObject({ unreadCount: 0 }));
    expect(changed.mock.calls.at(-1)?.[0].revision).toEqual(expect.any(String));
  });

  it("rejects stale relay-origin grants and requires capability rotation", async () => {
    const { service, relay, store } = await fixture();
    const mismatch = await service.upsertGrant({ ...grant, relayOrigin: "https://other.example.test" });
    expect(mismatch).toMatchObject({
      relayOrigin: "https://push.example.test", deviceRegistered: false,
    });
    expect(relay.sent).toEqual([]);

    const accepted = await service.upsertGrant(grant);
    expect(accepted).toMatchObject({ deviceRegistered: true, requiresGrantRotation: false });
    const snapshot = await service.status(grant.deviceId);
    expect(snapshot.relayOrigin).toBe("https://push.example.test");

    await store.update((document) => {
      delete document.grants[0]!.relayOrigin;
      return document;
    });
    await expect(service.status(grant.deviceId)).resolves.toMatchObject({
      deviceRegistered: false, requiresGrantRotation: true,
    });
  });

  it("disables invalid APNs grants and retains no future audience", async () => {
    const { service, relay } = await fixture(["invalid_token"]);
    await service.upsertGrant(grant);
    await service.enqueue({ sessionId: "session-one", sourceId: "tool-three", kind: "explicit", message: "hello" });
    await vi.waitFor(async () => expect((await service.status(grant.deviceId)).deviceRegistered).toBe(false));
    await expect(service.enqueue({ sessionId: "session-one", sourceId: "tool-four", kind: "explicit", message: "hello" })).resolves.toBe("unavailable");
    expect(relay.sent).toHaveLength(1);
  });

  it("invalidates a relay-rejected grant so mobile can rotate it", async () => {
    const { service } = await fixture(["invalid_grant"]);
    await service.upsertGrant(grant);
    await service.enqueue({ sessionId: "session-invalid-grant", sourceId: "tool-invalid-grant", kind: "explicit", message: "hello" });
    await vi.waitFor(async () => expect((await service.status(grant.deviceId))).toMatchObject({
      deviceRegistered: false, requiresGrantRotation: true,
    }));
    await expect(service.upsertGrant(grant)).resolves.toMatchObject({
      deviceRegistered: false, requiresGrantRotation: true,
    });
  });

  it("marks an undeliverable inbox row failed when its final target is removed", async () => {
    const changed = vi.fn();
    const { service, store } = await fixture(["retryable"], Date.now, undefined, changed);
    await service.upsertGrant(grant);
    await service.enqueue({ sessionId: "session-remove", sourceId: "source-remove", kind: "explicit", message: "hello" });
    await vi.waitFor(async () => expect((await store.snapshot()).pending[0]?.targets[0]?.outcome).toBe("retryable"));
    await service.removeDevice(grant.deviceId);
    expect((await service.inbox()).notifications[0]).toMatchObject({ outcome: "failed" });
    await vi.waitFor(() => expect(changed.mock.calls.at(-1)?.[0]).toMatchObject({ unreadCount: 1 }));
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
      relayOrigin: "https://push.example.test",
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
      relayOrigin: "https://push.example.test",
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

  it("polls a relay-owned provider attempt with the same request identity", async () => {
    let clock = Date.parse("2026-01-01T00:00:00.000Z");
    const { store, service, relay } = await fixture(["in_progress", "accepted_by_apns"], () => clock);
    await service.upsertGrant(grant);
    const drains = vi.spyOn(service, "drain");
    await service.enqueue({
      sessionId: "session-in-progress", sourceId: "tool-in-progress", kind: "explicit", message: "hello",
    });
    // The pending write precedes drain retirement. Join the actual enqueue-owned
    // drain before advancing time; an overlapping drain intentionally does no work.
    expect(drains).toHaveBeenCalledTimes(1);
    await drains.mock.results[0]!.value;
    drains.mockRestore();
    expect((await store.snapshot()).pending[0]?.targets[0]).toMatchObject({
      outcome: "retryable", attempts: 1,
    });
    const requestId = relay.sent[0].requestId;
    clock += 6_000;
    await service.drain();
    expect(relay.sent).toHaveLength(2);
    expect(relay.sent[1].requestId).toBe(requestId);
    expect((await store.snapshot()).pending).toEqual([]);
    expect((await service.inbox()).notifications[0]).toMatchObject({ outcome: "accepted_by_apns" });
  });

  it("queues one routed input-needed notification for an unobserved semantic interaction", async () => {
    const { service, relay } = await fixture();
    await service.upsertGrant(grant);
    await service.userInputRequired({
      sessionId: "session-input",
      interactionId: "interaction-one",
      machineId: "machine-abcdefgh",
      observed: false,
    });
    await vi.waitFor(() => expect(relay.sent).toHaveLength(1));
    expect(relay.sent[0]).toMatchObject({
      title: "Input needed",
      message: "Tron needs your input. Open Tron to respond.",
      sessionId: "session-input",
      machineId: "machine-abcdefgh",
    });
  });

  it("durably suppresses an observed input request without relay or inbox work", async () => {
    const { service, relay, store } = await fixture();
    await service.upsertGrant(grant);
    const input = {
      sessionId: "session-input",
      interactionId: "interaction-observed",
      observed: true,
    };
    await service.userInputRequired(input);
    expect(relay.sent).toEqual([]);
    expect((await service.inbox()).notifications).toEqual([]);
    expect((await store.snapshot()).receipts).toEqual([
      expect.objectContaining({ result: "suppressed", grantIds: [] }),
    ]);
    await service.userInputRequired({ ...input, observed: false });
    expect(relay.sent).toEqual([]);
  });

  it("rechecks ask policy inside admission when it changes after the early read", async () => {
    const { service, store, relay } = await fixture();
    await service.upsertGrant({ ...grant, notifyWhenAskPresented: true });
    const readCanonical = store.snapshot.bind(store);
    const updateCanonical = store.update.bind(store);
    const snapshot = vi.spyOn(store, "snapshot").mockImplementation(async () => {
      const current = await readCanonical();
      // Model a concurrent policy mutation after the early read but before the
      // notification admission transaction.
      await updateCanonical((document) => {
        document.policy.notifyWhenAskPresented = false;
        return document;
      });
      return current;
    });

    await service.userInputRequired({
      sessionId: "session-race", interactionId: "interaction-race", observed: false,
    });
    expect(snapshot).toHaveBeenCalledOnce();
    expect(relay.sent).toEqual([]);
    expect((await readCanonical()).pending).toEqual([]);
    expect((await service.inbox()).notifications).toEqual([]);
  });

  it("does not notify for semantic input when its typed persistent policy is disabled", async () => {
    const { service, relay } = await fixture();
    await service.upsertGrant({ ...grant, notifyWhenAskPresented: false });
    await service.userInputRequired({
      sessionId: "session-one", interactionId: "interaction-one", observed: false,
    });
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
    const relay = { available: false, relayOrigin: "https://push.example.test" } as PushRelayClient;
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

/**
 * Failure modes these cases own, all observed on live data:
 * 1. one unread row older than the newest 50 read rows lit the bell but was
 *    absent from the first page and from a client-side "Unread" filter;
 * 2. an offset cursor fenced by the whole-inbox revision failed on any change
 *    and could return or skip rows after reads and arrivals between pages;
 * 3. read-all had no cut and marked alerts that arrived while the user looked;
 * 4. listing the inbox rewrote the ~375KB credential document on every call;
 * 5. retention dropped the oldest unread rows while newer read rows remained;
 * 6. reading a row already evicted by the bound failed as `not_found`;
 * 7. an alert admitted while the user watched that chat still lit the bell.
 */
describe("canonical inbox keyset paging, retention and reads", () => {
  it("returns and counts an unread row that sits below a full page of read rows", async () => {
    const { service, store } = await fixture();
    await store.update((document) => {
      document.inbox = [
        seededEntry(0, { createdAt: ascending(0) }),
        ...Array.from({ length: 51 }, (_, index) =>
          seededEntry(index + 1, { createdAt: ascending(index + 1), readAt: "2025-12-02T00:00:00.000Z" })),
      ];
      return document;
    });
    const page = await service.inbox();
    expect(page.notifications).toHaveLength(50);
    expect(page.notifications.some((item) => item.id === "notification-000000")).toBe(false);
    expect(page.unreadCount).toBe(1);
    expect(page.nextCursor).toBeDefined();

    const unread = await service.inbox({ filter: "unread" });
    expect(unread.notifications.map((item) => item.id)).toEqual(["notification-000000"]);
    expect(unread.notifications[0]?.isUnread).toBe(true);
    expect(unread.unreadCount).toBe(1);
    expect(unread.nextCursor).toBeUndefined();
  });

  it("walks the whole inbox exactly once while rows arrive and rows are read between pages", async () => {
    const { service, store } = await fixture();
    const seeded = Array.from({ length: 62 }, (_, index) => seededEntry(index, { createdAt: ascending(index) }));
    await store.update((document) => {
      document.inbox = seeded;
      return document;
    });
    const seen: string[] = [];
    let cursor: string | undefined;
    for (let page = 0; page < 5; page += 1) {
      const result = await service.inbox({ ...(cursor === undefined ? {} : { cursor }), limit: 25 });
      seen.push(...result.notifications.map((item) => item.id));
      if (result.nextCursor === undefined) break;
      cursor = result.nextCursor;
      await store.update((document) => {
        for (let index = 0; index < 3; index += 1) {
          document.inbox.push(seededEntry(1000 + page * 10 + index, { createdAt: ascending(1000 + page * 10 + index) }));
        }
        for (const entry of document.inbox.slice(0, 5)) entry.readAt = "2025-12-03T00:00:00.000Z";
        return document;
      });
    }
    const newestFirst = seeded.map((entry) => entry.id).reverse();
    expect(seen).toEqual(newestFirst);
    expect(new Set(seen).size).toBe(seeded.length);
    // Rows admitted after the first page are newer than its cursor, so they are
    // never replayed into an older page.
    expect(seen.some((id) => id.startsWith("notification-0010"))).toBe(false);
  });

  it("reads only unread rows at or older than the read-all cut", async () => {
    const { service, store } = await fixture();
    await store.update((document) => {
      document.inbox = [0, 1, 2].map((index) => seededEntry(index, { createdAt: ascending(index) }));
      return document;
    });
    const newest = (await service.inbox()).notifications[0]!;
    const middle = (await service.inbox()).notifications[1]!;
    await expect(service.markAllInboxRead({ through: keyOf(middle) })).resolves.toEqual({ changed: 2 });
    const page = await service.inbox();
    expect(page.notifications.map((item) => [item.id, item.isUnread])).toEqual([
      ["notification-000002", true],
      ["notification-000001", false],
      ["notification-000000", false],
    ]);
    expect(page.unreadCount).toBe(1);

    await expect(service.markAllInboxRead({ through: keyOf(newest) })).resolves.toEqual({ changed: 1 });
    expect((await service.inbox()).unreadCount).toBe(0);
    await expect(service.markAllInboxRead({ through: "notification-000002" })).rejects.toMatchObject({ code: "invalid_request" });
    expect((await store.snapshot()).inbox.every((entry) => entry.readAt !== undefined)).toBe(true);
  });

  it("does not rewrite the credential document to list the inbox", async () => {
    const { service, store, root } = await fixture();
    await store.update((document) => {
      document.inbox = [0, 1, 2].map((index) => seededEntry(index, { createdAt: ascending(index) }));
      return document;
    });
    const path = join(root, "gateway", "notifications.json");
    const before = await stat(path);
    const bytes = await readFile(path);
    const first = await service.inbox({ limit: 1 });
    await service.inbox({ cursor: first.nextCursor, limit: 1 });
    await service.inbox({ filter: "unread" });
    const after = await stat(path);
    expect(after.ino).toBe(before.ino);
    expect(after.mtimeMs).toBe(before.mtimeMs);
    expect(await readFile(path)).toEqual(bytes);
  });

  it("writes the credential document only for a real inbox expiry transition", async () => {
    const now = Date.parse("2026-01-01T00:00:00.000Z");
    const { service, store, root } = await fixture(undefined, () => now);
    const lapsed = "2025-12-31T22:00:00.000Z";
    const dedupeKey = notificationHash("expired-intent");
    await store.update((document) => {
      document.pending.push({
        id: "intent-abcd1234",
        dedupeKey,
        sessionKey: notificationHash("session-expiry"),
        kind: "explicit",
        createdAt: lapsed,
        expiresAt: "2025-12-31T23:30:00.000Z",
        targets: [{
          grantId: "grant_abcdefgh", requestId: "request-abcd1234", message: "An update",
          attempts: 0, nextAttemptAt: lapsed, outcome: "pending",
        }],
      });
      document.inbox = [seededEntry(0, { createdAt: ascending(0), dedupeKey, outcome: "queued" })];
      return document;
    });
    const path = join(root, "gateway", "notifications.json");
    const before = await stat(path);
    const page = await service.inbox();
    expect(page.notifications[0]).toMatchObject({ outcome: "expired" });
    expect((await stat(path)).ino).not.toBe(before.ino);
    expect((await store.snapshot()).pending).toEqual([]);
    // The transition is now durable, so repeated listing is read-only again.
    const settled = await stat(path);
    await service.inbox();
    expect((await stat(path)).ino).toBe(settled.ino);
  });

  it("evicts the oldest read row before an older unread row and only then unread rows", async () => {
    const { service, store } = await fixture();
    await service.upsertGrant(grant);
    const full = Array.from({ length: MAXIMUM_NOTIFICATION_INBOX_ENTRIES }, (_, index) =>
      seededEntry(index, { createdAt: ascending(index), ...(index === 0 ? {} : { readAt: "2025-12-02T00:00:00.000Z" }) }));
    await store.update((document) => {
      document.inbox = full;
      return document;
    });
    await expect(service.enqueue({
      sessionId: "session-inbox", sourceId: "source-overflow", kind: "explicit", message: "Overflow",
    })).resolves.toBe("queued");
    const retained = (await store.snapshot()).inbox.map((entry) => entry.id);
    expect(retained).toHaveLength(MAXIMUM_NOTIFICATION_INBOX_ENTRIES);
    expect(retained).toContain("notification-000000");
    expect(retained).not.toContain("notification-000001");

    const allUnread = await fixture();
    await allUnread.service.upsertGrant(grant);
    await allUnread.store.update((document) => {
      document.inbox = Array.from({ length: MAXIMUM_NOTIFICATION_INBOX_ENTRIES }, (_, index) =>
        seededEntry(index, { createdAt: ascending(index) }));
      return document;
    });
    await expect(allUnread.service.enqueue({
      sessionId: "session-inbox", sourceId: "source-overflow-unread", kind: "explicit", message: "Overflow",
    })).resolves.toBe("queued");
    const evicted = (await allUnread.store.snapshot()).inbox.map((entry) => entry.id);
    expect(evicted).not.toContain("notification-000000");
    expect(evicted).toContain("notification-000001");
  });

  it("treats a read of a row that no longer exists as an idempotent no-op", async () => {
    const { service, store, root } = await fixture();
    await store.update((document) => {
      document.inbox = [seededEntry(0, { createdAt: ascending(0) })];
      return document;
    });
    const path = join(root, "gateway", "notifications.json");
    const before = await stat(path);
    await expect(service.markInboxRead({ id: "notification-evicted" })).resolves.toEqual({ changed: false });
    await expect(service.markInboxRead({ requestId: "request-evicted" })).resolves.toEqual({ changed: false });
    expect((await stat(path)).ino).toBe(before.ino);
    await expect(service.markInboxRead({ id: "notification-000000" })).resolves.toEqual({ changed: true, id: "notification-000000" });
    await expect(service.markInboxRead({ id: "notification-000000" })).resolves.toEqual({ changed: false, id: "notification-000000" });
  });

  it("creates an already-read row for an alert admitted while the user watched that chat", async () => {
    const { service, relay, store } = await fixture();
    await service.upsertGrant({ ...grant, previewsEnabled: true });
    await expect(service.enqueue({
      sessionId: "session-observed", sourceId: "source-observed", kind: "explicit",
      message: "Delivered while observed", readOnAdmission: true,
    })).resolves.toBe("queued");
    // Delivery is unchanged: only the inbox row starts read.
    await vi.waitFor(() => expect(relay.sent).toHaveLength(1));
    expect(relay.sent[0]?.message).toBe("Delivered while observed");
    const page = await service.inbox();
    expect(page.notifications[0]).toMatchObject({ message: "Delivered while observed", isUnread: false });
    expect(page.unreadCount).toBe(0);
    expect((await store.snapshot()).inbox[0]?.readAt).toBeDefined();
  });

  it("coalesces a burst of admission, delivery settlement and read into one final broadcast", async () => {
    vi.useFakeTimers();
    try {
      const changed = vi.fn();
      let clock = Date.parse("2026-01-01T00:00:00.000Z");
      const { service } = await fixture(["accepted_by_apns"], () => clock++, undefined, changed);
      await service.upsertGrant(grant);
      const drains = vi.spyOn(service, "drain");
      await expect(service.enqueue({
        sessionId: "session-burst", sourceId: "source-burst", kind: "explicit", message: "Burst",
      })).resolves.toBe("queued");
      await Promise.all(drains.mock.results.map((result) => result.value));
      const item = (await service.inbox()).notifications[0]!;
      await expect(service.markInboxRead({ id: item.id })).resolves.toMatchObject({ changed: true });
      // Nothing is broadcast inside the trailing window.
      expect(changed).not.toHaveBeenCalled();
      await vi.advanceTimersByTimeAsync(250);
      expect(changed).toHaveBeenCalledOnce();
      expect(changed.mock.calls[0]?.[0]).toMatchObject({ unreadCount: 0 });
      expect(changed.mock.calls[0]?.[0].revision).toEqual(expect.any(String));
    } finally {
      vi.useRealTimers();
    }
  });
});
