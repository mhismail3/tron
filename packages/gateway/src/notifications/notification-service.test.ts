import { chmod, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { NotificationGrantStore } from "./grant-store.js";
import { NotificationService } from "./notification-service.js";
import type { PushRelayClient, RelayNotificationOutcome } from "./relay-client.js";

const grant = {
  deviceId: "device_abcdefgh", installationId: "install_abcdefgh", grantId: "grant_abcdefgh",
  secret: Buffer.alloc(32, 9).toString("base64url"), environment: "sandbox" as const,
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

async function fixture(outcomes?: RelayNotificationOutcome[], now: () => number = Date.now) {
  const root = await mkdtemp(join(tmpdir(), "tron-notifications-"));
  const store = new NotificationGrantStore(root);
  await store.initialize();
  const relay = fakeRelay(outcomes);
  const service = new NotificationService(store, relay.client, now);
  return { root, store, service, relay };
}

describe("NotificationGrantStore and NotificationService", () => {
  it("persists only the bounded grant capability, admits durably, redacts previews, and deduplicates tool calls", async () => {
    const { root, store, service, relay } = await fixture();
    await service.upsertGrant({ ...grant, notifyWhenAskPresented: true });
    await expect(service.enqueue({ sessionId: "session-one", toolCallId: "tool-one", kind: "explicit", message: "sensitive text" })).resolves.toBe("queued");
    await vi.waitFor(() => expect(relay.sent).toHaveLength(1));
    expect(relay.sent[0].message).toBe("Tron has an update. Open Tron to view it.");
    await expect(service.enqueue({ sessionId: "session-one", toolCallId: "tool-one", kind: "explicit", message: "changed" })).resolves.toBe("suppressed");
    const persisted = await readFile(join(root, "gateway", "notifications.json"), "utf8");
    expect(persisted).not.toContain("sensitive text");
    expect(persisted).not.toContain("apnsToken");
    expect((await store.snapshot()).receipts[0]?.result).toBe("accepted_by_apns");
  });

  it("uses agent text only for a grant whose user enabled previews", async () => {
    const { service, relay } = await fixture();
    await service.upsertGrant({ ...grant, previewsEnabled: true });
    await service.enqueue({ sessionId: "session-one", toolCallId: "tool-two", kind: "explicit", message: "Build finished" });
    await vi.waitFor(() => expect(relay.sent).toHaveLength(1));
    expect(relay.sent[0].message).toBe("Build finished");
  });

  it("disables invalid APNs grants and retains no future audience", async () => {
    const { service, relay } = await fixture(["invalid_token"]);
    await service.upsertGrant(grant);
    await service.enqueue({ sessionId: "session-one", toolCallId: "tool-three", kind: "explicit", message: "hello" });
    await vi.waitFor(async () => expect((await service.status(grant.deviceId)).deviceRegistered).toBe(false));
    await expect(service.enqueue({ sessionId: "session-one", toolCallId: "tool-four", kind: "explicit", message: "hello" })).resolves.toBe("unavailable");
    expect(relay.sent).toHaveLength(1);
  });

  it("removes local authority first and drains a durable revocation tombstone", async () => {
    const { service, relay, store } = await fixture();
    await service.upsertGrant(grant);
    await expect(service.removeDevice(grant.deviceId)).resolves.toBe(true);
    expect((await service.status(grant.deviceId)).deviceRegistered).toBe(false);
    await service.drain();
    expect(relay.revoked).toEqual([grant.grantId]);
    expect((await store.snapshot()).revocations).toEqual([]);
  });

  it("rotates grants by retaining and draining a revocation tombstone for the previous capability", async () => {
    const { service, relay } = await fixture();
    await service.upsertGrant(grant);
    await service.upsertGrant({ ...grant, grantId: "grant_ijklmnop", secret: Buffer.alloc(32, 8).toString("base64url") });
    await vi.waitFor(() => expect(relay.revoked).toContain(grant.grantId));
    expect((await service.status(grant.deviceId)).enabledDeviceCount).toBe(1);
  });

  it("enforces the durable per-session hourly quota", async () => {
    const { service } = await fixture();
    await service.upsertGrant(grant);
    for (let index = 0; index < 12; index += 1) {
      await expect(service.enqueue({ sessionId: "session-quota", toolCallId: `tool-${index}`, kind: "explicit", message: "hello" })).resolves.toBe("queued");
    }
    await expect(service.enqueue({ sessionId: "session-quota", toolCallId: "tool-over-limit", kind: "explicit", message: "hello" })).resolves.toBe("rate_limited");
  });

  it("recovers a retryable pending intent with the same request identity after restart", async () => {
    let clock = Date.parse("2026-01-01T00:00:00.000Z");
    const { store, service, relay } = await fixture(["retryable"], () => clock);
    await service.upsertGrant(grant);
    await service.enqueue({ sessionId: "session-restart", toolCallId: "tool-restart", kind: "explicit", message: "hello" });
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
