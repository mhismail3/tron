import { createHash, randomUUID } from "node:crypto";
import { GatewayError } from "../errors.js";
import {
  MAXIMUM_NOTIFICATION_INBOX_ENTRIES,
  MAXIMUM_NOTIFICATION_RECEIPTS,
  MAXIMUM_PENDING_INTENTS,
  MAXIMUM_PUSH_GRANTS,
  MAXIMUM_REVOCATIONS,
  NotificationGrantStore,
  notificationHash,
  isEndpointSecret,
  type NotificationDocument,
  type NotificationInboxEntry,
  type NotificationInboxOutcome,
  type NotificationKind,
  type NotificationReceipt,
  type PushGrant,
} from "./grant-store.js";
import { PushRelayClient, type RelayNotificationOutcome } from "./relay-client.js";

const INTENT_TTL_MS = 15 * 60_000;
const RECEIPT_TTL_MS = 24 * 60 * 60_000;
interface NotificationRateLimits {
  dailyIntents: number;
  sessionHourlyIntents: number;
  targetDailyIntents: number;
}

const DEFAULT_NOTIFICATION_RATE_LIMITS: NotificationRateLimits = {
  // Receipts are bounded to 512 entries, so these remain enforceable abuse
  // ceilings without throttling ordinary high-volume local agent workflows.
  dailyIntents: 480,
  sessionHourlyIntents: 240,
  targetDailyIntents: 480,
};
const GENERIC_MESSAGE = "Tron has an update. Open Tron to view it.";
const RETRY_DELAYS_MS = [5_000, 20_000, 60_000, 180_000] as const;
const ACTIVE_OUTCOMES = new Set(["pending", "retryable"]);
const SESSION_ROUTE_ID = /^[A-Za-z0-9_:-]{1,160}$/u;
// Trailing coalescing window for `notification.inbox.changed`. A burst of
// admission, delivery settlement, and read mutations publishes the final state
// once instead of one broadcast per committed write.
const INBOX_CHANGED_DEBOUNCE_MS = 250;
const INBOX_CURSOR = /^(-?\d{1,16})\.([A-Za-z0-9_-]{8,160})$/u;

export type NotificationAdmissionStatus = "queued" | "suppressed" | "rate_limited" | "unavailable";
export interface NotificationStatus {
  available: boolean;
  registered: boolean;
  deviceRegistered: boolean;
  enabledDeviceCount: number;
  pendingCount: number;
  notifyWhenAskPresented: boolean;
  notifyWhenFinished: boolean;
  notifyWhenWaiting: boolean;
  relayOrigin?: string;
  requiresGrantRotation: boolean;
}

export interface NotificationInboxItem {
  version: 1;
  id: string;
  kind: NotificationKind;
  createdAt: string;
  updatedAt: string;
  title: string;
  message: string;
  sessionId: string;
  isUnread: boolean;
  outcome: NotificationInboxOutcome;
}
export interface NotificationInboxPage {
  notifications: NotificationInboxItem[];
  revision: string;
  unreadCount: number;
  nextCursor?: string;
}
/** The coalesced `notification.inbox.changed` payload: the committed state the
 * client can compare against its cache and project onto the bell immediately. */
export type NotificationInboxChanged = { revision: string; unreadCount: number };
export type NotificationInboxFilter = "all" | "unread";
/** One keyset position in the canonical inbox order: newest `createdAt` first,
 * then ascending id. */
interface InboxOrderKey { createdAt: number; id: string }

function inboxOrder(createdAt: string, id: string): InboxOrderKey { return { createdAt: Date.parse(createdAt), id }; }
function compareInboxOrder(left: InboxOrderKey, right: InboxOrderKey): number {
  if (left.createdAt !== right.createdAt) return right.createdAt - left.createdAt;
  return left.id.localeCompare(right.id);
}
function inboxCursor(key: InboxOrderKey): string { return `${key.createdAt}.${key.id}`; }
function parseInboxCursor(value: string): InboxOrderKey {
  const match = INBOX_CURSOR.exec(value);
  if (!match) throw new GatewayError("invalid_request", "Notification inbox cursor is invalid");
  return { createdAt: Number(match[1]), id: match[2]! };
}
function entryOrder(entry: NotificationInboxEntry): InboxOrderKey { return inboxOrder(entry.createdAt, entry.id); }

function iso(ms: number): string { return new Date(ms).toISOString(); }
function isID(value: string): boolean { return /^[A-Za-z0-9_-]{8,160}$/u.test(value); }
function boundedText(value: string, maximumBytes: number, field: "message" | "title"): string {
  const normalized = value.trim();
  if (!normalized || Buffer.byteLength(normalized) > maximumBytes || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(normalized)) {
    throw new GatewayError("invalid_request", `Notification ${field} must contain 1 through ${maximumBytes} UTF-8 bytes of text`);
  }
  return normalized;
}
function boundedRoute(route: { sessionId: string; machineId: string } | undefined, sessionId: string) {
  if (route === undefined) return undefined;
  if (route.sessionId !== sessionId || !SESSION_ROUTE_ID.test(route.sessionId) || !route.machineId
    || Buffer.byteLength(route.machineId) > 256 || /[\u0000-\u001f\u007f]/u.test(route.machineId)) {
    throw new GatewayError("invalid_request", "Notification route is malformed");
  }
  return route;
}
/** Bounded inbox retention over the admission-ordered (oldest-first) rows: read
 * rows are evicted before any unread row, so an unread alert is never dropped
 * while a read row still occupies the bound. */
function retainInboxRows(inbox: NotificationInboxEntry[]): NotificationInboxEntry[] {
  if (inbox.length <= MAXIMUM_NOTIFICATION_INBOX_ENTRIES) return inbox;
  const excess = inbox.length - MAXIMUM_NOTIFICATION_INBOX_ENTRIES;
  const evicted = new Set<string>();
  for (const entry of inbox) {
    if (evicted.size >= excess) break;
    if (entry.readAt !== undefined) evicted.add(entry.id);
  }
  for (const entry of inbox) {
    if (evicted.size >= excess) break;
    if (entry.readAt === undefined) evicted.add(entry.id);
  }
  return inbox.filter((entry) => !evicted.has(entry.id));
}

function prune(document: NotificationDocument, now: number): NotificationDocument {
  const expired = new Set(document.pending.filter((intent) => Date.parse(intent.expiresAt) <= now).map((intent) => intent.dedupeKey));
  for (const receipt of document.receipts) if (expired.has(receipt.dedupeKey) && receipt.result === "queued") receipt.result = "expired";
  for (const entry of document.inbox) {
    if (expired.has(entry.dedupeKey) && entry.outcome === "queued") {
      entry.outcome = "expired";
      entry.updatedAt = iso(now);
    }
  }
  document.receipts = document.receipts.filter((receipt) => Date.parse(receipt.expiresAt) > now).slice(-512);
  document.pending = document.pending.filter((intent) => Date.parse(intent.expiresAt) > now).slice(-MAXIMUM_PENDING_INTENTS);
  document.inbox = retainInboxRows(document.inbox);
  // Revocation authority must be retained until the relay acknowledges it.
  document.revocations = document.revocations.slice(-MAXIMUM_REVOCATIONS);
  return document;
}
function receiptFor(input: {
  dedupeKey: string; sessionKey: string; grantIds: string[]; now: number; result: NotificationReceipt["result"];
}): NotificationReceipt {
  return { dedupeKey: input.dedupeKey, sessionKey: input.sessionKey, grantIds: input.grantIds, createdAt: iso(input.now), expiresAt: iso(input.now + RECEIPT_TTL_MS), result: input.result };
}

/** Revision over every projected inbox field, so a session rekey that moves
 * rows between identities is as visible to clients as a read or outcome change. */
function inboxRevision(entries: NotificationInboxEntry[]): string {
  return createHash("sha256")
    .update(entries.map((entry) => `${entry.id}\0${entry.updatedAt}\0${entry.readAt ?? "unread"}\0${entry.outcome}\0${entry.sessionId}`).join("\n"))
    .digest("hex").slice(0, 32);
}

function inboxState(entries: NotificationInboxEntry[]): NotificationInboxChanged {
  return { revision: inboxRevision(entries), unreadCount: entries.filter((entry) => entry.readAt === undefined).length };
}

function inboxItem(entry: NotificationInboxEntry): NotificationInboxItem {
  return {
    version: 1,
    id: entry.id,
    kind: entry.kind,
    createdAt: entry.createdAt,
    updatedAt: entry.updatedAt,
    title: entry.title,
    message: entry.message,
    sessionId: entry.sessionId,
    isUnread: entry.readAt === undefined,
    outcome: entry.outcome,
  };
}

function retainRevocationAuthority(document: NotificationDocument, now: number): NotificationDocument {
  const revoking = new Set(document.revocations.map((item) => item.grantId));
  if (revoking.size === 0) return document;
  document.grants = document.grants.filter((grant) => !revoking.has(grant.grantId));
  for (const intent of document.pending) {
    intent.targets = intent.targets.filter((target) => !revoking.has(target.grantId));
    if (intent.targets.length === 0) {
      const receipt = document.receipts.find((candidate) => candidate.dedupeKey === intent.dedupeKey);
      if (receipt?.result === "queued") receipt.result = "failed";
      const inbox = document.inbox.find((entry) => entry.dedupeKey === intent.dedupeKey);
      if (inbox?.outcome === "queued") {
        inbox.outcome = "failed";
        inbox.updatedAt = iso(now);
      }
    }
  }
  document.pending = document.pending.filter((intent) => intent.targets.length > 0);
  return document;
}

export interface PushRegistrationInput {
  deviceId: string;
  installationId: string;
  grantId: string;
  secret: string;
  previewsEnabled: boolean;
  relayOrigin: string;
  notifyWhenAskPresented?: boolean;
  notifyWhenFinished?: boolean;
  notifyWhenWaiting?: boolean;
}

/** True when `previous` is exactly the grant this registration describes and the
 * retention pass left the document byte-identical (`before`). Both the durable
 * upsert and the receipt-free pre-check answer an identical registration with
 * the stored status, so they share this one predicate. */
function isUnchangedRegistration(
  document: NotificationDocument,
  before: string,
  previous: PushGrant | undefined,
  input: PushRegistrationInput,
): boolean {
  return previous !== undefined
    && previous.grantId === input.grantId
    && previous.installationId === input.installationId
    && previous.secret === input.secret
    && previous.relayOrigin === input.relayOrigin
    && previous.previewsEnabled === input.previewsEnabled
    && previous.active && previous.disabledReason === undefined
    && (input.notifyWhenAskPresented === undefined || document.policy.notifyWhenAskPresented === input.notifyWhenAskPresented)
    && (input.notifyWhenFinished === undefined || document.policy.notifyWhenFinished === input.notifyWhenFinished)
    && (input.notifyWhenWaiting === undefined || document.policy.notifyWhenWaiting === input.notifyWhenWaiting)
    && before === JSON.stringify(document);
}

/** The grant projection a reconnecting phone compares against the registration
 * it acknowledged: every grant's identity, activity, disabled reason and relay
 * origin, plus the origin the grants are valid for. It is derived from the
 * durable document alone, so it is stable across a Gateway restart that left
 * the document unchanged, and any runtime change to a grant (including the
 * relay disabling one) changes it (G-7). */
function registrationRevision(grants: readonly PushGrant[], relayOrigin: string | undefined): string {
  return createHash("sha256")
    .update([
      relayOrigin ?? "",
      ...grants
        .map((grant) => [grant.deviceId, grant.installationId, grant.grantId,
          grant.active ? "active" : grant.disabledReason ?? "inactive", grant.relayOrigin ?? ""].join("\0"))
        .sort(),
    ].join("\n"))
    .digest("hex")
    .slice(0, 32);
}

/** Gateway-owned push authority. Extension code receives only enqueue(), never credentials or transport. */
export class NotificationService {
  private timer: NodeJS.Timeout | undefined;
  private draining = false;
  private inboxChangedTimer: NodeJS.Timeout | undefined;
  private pendingInboxChanged: NotificationInboxChanged | undefined;
  private readonly pendingInboxReadIds = new Set<string>();
  private inboxReadFlush: Promise<void> | undefined;
  private advertisedGrantRevision = registrationRevision([], undefined);
  constructor(
    private readonly store: NotificationGrantStore,
    private readonly relay: PushRelayClient,
    private readonly now: () => number = Date.now,
    private readonly rateLimits: NotificationRateLimits = DEFAULT_NOTIFICATION_RATE_LIMITS,
    private readonly inboxChanged: (payload: NotificationInboxChanged) => void = () => {},
    private readonly inboxReadFailed: () => void = () => {},
  ) {}

  async initialize(): Promise<void> {
    await this.store.initialize();
    const now = this.now();
    await this.update((document) => retainRevocationAuthority(prune(document, now), now));
    this.timer = setInterval(() => void this.drain(), 2_000);
    this.timer.unref();
    void this.drain();
  }

  /** Every notification-document write refreshes the advertised grant revision,
   * which is what `hello`/`system.info` repeat so a reconnecting phone can tell
   * whether the registration it holds still describes what this Gateway stores. */
  private async update(transform: (document: NotificationDocument) => NotificationDocument | undefined): Promise<NotificationDocument> {
    const document = await this.store.update(transform);
    this.advertisedGrantRevision = registrationRevision(document.grants, this.relay.relayOrigin);
    return document;
  }

  /** Advertised grant revision; it changes exactly when this Gateway's stored
   * grants change. Read synchronously by the `system.info` projection. */
  get registrationRevision(): string { return this.advertisedGrantRevision; }

  dispose(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
    if (this.inboxChangedTimer) clearTimeout(this.inboxChangedTimer);
    this.inboxChangedTimer = undefined;
    this.pendingInboxChanged = undefined;
  }

  /** Publish one trailing `notification.inbox.changed` for a burst of committed
   * inbox mutations. The payload is that of the newest committed state. */
  private publishInboxChanged(document: NotificationDocument): void {
    this.pendingInboxChanged = inboxState(document.inbox);
    if (this.inboxChangedTimer) return;
    this.inboxChangedTimer = setTimeout(() => {
      this.inboxChangedTimer = undefined;
      const payload = this.pendingInboxChanged;
      this.pendingInboxChanged = undefined;
      if (!payload) return;
      try { this.inboxChanged(payload); } catch { /* invalidation delivery never owns canonical admission */ }
    }, INBOX_CHANGED_DEBOUNCE_MS);
    // Invalidation must never hold the process (or a test) open on its own.
    this.inboxChangedTimer.unref();
  }

  async upsertGrant(input: PushRegistrationInput): Promise<NotificationStatus> {
    if (![input.deviceId, input.installationId, input.grantId].every(isID) || !isEndpointSecret(input.secret)) {
      throw new GatewayError("invalid_request", "Push registration credentials are malformed");
    }
    if (!this.relay.relayOrigin || input.relayOrigin !== this.relay.relayOrigin) {
      return this.status(input.deviceId);
    }
    const now = this.now();
    let rotated = false;
    await this.update((document) => {
      // The phone re-sends its registration whenever it reconnects. When the
      // request describes the grant this document already holds, the answer is
      // the same status and the write would be byte-identical: return
      // undefined so neither the grant nor the receipt/revocation overlays are
      // rewritten (G-10's durable-write audit charged this path two fsyncs per
      // registration). The retention pass above still runs, so the fingerprint
      // compared below is also what proves it expired nothing.
      const before = JSON.stringify(document);
      retainRevocationAuthority(prune(document, now), now);
      if (document.revocations.some((item) => item.grantId === input.grantId)) {
        throw new GatewayError("conflict", "Push grant is awaiting revocation and must rotate before registration");
      }
      const anotherDevice = document.grants.find((grant) => grant.grantId === input.grantId && grant.deviceId !== input.deviceId);
      if (anotherDevice) throw new GatewayError("conflict", "Push grant is already bound to another device");
      const previous = document.grants.find((grant) => grant.deviceId === input.deviceId);
      if (isUnchangedRegistration(document, before, previous, input)) {
        return undefined;
      }
      if (previous && previous.grantId === input.grantId
        && (previous.relayOrigin !== input.relayOrigin
          || (!previous.active && previous.disabledReason === "invalid_token"))) {
        previous.active = false;
        previous.disabledReason = "invalid_token";
        previous.updatedAt = iso(now);
        return document;
      }
      if (previous && previous.grantId === input.grantId
        && (previous.installationId !== input.installationId || previous.secret !== input.secret)) {
        throw new GatewayError("conflict", "Push grant identity changed without an endpoint rotation");
      }
      const addsGrant = previous === undefined;
      const addsRevocation = previous !== undefined && previous.grantId !== input.grantId;
      if (document.grants.length + document.revocations.length + (addsGrant || addsRevocation ? 1 : 0) > MAXIMUM_REVOCATIONS) {
        throw new GatewayError("busy", "Push revocation capacity must drain before registering this endpoint", true);
      }
      if (addsRevocation) {
        rotated = true;
        document.revocations.push({
          grantId: previous.grantId,
          secret: previous.secret,
          requestId: notificationHash(`revoke\0${previous.grantId}`),
          createdAt: iso(now), attempts: 0, nextAttemptAt: iso(now),
        });
      }
      const next: PushGrant = {
        deviceId: input.deviceId,
        installationId: input.installationId,
        grantId: input.grantId,
        secret: input.secret,
        previewsEnabled: input.previewsEnabled,
        relayOrigin: input.relayOrigin,
        active: true,
        createdAt: previous?.createdAt ?? iso(now),
        updatedAt: iso(now),
      };
      document.grants = [...document.grants.filter((grant) => grant.deviceId !== input.deviceId && grant.grantId !== input.grantId), next];
      if (document.grants.length > MAXIMUM_PUSH_GRANTS) throw new GatewayError("busy", "Too many notification-enabled devices are registered", true);
      if (input.notifyWhenAskPresented !== undefined) document.policy.notifyWhenAskPresented = input.notifyWhenAskPresented;
      if (input.notifyWhenFinished !== undefined) document.policy.notifyWhenFinished = input.notifyWhenFinished;
      if (input.notifyWhenWaiting !== undefined) document.policy.notifyWhenWaiting = input.notifyWhenWaiting;
      return document;
    });
    if (rotated) void this.drain();
    return this.status(input.deviceId);
  }

  /** Answers whether this registration already describes the stored grant
   * without writing anything, so the RPC owner can answer an identical
   * registration without opening a command receipt (G-7 Do item 2). The read
   * runs outside the device's identity lane, so it is not ordered with that
   * device's lane operations: a remove or revoke racing an identical upsert is
   * read as whichever the snapshot happened to hold. It is read-only and can
   * never bring a grant back — it only decides to skip the write — and a relay
   * outcome that disables the grant in between is still visible in the status
   * the caller reads after the decision. */
  async registrationIsCurrent(input: PushRegistrationInput): Promise<boolean> {
    if (![input.deviceId, input.installationId, input.grantId].every(isID) || !isEndpointSecret(input.secret)) {
      throw new GatewayError("invalid_request", "Push registration credentials are malformed");
    }
    if (!this.relay.relayOrigin || input.relayOrigin !== this.relay.relayOrigin) return false;
    const document = await this.store.snapshot();
    const before = JSON.stringify(document);
    retainRevocationAuthority(prune(document, this.now()), this.now());
    if (document.revocations.some((item) => item.grantId === input.grantId)) return false;
    if (document.grants.some((grant) => grant.grantId === input.grantId && grant.deviceId !== input.deviceId)) return false;
    return isUnchangedRegistration(
      document,
      before,
      document.grants.find((grant) => grant.deviceId === input.deviceId),
      input,
    );
  }

  async removeDevice(deviceId: string): Promise<boolean> {
    let removed = false;
    let inboxDidChange = false;
    const now = this.now();
    const document = await this.update((current) => {
      prune(current, now);
      const grants = current.grants.filter((grant) => grant.deviceId === deviceId);
      removed = grants.length > 0;
      if (!removed) return undefined;
      current.grants = current.grants.filter((grant) => grant.deviceId !== deviceId);
      for (const intent of current.pending) {
        intent.targets = intent.targets.filter((target) => !grants.some((grant) => grant.grantId === target.grantId));
        if (intent.targets.length > 0) continue;
        const receipt = current.receipts.find((candidate) => candidate.dedupeKey === intent.dedupeKey);
        if (receipt?.result === "queued") receipt.result = "failed";
        const inbox = current.inbox.find((entry) => entry.dedupeKey === intent.dedupeKey);
        if (inbox?.outcome === "queued") {
          inbox.outcome = "failed";
          inbox.updatedAt = iso(now);
          inboxDidChange = true;
        }
      }
      current.pending = current.pending.filter((intent) => intent.targets.length > 0);
      for (const grant of grants) {
        current.revocations = current.revocations.filter((item) => item.grantId !== grant.grantId);
        current.revocations.push({
          grantId: grant.grantId,
          secret: grant.secret,
          requestId: notificationHash(`revoke\0${grant.grantId}`),
          createdAt: iso(now), attempts: 0, nextAttemptAt: iso(now),
        });
      }
      return current;
    });
    if (inboxDidChange) this.publishInboxChanged(document);
    if (removed) void this.drain();
    return removed;
  }

  async status(deviceId?: string): Promise<NotificationStatus> {
    const document = await this.store.snapshot();
    const revoking = new Set(document.revocations.map((item) => item.grantId));
    const relayOrigin = this.relay.relayOrigin;
    const active = document.grants.filter((grant) => grant.active && grant.relayOrigin === relayOrigin
      && !revoking.has(grant.grantId));
    const deviceGrant = deviceId === undefined ? undefined : document.grants.find((grant) => grant.deviceId === deviceId);
    return {
      available: this.relay.available,
      registered: active.length > 0,
      deviceRegistered: deviceId === undefined ? false : active.some((grant) => grant.deviceId === deviceId),
      enabledDeviceCount: active.length,
      pendingCount: document.pending.length,
      notifyWhenAskPresented: document.policy.notifyWhenAskPresented,
      notifyWhenFinished: document.policy.notifyWhenFinished,
      notifyWhenWaiting: document.policy.notifyWhenWaiting,
      ...(relayOrigin ? { relayOrigin } : {}),
      requiresGrantRotation: deviceGrant !== undefined && (deviceGrant.relayOrigin !== relayOrigin
        || !deviceGrant.active || deviceGrant.disabledReason === "invalid_token"),
    };
  }

  /** One newest-first page. `cursor` is an opaque keyset position, so a page
   * request never fails because the inbox changed between pages. */
  async inbox(input: { filter?: NotificationInboxFilter; cursor?: string; limit?: number } = {}): Promise<NotificationInboxPage> {
    const now = this.now();
    const cursor = input.cursor === undefined ? undefined : parseInboxCursor(input.cursor);
    const filter = input.filter ?? "all";
    const requested = input.limit ?? 50;
    const limit = Number.isFinite(requested) ? Math.min(50, Math.max(1, Math.floor(requested))) : 50;
    let expiryChanged = false;
    const document = await this.update((current) => {
      const queuedBefore = current.inbox.filter((entry) => entry.outcome === "queued").length;
      prune(current, now);
      // Expiry is the only terminal transition prune applies to an inbox row,
      // and retention only drops rows, so a queued-count drop is exactly an
      // inbox-row change. Listing is otherwise a read: without one it must not
      // rewrite the credential document.
      expiryChanged = current.inbox.filter((entry) => entry.outcome === "queued").length !== queuedBefore;
      return expiryChanged ? current : undefined;
    });
    if (expiryChanged) this.publishInboxChanged(document);
    const entries = [...document.inbox]
      .sort((left, right) => compareInboxOrder(entryOrder(left), entryOrder(right)))
      .filter((entry) => filter !== "unread" || entry.readAt === undefined)
      .filter((entry) => cursor === undefined || compareInboxOrder(entryOrder(entry), cursor) > 0);
    const selected = entries.slice(0, limit);
    const last = selected.at(-1);
    return {
      notifications: selected.map(inboxItem),
      // The revision covers the whole inbox state; unreadCount is every unread
      // row, not only the filtered or paged subset.
      ...inboxState(document.inbox),
      ...(last !== undefined && entries.length > limit ? { nextCursor: inboxCursor(entryOrder(last)) } : {}),
    };
  }

  async markInboxRead(input: { id?: string; requestId?: string }): Promise<{ changed: boolean; id?: string }> {
    if ((input.id === undefined) === (input.requestId === undefined)) {
      throw new GatewayError("invalid_request", "Notification read requires exactly one notification or request ID");
    }
    const identity = input.id ?? input.requestId!;
    if (!isID(identity)) throw new GatewayError("invalid_request", "Notification identity is malformed");
    const now = this.now();
    let changed = false;
    let resolvedId: string | undefined;
    const document = await this.update((current) => {
      prune(current, now);
      const entry = current.inbox.find((candidate) => input.id !== undefined
        ? candidate.id === input.id
        : candidate.requestIds.includes(input.requestId!));
      // A row evicted by the inbox bound is already gone, so reading it is an
      // idempotent no-op rather than an error.
      if (!entry) return undefined;
      resolvedId = entry.id;
      if (entry.readAt !== undefined) return undefined;
      entry.readAt = iso(now);
      entry.updatedAt = iso(now);
      changed = true;
      return current;
    });
    if (changed) this.publishInboxChanged(document);
    return { changed, ...(resolvedId ? { id: resolvedId } : {}) };
  }

  /** Marks only unread rows at or older than the caller's exact `through` cut
   * key, so rows the user has not seen stay unread. */
  async markAllInboxRead(input: { through: string }): Promise<{ changed: number }> {
    const cut = parseInboxCursor(input.through);
    const now = this.now();
    let changed = 0;
    const document = await this.update((current) => {
      prune(current, now);
      for (const entry of current.inbox) {
        if (entry.readAt !== undefined) continue;
        if (compareInboxOrder(entryOrder(entry), cut) < 0) continue;
        entry.readAt = iso(now);
        entry.updatedAt = iso(now);
        changed += 1;
      }
      return changed > 0 ? current : undefined;
    });
    if (changed > 0) this.publishInboxChanged(document);
    return { changed };
  }

  /** Move inbox rows onto a rekeyed canonical session identity. Row ids are
   * stable across a rekey, so captured pending reads need no rewriting. */
  async rekeySession(previousId: string, nextId: string): Promise<boolean> {
    if (!SESSION_ROUTE_ID.test(previousId) || !SESSION_ROUTE_ID.test(nextId)) {
      throw new GatewayError("invalid_request", "Notification session identity is malformed");
    }
    let matched = false;
    const document = await this.update((current) => {
      for (const entry of current.inbox) {
        if (entry.sessionId !== previousId) continue;
        entry.sessionId = nextId;
        matched = true;
      }
      return matched ? current : undefined;
    });
    if (matched) this.publishInboxChanged(document);
    return matched;
  }

  /** Capture one canonical cut; retries must never broaden it to later alerts. */
  async markSessionInboxRead(sessionId: string): Promise<void> {
    if (!SESSION_ROUTE_ID.test(sessionId)) throw new GatewayError("invalid_request", "Notification session identity is malformed");
    try { await this.persistInboxReads(sessionId); }
    catch (error) {
      try { this.inboxReadFailed(); } catch { /* diagnostics never own read admission */ }
      throw error;
    }
  }

  private async flushInboxReads(): Promise<void> {
    if (this.inboxReadFlush) return this.inboxReadFlush;
    if (this.pendingInboxReadIds.size === 0) return;
    const operation = this.persistInboxReads();
    this.inboxReadFlush = operation;
    try { await operation; }
    finally { this.inboxReadFlush = undefined; }
  }

  private async persistInboxReads(sessionId?: string): Promise<void> {
    const ids = new Set<string>();
    let changed = false;
    const document = await this.update((current) => {
      const unread = current.inbox.filter((entry) => entry.readAt === undefined);
      const retained = new Set(unread.map((entry) => entry.id));
      // Capture and mutation share the admission/settlement mutex. Only IDs
      // survive a failed write, bounded by the canonical inbox's 512 rows.
      for (const id of this.pendingInboxReadIds) if (!retained.has(id)) this.pendingInboxReadIds.delete(id);
      for (const entry of unread) if (entry.sessionId === sessionId) this.pendingInboxReadIds.add(entry.id);
      for (const id of this.pendingInboxReadIds) ids.add(id);
      const now = this.now();
      for (const entry of unread) {
        if (!ids.has(entry.id)) continue;
        entry.readAt = iso(now);
        entry.updatedAt = iso(Math.max(now, Date.parse(entry.updatedAt)));
        changed = true;
      }
      return changed ? current : undefined;
    });
    // Only a committed transaction retires the captured intent. It outlives
    // navigation/socket loss; retries never select later rows for that session.
    for (const id of ids) this.pendingInboxReadIds.delete(id);
    if (changed) this.publishInboxChanged(document);
  }

  async suppressAutomatic(input: {
    sessionId: string;
    sourceId: string;
    kind: Exclude<NotificationKind, "explicit">;
  }): Promise<"suppressed"> {
    if (!input.sessionId || !input.sourceId || (input.kind !== "ask" && input.kind !== "agent_finished")) {
      throw new GatewayError("invalid_request", "Automatic notification identity is malformed");
    }
    const now = this.now();
    const dedupeKey = notificationHash(`${input.kind}\0${input.sessionId}\0${input.sourceId}`);
    const sessionKey = notificationHash(`session\0${input.sessionId}`);
    await this.update((current) => {
      prune(current, now);
      if (current.receipts.some((receipt) => receipt.dedupeKey === dedupeKey)
        || current.pending.some((intent) => intent.dedupeKey === dedupeKey)) return undefined;
      current.receipts.push(receiptFor({
        dedupeKey,
        sessionKey,
        grantIds: [],
        now,
        result: "suppressed",
      }));
      current.receipts = current.receipts.slice(-MAXIMUM_NOTIFICATION_RECEIPTS);
      return current;
    });
    return "suppressed";
  }

  async enqueue(input: {
    sessionId: string;
    sourceId: string;
    kind: NotificationKind;
    message: string;
    title?: string;
    interruptionLevel?: "time-sensitive";
    route?: { sessionId: string; machineId: string };
    /** Internal admission fence for semantic ask notifications. */
    requireAskPolicy?: boolean;
    /** The user is watching this exact session, so its row starts read. */
    readOnAdmission?: boolean;
  }): Promise<NotificationAdmissionStatus> {
    const message = boundedText(input.message, 512, "message");
    const title = input.title === undefined ? undefined : boundedText(input.title, 256, "title");
    const route = boundedRoute(input.route, input.sessionId);
    if (!input.sessionId || !input.sourceId) throw new GatewayError("invalid_request", "Notification identity is missing");
    const now = this.now();
    const dedupeKey = notificationHash(`${input.kind}\0${input.sessionId}\0${input.sourceId}`);
    const sessionKey = notificationHash(`session\0${input.sessionId}`);
    let result: NotificationAdmissionStatus = "queued";
    const document = await this.update((current) => {
      retainRevocationAuthority(prune(current, now), now);
      // The outer policy read is only an early suppression optimization. The
      // admission transaction must recheck the canonical policy immediately
      // before appending an intent, otherwise a concurrent disable can still
      // deliver an ask notification.
      if (input.kind === "ask" && !current.policy.notifyWhenAskPresented
        || input.kind === "agent_finished" && !current.policy.notifyWhenFinished
        || input.kind === "waiting" && !current.policy.notifyWhenWaiting) {
        result = "suppressed";
        return undefined;
      }
      if (current.receipts.some((receipt) => receipt.dedupeKey === dedupeKey) || current.pending.some((intent) => intent.dedupeKey === dedupeKey)) {
        result = "suppressed";
        return undefined;
      }
      const grants = current.grants.filter((grant) => grant.active && grant.relayOrigin === this.relay.relayOrigin);
      if (!this.relay.available || grants.length === 0) {
        result = "unavailable";
        return undefined;
      }
      const day = now - 24 * 60 * 60_000;
      const hour = now - 60 * 60_000;
      const recent = current.receipts.filter((receipt) => Date.parse(receipt.createdAt) > day);
      // Rejected and presentation-suppressed receipts never consume delivery
      // quota or extend a lockout window.
      const admitted = recent.filter((receipt) => receipt.result !== "rate_limited" && receipt.result !== "suppressed");
      const targetLimited = grants.some((grant) => admitted
        .filter((receipt) => receipt.grantIds.includes(grant.grantId)).length >= this.rateLimits.targetDailyIntents);
      const dailyExempt = input.kind === "ask" || input.kind === "explicit";
      if ((!dailyExempt && (admitted.length >= this.rateLimits.dailyIntents || targetLimited))
        || admitted.filter((receipt) => receipt.sessionKey === sessionKey
          && Date.parse(receipt.createdAt) > hour).length >= this.rateLimits.sessionHourlyIntents
        || current.pending.length >= MAXIMUM_PENDING_INTENTS) {
        // Rejection is returned synchronously but is not persisted: a rejected
        // attempt owns no delivery and must not displace durable quota authority.
        result = "rate_limited";
        return undefined;
      }
      const intentId = randomUUID();
      const targets = grants.map((grant) => {
        const exposesModelText = input.kind !== "explicit" || grant.previewsEnabled;
        return {
          grantId: grant.grantId,
          requestId: notificationHash(`${intentId}\0${grant.grantId}`),
          message: exposesModelText ? message : GENERIC_MESSAGE,
          ...(title ? { title: exposesModelText ? title : "Tron" } : {}),
          ...(input.interruptionLevel ? { interruptionLevel: input.interruptionLevel } : {}),
          ...(route ? { route } : {}),
          attempts: 0, nextAttemptAt: iso(now), outcome: "pending" as const,
        };
      });
      current.pending.push({
        id: intentId, dedupeKey, sessionKey, kind: input.kind, createdAt: iso(now), expiresAt: iso(now + INTENT_TTL_MS), targets,
      });
      current.receipts.push(receiptFor({ dedupeKey, sessionKey, grantIds: grants.map((grant) => grant.grantId), now, result: "queued" }));
      const inboxExposesModelText = input.kind !== "explicit" || grants.every((grant) => grant.previewsEnabled);
      current.inbox.push({
        id: intentId,
        dedupeKey,
        requestIds: targets.map((target) => target.requestId),
        kind: input.kind,
        createdAt: iso(now),
        updatedAt: iso(now),
        title: inboxExposesModelText ? title ?? "Tron" : "Tron",
        message: inboxExposesModelText ? message : GENERIC_MESSAGE,
        sessionId: input.sessionId,
        ...(route ? { machineId: route.machineId } : {}),
        outcome: "queued",
        // An alert produced while the user is already reading that chat is
        // still delivered, but it must not light the bell afterwards.
        ...(input.readOnAdmission === true ? { readAt: iso(now) } : {}),
      });
      current.inbox = retainInboxRows(current.inbox);
      return current;
    });
    if (result === "queued") {
      this.publishInboxChanged(document);
      void this.drain();
    }
    return result;
  }

  async userInputRequired(input: {
    sessionId: string;
    interactionId: string;
    observed: boolean;
    machineId?: string;
  }): Promise<void> {
    const document = await this.store.snapshot();
    if (!document.policy.notifyWhenAskPresented) return;
    if (input.observed) {
      await this.suppressAutomatic({
        sessionId: input.sessionId,
        sourceId: input.interactionId,
        kind: "ask",
      });
      return;
    }
    await this.enqueue({
      sessionId: input.sessionId,
      sourceId: input.interactionId,
      kind: "ask",
      title: "Input needed",
      message: "Tron needs your input. Open Tron to respond.",
      interruptionLevel: "time-sensitive",
      ...(input.machineId ? { route: { sessionId: input.sessionId, machineId: input.machineId } } : {}),
      requireAskPolicy: true,
    });
  }

  async drain(): Promise<void> {
    // Reading an already-open chat is independent of relay availability and
    // in-flight delivery. Failed writes retain their exact IDs for the next tick.
    await this.flushInboxReads().catch(() => {});
    if (this.draining || !this.relay.available) return;
    this.draining = true;
    try {
      const now = this.now();
      const document = await this.store.snapshot();
      const work = document.pending.flatMap((intent) => intent.targets
        .filter((target) => ACTIVE_OUTCOMES.has(target.outcome) && Date.parse(target.nextAttemptAt) <= now)
        .map((target) => ({ intent, target, grant: document.grants.find((grant) => grant.grantId === target.grantId) })))
        .slice(0, 16);
      let cursor = 0;
      const workers = Array.from({ length: Math.min(4, work.length) }, async () => {
        while (cursor < work.length) {
          const item = work[cursor++]!;
          if (!item.grant?.active) { await this.recordOutcome(item.intent.id, item.target.grantId, "permanent_failure"); continue; }
          let outcome: RelayNotificationOutcome = "retryable";
          try {
            outcome = await this.relay.send({
              grantId: item.grant.grantId, secret: item.grant.secret, requestId: item.target.requestId,
              message: item.target.message,
              ...(item.target.title ? { title: item.target.title } : {}),
              notificationKind: item.intent.kind,
              ...(item.target.interruptionLevel ? { interruptionLevel: item.target.interruptionLevel } : {}),
              ...(item.target.route ? item.target.route : {}),
              expiresAt: item.intent.expiresAt,
            });
          } catch { outcome = "retryable"; }
          await this.recordOutcome(item.intent.id, item.target.grantId, outcome === "rate_limited" ? "retryable" : outcome);
        }
      });
      await Promise.all(workers);
      // Remote revocation is lower priority than live notifications and bounded
      // to one attempt per drain so an unavailable relay cannot wedge delivery.
      await this.drainRevocations();
    } catch {
      // The timer owns recovery from storage failures as well as relay failures.
      // Durable intents remain pending; a detached rejection must not kill the Gateway.
    } finally { this.draining = false; }
  }

  private async recordOutcome(intentId: string, grantId: string, outcome: RelayNotificationOutcome): Promise<void> {
    // The relay has already reserved this exact request ID. Poll an active
    // provider attempt through the ordinary bounded retry schedule; replaying
    // the ID cannot create a second APNs request. Other ambiguous results stay
    // terminal because the relay did not certify that ownership state.
    if (outcome === "rate_limited" || outcome === "in_progress") outcome = "retryable";
    if (outcome === "invalid_grant") outcome = "invalid_token";
    const now = this.now();
    let inboxDidChange = false;
    const document = await this.update((current) => {
      prune(current, now);
      const intent = current.pending.find((candidate) => candidate.id === intentId);
      const target = intent?.targets.find((candidate) => candidate.grantId === grantId);
      if (!intent || !target || !ACTIVE_OUTCOMES.has(target.outcome)) return undefined;
      target.attempts += 1;
      if (outcome === "retryable" && target.attempts < RETRY_DELAYS_MS.length && Date.parse(intent.expiresAt) > now) {
        target.outcome = "retryable";
        target.nextAttemptAt = iso(now + RETRY_DELAYS_MS[target.attempts - 1]!);
      } else {
        target.outcome = outcome === "retryable" ? "permanent_failure" : outcome;
      }
      if (outcome === "invalid_token") {
        const grant = current.grants.find((candidate) => candidate.grantId === grantId);
        if (grant) { grant.active = false; grant.disabledReason = "invalid_token"; grant.updatedAt = iso(now); }
      }
      if (intent.targets.every((candidate) => !ACTIVE_OUTCOMES.has(candidate.outcome))) {
        const receipt = current.receipts.find((candidate) => candidate.dedupeKey === intent.dedupeKey);
        const finalOutcome: NotificationInboxOutcome = intent.targets.some((candidate) => candidate.outcome === "accepted_by_apns") ? "accepted_by_apns"
          : intent.targets.some((candidate) => candidate.outcome === "ambiguous") ? "ambiguous" : "failed";
        if (receipt) receipt.result = finalOutcome;
        const inbox = current.inbox.find((entry) => entry.dedupeKey === intent.dedupeKey);
        if (inbox && inbox.outcome !== finalOutcome) {
          inbox.outcome = finalOutcome;
          inbox.updatedAt = iso(now);
          inboxDidChange = true;
        }
        current.pending = current.pending.filter((candidate) => candidate.id !== intent.id);
      }
      return current;
    });
    if (inboxDidChange) this.publishInboxChanged(document);
  }

  private async drainRevocations(): Promise<void> {
    const now = this.now();
    const document = await this.store.snapshot();
    for (const item of document.revocations.filter((candidate) => Date.parse(candidate.nextAttemptAt) <= now).slice(0, 1)) {
      let revoked = false;
      try { revoked = await this.relay.revoke(item.grantId, item.secret, item.requestId) === "revoked"; } catch { /* retained */ }
      await this.update((current) => {
        const candidate = current.revocations.find((entry) => entry.grantId === item.grantId);
        if (!candidate) return undefined;
        if (revoked) current.revocations = current.revocations.filter((entry) => entry.grantId !== item.grantId);
        else {
          candidate.attempts = Math.min(32, candidate.attempts + 1);
          candidate.nextAttemptAt = iso(this.now() + Math.min(60 * 60_000, 5_000 * 2 ** Math.min(candidate.attempts, 9)));
        }
        return prune(current, this.now());
      });
    }
  }
}
