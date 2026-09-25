import type { ChatOrigin, JsonValue } from "../protocol/types.js";
import {
  MAX_ID_BYTES,
  validOrigin,
  validText,
  validTimestamp,
} from "./invocation-receipts.js";

/** Canonical, non-context extension notification persisted in Pi JSONL. */
export const EXTENSION_NOTIFICATION_RECEIPT_TYPE = "tron.extension-notification.v1";
export const EXTENSION_NOTIFICATION_WRITER = "gateway";
const MAX_RECEIPT_BYTES = 40 * 1_024;
const MAX_MESSAGE_BYTES = 32 * 1_024;

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

