import { createHash } from "node:crypto";
import type { ExtensionOwner, ExtensionRunActivity, ExtensionRunAttention, ExtensionRunChild, ExtensionRunLifecycleState, ExtensionToolOrigin } from "../protocol/types.js";

/** Reserved Pi custom-entry type. Custom entries are canonical JSONL facts but
 * are intentionally not transcript messages or model context. */
export const EXTENSION_ACTIVITY_RECEIPT_TYPE = "tron.extension-activity.v1";
export const EXTENSION_ACTIVITY_HISTORY_CAPABILITY = "extension-activity-history.v1";
export const MAX_EXTENSION_HISTORY_PAGE = 50;
export const MAX_EXTENSION_HISTORY_BYTES = 256 * 1_024;

export interface ExtensionActivityReceipt {
  version: 1;
  activityId: string;
  sessionId: string;
  owner?: ExtensionOwner;
  /** Legacy display fallback, accepted only when owner is absent. */
  source?: string;
  toolCallId: string;
  runId?: string;
  mode?: string;
  state: Extract<ExtensionRunLifecycleState, "completed" | "failed" | "stopped" | "rejected">;
  startedAt: string;
  terminalAt: string;
  observedAt: string;
  durationMs?: number;
  /** Durable summaries intentionally exclude child task/output/path/timing data. */
  summary?: { children?: Array<{ id: string; label: string; parentId?: string; state: ExtensionRunLifecycleState; attention: ExtensionRunAttention; childSessionRef?: string }>; toolCount?: number; turnCount?: number };
}

function bounded(value: unknown, max: number): string | undefined {
  if (typeof value !== "string" || value.trim().length === 0) return undefined;
  const text = value.trim();
  if (Buffer.byteLength(text) > max) return undefined;
  return text;
}

function opaqueSessionRef(value: unknown): string | undefined {
  const ref = bounded(value, 256);
  return ref && !/[\\/\0]/u.test(ref) ? ref : undefined;
}

function finiteTime(value: unknown): value is string {
  return typeof value === "string" && Number.isFinite(Date.parse(value));
}

function monotonicReceiptTimeline(startedAt: string, terminalAt: string, observedAt: string): boolean {
  const started = Date.parse(startedAt);
  const terminal = Date.parse(terminalAt);
  const observed = Date.parse(observedAt);
  return started <= terminal && terminal <= observed;
}

function nonnegativeInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && (value as number) >= 0;
}

function ownerValue(value: unknown): ExtensionOwner | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const candidate = value as Record<string, unknown>;
  const id = bounded(candidate.id, 256);
  const title = bounded(candidate.title, 256);
  const source = bounded(candidate.source, 256);
  // Extension source is an opaque package identity, never a filesystem path.
  if (!id || !title || !source || /(?:[\\/]|^[A-Za-z]:|^file:)/u.test(source)) return undefined;
  return { id, title, source };
}

function terminalState(value: unknown): ExtensionActivityReceipt["state"] | undefined {
  return value === "completed" || value === "failed" || value === "stopped" || value === "rejected" ? value : undefined;
}

function terminalOrLifecycleState(value: unknown): value is ExtensionRunLifecycleState {
  return value === "queued" || value === "running" || value === "paused" || value === "completed"
    || value === "failed" || value === "stopped" || value === "rejected" || value === "unknown";
}

function attentionState(value: unknown): value is ExtensionRunAttention {
  return value === "none" || value === "activeLongRunning" || value === "needsAttention";
}

export function makeExtensionActivityReceipt(activity: ExtensionRunActivity, sessionId: string, terminalAt = activity.lifecycle?.terminalAt ?? activity.completedAt ?? activity.updatedAt): ExtensionActivityReceipt | undefined {
  const state = terminalState(activity.lifecycle?.state ?? (activity.status === "failed" ? "failed" : "completed"));
  const activityId = bounded(activity.activityId ?? activity.id, 256);
  const observedAt = activity.lifecycle?.observedAt ?? activity.updatedAt;
  if (!state || !activityId || !bounded(sessionId, 256) || !bounded(activity.toolCallId, 256)
    || !finiteTime(terminalAt) || !finiteTime(activity.startedAt) || !finiteTime(observedAt)
    || !monotonicReceiptTimeline(activity.startedAt, terminalAt, observedAt)) return undefined;
  const children: NonNullable<NonNullable<ExtensionActivityReceipt["summary"]>["children"]> = [];
  const appendChildren = (values: readonly ExtensionRunActivity["children"][number][], parentId?: string, depth = 0): void => {
    if (depth > 3) return;
    for (const child of values.slice(0, 32)) {
      if (children.length >= 64) return;
      const id = bounded(child.id, 256); const label = bounded(child.label, 256);
      const childState = child.lifecycle ?? (child.status === "failed" ? "failed" : child.status === "completed" ? "completed" : "running");
      const childAttention = child.attention ?? "none";
      if (!id || !label || !terminalOrLifecycleState(childState) || !attentionState(childAttention)) continue;
      const childSessionRef = opaqueSessionRef(child.childSessionRef);
      children.push({ id, label, ...(parentId ? { parentId } : {}), state: childState, attention: childAttention, ...(childSessionRef ? { childSessionRef } : {}) });
      if (child.children?.length) appendChildren(child.children, id, depth + 1);
    }
  };
  appendChildren(activity.children);
  const rawOwner = activity.source.owner;
  const owner = rawOwner === undefined ? undefined : ownerValue(rawOwner);
  if (rawOwner !== undefined && owner === undefined) return undefined;
  const rawDurationMs = activity.durationMs;
  const rawToolCount = activity.toolCount;
  const rawTurnCount = activity.turnCount;
  const durationMs = nonnegativeInteger(rawDurationMs) ? rawDurationMs : undefined;
  const toolCount = nonnegativeInteger(rawToolCount) ? rawToolCount : undefined;
  const turnCount = nonnegativeInteger(rawTurnCount) ? rawTurnCount : undefined;
  const fallbackSource = bounded(activity.source.source, 256);
  const safeFallbackSource = fallbackSource && !/(?:[\\/]|^[A-Za-z]:)/u.test(fallbackSource) ? fallbackSource : undefined;
  if (!owner && !safeFallbackSource) return undefined;
  const runId = bounded(activity.runId, 256);
  const mode = bounded(activity.mode, 64);
  return {
    version: 1,
    activityId,
    sessionId,
    ...(owner ? { owner } : {}),
    ...(owner ? {} : { source: safeFallbackSource! }),
    toolCallId: activity.toolCallId,
    ...(runId ? { runId } : {}),
    ...(mode ? { mode } : {}),
    state,
    startedAt: activity.startedAt,
    terminalAt,
    observedAt,
    ...(durationMs === undefined ? {} : { durationMs }),
    summary: {
      ...(toolCount === undefined ? {} : { toolCount }),
      ...(turnCount === undefined ? {} : { turnCount }),
      ...(children.length > 0 ? { children } : {}),
    },
  };
}

export function admitExtensionActivityReceipt(value: unknown, expectedSessionId?: string): ExtensionActivityReceipt | undefined {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return undefined;
  const candidate = value as Record<string, unknown>;
  const state = terminalState(candidate.state);
  const activityId = bounded(candidate.activityId, 256);
  const sessionId = bounded(candidate.sessionId, 256);
  const toolCallId = bounded(candidate.toolCallId, 256);
  const startedAt = candidate.startedAt;
  const terminalAt = candidate.terminalAt;
  const observedAt = candidate.observedAt;
  if (candidate.version !== 1 || !state || !activityId || !sessionId || !toolCallId
    || (expectedSessionId !== undefined && sessionId !== expectedSessionId)
    || !finiteTime(startedAt) || !finiteTime(terminalAt) || !finiteTime(observedAt)
    || !monotonicReceiptTimeline(startedAt, terminalAt, observedAt)) return undefined;
  const owner = candidate.owner === undefined ? undefined : ownerValue(candidate.owner);
  if (candidate.owner !== undefined && owner === undefined) return undefined;
  const source = bounded(candidate.source, 256);
  // A producer path is not a stable owner identity and must never be persisted
  // as the receipt fallback. Owners captured at the extension boundary are
  // opaque and may contain any source string.
  if (!owner && (!source || /(?:[\\/]|^[A-Za-z]:)/u.test(source))) return undefined;
  const summaryValue = candidate.summary;
  const summary = summaryValue && typeof summaryValue === "object" && !Array.isArray(summaryValue) ? summaryValue as Record<string, unknown> : undefined;
  const rawChildren = summary?.children;
  const children = Array.isArray(rawChildren) ? rawChildren.slice(0, 64).flatMap((value) => {
    if (!value || typeof value !== "object" || Array.isArray(value)) return [];
    const child = value as Record<string, unknown>;
    const id = bounded(child.id, 256); const label = bounded(child.label, 256);
    const childState = child.state;
    const childAttention = child.attention === undefined ? "none" : child.attention;
    if (!id || !label || !terminalOrLifecycleState(childState) || !attentionState(childAttention)) return [];
    const childSessionRef = opaqueSessionRef(child.childSessionRef);
    const parentId = bounded(child.parentId, 256);
    return [{ id, label, ...(parentId ? { parentId } : {}), state: childState, attention: childAttention, ...(childSessionRef ? { childSessionRef } : {}) }];
  }) : undefined;
  if (children) {
    const childIDs = new Set(children.map((child) => child.id));
    if (childIDs.size !== children.length
      || children.some((child) => child.parentId === child.id || (child.parentId !== undefined && !childIDs.has(child.parentId)))) return undefined;
    const parents = new Map(children.map((child) => [child.id, child.parentId]));
    for (const child of children) {
      const seen = new Set<string>();
      let cursor: string | undefined = child.id;
      while (cursor !== undefined) {
        if (!seen.add(cursor)) return undefined;
        cursor = parents.get(cursor);
      }
    }
  }
  const toolCount = summary?.toolCount;
  const turnCount = summary?.turnCount;
  if ((toolCount !== undefined && (!Number.isSafeInteger(toolCount) || (toolCount as number) < 0))
    || (turnCount !== undefined && (!Number.isSafeInteger(turnCount) || (turnCount as number) < 0))) return undefined;
  const runId = bounded(candidate.runId, 256);
  const mode = bounded(candidate.mode, 64);
  return {
    version: 1,
    activityId,
    sessionId,
    ...(owner?.id ? { owner: { id: owner.id, title: owner.title!, source: owner.source! } } : {}),
    ...(owner ? {} : { source: source! }),
    toolCallId,
    ...(runId ? { runId } : {}),
    ...(mode ? { mode } : {}),
    state,
    startedAt,
    terminalAt,
    observedAt,
    ...(Number.isSafeInteger(candidate.durationMs) && (candidate.durationMs as number) >= 0 ? { durationMs: candidate.durationMs as number } : {}),
    ...(summary ? { summary: {
      ...(Number.isSafeInteger(toolCount) && (toolCount as number) >= 0 ? { toolCount: toolCount as number } : {}),
      ...(Number.isSafeInteger(turnCount) && (turnCount as number) >= 0 ? { turnCount: turnCount as number } : {}),
      ...(children && children.length > 0 ? { children } : {}),
    } } : {}),
  };
}

export interface ExtensionActivityHistoryPage {
  /** Wire summaries use the same bounded activity schema as snapshots/iOS. */
  activities: ExtensionRunActivity[];
  historyRevision: string;
  nextCursor?: string;
  omissions?: { count: number; bytes: number; reason: "bytes" | "countAndBytes" };
}

export function extensionActivityHistoryRevision(entries: readonly unknown[], sessionId: string, branchRevision = ""): string {
  return revisionOf(canonicalReceiptSequence(extensionActivityReceipts(entries, sessionId)), sessionId, branchRevision);
}

function canonicalReceiptSequence(entries: Array<{ id?: string; parentId?: string | null; receipt: ExtensionActivityReceipt }>): Array<{ id?: string; parentId?: string | null; receipt: ExtensionActivityReceipt }> {
  return [...entries].sort((left, right) =>
    right.receipt.terminalAt.localeCompare(left.receipt.terminalAt)
    || right.receipt.activityId.localeCompare(left.receipt.activityId)
    || (right.id ?? "").localeCompare(left.id ?? "")
    || (right.parentId ?? "").localeCompare(left.parentId ?? "")
  );
}

function revisionOf(entries: Array<{ id?: string; parentId?: string | null; receipt: ExtensionActivityReceipt }>, sessionId: string, branchRevision = ""): string {
  return createHash("sha256").update(`${sessionId}\n${branchRevision}\n${entries.map((entry) => `${entry.id ?? ""}\0${entry.parentId ?? ""}\0${entry.receipt.activityId}\0${entry.receipt.terminalAt}`).join("\n")}`).digest("hex").slice(0, 32);
}

/** Reads reserved custom entries only. Callers may pass SessionManager.getEntries()
 * without exposing the entries to ordinary transcript projection. */
export function extensionActivityReceipts(entries: readonly unknown[], sessionId: string): Array<{ id?: string; parentId?: string | null; receipt: ExtensionActivityReceipt }> {
  const result: Array<{ id?: string; parentId?: string | null; receipt: ExtensionActivityReceipt }> = [];
  for (const value of entries) {
    if (!value || typeof value !== "object" || Array.isArray(value)) continue;
    const entry = value as Record<string, unknown>;
    if (entry.type !== "custom" && entry.type !== "customEntry") continue;
    if (entry.customType !== EXTENSION_ACTIVITY_RECEIPT_TYPE) continue;
    const receipt = admitExtensionActivityReceipt(entry.data, sessionId);
    if (!receipt) continue;
    const id = typeof entry.id === "string" ? entry.id : undefined;
    result.push({ ...(id ? { id } : {}), parentId: typeof entry.parentId === "string" ? entry.parentId : null, receipt });
  }
  return result;
}

export function listExtensionActivityHistory(entries: readonly unknown[], sessionId: string, cursor?: string, limit = 25, branchRevision?: string, filter?: { ownerId?: string; runId?: string; state?: ExtensionActivityReceipt["state"] }): ExtensionActivityHistoryPage {
  const canonical = canonicalReceiptSequence(extensionActivityReceipts(entries, sessionId));
  // Filters and duplicate collapse select page content only. Revision identity
  // remains global so detail and filtered list cursors agree.
  const historyRevision = revisionOf(canonical, sessionId, branchRevision);
  const sorted = canonical
    .filter(({ receipt }) => (!filter?.ownerId || receipt.owner?.id === filter.ownerId)
      && (!filter?.runId || receipt.runId === filter.runId)
      && (!filter?.state || receipt.state === filter.state));
  const seenActivityIDs = new Set<string>();
  const all = sorted.filter(({ receipt }) => {
    if (seenActivityIDs.has(receipt.activityId)) return false;
    seenActivityIDs.add(receipt.activityId);
    return true;
  });
  // Receipt identity changes still invalidate cursors even when duplicate
  // activity IDs are collapsed from the returned page.
  const boundedLimit = Math.min(MAX_EXTENSION_HISTORY_PAGE, Math.max(1, Math.floor(limit)));
  let offset = 0;
  if (cursor) {
    const [revision, encodedOffset] = cursor.split(":");
    if (revision !== historyRevision || !/^\d+$/u.test(encodedOffset ?? "")) throw new Error("extension activity history cursor conflict");
    offset = Number(encodedOffset);
    if (!Number.isSafeInteger(offset) || offset < 0 || offset > all.length) throw new Error("extension activity history cursor invalid");
  }
  const selected: typeof all = [];
  let bytes = 0;
  let omittedBytes = 0;
  let omittedCount = 0;
  const pageEnd = Math.min(all.length, offset + boundedLimit);
  for (let index = offset; index < pageEnd; index += 1) {
    const entry = all[index]!;
    const summary = extensionReceiptActivity(entry.receipt);
    const size = Buffer.byteLength(JSON.stringify(summary));
    if (bytes + size > MAX_EXTENSION_HISTORY_BYTES) {
      omittedBytes += size;
      omittedCount += 1;
      continue;
    }
    selected.push(entry);
    bytes += size;
  }
  const next = pageEnd < all.length ? `${historyRevision}:${pageEnd}` : undefined;
  return {
    activities: selected.map((entry) => extensionReceiptActivity(entry.receipt)),
    historyRevision,
    ...(next ? { nextCursor: next } : {}),
    ...(omittedCount > 0 ? { omissions: { count: omittedCount, bytes: omittedBytes, reason: "bytes" as const } } : {}),
  };
}

export function extensionReceiptActivity(receipt: ExtensionActivityReceipt): ExtensionRunActivity {
  const owner = receipt.owner;
  const source: ExtensionToolOrigin = owner
    ? { source: owner.source, owner }
    : { source: receipt.source ?? "unknown" };
  const childNodes = new Map<string, ExtensionRunChild>();
  for (const child of receipt.summary?.children ?? []) {
    if (childNodes.has(child.id)) continue;
    childNodes.set(child.id, {
      id: child.id,
      label: child.label,
      status: child.state === "failed" ? "failed" as const
        : child.state === "running" || child.state === "queued" || child.state === "paused" ? "running" as const
          : "completed" as const,
      lifecycle: child.state,
      attention: child.attention,
      ...(child.childSessionRef ? { childSessionRef: child.childSessionRef } : {}),
    });
  }
  const children: ExtensionRunChild[] = [];
  for (const child of receipt.summary?.children ?? []) {
    const node = childNodes.get(child.id);
    if (!node) continue;
    const parent = child.parentId ? childNodes.get(child.parentId) : undefined;
    if (!parent) {
      children.push(node);
      continue;
    }
    parent.children = [...(parent.children ?? []), node];
  }
  return {
    id: receipt.activityId,
    activityId: receipt.activityId,
    ...(receipt.runId ? { runId: receipt.runId } : {}),
    toolCallId: receipt.toolCallId,
    source,
    title: receipt.owner?.title ?? receipt.source ?? "Extension",
    ...(receipt.mode ? { mode: receipt.mode } : {}),
    status: receipt.state === "failed" ? "failed" : "completed",
    startedAt: receipt.startedAt,
    updatedAt: receipt.observedAt,
    completedAt: receipt.terminalAt,
    ...(receipt.durationMs === undefined ? {} : { durationMs: receipt.durationMs }),
    ...(receipt.summary?.toolCount === undefined ? {} : { toolCount: receipt.summary.toolCount }),
    ...(receipt.summary?.turnCount === undefined ? {} : { turnCount: receipt.summary.turnCount }),
    children,
    lifecycle: { version: 1, state: receipt.state, attention: "none", sequence: 0, observedAt: receipt.observedAt, terminalAt: receipt.terminalAt, recentUntil: new Date(Date.parse(receipt.terminalAt) + 900_000).toISOString(), visibility: "historical" },
  };
}
