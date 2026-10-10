import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { NotificationGrantStore, notificationHash } from "../notifications/grant-store.js";
import { NotificationService } from "../notifications/notification-service.js";
import type { PushRelayClient } from "../notifications/relay-client.js";
import * as durableJson from "../util/durable-json.js";
import { RuntimeRegistry } from "./runtime-registry.js";

const roots: string[] = [];
const registries: RuntimeRegistry[] = [];
afterEach(async () => {
  await Promise.all(registries.splice(0).map((registry) => registry.dispose()));
  vi.restoreAllMocks();
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-visible-inbox-"));
  roots.push(root);
  const store = new NotificationGrantStore(root);
  await store.initialize();
  const notifications = new NotificationService(store, { available: false } as PushRelayClient);
  const reads = vi.spyOn(notifications, "markSessionInboxRead");
  // No agent runtime is opened: this exercises the real admitted-subscription,
  // presence and notification owners without a provider or delivery service.
  const registry = new RuntimeRegistry({
    agentDir: join(root, "agent"), tronHome: root, idleRuntimeMs: 60_000,
    trust: new TrustService(join(root, "agent")), broadcast() {}, sessionSummaryChanged() {}, sessionListChanged() {},
    notifications,
  });
  registries.push(registry);
  const append = async (id: string, sessionId = "session-a") => {
    await store.update((document) => {
      document.inbox!.push({
        id, sessionId, dedupeKey: notificationHash(id), requestIds: [`request-${id}`], kind: "explicit",
        createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z",
        title: "Alert", message: "Message", outcome: "accepted_by_apns",
      });
      return document;
    });
  };
  const present = (revision: number, visible = true, subscriptionToken = "token-a") => registry.setPresentationVisibility({
    clientId: "phone", sessionId: "session-a", subscriptionToken, revision, visible,
  });
  return { store, notifications, reads, registry, append, present };
}

describe("visible session notification read admission", () => {
  it("acknowledges only opening/re-entry cuts, not subscriptions, hidden claims or renewals", async () => {
    const { store, reads, registry, append, present } = await fixture();
    await append("notification-a");
    await append("notification-b", "session-b");
    expect(() => present(1)).toThrow("subscription is not current");
    expect(reads).not.toHaveBeenCalled();
    registry.subscribe("phone", "session-a");
    present(1, false);
    expect(reads).not.toHaveBeenCalled();
    expect(present(2)).toEqual({ visible: true, revision: 2 });
    await reads.mock.results[0]?.value;
    expect((await store.snapshot()).inbox!.map((row) => [row.id, row.readAt !== undefined]))
      .toEqual([["notification-a", true], ["notification-b", false]]);

    await append("notification-later");
    present(2); // duplicate
    present(1); // delayed request
    present(3); // normal 15-second renewal
    expect(reads).toHaveBeenCalledTimes(1);
    expect((await store.snapshot()).inbox![2]!.readAt).toBeUndefined();
    present(4, false);
    present(3); // old visible request must not resurrect the hidden owner
    expect(reads).toHaveBeenCalledTimes(1);
    present(5);
    await reads.mock.results[1]!.value;
    expect((await store.snapshot()).inbox![2]!.readAt).toBeDefined();

    await append("notification-reconnect");
    present(1, true, "replacement-token");
    await reads.mock.results[2]!.value;
    expect((await store.snapshot()).inbox![3]!.readAt).toBeDefined();
    registry.unsubscribeClient("phone");
  });

  it("finishes a failed admitted write after the chat/socket leaves without reading later arrivals", async () => {
    const { store, notifications, reads, registry, append, present } = await fixture();
    await append("notification-original");
    registry.subscribe("phone", "session-a");
    vi.spyOn(durableJson, "durableAtomicWriteJson").mockRejectedValueOnce(new Error("planned persistence failure"));
    expect(present(1)).toEqual({ visible: true, revision: 1 });
    await expect(reads.mock.results[0]!.value).rejects.toThrow("planned persistence failure");
    registry.unsubscribeClient("phone");
    await append("notification-after-close");
    await notifications.drain();
    expect((await store.snapshot()).inbox!.map((row) => [row.id, row.readAt !== undefined]))
      .toEqual([["notification-original", true], ["notification-after-close", false]]);
    expect(registry.isSessionPresented("session-a")).toBe(false);
  });
});
