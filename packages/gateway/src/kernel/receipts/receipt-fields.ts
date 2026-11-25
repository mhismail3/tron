import type { ChatOrigin } from "../../protocol/types.js";
import { CONTROL_CHARACTER, CONTROL_CHARACTER_EXCEPT_LINE_BREAKS } from "../../foundation/control-characters.js";

export const MAX_ID_BYTES = 256;
export const MAX_NAME_BYTES = 512;
const ORIGIN_KINDS = new Set(["user", "subagent", "extension", "process", "gateway", "assistant", "unknown"] as const);
const ORIGIN_CONFIDENCE = new Set(["boundary", "receipt", "adapter", "unknown"] as const);

export function validText(value: unknown, bytes: number, allowNewlines = false): value is string {
  const controls = allowNewlines ? CONTROL_CHARACTER_EXCEPT_LINE_BREAKS : CONTROL_CHARACTER;
  return typeof value === "string" && value.length > 0 && Buffer.byteLength(value, "utf8") <= bytes
    && !controls.test(value);
}

export function validTimestamp(value: unknown): value is string {
  if (!validText(value, 64)) return false;
  const time = Date.parse(value);
  return Number.isFinite(time) && new Date(time).toISOString() === value;
}

export function validOrigin(value: unknown): value is ChatOrigin {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const origin = value as Record<string, unknown>;
  return ORIGIN_KINDS.has(origin.kind as ChatOrigin["kind"])
    && ORIGIN_CONFIDENCE.has(origin.confidence as ChatOrigin["confidence"])
    && (origin.ownerId === undefined || validText(origin.ownerId, MAX_ID_BYTES))
    && (origin.title === undefined || validText(origin.title, MAX_NAME_BYTES))
    && Object.keys(origin).every(key => ["kind", "confidence", "ownerId", "title"].includes(key));
}
