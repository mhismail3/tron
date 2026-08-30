import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import type { ChatOrigin, InvocationLifecycle, JsonValue, ResourceInvocation } from "../protocol/types.js";
import { GatewayError } from "../errors.js";
import { RESOURCE_ARGUMENTS_MAX_BYTES } from "./resource-invocation.js";

/** Internal folded lifecycle derived from canonical invocation receipts. */
export interface InvocationProjection {
  version: 1;
  invocationId: string;
  operationId: string;
  source: "plain" | "skill" | "prompt" | "extension";
  name?: string;
  arguments?: string;
  resourceInvocation?: ResourceInvocation;
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

interface InvocationReceiptCommon {
  receiptId: string;
  version: 1;
  receiptKind: ReceiptKind;
  invocationId: string;
  operationId: string;
  sessionId: string;
  source: ReceiptSource;
  sequence: number;
  createdAt: string;
}

export interface InvocationStartReceipt extends InvocationReceiptCommon {
  receiptKind: "start";
  name?: string;
  arguments?: string;
  lifecycle: "staged";
  origin: ChatOrigin;
}

export interface InvocationTransitionReceipt extends InvocationReceiptCommon {
  receiptKind: "transition";
  lifecycle: Exclude<InvocationLifecycle, "staged" | "completed" | "failed" | "interrupted" | "outcomeUnknown">;
}

export interface InvocationTerminalReceipt extends InvocationReceiptCommon {
  receiptKind: "terminal";
  lifecycle: "completed" | "failed" | "interrupted" | "outcomeUnknown";
  name?: string;
  origin?: ChatOrigin;
  retryable?: boolean;
  /** Terminal errors are codes, never arbitrary extension payloads. */
  errorCode?: string;
}

export interface InvocationBindingReceipt extends InvocationReceiptCommon {
  receiptKind: "binding";
  canonicalEntryId: string;
  parentEntryId?: string;
}

export type InvocationReceiptData =
  | (InvocationStartReceipt & { writer: typeof INVOCATION_RECEIPT_WRITER })
  | (InvocationTransitionReceipt & { writer: typeof INVOCATION_RECEIPT_WRITER })
  | (InvocationTerminalReceipt & { writer: typeof INVOCATION_RECEIPT_WRITER })
  | (InvocationBindingReceipt & { writer: typeof INVOCATION_RECEIPT_WRITER });

type ReceiptInput<T> = Omit<T, "writer"> & { writer?: never };

type InvocationReceiptInput =
  | ReceiptInput<InvocationStartReceipt>
  | ReceiptInput<InvocationTransitionReceipt>
  | ReceiptInput<InvocationTerminalReceipt>
  | ReceiptInput<InvocationBindingReceipt>;

function validText(value: unknown, bytes: number): value is string {
  return typeof value === "string" && value.length > 0 && Buffer.byteLength(value, "utf8") <= bytes
    && !/[\u0000-\u001f\u007f]/u.test(value);
}

function validArguments(value: unknown): value is string {
  return typeof value === "string" && value.length > 0
    && Buffer.byteLength(value, "utf8") <= RESOURCE_ARGUMENTS_MAX_BYTES
    && !/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(value);
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
export function makeInvocationReceipt(data: InvocationReceiptInput): InvocationReceiptData {
  // Semantic identity must never be silently shortened. Request boundaries
  // reject oversized values before this builder is reached.
  const receipt = { ...data, writer: INVOCATION_RECEIPT_WRITER } as InvocationReceiptData;
  const parsed = parseInvocationReceipt(receipt);
  if (!parsed) throw new GatewayError("invalid_request", "Gateway could not construct a valid invocation receipt");
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
  if (r.arguments !== undefined && !validArguments(r.arguments)) return undefined;
  if (r.lifecycle !== undefined && (!validText(r.lifecycle, 64) || !LIFECYCLES.has(r.lifecycle as InvocationLifecycle))) return undefined;
  if (r.canonicalEntryId !== undefined && !validText(r.canonicalEntryId, MAX_ID_BYTES)) return undefined;
  if (r.parentEntryId !== undefined && !validText(r.parentEntryId, MAX_ID_BYTES)) return undefined;
  if (r.origin !== undefined && !validOrigin(r.origin)) return undefined;
  if (kind === "start" && !validOrigin(r.origin)) return undefined;
  if (r.retryable !== undefined && typeof r.retryable !== "boolean") return undefined;
  if (r.errorCode !== undefined && !validText(r.errorCode, 256)) return undefined;
  if (kind === "start" && (r.lifecycle !== "staged"
      || r.canonicalEntryId !== undefined || r.errorCode !== undefined
      || r.retryable !== undefined || r.parentEntryId !== undefined
      || (r.source === "plain" && (r.name !== undefined || r.arguments !== undefined))
      || (r.source !== "plain" && r.name === undefined))) return undefined;
  if (kind === "transition" && (!r.lifecycle || r.lifecycle === "staged"
      || TERMINAL_LIFECYCLES.has(r.lifecycle as InvocationLifecycle))) return undefined;
  if (kind === "terminal" && (!TERMINAL_LIFECYCLES.has(r.lifecycle as InvocationLifecycle) || r.canonicalEntryId !== undefined)) return undefined;
  if (kind === "binding" && (r.canonicalEntryId === undefined || r.lifecycle !== undefined
      || r.errorCode !== undefined || r.name !== undefined || r.arguments !== undefined
      || r.origin !== undefined || r.retryable !== undefined)) return undefined;
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
  const entriesById = new Map(entries.map(entry => [entry.id, entry]));
  for (const entry of entries) {
    if (entry.type !== "custom" || entry.customType !== INVOCATION_RECEIPT_TYPE) continue;
    const receipt = parseInvocationReceipt(entry.data);
    if (!receipt || (sessionId !== undefined && receipt.sessionId !== sessionId)) continue;
    if (receipt.receiptKind === "binding") {
      const target = entriesById.get(receipt.canonicalEntryId);
      if (!target || target.type !== "message" || target.message.role !== "user") {
        throw new Error("invocation receipt target is not a canonical user message");
      }
      if (receipt.parentEntryId !== undefined && entry.parentId !== receipt.parentEntryId) {
        throw new Error("invocation receipt parent does not match canonical entry");
      }
    }
    const previous = records.get(receipt.receiptId);
    if (previous && canonicalJSON(previous) !== canonicalJSON(receipt)) throw new Error("contradictory invocation receipt");
    records.set(receipt.receiptId, receipt);
  }
  const values = [...records.values()];
  const startsByInvocation = new Map(values
    .filter((record): record is InvocationStartReceipt & { writer: typeof INVOCATION_RECEIPT_WRITER } => record.receiptKind === "start")
    .map(record => [record.invocationId, record]));
  const boundEntries = new Set<string>();
  const boundInvocations = new Set<string>();
  for (const record of values) {
    if (record.receiptKind !== "start" && !startsByInvocation.has(record.invocationId)) {
      throw new Error("invocation receipt has no start receipt");
    }
    if (record.receiptKind === "binding") {
      if (boundEntries.has(record.canonicalEntryId)) throw new Error("canonical entry has more than one invocation binding");
      if (boundInvocations.has(record.invocationId)) throw new Error("invocation has more than one canonical binding");
      boundEntries.add(record.canonicalEntryId);
      boundInvocations.add(record.invocationId);
    }
  }
  // Map insertion order is canonical branch order. Sequence is a bounded live
  // presentation fact only and can repeat across writes in one Gateway revision.
  return values;
}

function legalTransition(from: InvocationLifecycle, to: InvocationLifecycle, terminal: boolean): boolean {
  if (TERMINAL_LIFECYCLES.has(from)) return false;
  // A terminal observation is authoritative even if the accepted transition
  // could not be persisted after Pi admitted execution.
  if (terminal) return TERMINAL_LIFECYCLES.has(to);
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
  const boundEntries = new Set<string>();
  const boundInvocations = new Set<string>();
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
        lifecycle: receipt.lifecycle ?? "accepted",
        origin: receipt.origin ?? { kind: receipt.source === "extension" ? "extension" : "user", confidence: "receipt" },
        sequence: receipt.sequence, updatedAt: receipt.createdAt,
      });
      continue;
    }
    if (!previous) throw new Error("invocation receipt has no start receipt");
    if (receipt.receiptKind === "binding") {
      if (boundEntries.has(receipt.canonicalEntryId)) throw new Error("canonical entry has more than one invocation binding");
      if (boundInvocations.has(receipt.invocationId)) throw new Error("invocation has more than one canonical binding");
      boundEntries.add(receipt.canonicalEntryId);
      boundInvocations.add(receipt.invocationId);
    }
    if ("name" in receipt && receipt.name !== undefined && receipt.name !== previous.name) {
      throw new Error("invocation receipt resource name changed");
    }
    if ("origin" in receipt && canonicalJSON(receipt.origin) !== canonicalJSON(previous.origin)) {
      throw new Error("invocation receipt origin changed");
    }
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
      // Only canonical binding may arrive after terminal settlement.
      if (receipt.receiptKind !== "binding") {
        throw new Error("invocation changed after terminal receipt");
      }
    }
    const next: InvocationProjection = { ...previous, updatedAt: receipt.createdAt };
    if ("lifecycle" in receipt && receipt.lifecycle && !terminal.has(receipt.invocationId)) next.lifecycle = receipt.lifecycle;
    if (receipt.receiptKind === "terminal") next.lifecycle = receipt.lifecycle;
    if ("canonicalEntryId" in receipt && receipt.canonicalEntryId) next.canonicalEntryId = receipt.canonicalEntryId;
    if ("retryable" in receipt && receipt.retryable !== undefined) next.retryable = receipt.retryable;
    grouped.set(receipt.invocationId, next);
  }
  return [...grouped.values()].sort((a, b) => a.sequence - b.sequence);
}

export function receiptJSON(data: InvocationReceiptData): JsonValue {
  return data as unknown as JsonValue;
}
