import { randomUUID } from "node:crypto";
import { GatewayError } from "../errors.js";
import {
  MAXIMUM_PENDING_INTENTS,
  MAXIMUM_PUSH_GRANTS,
  MAXIMUM_REVOCATIONS,
  NotificationGrantStore,
  notificationHash,
  isEndpointSecret,
  type NotificationDocument,
  type NotificationKind,
  type NotificationReceipt,
  type PushGrant,
} from "./grant-store.js";
import { PushRelayClient, type RelayNotificationOutcome } from "./relay-client.js";

const INTENT_TTL_MS = 15 * 60_000;
const RECEIPT_TTL_MS = 24 * 60 * 60_000;
const MAXIMUM_DAILY_INTENTS = 60;
const MAXIMUM_SESSION_HOURLY_INTENTS = 12;
const MAXIMUM_TARGET_DAILY_INTENTS = 40;
const GENERIC_MESSAGE = "Tron has an update. Open Tron to view it.";
const RETRY_DELAYS_MS = [5_000, 20_000, 60_000, 180_000] as const;
const ACTIVE_OUTCOMES = new Set(["pending", "retryable"]);

export type NotificationAdmissionStatus = "queued" | "suppressed" | "rate_limited" | "unavailable";
export interface NotificationStatus {
  available: boolean;
  registered: boolean;
  deviceRegistered: boolean;
  enabledDeviceCount: number;
  pendingCount: number;
  notifyWhenAskPresented: boolean;
}

function iso(ms: number): string { return new Date(ms).toISOString(); }
function isID(value: string): boolean { return /^[A-Za-z0-9_-]{8,160}$/u.test(value); }
function boundedMessage(value: string): string {
  const normalized = value.trim();
  if (!normalized || Buffer.byteLength(normalized) > 512 || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(normalized)) {
    throw new GatewayError("invalid_request", "Notification message must contain 1 through 512 UTF-8 bytes of text");
  }
  return normalized;
}
function prune(document: NotificationDocument, now: number): NotificationDocument {
  const expired = new Set(document.pending.filter((intent) => Date.parse(intent.expiresAt) <= now).map((intent) => intent.dedupeKey));
  for (const receipt of document.receipts) if (expired.has(receipt.dedupeKey) && receipt.result === "queued") receipt.result = "expired";
  document.receipts = document.receipts.filter((receipt) => Date.parse(receipt.expiresAt) > now).slice(-512);
  document.pending = document.pending.filter((intent) => Date.parse(intent.expiresAt) > now).slice(-MAXIMUM_PENDING_INTENTS);
  // Revocation authority must be retained until the relay acknowledges it.
  document.revocations = document.revocations.slice(-MAXIMUM_REVOCATIONS);
  return document;
}
function receiptFor(input: {
  dedupeKey: string; sessionKey: string; grantIds: string[]; now: number; result: NotificationReceipt["result"];
}): NotificationReceipt {
  return { dedupeKey: input.dedupeKey, sessionKey: input.sessionKey, grantIds: input.grantIds, createdAt: iso(input.now), expiresAt: iso(input.now + RECEIPT_TTL_MS), result: input.result };
}

function retainRevocationAuthority(document: NotificationDocument): NotificationDocument {
  const revoking = new Set(document.revocations.map((item) => item.grantId));
  if (revoking.size === 0) return document;
  document.grants = document.grants.filter((grant) => !revoking.has(grant.grantId));
  for (const intent of document.pending) {
    intent.targets = intent.targets.filter((target) => !revoking.has(target.grantId));
    if (intent.targets.length === 0) {
      const receipt = document.receipts.find((candidate) => candidate.dedupeKey === intent.dedupeKey);
      if (receipt?.result === "queued") receipt.result = "failed";
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
  ) {}

  async initialize(): Promise<void> {
    await this.store.initialize();
    await this.store.update((document) => retainRevocationAuthority(prune(document, this.now())));
    this.timer = setInterval(() => void this.drain(), 2_000);
    this.timer.unref();
    void this.drain();
  }

  dispose(): void { if (this.timer) clearInterval(this.timer); this.timer = undefined; }

  async upsertGrant(input: {
    deviceId: string; installationId: string; grantId: string; secret: string; previewsEnabled: boolean; notifyWhenAskPresented?: boolean;
  }): Promise<NotificationStatus> {
    if (![input.deviceId, input.installationId, input.grantId].every(isID) || !isEndpointSecret(input.secret)) {
      throw new GatewayError("invalid_request", "Push registration credentials are malformed");
    }
    const now = this.now();
    let rotated = false;
    await this.store.update((document) => {
      retainRevocationAuthority(prune(document, now));
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
    const now = this.now();
    await this.store.update((document) => {
      prune(document, now);
      const grants = document.grants.filter((grant) => grant.deviceId === deviceId);
      removed = grants.length > 0;
      document.grants = document.grants.filter((grant) => grant.deviceId !== deviceId);
      document.pending = document.pending.map((intent) => ({ ...intent, targets: intent.targets.filter((target) => !grants.some((grant) => grant.grantId === target.grantId)) }))
        .filter((intent) => intent.targets.length > 0);
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

  async enqueue(input: { sessionId: string; toolCallId: string; kind: NotificationKind; message: string }): Promise<NotificationAdmissionStatus> {
    const message = boundedMessage(input.message);
    if (!input.sessionId || !input.toolCallId) throw new GatewayError("invalid_request", "Notification identity is missing");
    const now = this.now();
    const dedupeKey = notificationHash(`${input.kind}\0${input.sessionId}\0${input.toolCallId}`);
    const sessionKey = notificationHash(`session\0${input.sessionId}`);
    let result: NotificationAdmissionStatus = "queued";
    await this.store.update((document) => {
      retainRevocationAuthority(prune(document, now));
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
      const targetLimited = grants.some((grant) => recent.filter((receipt) => receipt.grantIds.includes(grant.grantId)).length >= MAXIMUM_TARGET_DAILY_INTENTS);
      if (recent.length >= MAXIMUM_DAILY_INTENTS
        || recent.filter((receipt) => receipt.sessionKey === sessionKey && Date.parse(receipt.createdAt) > hour).length >= MAXIMUM_SESSION_HOURLY_INTENTS
        || targetLimited || document.pending.length >= MAXIMUM_PENDING_INTENTS) {
        document.receipts.push(receiptFor({ dedupeKey, sessionKey, grantIds: grants.map((grant) => grant.grantId), now, result: "rate_limited" }));
        result = "rate_limited";
        return document;
      }
      const intentId = randomUUID();
      document.pending.push({
        id: intentId, dedupeKey, sessionKey, kind: input.kind, createdAt: iso(now), expiresAt: iso(now + INTENT_TTL_MS),
        targets: grants.map((grant) => ({
          grantId: grant.grantId,
          requestId: notificationHash(`${intentId}\0${grant.grantId}`),
          message: grant.previewsEnabled ? message : GENERIC_MESSAGE,
          attempts: 0, nextAttemptAt: iso(now), outcome: "pending",
        })),
      });
      document.receipts.push(receiptFor({ dedupeKey, sessionKey, grantIds: grants.map((grant) => grant.grantId), now, result: "queued" }));
      return document;
    });
    if (result === "queued") void this.drain();
    return result;
  }

  async askPresented(sessionId: string, toolCallId: string): Promise<void> {
    const document = await this.store.snapshot();
    if (!document.policy.notifyWhenAskPresented) return;
    await this.enqueue({ sessionId, toolCallId, kind: "ask", message: "Tron needs your input. Open Tron to answer a question." });
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
              message: item.target.message, expiresAt: item.intent.expiresAt,
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
        if (receipt) {
          receipt.result = intent.targets.some((candidate) => candidate.outcome === "accepted_by_apns") ? "accepted_by_apns"
            : intent.targets.some((candidate) => candidate.outcome === "ambiguous") ? "ambiguous" : "failed";
        }
        document.pending = document.pending.filter((candidate) => candidate.id !== intent.id);
      }
      return document;
    });
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
