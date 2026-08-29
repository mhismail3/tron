import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import type { ChatOrigin, InvocationLifecycle, JsonValue, ResourceInvocation } from "../protocol/types.js";

/** Internal folded lifecycle derived from canonical invocation receipts. */
export interface InvocationProjection {
  version: 1;
  invocationId: string;
  operationId: string;
  source: "plain" | "skill" | "prompt" | "extension";
  name?: string;
  arguments?: string;
  resourceInvocation?: ResourceInvocation;
  disposition: "canonicalPrompt" | "queuedPrompt" | "extensionCommand";
  lifecycle: InvocationLifecycle;
  canonicalEntryId?: string;
  origin: ChatOrigin;
  retryable?: boolean;
  sequence: number;
  updatedAt: string;
}

/** Canonical, non-context receipt family for Gateway invocation causality. */
export const INVOCATION_RECEIPT_TYPE = "tron.chat-invocation.v1";
export const INVOCATION_RECEIPT_WRITER = "gateway";
export const MAX_RECEIPT_BYTES = 8_192;
const MAX_ID_BYTES = 256;
const MAX_NAME_BYTES = 512;
const MAX_ARGUMENT_BYTES = 64_000;
const TERMINAL_LIFECYCLES = new Set<InvocationLifecycle>(["completed", "failed", "interrupted", "outcomeUnknown"]);
const LIFECYCLES = new Set<InvocationLifecycle>([
  "staged", "accepted", "queued", "running", "waitingForInput", "retrying", "settling", "completed", "failed", "interrupted", "outcomeUnknown",
]);
const KINDS = new Set(["start", "transition", "terminal", "binding"] as const);
const SOURCES = new Set(["plain", "skill", "prompt", "extension"] as const);
const ORIGIN_KINDS = new Set(["user", "subagent", "extension", "process", "gateway", "assistant", "unknown"] as const);
const ORIGIN_CONFIDENCE = new Set(["boundary", "receipt", "adapter", "unknown"] as const);

type ReceiptKind = "start" | "transition" | "terminal" | "binding";
type ReceiptSource = "plain" | "skill" | "prompt" | "extension";

export interface InvocationReceiptData {
  writer: typeof INVOCATION_RECEIPT_WRITER;
  version: 1;
  receiptId: string;
  receiptKind: ReceiptKind;
  invocationId: string;
  operationId: string;
  sessionId: string;
  source: ReceiptSource;
  name?: string;
  arguments?: string;
  lifecycle?: InvocationLifecycle;
  canonicalEntryId?: string;
  parentEntryId?: string;
  origin?: ChatOrigin;
  retryable?: boolean;
  sequence: number;
  createdAt: string;
  /** Terminal errors are codes, never arbitrary extension payloads. */
  errorCode?: string;
}

function validText(value: unknown, bytes: number): value is string {
  return typeof value === "string" && value.length > 0 && Buffer.byteLength(value, "utf8") <= bytes
    && !/[\u0000-\u001f\u007f]/u.test(value);
}

function utf8Prefix(value: string, bytes: number): string {
  if (Buffer.byteLength(value, "utf8") <= bytes) return value;
  return Buffer.from(value, "utf8").subarray(0, bytes).toString("utf8").replace(/\uFFFD$/u, "");
}

function validTimestamp(value: unknown): value is string {
  if (!validText(value, 64)) return false;
  const time = Date.parse(value);
  return Number.isFinite(time) && new Date(time).toISOString() === value;
}

function canonicalJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value as Record<string, unknown>).sort().map(key => `${JSON.stringify(key)}:${canonicalJSON((value as Record<string, unknown>)[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function validOrigin(value: unknown): value is ChatOrigin {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const origin = value as Record<string, unknown>;
  return ORIGIN_KINDS.has(origin.kind as ChatOrigin["kind"])
    && ORIGIN_CONFIDENCE.has(origin.confidence as ChatOrigin["confidence"])
    && (origin.ownerId === undefined || validText(origin.ownerId, MAX_ID_BYTES))
    && (origin.title === undefined || validText(origin.title, MAX_NAME_BYTES))
    && Object.keys(origin).every(key => ["kind", "confidence", "ownerId", "title"].includes(key));
}

function allowedKeys(kind: ReceiptKind): Set<string> {
  const common = ["writer", "version", "receiptId", "receiptKind", "invocationId", "operationId", "sessionId", "source", "sequence", "createdAt"];
  if (kind === "start") common.push("name", "arguments", "lifecycle", "origin");
  if (kind === "transition") common.push("lifecycle");
  if (kind === "terminal") common.push("name", "origin", "lifecycle", "retryable", "errorCode");
  if (kind === "binding") common.push("canonicalEntryId", "parentEntryId");
  return new Set(common);
}

/** Add the Gateway writer marker and reject an oversized encoded record. */
export function makeInvocationReceipt(data: Omit<InvocationReceiptData, "writer">): InvocationReceiptData {
  const receipt = {
    ...data,
    ...(data.arguments === undefined ? {} : { arguments: utf8Prefix(data.arguments, 5_000) }),
    ...(data.name === undefined ? {} : { name: utf8Prefix(data.name, MAX_NAME_BYTES) }),
    writer: INVOCATION_RECEIPT_WRITER,
  } as InvocationReceiptData;
  const parsed = parseInvocationReceipt(receipt);
  if (!parsed) throw new Error("invalid invocation receipt");
  return parsed;
}

export function parseInvocationReceipt(value: unknown): InvocationReceiptData | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const r = value as Record<string, unknown>;
  if (r.writer !== INVOCATION_RECEIPT_WRITER || r.version !== 1
      || !validText(r.receiptId, MAX_ID_BYTES) || !validText(r.invocationId, MAX_ID_BYTES)
      || !validText(r.operationId, MAX_ID_BYTES) || !validText(r.sessionId, MAX_ID_BYTES)
      || !SOURCES.has(r.source as ReceiptSource) || !KINDS.has(r.receiptKind as ReceiptKind)
      || !Number.isSafeInteger(r.sequence) || Number(r.sequence) < 0 || !validTimestamp(r.createdAt)
      || !Object.keys(r).every(key => allowedKeys(r.receiptKind as ReceiptKind).has(key))) return undefined;
  const kind = r.receiptKind as ReceiptKind;
  if (r.name !== undefined && !validText(r.name, MAX_NAME_BYTES)) return undefined;
  if (r.arguments !== undefined && !validText(r.arguments, MAX_ARGUMENT_BYTES)) return undefined;
  if (r.lifecycle !== undefined && (!validText(r.lifecycle, 64) || !LIFECYCLES.has(r.lifecycle as InvocationLifecycle))) return undefined;
  if (r.canonicalEntryId !== undefined && !validText(r.canonicalEntryId, MAX_ID_BYTES)) return undefined;
  if (r.parentEntryId !== undefined && !validText(r.parentEntryId, MAX_ID_BYTES)) return undefined;
  if (r.origin !== undefined && !validOrigin(r.origin)) return undefined;
  if (r.retryable !== undefined && typeof r.retryable !== "boolean") return undefined;
  if (r.errorCode !== undefined && !validText(r.errorCode, 256)) return undefined;
  if (kind === "start" && (r.lifecycle !== "staged"
      || r.canonicalEntryId !== undefined || r.errorCode !== undefined)) return undefined;
  if (kind === "transition" && (!r.lifecycle || TERMINAL_LIFECYCLES.has(r.lifecycle as InvocationLifecycle))) return undefined;
  if (kind === "terminal" && (!TERMINAL_LIFECYCLES.has(r.lifecycle as InvocationLifecycle) || r.canonicalEntryId !== undefined)) return undefined;
  if (kind === "binding" && (r.canonicalEntryId === undefined || r.lifecycle !== undefined || r.errorCode !== undefined)) return undefined;
  if (Buffer.byteLength(JSON.stringify(r), "utf8") > MAX_RECEIPT_BYTES) return undefined;
  return r as unknown as InvocationReceiptData;
}

/**
 * Read only Gateway-authored records. Same-id identical records are harmless
 * duplicate delivery; same-id contradictory records are rejected rather than
 * allowing an extension to rewrite a terminal fact.
 */
export function invocationReceipts(entries: readonly SessionEntry[], sessionId?: string): InvocationReceiptData[] {
  const records = new Map<string, InvocationReceiptData>();
  for (const entry of entries) {
    if (entry.type !== "custom" || entry.customType !== INVOCATION_RECEIPT_TYPE) continue;
    const receipt = parseInvocationReceipt(entry.data);
    if (!receipt || (sessionId !== undefined && receipt.sessionId !== sessionId)) continue;
    if (receipt.canonicalEntryId !== undefined) {
      const target = entries.find(candidate => candidate.id === receipt.canonicalEntryId);
      if (!target || (target.type === "custom" && target.customType === INVOCATION_RECEIPT_TYPE)) {
        throw new Error("invocation receipt target is not canonical");
      }
      if (receipt.parentEntryId !== undefined && entry.parentId !== receipt.parentEntryId) {
        throw new Error("invocation receipt parent does not match canonical entry");
      }
    }
    const previous = records.get(receipt.receiptId);
    if (previous && canonicalJSON(previous) !== canonicalJSON(receipt)) throw new Error("contradictory invocation receipt");
    records.set(receipt.receiptId, receipt);
  }
  // Map insertion order is canonical branch order. Sequence is a bounded live
  // presentation fact only and can repeat across writes in one Gateway revision.
  return [...records.values()];
}

function legalTransition(from: InvocationLifecycle, to: InvocationLifecycle, terminal: boolean): boolean {
  if (TERMINAL_LIFECYCLES.has(from)) return false;
  if (terminal) return from === "staged"
      ? to === "failed" || to === "outcomeUnknown"
      : TERMINAL_LIFECYCLES.has(to);
  const transitions: Record<string, InvocationLifecycle[]> = {
    staged: ["accepted", "queued", "running", "waitingForInput", "retrying", "settling"],
    accepted: ["queued", "running", "waitingForInput", "retrying", "settling"],
    queued: ["running", "settling"],
    running: ["waitingForInput", "retrying", "settling"],
    waitingForInput: ["running", "settling"],
    retrying: ["running", "settling"],
    settling: [],
  };
  return transitions[from]?.includes(to) === true;
}

export function invocationProjection(receipts: readonly InvocationReceiptData[]): InvocationProjection[] {
  const grouped = new Map<string, InvocationProjection>();
  const terminal = new Set<string>();
  for (const receipt of receipts) {
    const previous = grouped.get(receipt.invocationId);
    if (receipt.receiptKind === "start" && previous) {
      throw new Error("invocation has more than one start receipt");
    }
    if (previous && (previous.operationId !== receipt.operationId || previous.source !== receipt.source)) {
      throw new Error("invocation receipt ownership changed");
    }
    if (receipt.receiptKind === "start" && !previous) {
      grouped.set(receipt.invocationId, {
        version: 1, invocationId: receipt.invocationId, operationId: receipt.operationId,
        source: receipt.source, ...(receipt.name ? { name: receipt.name } : {}),
        ...(receipt.arguments ? { arguments: receipt.arguments } : {}),
        ...(["skill", "prompt", "extension"].includes(receipt.source) && receipt.name !== undefined
          ? { resourceInvocation: { source: receipt.source as "skill" | "prompt" | "extension", name: receipt.name, arguments: receipt.arguments ?? "" } }
          : {}),
        disposition: receipt.source === "extension" ? "extensionCommand" : "canonicalPrompt",
        lifecycle: receipt.lifecycle ?? "accepted",
        origin: receipt.origin ?? { kind: receipt.source === "extension" ? "extension" : "user", confidence: "receipt" },
        sequence: receipt.sequence, updatedAt: receipt.createdAt,
      });
      continue;
    }
    if (!previous) continue;
    if (receipt.receiptKind === "terminal") {
      if (terminal.has(receipt.invocationId)) {
        const current = previous.lifecycle;
        if (current !== receipt.lifecycle) throw new Error("contradictory terminal invocation receipt");
      } else if (!legalTransition(previous.lifecycle, receipt.lifecycle!, true)) {
        throw new Error("illegal terminal invocation transition");
      }
      terminal.add(receipt.invocationId);
    } else if (receipt.receiptKind === "transition") {
      if (!legalTransition(previous.lifecycle, receipt.lifecycle!, false)) {
        throw new Error("illegal invocation transition");
      }
    } else if (terminal.has(receipt.invocationId)) {
      // Facts after terminal settlement cannot mutate the lifecycle, but a
      // binding/turn may still fill canonical identity without reopening it.
      if (receipt.lifecycle !== undefined) throw new Error("invocation lifecycle changed after terminal receipt");
    }
    const next: InvocationProjection = { ...previous, updatedAt: receipt.createdAt };
    if (receipt.lifecycle && !terminal.has(receipt.invocationId)) next.lifecycle = receipt.lifecycle;
    if (receipt.lifecycle && receipt.receiptKind === "terminal") next.lifecycle = receipt.lifecycle;
    if (receipt.canonicalEntryId) next.canonicalEntryId = receipt.canonicalEntryId;
    if (receipt.retryable !== undefined) next.retryable = receipt.retryable;
    grouped.set(receipt.invocationId, next);
  }
  return [...grouped.values()].sort((a, b) => a.sequence - b.sequence);
}

export function receiptJSON(data: InvocationReceiptData): JsonValue {
  return data as unknown as JsonValue;
}
