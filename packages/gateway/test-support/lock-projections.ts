import { expect } from "vitest";

/**
 * What a behavior lock asserts about a session (#2279): the parts of the transcript
 * projection, the canonical messages and the provider requests a client or the
 * model acts on, without the per-run identities, times and token counts. Each
 * function keeps every remaining field of its record, so a changed classification,
 * grouping, ordering or text fails the lock; the identities it drops are checked
 * by relation instead (`toolCallsResolve`).
 */

/** Per-run values: identities, times, counters and host-derived numbers. */
const VOLATILE = new Set([
  "id", "parentId", "timestamp", "presentationId", "invocationId", "operationId", "toolCallId", "toolSegmentId", "groupId",
  "receiptId", "sequence", "progressSequence", "startedAt", "completedAt", "lastProgressAt", "durationMs", "usage", "api",
  "canonicalEntryId",
]);

/**
 * Values whose numbers the host and checkout decide (`tokensBefore` estimates the
 * context from serialized absolute paths): their presence is kept, as `<value>`.
 */
const HOST_DERIVED = new Set(["tokensBefore"]);

/** A record without its per-run values, and each lock's faux provider named `<LOCK>`. */
export function projected(value: unknown): unknown {
  const strip = (node: unknown): unknown => {
    if (Array.isArray(node)) return node.map(strip);
    if (node === null || typeof node !== "object") return typeof node === "string" ? node.replace(/tron-lock-[a-z0-9-]+/gu, "<LOCK>") : node;
    return Object.fromEntries(Object.entries(node).filter(([key]) => !VOLATILE.has(key))
      .map(([key, child]) => [key, HOST_DERIVED.has(key) ? "<value>" : strip(child)]));
  };
  return strip(value);
}

/** The canonical session messages after the system entry, projected. */
export function canonicalMessages(entries: readonly unknown[]): unknown[] {
  return entries.flatMap((entry) => {
    const record = entry as { type?: string; message?: { role?: string } };
    return record.type === "message" && record.message?.role !== "system" ? [projected(record.message)] : [];
  });
}

/** Every tool call in the transcript is answered by exactly one tool result naming it, in its group. */
export function toolCallsResolve(items: readonly unknown[]): boolean {
  const calls = new Map<string, string | undefined>();
  const results: Array<{ toolCallId?: string; groupId?: string }> = [];
  for (const item of items as Array<{ role?: string; content?: Array<{ type?: string; toolCallId?: string; groupId?: string }>; toolCallId?: string; groupId?: string }>) {
    for (const block of item.content ?? []) if (block.type === "toolCall") calls.set(block.toolCallId!, block.groupId);
    if (item.role === "toolResult") results.push(item);
  }
  return results.length === calls.size && [...calls.keys()].every((id) => typeof id === "string" && id.length > 0)
    && results.every((result) => typeof result.toolCallId === "string" && calls.has(result.toolCallId) && calls.get(result.toolCallId) === result.groupId);
}

/** A session snapshot's per-run values beyond a record's: its subscription, sync and runtime identities and revisions. */
const SNAPSHOT_VOLATILE = new Set([
  "sessionId", "subscriptionToken", "syncToken", "hostEpoch", "eventSequence", "revision", "extensionActivityAsOf", "asOf",
  "leafEntryId", "runtimeGeneration",
]);

/** A recorded (normalized) `session.open` response without its per-run values: what a client starts from. */
export function projectedSnapshot(value: unknown): unknown {
  const strip = (node: unknown): unknown => {
    if (Array.isArray(node)) return node.map(strip);
    if (node === null || typeof node !== "object") return node;
    return Object.fromEntries(Object.entries(node).filter(([key]) => !SNAPSHOT_VOLATILE.has(key)).map(([key, child]) => [key, strip(child)]));
  };
  return strip(projected(value));
}

/** What a converted scenario lock expects of one session, generated from its former golden and reviewed as code. */
export interface SessionLockExpectation {
  /** Every client request (method, parameters) and its response; `session.transcript` reads only when `items` is absent. */
  readonly exchanges: unknown[];
  /** The transcript items a client reads at the end, when the lock reads one session's transcript separately. */
  readonly items?: unknown[];
  /** The canonical messages after the system entry. */
  readonly messages: unknown[];
  /** Each canonical entry's type (with custom type or message role), in file order. */
  readonly types: string[];
  /** The invocation receipts' kind, lifecycle, error code and source, in order. */
  readonly receipts: unknown[];
  /** The session header, model and thinking-level entries. */
  readonly sessionEntries: unknown[];
  /** The conversation each provider request carried. */
  readonly providers: unknown[];
}

/** One canonical entry's kind: its type, custom type or message role. */
export function entryType(entry: unknown): string {
  const record = entry as { type: string; customType?: string; message?: { role?: string } };
  return record.type + (record.customType ? `:${record.customType}` : "") + (record.message ? `:${record.message.role}` : "");
}

/** The invocation receipts in a session's canonical JSONL: kind, lifecycle, error code and source. */
export function invocationReceipts(entries: readonly unknown[]): unknown[] {
  return entries.flatMap((entry) => {
    const record = entry as { customType?: string; data?: { receiptKind?: string; lifecycle?: string; errorCode?: string; source?: string } };
    if (record.customType !== "tron.chat-invocation.v1") return [];
    const { receiptKind, lifecycle, errorCode, source } = record.data!;
    return [Object.fromEntries(Object.entries({ receiptKind, lifecycle, errorCode, source }).filter(([, value]) => value !== undefined))];
  });
}

/** What a converted scenario lock observed of one session, as the harness recorded it. */
export interface SessionLockActual {
  /** The harness's recorded (normalized) exchanges, in order. */
  readonly exchanges: readonly unknown[];
  /** The session's canonical JSONL (normalized). */
  readonly canonical: readonly unknown[];
  /** The transcript items the client read at the end (raw). */
  readonly items: readonly unknown[];
  /** Each provider request's messages, as the harness recorded them. */
  readonly providers: readonly unknown[];
}

/** Assert one converted scenario lock's session against its expectation, exactly. */
export function expectSessionLock(label: string, actual: SessionLockActual, expected: SessionLockExpectation): void {
  expect((actual.exchanges as Array<{ method: string; params: unknown; response: unknown }>)
    .filter((exchange) => expected.items === undefined || exchange.method !== "session.transcript")
    .map((exchange) => ({ method: exchange.method, params: projectedSnapshot(exchange.params), response: projectedSnapshot(exchange.response) })),
  `${label}: the client's requests and responses`).toEqual(expected.exchanges);
  if (expected.items !== undefined) {
    expect(projected(actual.items), `${label}: the transcript a client reads`).toEqual(expected.items);
    expect(toolCallsResolve(actual.items), `${label}: each tool call has its result, in its group`).toBe(true);
  }
  expect(canonicalMessages(actual.canonical), `${label}: the canonical messages`).toEqual(expected.messages);
  expect(actual.canonical.map(entryType), `${label}: the canonical entries, in order`).toEqual(expected.types);
  expect(invocationReceipts(actual.canonical), `${label}: the invocation receipts, in order`).toEqual(expected.receipts);
  expect(actual.canonical.filter((entry) => ["session", "model_change", "thinking_level_change"].includes((entry as { type: string }).type))
    .map(projectedSnapshot), `${label}: the session header, model and thinking-level entries`).toEqual(expected.sessionEntries);
  expect(actual.providers, `${label}: what each provider request carried`).toEqual(expected.providers);
}
