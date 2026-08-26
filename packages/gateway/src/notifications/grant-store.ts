import { createHash } from "node:crypto";
import { lstat, mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { AsyncMutex } from "../util/async-mutex.js";
import { atomicWriteJson } from "../util/json.js";
import { readSecureJson, SecureJsonFileError } from "../util/secure-json.js";
import { isGatewayTimestamp } from "../util/timestamp.js";
import { GatewayError } from "../errors.js";

export type NotificationKind = "explicit" | "ask" | "agent_finished";
export type DeliveryOutcome = "pending" | "accepted_by_apns" | "retryable" | "invalid_token" | "permanent_failure" | "ambiguous" | "expired";

export interface PushGrant {
  deviceId: string;
  installationId: string;
  grantId: string;
  secret: string;
  previewsEnabled: boolean;
  active: boolean;
  disabledReason?: "invalid_token";
  createdAt: string;
  updatedAt: string;
}

export interface PendingTarget {
  grantId: string;
  requestId: string;
  message: string;
  title?: string;
  route?: { sessionId: string; machineId: string };
  attempts: number;
  nextAttemptAt: string;
  outcome: DeliveryOutcome;
}

export interface PendingIntent {
  id: string;
  dedupeKey: string;
  sessionKey: string;
  kind: NotificationKind;
  createdAt: string;
  expiresAt: string;
  targets: PendingTarget[];
}

export interface NotificationReceipt {
  dedupeKey: string;
  sessionKey: string;
  grantIds: string[];
  createdAt: string;
  expiresAt: string;
  result: "queued" | "accepted_by_apns" | "suppressed" | "rate_limited" | "failed" | "ambiguous" | "expired";
}

export interface RevocationTombstone {
  grantId: string;
  secret: string;
  requestId: string;
  createdAt: string;
  attempts: number;
  nextAttemptAt: string;
}

export type NotificationInboxOutcome = "queued" | "accepted_by_apns" | "failed" | "ambiguous" | "expired";
export interface NotificationInboxEntry {
  id: string;
  dedupeKey: string;
  requestIds: string[];
  kind: NotificationKind;
  createdAt: string;
  updatedAt: string;
  title: string;
  message: string;
  sessionId: string;
  machineId?: string;
  readAt?: string;
  outcome: NotificationInboxOutcome;
}

export interface NotificationDocument {
  version: 1;
  policy: { notifyWhenAskPresented: boolean };
  grants: PushGrant[];
  pending: PendingIntent[];
  receipts: NotificationReceipt[];
  revocations: RevocationTombstone[];
  /** Added compatibly to version 1. Missing means a pre-inbox document. */
  inbox?: NotificationInboxEntry[];
}

export const MAXIMUM_PUSH_GRANTS = 64;
export const MAXIMUM_PENDING_INTENTS = 256;
export const MAXIMUM_NOTIFICATION_RECEIPTS = 512;
export const MAXIMUM_NOTIFICATION_INBOX_ENTRIES = 512;
export const MAXIMUM_REVOCATIONS = 192;
const MAXIMUM_DOCUMENT_BYTES = 1 * 1_024 * 1_024;
const ID = /^[A-Za-z0-9_-]{8,160}$/u;
const SESSION_ID = /^[A-Za-z0-9_:-]{1,160}$/u;
const SECRET = /^[A-Za-z0-9_-]{43,171}$/u;
const HASH = /^[A-Za-z0-9_-]{43}$/u;

export function notificationHash(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("base64url");
}

function exact(value: Record<string, unknown>, required: readonly string[], optional: readonly string[] = []): boolean {
  const keys = Object.keys(value);
  const allowed = new Set([...required, ...optional]);
  return required.every((key) => key in value) && keys.every((key) => allowed.has(key));
}
function timestamp(value: unknown): value is string { return typeof value === "string" && isGatewayTimestamp(value); }
function id(value: unknown): value is string { return typeof value === "string" && ID.test(value); }
export function isEndpointSecret(value: unknown): value is string {
  if (typeof value !== "string" || !SECRET.test(value)) return false;
  try {
    const decoded = Buffer.from(value, "base64url");
    return decoded.length >= 32 && decoded.length <= 128 && decoded.toString("base64url") === value;
  } catch { return false; }
}
function stringList(value: unknown, maximum: number): value is string[] {
  return Array.isArray(value) && value.length <= maximum && value.every(id) && new Set(value).size === value.length;
}
function isGrant(value: unknown): value is PushGrant {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const v = value as Record<string, unknown>;
  return exact(v, ["deviceId", "installationId", "grantId", "secret", "previewsEnabled", "active", "createdAt", "updatedAt"], ["disabledReason"])
    && id(v.deviceId) && id(v.installationId) && id(v.grantId) && isEndpointSecret(v.secret)
    && typeof v.previewsEnabled === "boolean" && typeof v.active === "boolean"
    && (v.disabledReason === undefined || v.disabledReason === "invalid_token")
    && timestamp(v.createdAt) && timestamp(v.updatedAt);
}
function isTarget(value: unknown): value is PendingTarget {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const v = value as Record<string, unknown>;
  const route = v.route as Record<string, unknown> | undefined;
  return exact(v, ["grantId", "requestId", "message", "attempts", "nextAttemptAt", "outcome"], ["title", "route"])
    && id(v.grantId) && id(v.requestId) && typeof v.message === "string" && Buffer.byteLength(v.message) <= 512
    && (v.title === undefined || (typeof v.title === "string" && Buffer.byteLength(v.title) > 0 && Buffer.byteLength(v.title) <= 256))
    && (route === undefined || (typeof route === "object" && route !== null && !Array.isArray(route)
      && exact(route, ["sessionId", "machineId"]) && id(route.sessionId)
      && typeof route.machineId === "string" && Buffer.byteLength(route.machineId) > 0
      && Buffer.byteLength(route.machineId) <= 256 && !/[\u0000-\u001f\u007f]/u.test(route.machineId)))
    && Number.isSafeInteger(v.attempts) && (v.attempts as number) >= 0 && (v.attempts as number) <= 8
    && timestamp(v.nextAttemptAt) && ["pending", "accepted_by_apns", "retryable", "invalid_token", "permanent_failure", "ambiguous", "expired"].includes(v.outcome as string);
}
function isIntent(value: unknown): value is PendingIntent {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const v = value as Record<string, unknown>;
  return exact(v, ["id", "dedupeKey", "sessionKey", "kind", "createdAt", "expiresAt", "targets"])
    && id(v.id) && typeof v.dedupeKey === "string" && HASH.test(v.dedupeKey) && typeof v.sessionKey === "string" && HASH.test(v.sessionKey)
    && (v.kind === "explicit" || v.kind === "ask" || v.kind === "agent_finished") && timestamp(v.createdAt) && timestamp(v.expiresAt)
    && Array.isArray(v.targets) && v.targets.length >= 1 && v.targets.length <= MAXIMUM_PUSH_GRANTS && v.targets.every(isTarget)
    && new Set(v.targets.map((target) => target.grantId)).size === v.targets.length;
}
function isReceipt(value: unknown): value is NotificationReceipt {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const v = value as Record<string, unknown>;
  return exact(v, ["dedupeKey", "sessionKey", "grantIds", "createdAt", "expiresAt", "result"])
    && typeof v.dedupeKey === "string" && HASH.test(v.dedupeKey) && typeof v.sessionKey === "string" && HASH.test(v.sessionKey)
    && stringList(v.grantIds, MAXIMUM_PUSH_GRANTS) && timestamp(v.createdAt) && timestamp(v.expiresAt)
    && ["queued", "accepted_by_apns", "suppressed", "rate_limited", "failed", "ambiguous", "expired"].includes(v.result as string);
}
function isRevocation(value: unknown): value is RevocationTombstone {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const v = value as Record<string, unknown>;
  return exact(v, ["grantId", "secret", "requestId", "createdAt", "attempts", "nextAttemptAt"])
    && id(v.grantId) && isEndpointSecret(v.secret) && id(v.requestId) && timestamp(v.createdAt)
    && Number.isSafeInteger(v.attempts) && (v.attempts as number) >= 0 && (v.attempts as number) <= 32 && timestamp(v.nextAttemptAt);
}
function isInboxEntry(value: unknown): value is NotificationInboxEntry {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const v = value as Record<string, unknown>;
  return exact(v, ["id", "dedupeKey", "requestIds", "kind", "createdAt", "updatedAt", "title", "message", "sessionId", "outcome"], ["machineId", "readAt"])
    && id(v.id) && typeof v.dedupeKey === "string" && HASH.test(v.dedupeKey)
    && stringList(v.requestIds, MAXIMUM_PUSH_GRANTS) && (v.requestIds as string[]).length > 0
    && (v.kind === "explicit" || v.kind === "ask" || v.kind === "agent_finished")
    && timestamp(v.createdAt) && timestamp(v.updatedAt) && (v.readAt === undefined || timestamp(v.readAt))
    && typeof v.title === "string" && Buffer.byteLength(v.title) > 0 && Buffer.byteLength(v.title) <= 256
    && typeof v.message === "string" && Buffer.byteLength(v.message) > 0 && Buffer.byteLength(v.message) <= 512
    && typeof v.sessionId === "string" && SESSION_ID.test(v.sessionId)
    && (v.machineId === undefined || (typeof v.machineId === "string" && Buffer.byteLength(v.machineId) > 0
      && Buffer.byteLength(v.machineId) <= 256 && !/[\u0000-\u001f\u007f]/u.test(v.machineId)))
    && ["queued", "accepted_by_apns", "failed", "ambiguous", "expired"].includes(v.outcome as string);
}
function validate(value: unknown): NotificationDocument {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("not object");
  const v = value as Record<string, unknown>;
  if (!exact(v, ["version", "policy", "grants", "pending", "receipts", "revocations"], ["inbox"]) || v.version !== 1) throw new Error("shape");
  if (!v.policy || typeof v.policy !== "object" || Array.isArray(v.policy)
    || !exact(v.policy as Record<string, unknown>, ["notifyWhenAskPresented"])
    || typeof (v.policy as { notifyWhenAskPresented?: unknown }).notifyWhenAskPresented !== "boolean") throw new Error("policy");
  if (!Array.isArray(v.grants) || v.grants.length > MAXIMUM_PUSH_GRANTS || !v.grants.every(isGrant)) throw new Error("grants");
  if (!Array.isArray(v.pending) || v.pending.length > MAXIMUM_PENDING_INTENTS || !v.pending.every(isIntent)) throw new Error("pending");
  if (!Array.isArray(v.receipts) || v.receipts.length > MAXIMUM_NOTIFICATION_RECEIPTS || !v.receipts.every(isReceipt)) throw new Error("receipts");
  if (!Array.isArray(v.revocations) || v.revocations.length > MAXIMUM_REVOCATIONS || !v.revocations.every(isRevocation)) throw new Error("revocations");
  if (v.inbox !== undefined && (!Array.isArray(v.inbox) || v.inbox.length > MAXIMUM_NOTIFICATION_INBOX_ENTRIES || !v.inbox.every(isInboxEntry))) throw new Error("inbox");
  if ((v.grants as unknown[]).length + v.revocations.length > MAXIMUM_REVOCATIONS) throw new Error("revocation reserve");
  const grants = v.grants as PushGrant[];
  if (new Set(grants.map((grant) => grant.deviceId)).size !== grants.length || new Set(grants.map((grant) => grant.grantId)).size !== grants.length) throw new Error("duplicate grants");
  const inbox = (v.inbox ?? []) as NotificationInboxEntry[];
  if (new Set(inbox.map((entry) => entry.id)).size !== inbox.length
    || new Set(inbox.flatMap((entry) => entry.requestIds)).size !== inbox.flatMap((entry) => entry.requestIds).length) throw new Error("duplicate inbox identity");
  return structuredClone(value) as NotificationDocument;
}

const empty = (): NotificationDocument => ({
  version: 1, policy: { notifyWhenAskPresented: true }, grants: [], pending: [], receipts: [], revocations: [], inbox: [],
});

/** One-process owner for the bounded credential document. Runtime locking guarantees one live Gateway. */
export class NotificationGrantStore {
  private readonly path: string;
  private readonly mutex = new AsyncMutex();
  constructor(tronHome: string, path = join(tronHome, "gateway", "notifications.json")) { this.path = path; }

  async initialize(): Promise<void> {
    await this.mutex.run(async () => {
      await this.ensureSecureParent();
      const current = await this.read();
      if (!current.present) {
        await atomicWriteJson(this.path, empty());
        await this.ensureSecureParent();
        return;
      }
      try { validate(current.value); }
      catch { throw new GatewayError("conflict", "Notification state is malformed or oversized"); }
    });
  }

  async snapshot(): Promise<NotificationDocument> {
    return this.mutex.run(async () => (await this.requireDocument()));
  }

  async update(update: (current: NotificationDocument) => NotificationDocument): Promise<NotificationDocument> {
    return this.mutex.run(async () => {
      const current = await this.requireDocument();
      const next = validate(update(structuredClone(current)));
      const encoded = Buffer.byteLength(JSON.stringify(next));
      if (encoded > MAXIMUM_DOCUMENT_BYTES) throw new GatewayError("busy", "Notification state exceeds its bounded capacity", true);
      await this.ensureSecureParent();
      await atomicWriteJson(this.path, next);
      await this.ensureSecureParent();
      return structuredClone(next);
    });
  }

  private async requireDocument(): Promise<NotificationDocument> {
    const result = await this.read();
    if (!result.present) throw new GatewayError("conflict", "Notification state disappeared while the Gateway was running");
    try { return validate(result.value); }
    catch { throw new GatewayError("conflict", "Notification state is malformed or oversized"); }
  }

  private async ensureSecureParent(): Promise<void> {
    const parent = dirname(this.path);
    const ownerUid = process.getuid?.();
    if (ownerUid === undefined) throw new GatewayError("conflict", "Notification state ownership cannot be verified");
    try { await mkdir(parent, { recursive: true, mode: 0o700 }); }
    catch { throw new GatewayError("conflict", "Notification state directory could not be created securely"); }
    let metadata;
    try { metadata = await lstat(parent); }
    catch { throw new GatewayError("conflict", "Notification state directory could not be inspected securely"); }
    if (!metadata.isDirectory() || metadata.isSymbolicLink() || metadata.uid !== ownerUid || (metadata.mode & 0o077) !== 0) {
      throw new GatewayError("conflict", "Notification state directory must be an owner-only non-symlink directory");
    }
  }

  private async read(): Promise<{ present: false } | { present: true; value: unknown }> {
    try { return await readSecureJson<unknown>(this.path, MAXIMUM_DOCUMENT_BYTES); }
    catch (error) {
      if (error instanceof SecureJsonFileError || error instanceof RangeError || error instanceof SyntaxError) {
        throw new GatewayError("conflict", "Notification state is unsafe, malformed, or oversized");
      }
      throw error;
    }
  }
}
