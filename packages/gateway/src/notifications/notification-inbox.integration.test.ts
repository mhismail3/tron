import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { NotificationGrantStore, notificationHash, type NotificationInboxEntry } from "./grant-store.js";
import { NotificationService, type NotificationInboxChanged, type NotificationInboxItem } from "./notification-service.js";
import type { PushRelayClient } from "./relay-client.js";
import { GatewayService, type ClientContext } from "../transport/gateway-service.js";
import { waitFor } from "../../test-support/wait-for.js";

/**
 * Failure modes this case owns against the real RPC handlers and one real
 * on-disk credential document:
 * 1. a single unread row older than the newest page lit the bell but was absent
 *    from every page and unattainable through a client-side "Unread" filter;
 * 2. the retired offset+revision cursor failed with `conflict` as soon as the
 *    inbox changed, and could return or skip rows after reads between pages;
 * 3. read-all marked the whole inbox, including alerts the user never saw;
 * 4. reading a row already evicted by the bound failed as `not_found`;
 * 5. each mutation broadcast `notification.inbox.changed` with an empty payload,
 *    forcing the client to refetch without a revision or unread count.
 * Retained, regenerable evidence for one run lives at
 * `packages/gateway/test-results/notification-inbox.integration.json`.
 */
const REPORT_PATH = join(process.cwd(), "test-results", "notification-inbox.integration.json");
const report: {
  generatedAt: string;
  cases: Array<{ name: string; passed: boolean; evidence: Record<string, unknown> }>;
} = { generatedAt: new Date().toISOString(), cases: [] };

function record(name: string, evidence: Record<string, unknown>): void {
  report.cases.push({ name, passed: true, evidence });
}

afterAll(async () => {
  await mkdir(dirname(REPORT_PATH), { recursive: true });
  await writeFile(REPORT_PATH, `${JSON.stringify(report, null, 2)}\n`, "utf8");
});

const roots: string[] = [];
afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

const INBOX_ROWS = 62;
const createdAt = (index: number): string => new Date(Date.parse("2026-01-01T00:00:00.000Z") + index * 1_000).toISOString();
const rowId = (index: number): string => `notification-${index.toString().padStart(6, "0")}`;
/** The keyset key a client derives from the newest row it has displayed. */
const keyOf = (item: Pick<NotificationInboxItem, "createdAt" | "id">): string => `${Date.parse(item.createdAt)}.${item.id}`;

function row(index: number, unread: boolean): NotificationInboxEntry {
  return {
    id: rowId(index),
    dedupeKey: notificationHash(`inbox-row-${index}`),
    requestIds: [`request-${index.toString().padStart(6, "0")}`],
    kind: "agent_finished",
    createdAt: createdAt(index),
    updatedAt: createdAt(index),
    title: "Agent finished",
    message: "The agent finished responding.",
    sessionId: "session-inbox",
    outcome: "accepted_by_apns",
    ...(unread ? {} : { readAt: "2026-01-01T00:10:00.000Z" }),
  };
}

const client = (): ClientContext => ({
  id: "connection-integration", identity: "device_abcdefgh", isLocal: false,
  beginSynchronization: () => "sync", establishSynchronization() {}, completeSynchronization() {}, unsubscribe: () => true,
  attachTerminal() {}, detachTerminal() {}, ownsTerminal: () => false,
  isSubscribed: () => true, isRevoked: () => false, revokeDevice: () => {},
});

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-notification-inbox-"));
  roots.push(root);
  const store = new NotificationGrantStore(root);
  await store.initialize();
  // The newest row and the single oldest row are the two unread alerts: the
  // oldest one is exactly the row the retired client-side filter could not see.
  await store.update((document) => {
    document.inbox = Array.from({ length: INBOX_ROWS }, (_, index) => row(index, index === 0 || index === INBOX_ROWS - 1));
    return document;
  });
  const broadcasts: NotificationInboxChanged[] = [];
  const notifications = new NotificationService(
    store,
    { available: false, relayOrigin: "https://push.example.test" } as PushRelayClient,
    Date.now,
    undefined,
    (payload) => broadcasts.push(payload),
  );
  const service = new GatewayService({
    config: { tronHome: root },
    notifications,
    sessions: { isAdministrativeDrainStarted: false },
    devices: { hasDevice: async () => false, revoke: async () => false },
    receipts: { execute: async (_identity: string, _method: string, _command: string, operation: () => Promise<unknown>) => operation() },
  } as never);
  return { root, store, notifications, broadcasts, service };
}

const invoke = async (service: GatewayService, method: string, params: Record<string, unknown>) =>
  await service.invoke(client(), method, params) as Record<string, unknown>;

describe("notification inbox RPCs over a real credential document", () => {
  it("pages, filters, cuts and acknowledges the whole inbox across a full walk", async () => {
    const { notifications, broadcasts, service } = await fixture();
    const list = async (params: Record<string, unknown>) =>
      await invoke(service, "notification.inbox.list", params) as unknown as {
        notifications: NotificationInboxItem[]; revision: string; unreadCount: number; nextCursor?: string;
      };

    const first = await list({ limit: 50 });
    expect(first.notifications).toHaveLength(50);
    expect(first.unreadCount).toBe(2);
    expect(first.nextCursor).toBeDefined();
    expect(first.notifications.some((item) => item.id === rowId(0))).toBe(false);
    expect(first.notifications.filter((item) => item.isUnread).map((item) => item.id)).toEqual([rowId(INBOX_ROWS - 1)]);

    // Every row is reachable exactly once, and the unread filter surfaces the
    // oldest alert that the first page could never show.
    const walked: string[] = first.notifications.map((item) => item.id);
    const second = await list({ cursor: first.nextCursor!, limit: 50 });
    walked.push(...second.notifications.map((item) => item.id));
    expect(second.nextCursor).toBeUndefined();
    expect(walked).toHaveLength(INBOX_ROWS);
    expect(new Set(walked).size).toBe(INBOX_ROWS);

    const unread = await list({ filter: "unread", limit: 50 });
    expect(unread.notifications.map((item) => item.id)).toEqual([rowId(INBOX_ROWS - 1), rowId(0)]);
    expect(unread.nextCursor).toBeUndefined();

    // Marking a read row does not invalidate the page cursor the client holds.
    await invoke(service, "notification.inbox.read", { commandId: "command-read-mid", id: second.notifications[0]!.id });
    const resumed = await list({ cursor: first.nextCursor!, limit: 50 });
    expect(resumed.notifications.map((item) => item.id)).toEqual(second.notifications.map((item) => item.id));

    // A cut at the second-newest row acknowledges the whole older history and
    // leaves the alert the user has not seen unread.
    const cut = keyOf(first.notifications[1]!);
    const partial = await invoke(service, "notification.inbox.readAll", { commandId: "command-read-all-cut", through: cut });
    expect(partial).toEqual({ changed: 1 });
    const afterCut = await list({ filter: "unread", limit: 50 });
    expect(afterCut.notifications.map((item) => item.id)).toEqual([rowId(INBOX_ROWS - 1)]);
    expect(afterCut.unreadCount).toBe(1);

    const complete = await invoke(service, "notification.inbox.readAll", {
      commandId: "command-read-all-complete",
      through: keyOf(first.notifications[0]!),
    });
    expect(complete).toEqual({ changed: 1 });
    const final = await list({});
    expect(final.unreadCount).toBe(0);
    expect(final.notifications.every((item) => !item.isUnread)).toBe(true);

    // An evicted row is an idempotent no-op, and a malformed cursor or missing
    // cut is rejected instead of silently returning a wrong page.
    await expect(invoke(service, "notification.inbox.read", { commandId: "command-read-evicted", id: "notification-evicted" }))
      .resolves.toEqual({ changed: false });
    await expect(invoke(service, "notification.inbox.list", { cursor: "revision:50" }))
      .rejects.toMatchObject({ code: "invalid_request" });
    await expect(invoke(service, "notification.inbox.readAll", { commandId: "command-read-all-missing-cut" }))
      .rejects.toMatchObject({ code: "invalid_request" });

    // The coalesced broadcast carries the committed state, not an empty payload.
    await waitFor(() => broadcasts.at(-1)?.unreadCount === 0, "the coalesced read-all broadcast");
    const lastBroadcast = broadcasts.at(-1)!;
    expect(lastBroadcast.revision).toEqual(expect.any(String));
    expect(lastBroadcast.revision).toBe(final.revision);
    record("pages, filters, cuts and acknowledges the whole inbox", {
      rows: INBOX_ROWS,
      firstPage: first.notifications.map((item) => item.id),
      walkedRows: walked.length,
      unreadAfterCut: afterCut.notifications.map((item) => item.id),
      broadcast: lastBroadcast,
      revision: final.revision,
    });
  });

  it("keeps the credential document unchanged across read-only listing", async () => {
    const { root, store, service } = await fixture();
    const path = join(root, "gateway", "notifications.json");
    const before = await stat(path);
    const bytes = await readFile(path);
    await invoke(service, "notification.inbox.list", { limit: 10, filter: "unread" });
    await invoke(service, "notification.inbox.list", {});
    const after = await stat(path);
    expect(after.ino).toBe(before.ino);
    expect(after.mtimeMs).toBe(before.mtimeMs);
    expect(await readFile(path)).toEqual(bytes);
    expect((await store.snapshot()).inbox).toHaveLength(INBOX_ROWS);
    record("keeps the credential document unchanged across read-only listing", {
      bytes: bytes.byteLength,
      rows: INBOX_ROWS,
    });
  });
});
