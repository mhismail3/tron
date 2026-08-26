import { createHash } from "node:crypto";
import type { SessionManager } from "@earendil-works/pi-coding-agent";

type ReadonlySessionManager = Pick<SessionManager, "getBranch" | "getEntries" | "getSessionId" | "getLeafId">;
import type {
  ExtensionRunActivity,
  ExtensionRunChild,
  SessionProcessActivity,
  SessionProcessHistoryPage,
  SessionProcessOverview,
  SessionProcessState,
  ToolExecutionState,
} from "../protocol/types.js";
import { extensionActivityReceipts, extensionReceiptActivity } from "./extension-activity-history.js";
import { PROCESS_ACTIVITY_RECENT_MS } from "./process-activity-recency.js";

export const PROCESS_ACTIVITY_HISTORY_CAPABILITY = "process-history.v1";
export const PROCESS_TRANSCRIPT_CAPABILITY = "process-transcript.v1";
export const MAX_PROCESS_ACTIVITY_COUNT = 32;
export const MAX_PROCESS_ACTIVITY_BYTES = 256 * 1_024;
export const MAX_PROCESS_HISTORY_PAGE = 50;
export const MAX_PROCESS_HISTORY_BYTES = 256 * 1_024;

const terminalStates = new Set<SessionProcessState>([
  "completed", "failed", "stopped", "rejected", "interrupted",
]);

function utf8Prefix(value: string, maximumBytes: number): { value: string; truncated: boolean } {
  const encoded = Buffer.from(value);
  if (encoded.length <= maximumBytes) return { value, truncated: false };
  return {
    value: `${encoded.subarray(0, Math.max(0, maximumBytes - 3)).toString("utf8").replace(/\uFFFD$/u, "")}…`,
    truncated: true,
  };
}

function utf8Suffix(value: string, maximumBytes: number): { value: string; truncated: boolean } {
  const encoded = Buffer.from(value);
  if (encoded.length <= maximumBytes) return { value, truncated: false };
  const marker = "… earlier output truncated by Gateway …\n";
  return {
    value: marker + encoded.subarray(encoded.length - Math.max(0, maximumBytes - Buffer.byteLength(marker)))
      .toString("utf8").replace(/^\uFFFD/u, ""),
    truncated: true,
  };
}

function processHash(namespace: string, ...parts: string[]): string {
  return `process:${namespace}:${createHash("sha256").update(parts.join("\0")).digest("hex").slice(0, 32)}`;
}

export function commandProcessId(sessionId: string, toolCallId: string): string {
  return processHash("command", sessionId, toolCallId);
}

export function subagentProcessId(sessionId: string, toolCallId: string, childId: string): string {
  return processHash("subagent", sessionId, toolCallId, childId);
}

function commandArgument(argumentsValue: ToolExecutionState["arguments"]): string {
  if (!argumentsValue || typeof argumentsValue !== "object" || Array.isArray(argumentsValue)) return "Shell command";
  const command = argumentsValue.command;
  return utf8Prefix(typeof command === "string" && command.trim() ? command.trim() : "Shell command", 2_048).value;
}

/** Projects only the assistant-owned runtime bash tool state supplied by
 * RuntimeSlot. Direct user bash and Terminal PTYs never enter this function. */
export function commandProcessFromTool(sessionId: string, tool: ToolExecutionState): SessionProcessActivity | undefined {
  if (tool.toolName !== "bash") return undefined;
  const terminalAt = tool.status === "running" ? undefined : tool.completedAt ?? tool.updatedAt;
  const state: SessionProcessState = tool.status === "running" ? "running" : tool.status === "failed" ? "failed" : "completed";
  const output = tool.output === undefined ? undefined : utf8Suffix(tool.output, 32 * 1_024);
  return {
    version: 1,
    processId: commandProcessId(sessionId, tool.toolCallId),
    kind: "command",
    executionMode: "foreground",
    source: "mainAssistant",
    lifecycle: {
      version: 1,
      state,
      attention: "none",
      sequence: Math.max(0, tool.progressSequence),
      observedAt: tool.updatedAt,
      ...(terminalAt ? { terminalAt, recentUntil: new Date(Date.parse(terminalAt) + PROCESS_ACTIVITY_RECENT_MS).toISOString() } : {}),
    },
    visibility: terminalAt ? "recent" : "active",
    startedAt: tool.startedAt,
    title: "Command",
    command: commandArgument(tool.arguments),
    ...(output ? { outputTail: output.value } : {}),
    outputTruncated: tool.outputTruncated === true || output?.truncated === true,
    toolCallId: tool.toolCallId,
  };
}

function extensionState(value: unknown): SessionProcessState {
  return value === "queued" || value === "running" || value === "paused"
    || value === "completed" || value === "failed" || value === "stopped"
    || value === "rejected" || value === "unknown" ? value : "unknown";
}

function subagentMode(mode: string | undefined): SessionProcessActivity["executionMode"] {
  const normalized = mode?.toLowerCase();
  if (normalized?.includes("async") || normalized?.includes("background") || normalized?.includes("detached")) return "asynchronous";
  if (normalized?.includes("sync") || normalized === "workflow" || normalized === "single") return "synchronous";
  return "unknown";
}

function childRows(
  sessionId: string,
  activity: ExtensionRunActivity,
  children: readonly ExtensionRunChild[],
  parentProcessId?: string,
): SessionProcessActivity[] {
  const rows: SessionProcessActivity[] = [];
  for (const child of children) {
    const processId = subagentProcessId(sessionId, activity.toolCallId, child.id);
    const state = extensionState(child.lifecycle ?? (child.status === "running" ? "running" : child.status === "failed" ? "failed" : "completed"));
    const terminalAt = terminalStates.has(state) ? activity.lifecycle?.terminalAt ?? activity.completedAt : undefined;
    const output = child.output === undefined ? undefined : utf8Suffix(child.output, 32 * 1_024);
    rows.push({
      version: 1,
      processId,
      kind: "subagent",
      executionMode: subagentMode(activity.mode),
      source: "delegatedAgent",
      ...(parentProcessId ? { parentProcessId } : {}),
      lifecycle: {
        version: 1,
        state,
        attention: child.attention ?? "none",
        sequence: Math.max(0, activity.lifecycle?.sequence ?? 0),
        observedAt: activity.lifecycle?.observedAt ?? activity.updatedAt,
        ...(activity.lifecycle?.producerUpdatedAt ? { producerUpdatedAt: activity.lifecycle.producerUpdatedAt } : {}),
        ...(terminalAt ? { terminalAt, recentUntil: new Date(Date.parse(terminalAt) + PROCESS_ACTIVITY_RECENT_MS).toISOString() } : {}),
      },
      visibility: terminalAt ? "recent" : state === "unknown" ? "unknown" : "active",
      startedAt: activity.startedAt,
      title: utf8Prefix(child.label, 512).value,
      ...(child.currentTool ? { currentTool: utf8Prefix(child.currentTool, 2_048).value } : {}),
      ...(child.currentPath ? { currentPathBasename: utf8Prefix(child.currentPath, 2_048).value } : {}),
      ...(output ? { outputTail: output.value } : {}),
      outputTruncated: output?.truncated === true,
      ...(child.toolCount === undefined ? {} : { toolCount: Math.max(0, child.toolCount) }),
      ...(child.turnCount === undefined ? {} : { turnCount: Math.max(0, child.turnCount) }),
      ...((child.children?.length ?? 0) > 0 ? { childCount: child.children!.length } : {}),
      toolCallId: activity.toolCallId,
      ...(activity.runId ? { runId: activity.runId } : {}),
      ...(child.childSessionRef ? { childSessionRef: child.childSessionRef } : {}),
    });
    if (child.children?.length) rows.push(...childRows(sessionId, activity, child.children, processId));
  }
  return rows;
}

export function subagentProcessesFromActivity(sessionId: string, activity: ExtensionRunActivity): SessionProcessActivity[] {
  if (activity.children.length > 0) return childRows(sessionId, activity, activity.children);
  const processId = subagentProcessId(sessionId, activity.toolCallId, activity.runId ?? activity.activityId ?? activity.id);
  const state = extensionState(activity.lifecycle?.state ?? (activity.status === "running" ? "running" : activity.status === "failed" ? "failed" : "completed"));
  const terminalAt = terminalStates.has(state) ? activity.lifecycle?.terminalAt ?? activity.completedAt : undefined;
  const output = activity.output === undefined ? undefined : utf8Suffix(activity.output, 32 * 1_024);
  return [{
    version: 1,
    processId,
    kind: "subagent",
    executionMode: subagentMode(activity.mode),
    source: "admittedExtension",
    lifecycle: {
      version: 1,
      state,
      attention: activity.lifecycle?.attention ?? "none",
      sequence: Math.max(0, activity.lifecycle?.sequence ?? 0),
      observedAt: activity.lifecycle?.observedAt ?? activity.updatedAt,
      ...(activity.lifecycle?.producerUpdatedAt ? { producerUpdatedAt: activity.lifecycle.producerUpdatedAt } : {}),
      ...(terminalAt ? { terminalAt, recentUntil: new Date(Date.parse(terminalAt) + PROCESS_ACTIVITY_RECENT_MS).toISOString() } : {}),
    },
    visibility: terminalAt ? "recent" : state === "unknown" ? "unknown" : "active",
    startedAt: activity.startedAt,
    title: utf8Prefix(activity.title === "Pi Subagents" ? "Subagent" : activity.title, 512).value,
    ...(activity.currentTool ? { currentTool: utf8Prefix(activity.currentTool, 2_048).value } : {}),
    ...(activity.currentPath ? { currentPathBasename: utf8Prefix(activity.currentPath, 2_048).value } : {}),
    ...(output ? { outputTail: output.value } : {}),
    outputTruncated: output?.truncated === true,
    ...(activity.toolCount === undefined ? {} : { toolCount: Math.max(0, activity.toolCount) }),
    ...(activity.turnCount === undefined ? {} : { turnCount: Math.max(0, activity.turnCount) }),
    toolCallId: activity.toolCallId,
    ...(activity.runId ? { runId: activity.runId } : {}),
  }];
}

export function boundProcessActivities(activities: readonly SessionProcessActivity[]): {
  activities: SessionProcessActivity[];
  omittedCount: number;
  omittedBytes: number;
  hitCount: boolean;
  hitBytes: boolean;
} {
  const ordered = [...activities].sort((left, right) => {
    const bucket = (activity: SessionProcessActivity) => activity.visibility === "active" ? 0 : 1;
    return bucket(left) - bucket(right)
      || (right.lifecycle.terminalAt ?? right.lifecycle.observedAt).localeCompare(left.lifecycle.terminalAt ?? left.lifecycle.observedAt)
      || left.processId.localeCompare(right.processId);
  });
  const retained: SessionProcessActivity[] = [];
  const seen = new Set<string>();
  let bytes = 2;
  let omittedBytes = 0;
  let hitCount = false;
  let hitBytes = false;
  for (const activity of ordered) {
    if (!seen.add(activity.processId)) continue;
    const size = Buffer.byteLength(JSON.stringify(activity)) + 1;
    if (retained.length >= MAX_PROCESS_ACTIVITY_COUNT || bytes + size > MAX_PROCESS_ACTIVITY_BYTES) {
      if (retained.length >= MAX_PROCESS_ACTIVITY_COUNT) hitCount = true;
      if (bytes + size > MAX_PROCESS_ACTIVITY_BYTES) hitBytes = true;
      omittedBytes += size;
      continue;
    }
    retained.push(activity);
    bytes += size;
  }
  return { activities: retained, omittedCount: ordered.length - retained.length, omittedBytes, hitCount, hitBytes };
}

export function processOverview(
  activities: readonly SessionProcessActivity[],
  revision: number,
  asOf: string,
  omissions?: SessionProcessOverview["omissions"],
): SessionProcessOverview {
  const active = activities.filter((activity) => activity.visibility === "active");
  const recent = activities.filter((activity) => activity.visibility === "recent");
  const problems = activities.filter((activity) => ["failed", "rejected", "interrupted"].includes(activity.lifecycle.state));
  const expiries = recent.map((activity) => activity.lifecycle.recentUntil).filter((value): value is string => value !== undefined).sort();
  return {
    version: 1,
    revision,
    asOf,
    activeCount: active.length,
    recentCount: recent.length,
    problemCount: problems.length,
    visibility: active.length > 0 ? "active" : recent.length > 0 ? "recent" : "hidden",
    ...(expiries[0] ? { nearestExpiry: expiries[0] } : {}),
    ...(omissions ? { omissions } : {}),
  };
}

function commandHistory(manager: ReadonlySessionManager): SessionProcessActivity[] {
  const declarations = new Map<string, { command: string; timestamp: string }>();
  const results: SessionProcessActivity[] = [];
  for (const entry of manager.getBranch()) {
    if (entry.type !== "message") continue;
    const message = entry.message;
    if (message.role === "assistant") {
      for (const part of message.content) {
        if (part.type !== "toolCall" || part.name !== "bash") continue;
        const raw = part.arguments && typeof part.arguments.command === "string" ? part.arguments.command : "Shell command";
        declarations.set(part.id, { command: utf8Prefix(raw, 2_048).value, timestamp: entry.timestamp });
      }
      continue;
    }
    if (message.role !== "toolResult" || message.toolName !== "bash") continue;
    const declaration = declarations.get(message.toolCallId);
    if (!declaration) continue;
    const outputValue = message.content.filter((part) => part.type === "text").map((part) => part.text).join("\n");
    const output = outputValue ? utf8Suffix(outputValue, 32 * 1_024) : undefined;
    const terminalAt = entry.timestamp;
    results.push({
      version: 1,
      processId: commandProcessId(manager.getSessionId(), message.toolCallId),
      kind: "command",
      executionMode: "foreground",
      source: "mainAssistant",
      lifecycle: {
        version: 1,
        state: message.isError ? "failed" : "completed",
        attention: "none",
        sequence: 0,
        observedAt: terminalAt,
        terminalAt,
        recentUntil: new Date(Date.parse(terminalAt) + PROCESS_ACTIVITY_RECENT_MS).toISOString(),
      },
      visibility: "historical",
      startedAt: declaration.timestamp,
      title: "Command",
      command: declaration.command,
      ...(output ? { outputTail: output.value } : {}),
      outputTruncated: output?.truncated === true,
      toolCallId: message.toolCallId,
    });
  }
  return results;
}

export function canonicalProcessHistory(manager: ReadonlySessionManager): SessionProcessActivity[] {
  const commands = commandHistory(manager);
  const subagents = extensionActivityReceipts(manager.getEntries(), manager.getSessionId())
    .flatMap(({ receipt }) => subagentProcessesFromActivity(manager.getSessionId(), extensionReceiptActivity(receipt)));
  const byID = new Map<string, SessionProcessActivity>();
  for (const activity of [...commands, ...subagents]) {
    const previous = byID.get(activity.processId);
    if (!previous || (activity.lifecycle.terminalAt ?? activity.lifecycle.observedAt)
      > (previous.lifecycle.terminalAt ?? previous.lifecycle.observedAt)) byID.set(activity.processId, activity);
  }
  return [...byID.values()].sort((left, right) =>
    (right.lifecycle.terminalAt ?? right.lifecycle.observedAt).localeCompare(left.lifecycle.terminalAt ?? left.lifecycle.observedAt)
    || left.processId.localeCompare(right.processId));
}

export function processHistoryRevision(manager: ReadonlySessionManager): string {
  const history = canonicalProcessHistory(manager);
  return createHash("sha256")
    .update(`${manager.getSessionId()}\n${manager.getLeafId() ?? "root"}\n${history.map((activity) => `${activity.processId}\0${activity.lifecycle.terminalAt ?? activity.lifecycle.observedAt}`).join("\n")}`)
    .digest("hex").slice(0, 32);
}

export function listProcessHistory(
  manager: ReadonlySessionManager,
  cursor?: string,
  limit = 25,
  filter?: { kind?: SessionProcessActivity["kind"]; state?: SessionProcessState },
): SessionProcessHistoryPage {
  const revision = processHistoryRevision(manager);
  const all = canonicalProcessHistory(manager).filter((activity) =>
    (!filter?.kind || activity.kind === filter.kind) && (!filter?.state || activity.lifecycle.state === filter.state));
  let offset = 0;
  if (cursor) {
    const [cursorRevision, rawOffset] = cursor.split(":");
    if (cursorRevision !== revision || !/^\d+$/u.test(rawOffset ?? "")) throw new Error("process history cursor conflict");
    offset = Number(rawOffset);
    if (!Number.isSafeInteger(offset) || offset < 0 || offset > all.length) throw new Error("process history cursor invalid");
  }
  const boundedLimit = Math.min(MAX_PROCESS_HISTORY_PAGE, Math.max(1, Math.floor(limit)));
  const pageEnd = Math.min(all.length, offset + boundedLimit);
  const activities: SessionProcessActivity[] = [];
  let bytes = 2;
  let omittedBytes = 0;
  let omittedCount = 0;
  for (let index = offset; index < pageEnd; index += 1) {
    const activity = all[index]!;
    const size = Buffer.byteLength(JSON.stringify(activity)) + 1;
    if (bytes + size > MAX_PROCESS_HISTORY_BYTES) {
      omittedBytes += size;
      omittedCount += 1;
      continue;
    }
    activities.push(activity);
    bytes += size;
  }
  return {
    activities,
    historyRevision: revision,
    ...(pageEnd < all.length ? { nextCursor: `${revision}:${pageEnd}` } : {}),
    ...(omittedCount > 0 ? { omissions: { count: omittedCount, bytes: omittedBytes, reason: "bytes" as const } } : {}),
  };
}

export function processHistoryDetail(manager: ReadonlySessionManager, processId: string, expectedRevision?: string): SessionProcessActivity | undefined {
  if (expectedRevision !== undefined && processHistoryRevision(manager) !== expectedRevision) {
    throw new Error("process history generation conflict");
  }
  return canonicalProcessHistory(manager).find((activity) => activity.processId === processId);
}
