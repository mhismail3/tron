import type { SessionEntry } from "../pi/coding-agent.js";
import { SETTINGS_OUTCOME_MESSAGE, INPUT_TRIGGER_MESSAGE, INPUT_TRIGGER_RESUME_MESSAGE } from "./delivery-tags.js";
import type { ChatOrigin, InvocationLifecycle, JsonValue, ResourceInvocation } from "../../protocol/types.js";
import { GatewayError } from "../../errors.js";
import { MAXIMUM_RESOURCE_INVOCATIONS, RESOURCE_ARGUMENTS_MAX_BYTES } from "../resources/resource-invocation.js";
import { MAX_ID_BYTES, MAX_NAME_BYTES, validOrigin, validText, validTimestamp } from "./receipt-fields.js";
import { core as lifecycle, type Fact, type Kind, type Life, type Mark, type Refusal } from "../../core/receipts/invocation-lifecycle/facade.js";

/** Internal folded lifecycle derived from canonical invocation receipts. */
export interface InvocationProjection {
  version: 1;
  invocationId: string;
  operationId: string;
  source: InvocationSource;
  name?: string;
  arguments?: string;
  /** User-authored text for image-bearing prompts, whose canonical message Pi may
   * append resize notes to, and for skill/prompt invocations, whose canonical
   * message is the expansions followed by this text. */
  submittedText?: string;
  /** Ordered invoked resources: skills and prompts, or one extension command. */
  resourceInvocations?: ResourceInvocation[];
  lifecycle: InvocationLifecycle;
  canonicalEntryId?: string;
  origin: ChatOrigin;
  retryable?: boolean;
  sequence: number;
  updatedAt: string;
}

/** The Home task result custom message a Home wake is bound to. */

export const HOME_TASK_RESULT_MESSAGE = "tron.home-task-result.v1";
/** Canonical, non-context receipt family for Gateway invocation causality. */
export const INVOCATION_RECEIPT_TYPE = "tron.chat-invocation.v1";
const INVOCATION_RECEIPT_WRITER = "gateway";
const MAX_RECEIPT_BYTES = 400 * 1_024;
const TERMINAL_LIFECYCLES = new Set<InvocationLifecycle>(["completed", "failed", "interrupted", "outcomeUnknown"]);
const LIFECYCLES = new Set<InvocationLifecycle>([
  "staged", "accepted", "queued", "running", "waitingForInput", "retrying", "settling", "completed", "failed", "interrupted", "outcomeUnknown",
]);
const KINDS = new Set(["start", "transition", "terminal", "binding"] as const);
/** Gateway-authored sources without a user-authored name. An older Gateway that
 * does not know a source skips its receipt (rollback degrades to unattributed work). */
export type InvocationSource = "plain" | "skill" | "prompt" | "extension" | "subagentWake" | "homeWake";
const SOURCES = new Set<InvocationSource>(["plain", "skill", "prompt", "extension", "subagentWake", "homeWake"]);
/** Sources that carry no name or arguments: a plain prompt or a Gateway-authored wake. */
const UNNAMED_SOURCES: ReadonlySet<unknown> = new Set<InvocationSource>(["plain", "subagentWake", "homeWake"]);

type ReceiptKind = "start" | "transition" | "terminal" | "binding";

interface InvocationReceiptCommon {
  receiptId: string;
  version: 1;
  receiptKind: ReceiptKind;
  invocationId: string;
  operationId: string;
  sessionId: string;
  source: InvocationSource;
  sequence: number;
  createdAt: string;
}

/** One skill or prompt a message invoked; the receipt's `submittedText` carries the message text. */
export interface InvokedResource {
  source: "skill" | "prompt";
  name: string;
}

interface InvocationStartReceipt extends InvocationReceiptCommon {
  receiptKind: "start";
  /** The first invoked resource's name for skill/prompt sources. */
  name?: string;
  arguments?: string;
  /** Every skill and prompt the message invoked, in order (#311). A start
   * receipt written before multi-resource messages names one resource through
   * `source`, `name` and `arguments` only, and stays readable as that one. */
  resources?: InvokedResource[];
  submittedText?: string;
  lifecycle: "staged";
  origin: ChatOrigin;
}

interface InvocationTransitionReceipt extends InvocationReceiptCommon {
  receiptKind: "transition";
  lifecycle: Exclude<InvocationLifecycle, "staged" | "completed" | "failed" | "interrupted" | "outcomeUnknown">;
}

interface InvocationTerminalReceipt extends InvocationReceiptCommon {
  receiptKind: "terminal";
  lifecycle: "completed" | "failed" | "interrupted" | "outcomeUnknown";
  name?: string;
  origin?: ChatOrigin;
  retryable?: boolean;
  /** Terminal errors are codes, never arbitrary extension payloads. */
  errorCode?: string;
}

interface InvocationBindingReceipt extends InvocationReceiptCommon {
  receiptKind: "binding";
  canonicalEntryId: string;
  parentEntryId?: string;
}

type InvocationReceiptData =
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

function validResources(value: unknown, source: unknown, name: unknown, argumentsText: unknown): value is InvokedResource[] {
  if (!Array.isArray(value) || value.length === 0 || value.length > MAXIMUM_RESOURCE_INVOCATIONS
    || argumentsText !== undefined) return false;
  const seen = new Set<string>();
  const valid = value.every((resource: unknown) => {
    if (!resource || typeof resource !== "object" || Array.isArray(resource)) return false;
    const candidate = resource as Record<string, unknown>;
    return (candidate.source === "skill" || candidate.source === "prompt")
      && validText(candidate.name, MAX_NAME_BYTES)
      && Object.keys(candidate).every(key => key === "source" || key === "name")
      && seen.add(`${candidate.source}:${candidate.name}`);
  });
  const first = value[0] as Record<string, unknown> | undefined;
  return valid && seen.size === value.length && first?.source === source && first?.name === name;
}

function canonicalJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value as Record<string, unknown>).sort().map(key => `${JSON.stringify(key)}:${canonicalJSON((value as Record<string, unknown>)[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

const COMMON_KEYS = ["writer", "version", "receiptId", "receiptKind", "invocationId", "operationId", "sessionId", "source", "sequence", "createdAt"];
const ALLOWED_KEYS: Record<ReceiptKind, ReadonlySet<string>> = {
  start: new Set([...COMMON_KEYS, "name", "arguments", "resources", "submittedText", "lifecycle", "origin"]),
  transition: new Set([...COMMON_KEYS, "lifecycle"]),
  terminal: new Set([...COMMON_KEYS, "name", "origin", "lifecycle", "retryable", "errorCode"]),
  binding: new Set([...COMMON_KEYS, "canonicalEntryId", "parentEntryId"]),
};

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
      || !SOURCES.has(r.source as InvocationSource) || !KINDS.has(r.receiptKind as ReceiptKind)
      || !Number.isSafeInteger(r.sequence) || Number(r.sequence) < 0 || !validTimestamp(r.createdAt)
      || !Object.keys(r).every(key => ALLOWED_KEYS[r.receiptKind as ReceiptKind].has(key))) return undefined;
  const kind = r.receiptKind as ReceiptKind;
  if (r.name !== undefined && !validText(r.name, MAX_NAME_BYTES)) return undefined;
  if (r.arguments !== undefined && !validText(r.arguments, RESOURCE_ARGUMENTS_MAX_BYTES, true)) return undefined;
  if (r.submittedText !== undefined && (typeof r.submittedText !== "string"
      || Buffer.byteLength(r.submittedText, "utf8") > 192 * 1_024
      || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(r.submittedText))) return undefined;
  if (r.resources !== undefined && !validResources(r.resources, r.source, r.name, r.arguments)) return undefined;
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
      || (UNNAMED_SOURCES.has(r.source) && (r.name !== undefined || r.arguments !== undefined))
      || (!UNNAMED_SOURCES.has(r.source) && r.name === undefined))) return undefined;
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
  // A branch with no invocation receipt has nothing to fold, and a snapshot
  // projection runs this over the whole branch on every build: skip indexing
  // every entry for a record set that stays empty (G-2).
  if (!entries.some((entry) => entry.type === "custom" && entry.customType === INVOCATION_RECEIPT_TYPE)) return [];
  const records = new Map<string, InvocationReceiptData>();
  const entriesById = new Map(entries.map(entry => [entry.id, entry]));
  for (const entry of entries) {
    if (entry.type !== "custom" || entry.customType !== INVOCATION_RECEIPT_TYPE) continue;
    const receipt = parseInvocationReceipt(entry.data);
    if (!receipt || (sessionId !== undefined && receipt.sessionId !== sessionId)) continue;
    if (receipt.receiptKind === "binding") {
      const target = entriesById.get(receipt.canonicalEntryId);
      // A Home wake binds the result message that triggered it, never a user message.
      const valid = receipt.source === "homeWake"
        ? target?.type === "custom_message" && (target.customType === HOME_TASK_RESULT_MESSAGE || target.customType === SETTINGS_OUTCOME_MESSAGE || target.customType === INPUT_TRIGGER_MESSAGE || target.customType === INPUT_TRIGGER_RESUME_MESSAGE)
        : target?.type === "message" && target.message.role === "user";
      if (!valid) throw new Error("invocation receipt target is not the canonical message its source binds");
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

const KINDS_AS_FACTS: Record<ReceiptKind, Kind> = { start: "Start", transition: "Transition", terminal: "Terminal", binding: "Binding" };
const LIVES_AS_FACTS: Record<InvocationLifecycle, Life> = {
  staged: "Staged", accepted: "Accepted", queued: "Queued", running: "Running", waitingForInput: "WaitingForInput", retrying: "Retrying",
  settling: "Settling", completed: "Completed", failed: "Failed", interrupted: "Interrupted", outcomeUnknown: "OutcomeUnknown",
};
const LIFECYCLES_OF_FACTS = Object.fromEntries(Object.entries(LIVES_AS_FACTS).map(([lifecycle, life]) => [life, lifecycle])) as Record<Life, InvocationLifecycle>;
const LIFE_FACTS = Object.fromEntries(Object.entries(LIVES_AS_FACTS).map(([lifecycle, life]) => [lifecycle, { $: "LifeOf", l: life }])) as Record<InvocationLifecycle, Fact["life"]>;
const REFUSALS: Record<Refusal, string> = {
  DuplicateStart: "invocation has more than one start receipt",
  OwnershipChanged: "invocation receipt ownership changed",
  NoStart: "invocation receipt has no start receipt",
  EntryBound: "canonical entry has more than one invocation binding",
  InvocationBound: "invocation has more than one canonical binding",
  NameChanged: "invocation receipt resource name changed",
  OriginChanged: "invocation receipt origin changed",
  ContradictoryTerminal: "contradictory terminal invocation receipt",
  IllegalTerminal: "illegal terminal invocation transition",
  IllegalTransition: "illegal invocation transition",
};
const NO_LIFE = { $: "NoLife" } as const;
const NO_INDEX = { $: "NoIndex" } as const;
const NO_FLAG = { $: "NoFlag" } as const;

function startOrigin(start: InvocationReceiptCommon): ChatOrigin {
  return ("origin" in start ? start.origin as ChatOrigin | undefined : undefined) ?? { kind: start.source === "extension" ? "extension" : "user", confidence: "receipt" };
}

/**
 * Fold a session's receipts into each invocation's lifecycle, or throw for the first receipt that contradicts
 * the ones before it. Proof block receipts/invocation-lifecycle (packages/core) decides the fold: which receipt
 * is refused and why, each invocation's lifecycle, and which receipts its canonical entry, retryable flag and
 * time come from. This function states each receipt to the block as a fact (numbers for the invocation and the
 * canonical entry; whether its operation, source, name and origin are those of its invocation's first start
 * receipt) and writes the block's answer back from the receipts it names.
 */
export function invocationProjection(receipts: readonly InvocationReceiptData[]): InvocationProjection[] {
  const invocations = new Map<string, number>();
  const entries = new Map<string, number>();
  // Per invocation number: its first start receipt, and the position of its first receipt with a retryable flag.
  const starts: Array<InvocationReceiptData | undefined> = [];
  const firstFlagAt: number[] = [];
  const facts = receipts.map((receipt, position): Fact => {
    let inv = invocations.get(receipt.invocationId);
    if (inv === undefined) invocations.set(receipt.invocationId, inv = invocations.size);
    const start = starts[inv];
    const isStart = receipt.receiptKind === "start";
    if (isStart && start === undefined) starts[inv] = receipt;
    let entry: Fact["entry"] = NO_INDEX;
    if ("canonicalEntryId" in receipt && receipt.canonicalEntryId !== undefined) {
      let number = entries.get(receipt.canonicalEntryId);
      if (number === undefined) entries.set(receipt.canonicalEntryId, number = entries.size);
      entry = { $: "IndexOf", i: number };
    }
    const flagged = "retryable" in receipt && receipt.retryable !== undefined;
    if (flagged && firstFlagAt[inv] === undefined) firstFlagAt[inv] = position;
    const lifecycle = "lifecycle" in receipt ? receipt.lifecycle : undefined;
    let name: Mark = "Absent";
    let origin: Mark = "Absent";
    if (isStart || start === undefined) {
      if (isStart && receipt.name) name = "Same";
      if (isStart) origin = "Same";
    } else {
      if ("name" in receipt && receipt.name !== undefined) name = receipt.name === (("name" in start && start.name) || undefined) ? "Same" : "Differs";
      if ("origin" in receipt) origin = canonicalJSON(receipt.origin) === canonicalJSON(startOrigin(start)) ? "Same" : "Differs";
    }
    return {
      inv, kind: KINDS_AS_FACTS[receipt.receiptKind], life: lifecycle ? LIFE_FACTS[lifecycle] : NO_LIFE,
      owned: isStart || start === undefined || (start.operationId === receipt.operationId && start.source === receipt.source),
      name, origin, entry, retryable: flagged ? { $: "FlagOf", b: receipt.retryable! } : NO_FLAG,
    };
  });
  const folded = lifecycle.Fold(facts);
  if (folded.$ === "Stopped") throw new Error(REFUSALS[folded.why]);
  if (folded.$ === "Unfit") throw new Error("invocation receipts are not numbered for the fold");
  return folded.cells.map((cell): InvocationProjection => {
    const start = receipts[cell.start] as InvocationStartReceipt;
    const projection: InvocationProjection = {
      version: 1, invocationId: start.invocationId, operationId: start.operationId,
      source: start.source, ...(start.name ? { name: start.name } : {}),
      ...(start.arguments ? { arguments: start.arguments } : {}),
      ...(start.submittedText === undefined ? {} : { submittedText: start.submittedText }),
      ...(start.resources !== undefined
        ? { resourceInvocations: start.resources.map(resource => ({ ...resource, arguments: "" })) }
        : ["skill", "prompt", "extension"].includes(start.source) && start.name !== undefined
          ? { resourceInvocations: [{ source: start.source as "skill" | "prompt" | "extension", name: start.name, arguments: start.arguments ?? "" }] }
          : {}),
      lifecycle: LIFECYCLES_OF_FACTS[cell.life],
      origin: startOrigin(start),
      sequence: start.sequence, updatedAt: receipts[cell.updated]!.createdAt,
    };
    // The canonical entry and the retryable flag are written in the order their receipts came.
    const bound = cell.entryAt < 0 ? undefined : (receipts[cell.entryAt] as InvocationBindingReceipt).canonicalEntryId;
    const flagAt = cell.retryable.$ === "FlagOf" ? firstFlagAt[facts[cell.start]!.inv]! : -1;
    if (bound && (flagAt < 0 || cell.entryAt < flagAt)) projection.canonicalEntryId = bound;
    if (cell.retryable.$ === "FlagOf") projection.retryable = cell.retryable.b;
    if (bound && flagAt >= 0 && cell.entryAt > flagAt) projection.canonicalEntryId = bound;
    return projection;
  }).sort((a, b) => a.sequence - b.sequence);
}

export function receiptJSON(data: InvocationReceiptData): JsonValue {
  return data as unknown as JsonValue;
}
