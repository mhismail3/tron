import type { ExtensionOwner, ExtensionRunActivity, ExtensionRunAttention, ExtensionRunChild, ExtensionRunLifecycleState, ExtensionToolOrigin } from "../../protocol/types.js";

export const EXTENSION_ACTIVITY_RECEIPT_TYPE = "tron.extension-activity.v1";

export interface ExtensionActivityReceipt {
  version: 1;
  activityId: string;
  sessionId: string;
  owner?: ExtensionOwner;
  source?: string;
  toolCallId: string;
  runId?: string;
  mode?: string;
  state: Extract<ExtensionRunLifecycleState, "completed" | "failed" | "stopped" | "rejected">;
  startedAt: string;
  terminalAt: string;
  observedAt: string;
  durationMs?: number;
  summary?: { children?: Array<{ id: string; producerId?: string; sessionOwnerId?: string; label: string; parentId?: string; state: ExtensionRunLifecycleState; attention: ExtensionRunAttention; childSessionRef?: string }>; toolCount?: number; turnCount?: number };
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

export function classifyCapturedExtensionOwner(owner: ExtensionOwner): ExtensionOwner & { kind: "subagent" | "extension" } {
  const subagent = /^npm:pi-subagents(?:@[^\s/]+)?$/u.test(owner.source)
    || /^tron:pi-subagents@[^\s/#]+#[a-f0-9]{128}$/u.test(owner.source);
  return { ...owner, kind: owner.kind ?? (subagent ? "subagent" : "extension") };
}

function ownerValue(value: unknown): ExtensionOwner | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const candidate = value as Record<string, unknown>;
  const id = bounded(candidate.id, 256);
  const title = bounded(candidate.title, 256);
  const source = bounded(candidate.source, 256);
  if (!id || !title || !source || /(?:[\\/]|^[A-Za-z]:|^file:)/u.test(source)) return undefined;
  if (candidate.kind !== undefined && candidate.kind !== "subagent" && candidate.kind !== "extension") return undefined;
  return classifyCapturedExtensionOwner({ id, title, source,
    ...(candidate.kind === "subagent" || candidate.kind === "extension" ? { kind: candidate.kind } : {}),
  });
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
      const producerId = opaqueSessionRef(child.producerId);
      const sessionOwnerId = opaqueSessionRef(child.sessionOwnerId);
      children.push({ id, ...(producerId ? { producerId } : {}), ...(sessionOwnerId ? { sessionOwnerId } : {}), label, ...(parentId ? { parentId } : {}), state: childState, attention: childAttention, ...(childSessionRef ? { childSessionRef } : {}) });
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

function admitExtensionActivityReceipt(value: unknown, expectedSessionId?: string): ExtensionActivityReceipt | undefined {
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
    const producerId = opaqueSessionRef(child.producerId);
    const sessionOwnerId = opaqueSessionRef(child.sessionOwnerId);
    const parentId = bounded(child.parentId, 256);
    return [{ id, ...(producerId ? { producerId } : {}), ...(sessionOwnerId ? { sessionOwnerId } : {}), label, ...(parentId ? { parentId } : {}), state: childState, attention: childAttention, ...(childSessionRef ? { childSessionRef } : {}) }];
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
        if (seen.has(cursor)) return undefined;
        seen.add(cursor);
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
    ...(owner ? { owner } : {}),
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
      ...(child.producerId ? { producerId: child.producerId } : {}),
      ...(child.sessionOwnerId ? { sessionOwnerId: child.sessionOwnerId } : {}),
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

interface BoundedHistoryPage<Row> {
  activities: Row[];
  nextCursor?: string;
  omissions?: { count: number; bytes: number; reason: "bytes" | "countAndBytes" };
}

export function boundedHistoryPage<Row>(options: {
  rowCount: number;
  project: (index: number) => Row;
  cursor: string | undefined;
  revision: string;
  query: string;
  limit: number;
  maximumPage: number;
  maximumBytes: number;
  label: string;
}): BoundedHistoryPage<Row> {
  let offset = 0;
  if (options.cursor) {
    const parts = options.cursor.split(":");
    if (parts.length !== 3) throw new Error(`${options.label} cursor conflict`);
    const [cursorRevision, cursorQuery, encodedOffset] = parts;
    if (cursorRevision !== options.revision || cursorQuery !== options.query) throw new Error(`${options.label} cursor conflict`);
    if (!/^\d+$/u.test(encodedOffset ?? "")) throw new Error(`${options.label} cursor invalid`);
    offset = Number(encodedOffset);
    if (!Number.isSafeInteger(offset) || offset < 0 || offset > options.rowCount) throw new Error(`${options.label} cursor invalid`);
  }
  const boundedLimit = Math.min(options.maximumPage, Math.max(1, Math.floor(options.limit)));
  const maximumEnd = Math.min(options.rowCount, offset + boundedLimit);
  const activities: Row[] = [];
  let bytes = 2;
  let omittedBytes = 0;
  let omittedCount = 0;
  let nextOffset = offset;
  for (let index = offset; index < maximumEnd; index += 1) {
    const row = options.project(index);
    const size = Buffer.byteLength(JSON.stringify(row)) + 1;
    if (bytes + size > options.maximumBytes) {
      if (activities.length > 0 || omittedCount > 0) break;
      omittedBytes += size;
      omittedCount += 1;
      nextOffset = index + 1;
      continue;
    }
    activities.push(row);
    bytes += size;
    nextOffset = index + 1;
  }
  return {
    activities,
    ...(nextOffset < options.rowCount ? { nextCursor: `${options.revision}:${options.query}:${nextOffset}` } : {}),
    ...(omittedCount > 0 ? { omissions: { count: omittedCount, bytes: omittedBytes, reason: "bytes" as const } } : {}),
  };
}
