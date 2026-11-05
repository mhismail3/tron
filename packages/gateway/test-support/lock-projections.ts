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
