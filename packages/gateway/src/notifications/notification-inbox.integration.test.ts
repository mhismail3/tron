import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { NotificationGrantStore, notificationHash, type NotificationInboxEntry } from "./grant-store.js";
import { NotificationService, type NotificationInboxChanged, type NotificationInboxItem } from "./notification-service.js";
import { PushRelayClient } from "./relay-client.js";
import { GatewayService, type ClientContext } from "../transport/gateway-service.js";
import { waitFor } from "../../test-support/wait-for.js";

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

  isSubscribed: () => true, isRevoked: () => false, revokeDevice: () => {},
});

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-notification-inbox-"));
  roots.push(root);
  const store = new NotificationGrantStore(root);
  await store.initialize();
  await store.update((document) => {
    document.inbox = Array.from({ length: INBOX_ROWS }, (_, index) => row(index, index === 0 || index === INBOX_ROWS - 1));
    return document;
  });
  const broadcasts: NotificationInboxChanged[] = [];
  const notifications = new NotificationService(
    store,
    { available: false, relayOrigin: "https://push.example.test" } as PushRelayClient,
    async () => ({ inputNeeded: true, finished: true, waiting: true }),
    Date.now,
    (payload) => broadcasts.push(payload),
  );
  const service = new GatewayService({ display: {} as never,
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

    const walked: string[] = first.notifications.map((item) => item.id);
    const second = await list({ cursor: first.nextCursor!, limit: 50 });
    walked.push(...second.notifications.map((item) => item.id));
    expect(second.nextCursor).toBeUndefined();
    expect(walked).toHaveLength(INBOX_ROWS);
    expect(new Set(walked).size).toBe(INBOX_ROWS);

    const unread = await list({ filter: "unread", limit: 50 });
    expect(unread.notifications.map((item) => item.id)).toEqual([rowId(INBOX_ROWS - 1), rowId(0)]);
    expect(unread.nextCursor).toBeUndefined();

    await invoke(service, "notification.inbox.read", { commandId: "command-read-mid", id: second.notifications[0]!.id });
    const resumed = await list({ cursor: first.nextCursor!, limit: 50 });
    expect(resumed.notifications.map((item) => item.id)).toEqual(second.notifications.map((item) => item.id));

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

    await expect(invoke(service, "notification.inbox.read", { commandId: "command-read-evicted", id: "notification-evicted" }))
      .resolves.toEqual({ changed: false });
    await expect(invoke(service, "notification.inbox.list", { cursor: "revision:50" }))
      .rejects.toMatchObject({ code: "invalid_request" });
    await expect(invoke(service, "notification.inbox.readAll", { commandId: "command-read-all-missing-cut" }))
      .rejects.toMatchObject({ code: "invalid_request" });

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
    const path = join(root, "state", "notifications.json");
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

describe("push alert policy is read from the Global keys", () => {
  it("sends no push for a kind whose key is off and one push for a kind whose key is on", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-notification-policy-"));
    roots.push(root);
    const relayOrigin = "https://relay.policy.invalid";
    const envelopes: Array<Record<string, unknown>> = [];
    const relay = new PushRelayClient(relayOrigin, async (_url, init) => {
      envelopes.push(JSON.parse(String(init.body)) as Record<string, unknown>);
      return new Response(JSON.stringify({ status: "accepted_by_apns" }), { status: 200 }) as never;
    });
    const store = new NotificationGrantStore(root);
    await store.initialize();
    const policy = { inputNeeded: false, finished: true, waiting: true };
    const notifications = new NotificationService(store, relay, async () => ({ ...policy }));
    await notifications.initialize();
    await notifications.upsertGrant({
      deviceId: "device_abcdefgh", installationId: "install_abcdefgh", grantId: "grant_abcdefgh",
      secret: Buffer.alloc(32, 7).toString("base64url"), previewsEnabled: false, relayOrigin,
    });
    expect(await notifications.enqueue({ sessionId: "session-policy", sourceId: "ask-off", kind: "ask", message: "Input needed" })).toBe("suppressed");
    expect(envelopes).toHaveLength(0);
    policy.inputNeeded = true;
    expect(await notifications.enqueue({ sessionId: "session-policy", sourceId: "ask-on", kind: "ask", message: "Input needed" })).toBe("queued");
    await waitFor(() => envelopes.length === 1, "the push for the kind whose key is on");
    expect(envelopes).toHaveLength(1);
    record("push policy keys gate admission", { suppressedWhileOff: true, pushedWhileOn: envelopes.length });
  });
});
