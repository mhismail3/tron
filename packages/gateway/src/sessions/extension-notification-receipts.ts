import type { ChatOrigin, JsonValue } from "../protocol/types.js";

/** Canonical, non-context extension notification persisted in Pi JSONL. */
export const EXTENSION_NOTIFICATION_RECEIPT_TYPE = "tron.extension-notification.v1";
export const EXTENSION_NOTIFICATION_WRITER = "gateway";
const MAX_RECEIPT_BYTES = 40 * 1_024;
const MAX_ID_BYTES = 256;
const MAX_MESSAGE_BYTES = 32 * 1_024;
const ORIGIN_KINDS = new Set(["user", "subagent", "extension", "process", "gateway", "assistant", "unknown"] as const);
const ORIGIN_CONFIDENCE = new Set(["boundary", "receipt", "adapter", "unknown"] as const);

export interface ExtensionNotificationReceipt {
  writer: typeof EXTENSION_NOTIFICATION_WRITER;
  version: 1;
  receiptId: string;
  sessionId: string;
  message: string;
  tone: "info" | "warning" | "error";
  origin: ChatOrigin;
  invocationId?: string;
  operationId?: string;
  sequence: number;
  createdAt: string;
}

export type ExtensionNotificationReceiptInput = Omit<ExtensionNotificationReceipt, "writer"> & { writer?: never };

function validText(value: unknown, maximum: number, allowNewlines = false): value is string {
  const controls = allowNewlines ? /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u : /[\u0000-\u001f\u007f]/u;
  return typeof value === "string" && value.length > 0
    && Buffer.byteLength(value, "utf8") <= maximum && !controls.test(value);
}

function validTimestamp(value: unknown): value is string {
  if (!validText(value, 64)) return false;
  const time = Date.parse(value);
  return Number.isFinite(time) && new Date(time).toISOString() === value;
}

function validOrigin(value: unknown): value is ChatOrigin {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const origin = value as Record<string, unknown>;
  const keys = Object.keys(origin);
  if (keys.some(key => !["kind", "ownerId", "title", "confidence"].includes(key))) return false;
  return ORIGIN_KINDS.has(origin.kind as ChatOrigin["kind"])
    && ORIGIN_CONFIDENCE.has(origin.confidence as ChatOrigin["confidence"])
    && (origin.ownerId === undefined || validText(origin.ownerId, MAX_ID_BYTES))
    && (origin.title === undefined || validText(origin.title, 512));
}

export function makeExtensionNotificationReceipt(input: ExtensionNotificationReceiptInput): ExtensionNotificationReceipt {
  return { ...input, writer: EXTENSION_NOTIFICATION_WRITER };
}

export function extensionNotificationJSON(receipt: ExtensionNotificationReceipt): JsonValue {
  return receipt as unknown as JsonValue;
}

export function parseExtensionNotificationReceipt(value: unknown): ExtensionNotificationReceipt | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)
    || Buffer.byteLength(JSON.stringify(value), "utf8") > MAX_RECEIPT_BYTES) return undefined;
  const receipt = value as Record<string, unknown>;
  const allowed = new Set([
    "writer", "version", "receiptId", "sessionId", "message", "tone", "origin",
    "invocationId", "operationId", "sequence", "createdAt",
  ]);
  if (Object.keys(receipt).some(key => !allowed.has(key))
    || receipt.writer !== EXTENSION_NOTIFICATION_WRITER || receipt.version !== 1
    || !validText(receipt.receiptId, MAX_ID_BYTES)
    || !validText(receipt.sessionId, MAX_ID_BYTES)
    || !validText(receipt.message, MAX_MESSAGE_BYTES, true)
    || !["info", "warning", "error"].includes(receipt.tone as string)
    || !validOrigin(receipt.origin)
    || (receipt.invocationId !== undefined && !validText(receipt.invocationId, MAX_ID_BYTES))
    || (receipt.operationId !== undefined && !validText(receipt.operationId, MAX_ID_BYTES))
    || !Number.isSafeInteger(receipt.sequence) || (receipt.sequence as number) < 0
    || !validTimestamp(receipt.createdAt)) return undefined;
  return value as ExtensionNotificationReceipt;
}

