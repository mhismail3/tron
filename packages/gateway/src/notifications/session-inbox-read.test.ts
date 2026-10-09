import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import * as durableJson from "../util/durable-json.js";
import { NotificationGrantStore, notificationHash, type NotificationInboxEntry } from "./grant-store.js";
import { NotificationService } from "./notification-service.js";
import type { PushRelayClient } from "./relay-client.js";
import { waitFor } from "../../test-support/wait-for.js";

const roots: string[] = [];
afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

function entry(index: number, sessionId = "session-a"): NotificationInboxEntry {
  return {
    id: `notification-${index}`, dedupeKey: notificationHash(`dedupe-${index}`),
    requestIds: [`request-${index}`], kind: "explicit",
    createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z",
    title: "Alert", message: "An update", sessionId, outcome: "queued",
  };
}

async function fixture(entries: NotificationInboxEntry[]) {
  const root = await mkdtemp(join(tmpdir(), "tron-session-inbox-"));
  roots.push(root);
  const store = new NotificationGrantStore(root);
  await store.initialize();
  await store.update((document) => ({ ...document, inbox: entries }));
  const relay = {
    available: false, relayOrigin: "https://push.example.test",
    send: vi.fn(async () => "accepted_by_apns" as const),
    revoke: vi.fn(async () => "revoked" as const),
  };
  const changed = vi.fn();
  const service = new NotificationService(store, relay as unknown as PushRelayClient,
    () => Date.parse("2026-01-01T00:00:00.000Z"), changed);
  return { root, store, relay, service, changed };
}

const grant = {
  deviceId: "device_abcdefgh", installationId: "install_abcdefgh", grantId: "grant_abcdefgh",
  secret: Buffer.alloc(32, 9).toString("base64url"), previewsEnabled: true,
  relayOrigin: "https://push.example.test",
};

describe("session notification read cuts", () => {
  it("reads every kind/outcome beyond a page, preserves other sessions and survives restart", async () => {
    const kinds = ["explicit", "ask", "agent_finished"] as const;
    const outcomes = ["queued", "accepted_by_apns", "failed", "ambiguous", "expired"] as const;
    const entries: NotificationInboxEntry[] = Array.from({ length: 80 }, (_, index) => ({
      ...entry(index, index < 70 ? "session-a" : "session-b"),
      kind: kinds[index % kinds.length]!, outcome: outcomes[index % outcomes.length]!,
    }));
    entries[0] = { ...entries[0]!, readAt: "2026-01-01T00:00:01.000Z" };
    const { root, service, store, changed } = await fixture(entries);
    await service.markSessionInboxRead("session-a");
    const saved = (await store.snapshot()).inbox!;
    expect(saved.slice(0, 70).every((row) => row.readAt !== undefined)).toBe(true);
    expect(saved[0]).toEqual(entries[0]);
    expect(saved.slice(70)).toEqual(entries.slice(70));
    expect(saved.map(({ readAt: _, updatedAt: __, ...row }) => row))
      .toEqual(entries.map(({ readAt: _, updatedAt: __, ...row }) => row));
    await waitFor(() => changed.mock.calls.at(-1)?.[0]?.unreadCount === 10, "the session read-cut broadcast");
    const restored = new NotificationService(new NotificationGrantStore(root), { available: false } as PushRelayClient);
    const page = await restored.inbox();
    expect(page.notifications).toHaveLength(50);
    expect(page.unreadCount).toBe(10);
    expect(page.nextCursor).toBeDefined();
  });

  it("moves a rekeyed session's rows so the replacement identity acknowledges them", async () => {
    const { service, store } = await fixture([entry(1), entry(2, "session-b")]);
    await expect(service.rekeySession("session-a", "session-b")).resolves.toBe(true);
    expect((await service.inbox()).notifications.filter((item) => item.sessionId === "session-b")).toHaveLength(2);
    // The former identity no longer owns any row, and the replacement takes the
    // canonical cut over the rows it inherited.
    await service.markSessionInboxRead("session-a");
    expect((await store.snapshot()).inbox!.every((row) => row.readAt === undefined)).toBe(true);
    await service.markSessionInboxRead("session-b");
    expect((await store.snapshot()).inbox!.every((row) => row.readAt !== undefined)).toBe(true);
    // A rekey that matches nothing is not a credential-document write.
    const write = vi.spyOn(durableJson, "durableAtomicWriteJson");
    await expect(service.rekeySession("session-missing", "session-other")).resolves.toBe(false);
    expect(write).not.toHaveBeenCalled();
  });

  it("does not rewrite credentials or invalidate the inbox for an empty or already-read cut", async () => {
    const { service, changed } = await fixture([entry(1)]);
    const write = vi.spyOn(durableJson, "durableAtomicWriteJson");
    await service.markSessionInboxRead("session-other");
    expect(write).not.toHaveBeenCalled();
    expect(changed).not.toHaveBeenCalled();
    await service.markSessionInboxRead("session-a");
    expect(write).toHaveBeenCalledOnce();
    await waitFor(() => changed.mock.calls.length === 1, "the read-cut broadcast");
    write.mockClear();
    changed.mockClear();
    await service.markSessionInboxRead("session-a");
    await service.drain();
    expect(write).not.toHaveBeenCalled();
    expect(changed).not.toHaveBeenCalled();
  });

  it("retries failed writes while the relay is offline without consuming newer same-session alerts", async () => {
    const { service, store, changed } = await fixture([entry(1), entry(2, "session-b")]);
    vi.spyOn(durableJson, "durableAtomicWriteJson").mockRejectedValueOnce(new Error("planned persistence failure"));
    await expect(service.markSessionInboxRead("session-a")).rejects.toThrow("planned persistence failure");
    expect(changed).not.toHaveBeenCalled();
    expect((await store.snapshot()).inbox!.every((row) => row.readAt === undefined)).toBe(true);
    await store.update((document) => ({ ...document, inbox: [...document.inbox!, entry(3)] }));
    // This is the existing background tick, not another session opening.
    await service.drain();
    const saved = (await store.snapshot()).inbox!;
    expect(saved[0]!.readAt).toBeDefined();
    expect(saved.slice(1).every((row) => row.readAt === undefined)).toBe(true);
    await waitFor(() => changed.mock.calls.length === 1, "the read-cut broadcast");
  });

  it("linearizes the opening cut with real notification admission, even at equal timestamps", async () => {
    const { service, store, relay } = await fixture([]);
    relay.available = true;
    await service.upsertGrant(grant);
    // Delivery is independent of the admission/read ordering under test.
    vi.spyOn(service, "drain").mockResolvedValue();
    const before = service.enqueue({ sessionId: "session-a", sourceId: "before", kind: "ask", message: "Before" });
    const opened = service.markSessionInboxRead("session-a");
    const after = service.enqueue({ sessionId: "session-a", sourceId: "after", kind: "explicit", message: "After" });
    await Promise.all([before, opened, after]);
    const rows = (await store.snapshot()).inbox!;
    expect(rows.map((row) => [row.message, row.readAt !== undefined])).toEqual([["Before", true], ["After", false]]);
  });

  it("keeps the background drain retryable after a notification-state read failure", async () => {
    const { service, store, relay } = await fixture([]);
    relay.available = true;
    await service.upsertGrant(grant);
    vi.spyOn(store, "snapshot").mockRejectedValueOnce(new Error("planned state read failure"));
    await expect(service.drain()).resolves.toBeUndefined();
    const drains = vi.spyOn(service, "drain");
    await service.enqueue({ sessionId: "session-a", sourceId: "after-failure", kind: "explicit", message: "Recovered" });
    await Promise.all(drains.mock.results.map((result) => result.value));
    expect((await store.snapshot()).inbox![0]).toMatchObject({ outcome: "accepted_by_apns", message: "Recovered" });
  });

  it("never resurrects a queued row when its in-flight APNs delivery settles", async () => {
    const { service, store, relay } = await fixture([]);
    relay.available = true;
    await service.upsertGrant(grant);
    let settle!: (value: "accepted_by_apns") => void;
    relay.send.mockImplementation(() => new Promise((resolve) => { settle = resolve; }));
    const drain = vi.spyOn(service, "drain");
    try {
      await service.enqueue({ sessionId: "session-a", sourceId: "queued", kind: "explicit", message: "Pending delivery" });
      await waitFor(() => relay.send.mock.calls.length === 1, "the pending relay delivery");
      await service.markSessionInboxRead("session-a");
      expect((await store.snapshot()).inbox![0]).toMatchObject({ outcome: "queued", readAt: expect.any(String) });
    } finally {
      settle?.("accepted_by_apns");
      await Promise.all(drain.mock.results.map((result) => result.value));
    }
    expect((await store.snapshot()).inbox![0]).toMatchObject({ outcome: "accepted_by_apns", readAt: expect.any(String) });
  });
});
