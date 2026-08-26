import { createHash, randomUUID } from "node:crypto";
import { GatewayError } from "../errors.js";
import {
  MAXIMUM_NOTIFICATION_INBOX_ENTRIES,
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

export type NotificationAdmissionStatus = "queued" | "suppressed" | "rate_limited" | "unavailable";
export interface NotificationStatus {
  available: boolean;
  registered: boolean;
  deviceRegistered: boolean;
  enabledDeviceCount: number;
  pendingCount: number;
  notifyWhenAskPresented: boolean;
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
function prune(document: NotificationDocument, now: number): NotificationDocument {
  const expired = new Set(document.pending.filter((intent) => Date.parse(intent.expiresAt) <= now).map((intent) => intent.dedupeKey));
  for (const receipt of document.receipts) if (expired.has(receipt.dedupeKey) && receipt.result === "queued") receipt.result = "expired";
  for (const entry of document.inbox ?? []) {
    if (expired.has(entry.dedupeKey) && entry.outcome === "queued") {
      entry.outcome = "expired";
      entry.updatedAt = iso(now);
    }
  }
  document.receipts = document.receipts.filter((receipt) => Date.parse(receipt.expiresAt) > now).slice(-512);
  document.pending = document.pending.filter((intent) => Date.parse(intent.expiresAt) > now).slice(-MAXIMUM_PENDING_INTENTS);
  document.inbox = (document.inbox ?? []).slice(-MAXIMUM_NOTIFICATION_INBOX_ENTRIES);
  // Revocation authority must be retained until the relay acknowledges it.
  document.revocations = document.revocations.slice(-MAXIMUM_REVOCATIONS);
  return document;
}
function receiptFor(input: {
  dedupeKey: string; sessionKey: string; grantIds: string[]; now: number; result: NotificationReceipt["result"];
}): NotificationReceipt {
  return { dedupeKey: input.dedupeKey, sessionKey: input.sessionKey, grantIds: input.grantIds, createdAt: iso(input.now), expiresAt: iso(input.now + RECEIPT_TTL_MS), result: input.result };
}

function inboxRevision(entries: NotificationInboxEntry[]): string {
  return createHash("sha256")
    .update(entries.map((entry) => `${entry.id}\0${entry.updatedAt}\0${entry.readAt ?? "unread"}\0${entry.outcome}`).join("\n"))
    .digest("hex").slice(0, 32);
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
      const inbox = document.inbox?.find((entry) => entry.dedupeKey === intent.dedupeKey);
      if (inbox?.outcome === "queued") {
        inbox.outcome = "failed";
        inbox.updatedAt = iso(now);
      }
    }
  }
  document.pending = document.pending.filter((intent) => intent.targets.length > 0);
  return document;
}

/** Gateway-owned push authority. Extension code receives only enqueue(), never credentials or transport. */
export class NotificationService {
  private timer: NodeJS.Timeout | undefined;
  private draining = false;
  constructor(
    private readonly store: NotificationGrantStore,
    private readonly relay: PushRelayClient,
    private readonly now: () => number = Date.now,
    private readonly rateLimits: NotificationRateLimits = DEFAULT_NOTIFICATION_RATE_LIMITS,
    private readonly inboxChanged: () => void = () => {},
  ) {}

  async initialize(): Promise<void> {
    await this.store.initialize();
    const now = this.now();
    await this.store.update((document) => retainRevocationAuthority(prune(document, now), now));
    this.timer = setInterval(() => void this.drain(), 2_000);
    this.timer.unref();
    void this.drain();
  }

  dispose(): void { if (this.timer) clearInterval(this.timer); this.timer = undefined; }

  private publishInboxChanged(): void {
    try { this.inboxChanged(); } catch { /* invalidation delivery never owns canonical admission */ }
  }

  async upsertGrant(input: {
    deviceId: string; installationId: string; grantId: string; secret: string; previewsEnabled: boolean; notifyWhenAskPresented?: boolean;
  }): Promise<NotificationStatus> {
    if (![input.deviceId, input.installationId, input.grantId].every(isID) || !isEndpointSecret(input.secret)) {
      throw new GatewayError("invalid_request", "Push registration credentials are malformed");
    }
    const now = this.now();
    let rotated = false;
    await this.store.update((document) => {
      retainRevocationAuthority(prune(document, now), now);
      if (document.revocations.some((item) => item.grantId === input.grantId)) {
        throw new GatewayError("conflict", "Push grant is awaiting revocation and must rotate before registration");
      }
      const anotherDevice = document.grants.find((grant) => grant.grantId === input.grantId && grant.deviceId !== input.deviceId);
      if (anotherDevice) throw new GatewayError("conflict", "Push grant is already bound to another device");
      const previous = document.grants.find((grant) => grant.deviceId === input.deviceId);
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
        active: true,
        createdAt: previous?.createdAt ?? iso(now),
        updatedAt: iso(now),
      };
      document.grants = [...document.grants.filter((grant) => grant.deviceId !== input.deviceId && grant.grantId !== input.grantId), next];
      if (document.grants.length > MAXIMUM_PUSH_GRANTS) throw new GatewayError("busy", "Too many notification-enabled devices are registered", true);
      if (input.notifyWhenAskPresented !== undefined) document.policy.notifyWhenAskPresented = input.notifyWhenAskPresented;
      return document;
    });
    if (rotated) void this.drain();
    return this.status(input.deviceId);
  }

  async removeDevice(deviceId: string): Promise<boolean> {
    let removed = false;
    let inboxDidChange = false;
    const now = this.now();
    await this.store.update((document) => {
      prune(document, now);
      const grants = document.grants.filter((grant) => grant.deviceId === deviceId);
      removed = grants.length > 0;
      document.grants = document.grants.filter((grant) => grant.deviceId !== deviceId);
      for (const intent of document.pending) {
        intent.targets = intent.targets.filter((target) => !grants.some((grant) => grant.grantId === target.grantId));
        if (intent.targets.length > 0) continue;
        const receipt = document.receipts.find((candidate) => candidate.dedupeKey === intent.dedupeKey);
        if (receipt?.result === "queued") receipt.result = "failed";
        const inbox = document.inbox?.find((entry) => entry.dedupeKey === intent.dedupeKey);
        if (inbox?.outcome === "queued") {
          inbox.outcome = "failed";
          inbox.updatedAt = iso(now);
          inboxDidChange = true;
        }
      }
      document.pending = document.pending.filter((intent) => intent.targets.length > 0);
      for (const grant of grants) {
        document.revocations = document.revocations.filter((item) => item.grantId !== grant.grantId);
        document.revocations.push({
          grantId: grant.grantId,
          secret: grant.secret,
          requestId: notificationHash(`revoke\0${grant.grantId}`),
          createdAt: iso(now), attempts: 0, nextAttemptAt: iso(now),
        });
      }
      return document;
    });
    if (inboxDidChange) this.publishInboxChanged();
    if (removed) void this.drain();
    return removed;
  }

  async status(deviceId?: string): Promise<NotificationStatus> {
    const document = await this.store.snapshot();
    const revoking = new Set(document.revocations.map((item) => item.grantId));
    const active = document.grants.filter((grant) => grant.active && !revoking.has(grant.grantId));
    return {
      available: this.relay.available,
      registered: active.length > 0,
      deviceRegistered: deviceId === undefined ? false : active.some((grant) => grant.deviceId === deviceId),
      enabledDeviceCount: active.length,
      pendingCount: document.pending.length,
      notifyWhenAskPresented: document.policy.notifyWhenAskPresented,
    };
  }

  async inbox(cursor?: string, limit = 50): Promise<NotificationInboxPage> {
    const now = this.now();
    let expiredChanged = false;
    const document = await this.store.update((current) => {
      const before = (current.inbox ?? []).filter((entry) => entry.outcome === "queued").length;
      prune(current, now);
      expiredChanged = (current.inbox ?? []).filter((entry) => entry.outcome === "queued").length !== before;
      return current;
    });
    if (expiredChanged) this.publishInboxChanged();
    const entries = [...(document.inbox ?? [])].sort((left, right) => {
      const delta = Date.parse(right.createdAt) - Date.parse(left.createdAt);
      return delta || left.id.localeCompare(right.id);
    });
    const revision = inboxRevision(entries);
    let offset = 0;
    if (cursor !== undefined) {
      const [cursorRevision, rawOffset] = cursor.split(":");
      if (cursorRevision !== revision || !/^\d+$/u.test(rawOffset ?? "")) {
        throw new GatewayError("conflict", "Notification inbox changed during pagination", true);
      }
      offset = Number(rawOffset);
      if (!Number.isSafeInteger(offset) || offset < 0 || offset > entries.length) {
        throw new GatewayError("invalid_request", "Notification inbox cursor is invalid");
      }
    }
    const boundedLimit = Math.min(50, Math.max(1, Math.floor(limit)));
    const selected = entries.slice(offset, offset + boundedLimit);
    const nextOffset = offset + selected.length;
    return {
      notifications: selected.map(inboxItem),
      revision,
      unreadCount: entries.filter((entry) => entry.readAt === undefined).length,
      ...(nextOffset < entries.length ? { nextCursor: `${revision}:${nextOffset}` } : {}),
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
    await this.store.update((document) => {
      prune(document, now);
      const entry = (document.inbox ?? []).find((candidate) => input.id !== undefined
        ? candidate.id === input.id
        : candidate.requestIds.includes(input.requestId!));
      if (!entry) throw new GatewayError("not_found", "Notification was not found");
      resolvedId = entry.id;
      if (entry.readAt === undefined) {
        entry.readAt = iso(now);
        entry.updatedAt = iso(now);
        changed = true;
      }
      return document;
    });
    if (changed) this.publishInboxChanged();
    return { changed, ...(resolvedId ? { id: resolvedId } : {}) };
  }

  async markAllInboxRead(): Promise<{ changed: number }> {
    const now = this.now();
    let changed = 0;
    await this.store.update((document) => {
      prune(document, now);
      for (const entry of document.inbox ?? []) {
        if (entry.readAt !== undefined) continue;
        entry.readAt = iso(now);
        entry.updatedAt = iso(now);
        changed += 1;
      }
      return document;
    });
    if (changed > 0) this.publishInboxChanged();
    return { changed };
  }

  async enqueue(input: {
    sessionId: string;
    sourceId: string;
    kind: NotificationKind;
    message: string;
    title?: string;
    route?: { sessionId: string; machineId: string };
  }): Promise<NotificationAdmissionStatus> {
    const message = boundedText(input.message, 512, "message");
    const title = input.title === undefined ? undefined : boundedText(input.title, 256, "title");
    const route = boundedRoute(input.route, input.sessionId);
    if (!input.sessionId || !input.sourceId) throw new GatewayError("invalid_request", "Notification identity is missing");
    const now = this.now();
    const dedupeKey = notificationHash(`${input.kind}\0${input.sessionId}\0${input.sourceId}`);
    const sessionKey = notificationHash(`session\0${input.sessionId}`);
    let result: NotificationAdmissionStatus = "queued";
    await this.store.update((document) => {
      retainRevocationAuthority(prune(document, now), now);
      if (document.receipts.some((receipt) => receipt.dedupeKey === dedupeKey) || document.pending.some((intent) => intent.dedupeKey === dedupeKey)) {
        result = "suppressed";
        return document;
      }
      const grants = document.grants.filter((grant) => grant.active);
      if (!this.relay.available || grants.length === 0) {
        result = "unavailable";
        return document;
      }
      const day = now - 24 * 60 * 60_000;
      const hour = now - 60 * 60_000;
      const recent = document.receipts.filter((receipt) => Date.parse(receipt.createdAt) > day);
      // Legacy rejected receipts remain readable until normal expiry, but they
      // never consume quota or extend their own lockout window.
      const admitted = recent.filter((receipt) => receipt.result !== "rate_limited");
      const targetLimited = grants.some((grant) => admitted
        .filter((receipt) => receipt.grantIds.includes(grant.grantId)).length >= this.rateLimits.targetDailyIntents);
      if (admitted.length >= this.rateLimits.dailyIntents
        || admitted.filter((receipt) => receipt.sessionKey === sessionKey
          && Date.parse(receipt.createdAt) > hour).length >= this.rateLimits.sessionHourlyIntents
        || targetLimited || document.pending.length >= MAXIMUM_PENDING_INTENTS) {
        // Rejection is returned synchronously but is not persisted: a rejected
        // attempt owns no delivery and must not displace durable quota authority.
        result = "rate_limited";
        return document;
      }
      const intentId = randomUUID();
      const targets = grants.map((grant) => {
        const exposesModelText = input.kind !== "explicit" || grant.previewsEnabled;
        return {
          grantId: grant.grantId,
          requestId: notificationHash(`${intentId}\0${grant.grantId}`),
          message: exposesModelText ? message : GENERIC_MESSAGE,
          ...(title ? { title: exposesModelText ? title : "Tron" } : {}),
          ...(route ? { route } : {}),
          attempts: 0, nextAttemptAt: iso(now), outcome: "pending" as const,
        };
      });
      document.pending.push({
        id: intentId, dedupeKey, sessionKey, kind: input.kind, createdAt: iso(now), expiresAt: iso(now + INTENT_TTL_MS), targets,
      });
      document.receipts.push(receiptFor({ dedupeKey, sessionKey, grantIds: grants.map((grant) => grant.grantId), now, result: "queued" }));
      document.inbox ??= [];
      const inboxExposesModelText = input.kind !== "explicit" || grants.every((grant) => grant.previewsEnabled);
      document.inbox.push({
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
      });
      document.inbox = document.inbox.slice(-MAXIMUM_NOTIFICATION_INBOX_ENTRIES);
      return document;
    });
    if (result === "queued") {
      this.publishInboxChanged();
      void this.drain();
    }
    return result;
  }

  async askPresented(sessionId: string, toolCallId: string, machineId?: string): Promise<void> {
    const document = await this.store.snapshot();
    if (!document.policy.notifyWhenAskPresented) return;
    await this.enqueue({
      sessionId,
      sourceId: toolCallId,
      kind: "ask",
      title: "Input needed",
      message: "Tron needs your input. Open Tron to answer a question.",
      ...(machineId ? { route: { sessionId, machineId } } : {}),
    });
  }

  async drain(): Promise<void> {
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
    } finally { this.draining = false; }
  }

  private async recordOutcome(intentId: string, grantId: string, outcome: RelayNotificationOutcome): Promise<void> {
    if (outcome === "rate_limited") outcome = "retryable";
    const now = this.now();
    let inboxDidChange = false;
    await this.store.update((document) => {
      prune(document, now);
      const intent = document.pending.find((candidate) => candidate.id === intentId);
      const target = intent?.targets.find((candidate) => candidate.grantId === grantId);
      if (!intent || !target || !ACTIVE_OUTCOMES.has(target.outcome)) return document;
      target.attempts += 1;
      if (outcome === "retryable" && target.attempts < RETRY_DELAYS_MS.length && Date.parse(intent.expiresAt) > now) {
        target.outcome = "retryable";
        target.nextAttemptAt = iso(now + RETRY_DELAYS_MS[target.attempts - 1]!);
      } else {
        target.outcome = outcome === "retryable" ? "permanent_failure" : outcome;
      }
      if (outcome === "invalid_token") {
        const grant = document.grants.find((candidate) => candidate.grantId === grantId);
        if (grant) { grant.active = false; grant.disabledReason = "invalid_token"; grant.updatedAt = iso(now); }
      }
      if (intent.targets.every((candidate) => !ACTIVE_OUTCOMES.has(candidate.outcome))) {
        const receipt = document.receipts.find((candidate) => candidate.dedupeKey === intent.dedupeKey);
        const finalOutcome: NotificationInboxOutcome = intent.targets.some((candidate) => candidate.outcome === "accepted_by_apns") ? "accepted_by_apns"
          : intent.targets.some((candidate) => candidate.outcome === "ambiguous") ? "ambiguous" : "failed";
        if (receipt) receipt.result = finalOutcome;
        const inbox = document.inbox?.find((entry) => entry.dedupeKey === intent.dedupeKey);
        if (inbox && inbox.outcome !== finalOutcome) {
          inbox.outcome = finalOutcome;
          inbox.updatedAt = iso(now);
          inboxDidChange = true;
        }
        document.pending = document.pending.filter((candidate) => candidate.id !== intent.id);
      }
      return document;
    });
    if (inboxDidChange) this.publishInboxChanged();
  }

  private async drainRevocations(): Promise<void> {
    const now = this.now();
    const document = await this.store.snapshot();
    for (const item of document.revocations.filter((candidate) => Date.parse(candidate.nextAttemptAt) <= now).slice(0, 1)) {
      let revoked = false;
      try { revoked = await this.relay.revoke(item.grantId, item.secret, item.requestId) === "revoked"; } catch { /* retained */ }
      await this.store.update((current) => {
        const candidate = current.revocations.find((entry) => entry.grantId === item.grantId);
        if (!candidate) return current;
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
