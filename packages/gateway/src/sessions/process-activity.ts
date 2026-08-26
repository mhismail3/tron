import { createHash } from "node:crypto";
import { basename } from "node:path";
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

export const PROCESS_ACTIVITY_CAPABILITY = "process-activity.v1";
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

/** Process presentation is not an alternate secret store. Canonical JSONL is
 * left untouched; bounded wire previews fail closed for common shell, header,
 * structured, provider-token, and high-entropy credential shapes. */
export function redactProcessText(value: string): string {
  const secretName = "(?:api[_-]?key|access[_-]?key|access[_-]?token|auth(?:orization)?[_-]?token|token|password|passwd|secret|client[_-]?secret|private[_-]?key|session[_-]?key|cookie)";
  const quotedOrToken = "(?:\"[^\"]*\"|'[^']*'|[^\\s]+)";
  let redacted = value
    // Environment assignments are intentionally all masked: arbitrary names
    // can carry credentials and the process surface does not need their value.
    .replace(/(\b[A-Za-z_][A-Za-z0-9_]*\s*=\s*)(?:"[^"]*"|'[^']*'|[^\s]+)/gu, "$1[REDACTED]")
    .replace(new RegExp(`(\\b${secretName}\\b\\s*[=:]\\s*)${quotedOrToken}`, "giu"), "$1[REDACTED]")
    .replace(new RegExp(`(--${secretName})(?:=|\\s+)${quotedOrToken}`, "giu"), "$1=[REDACTED]")
    .replace(new RegExp(`(["']${secretName}["']\\s*:\\s*["'])[^"']*(["'])`, "giu"), "$1[REDACTED]$2")
    .replace(/(authorization\s*:\s*)[^\r\n]+/giu, "$1[REDACTED]")
    .replace(/((?:-H|--header)\s+)(["']?)([^\r\n"']+)(["']?)/giu, (_match, flag: string, openQuote: string, header: string, closeQuote: string) => {
      const separator = header.indexOf(":");
      const name = separator >= 0 ? header.slice(0, separator + 1) : "Header:";
      return `${flag}${openQuote}${name} [REDACTED]${closeQuote}`;
    })
    .replace(/((?:-b|--cookie|--cookie-jar|-u|--user|-p|--password)\s+)(?:"[^"]*"|'[^']*'|[^\s]+)/giu, "$1[REDACTED]")
    .replace(/([?&](?:api[_-]?key|access[_-]?token|token|password|secret|signature)=)[^&#\s]+/giu, "$1[REDACTED]")
    .replace(/:\/\/([^\s/:@]+):([^\s/@]+)@/gu, "://$1:[REDACTED]@")
    .replace(/-----BEGIN [^-\r\n]{1,80}-----[\s\S]*?-----END [^-\r\n]{1,80}-----/gu, "[REDACTED PRIVATE KEY]")
    .replace(/\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/gu, "[REDACTED]")
    .replace(/\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{16,}|xox[baprs]-[A-Za-z0-9-]{16,})\b/gu, "[REDACTED]")
    .replace(/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/gu, "[REDACTED]");
  // Provider-neutral high-entropy fallback. Preserve ordinary hashes/IDs only
  // when they are not mixed alphabetic+numeric bearer-like tokens.
  redacted = redacted.replace(/\b[A-Za-z0-9_+/=-]{32,}\b/gu, (token) =>
    /[A-Za-z]/u.test(token) && /\d/u.test(token) ? "[REDACTED]" : token);
  return redacted;
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
  const source = typeof command === "string" && command.trim() ? command.trim() : "Shell command";
  return utf8Prefix(redactProcessText(source), 2_048).value;
}

function processOutput(value: string | undefined): { value: string; truncated: boolean } | undefined {
  if (value === undefined) return undefined;
  return utf8Suffix(redactProcessText(value), 32 * 1_024);
}

function boundedDurationMs(value: number | undefined, startedAt?: string, terminalAt?: string): number | undefined {
  const derived = startedAt && terminalAt ? Date.parse(terminalAt) - Date.parse(startedAt) : undefined;
  const candidate = value ?? derived;
  if (candidate === undefined || !Number.isFinite(candidate) || candidate < 0) return undefined;
  return Math.min(Number.MAX_SAFE_INTEGER, Math.round(candidate));
}

/** Projects only the assistant-owned runtime bash tool state supplied by
 * RuntimeSlot. Direct user bash and Terminal PTYs never enter this function. */
export function commandProcessFromTool(sessionId: string, tool: ToolExecutionState): SessionProcessActivity | undefined {
  if (tool.toolName !== "bash" || tool.extensionOrigin !== undefined) return undefined;
  const terminalAt = tool.status === "running" ? undefined : tool.completedAt ?? tool.updatedAt;
  const state: SessionProcessState = tool.status === "running" ? "running" : tool.status === "failed" ? "failed" : "completed";
  const output = processOutput(tool.output);
  const durationMs = boundedDurationMs(tool.durationMs, tool.startedAt, terminalAt);
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
    ...(durationMs === undefined ? {} : { durationMs }),
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
  const parentState = extensionState(activity.lifecycle?.state);
  const parentIsTerminal = terminalStates.has(parentState);
  for (const child of children) {
    // Compatibility child IDs may be label/index fallbacks. They are useful to
    // the old extension renderer but are not process ownership evidence.
    const exactChildId = child.producerId;
    const processId = exactChildId
      ? subagentProcessId(sessionId, activity.toolCallId, exactChildId)
      : undefined;
    const reportedState = extensionState(child.lifecycle ?? (child.status === "running" ? "running" : child.status === "failed" ? "failed" : "completed"));
    // A terminal receipt cannot author an active historical child. Conversely,
    // a child may finish while its workflow parent remains active; Gateway
    // observation time then owns that child's terminal admission.
    const state = parentIsTerminal && !terminalStates.has(reportedState) ? parentState : reportedState;
    const terminalAt = terminalStates.has(state)
      ? parentIsTerminal
        ? activity.lifecycle?.terminalAt ?? activity.completedAt
        : activity.lifecycle?.observedAt ?? activity.updatedAt
      : undefined;
    const output = processOutput(child.output);
    const durationMs = boundedDurationMs(child.durationMs ?? activity.durationMs, activity.startedAt, terminalAt);
    const executable = exactChildId !== undefined && (
      !(child.children?.length)
      || child.childSessionRef !== undefined
      || child.currentTool !== undefined
      || child.output !== undefined
      || child.toolCount !== undefined
      || child.turnCount !== undefined
    );
    if (executable && processId) rows.push({
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
      ...(durationMs === undefined ? {} : { durationMs }),
      title: utf8Prefix(child.label, 512).value,
      ...(child.currentTool ? { currentTool: utf8Prefix(child.currentTool, 2_048).value } : {}),
      ...(child.currentPath ? { currentPathBasename: utf8Prefix(basename(child.currentPath), 2_048).value } : {}),
      ...(output ? { outputTail: output.value } : {}),
      outputTruncated: output?.truncated === true,
      ...(child.toolCount === undefined ? {} : { toolCount: Math.max(0, child.toolCount) }),
      ...(child.turnCount === undefined ? {} : { turnCount: Math.max(0, child.turnCount) }),
      ...((child.children?.length ?? 0) > 0 ? { childCount: child.children!.length } : {}),
      toolCallId: activity.toolCallId,
      ...(activity.runId ? { runId: activity.runId } : {}),
      ...(child.childSessionRef ? { childSessionRef: child.childSessionRef } : {}),
    });
    if (child.children?.length) rows.push(...childRows(
      sessionId,
      activity,
      child.children,
      executable && processId ? processId : parentProcessId,
    ));
  }
  return rows;
}

export function subagentProcessesFromActivity(sessionId: string, activity: ExtensionRunActivity): SessionProcessActivity[] {
  if (activity.children.length > 0) return childRows(sessionId, activity, activity.children);
  // Workflow roots are orchestration containers, not executable subagents.
  // A single/sync run still has exact run identity and remains a valid row.
  if (!activity.runId || activity.mode?.toLowerCase() === "workflow") return [];
  const mode = subagentMode(activity.mode);
  const hasExecutionEvidence = activity.currentTool !== undefined
    || activity.output !== undefined || activity.toolCount !== undefined
    || activity.turnCount !== undefined || activity.lifecycle?.producerUpdatedAt !== undefined;
  // An asyncId-only launcher acknowledgement has correlation but no observed
  // child execution. Do not turn that settled launcher into a phantom process.
  if (mode === "asynchronous" && !hasExecutionEvidence) return [];
  const processId = subagentProcessId(sessionId, activity.toolCallId, activity.runId);
  const state = extensionState(activity.lifecycle?.state ?? (activity.status === "running" ? "running" : activity.status === "failed" ? "failed" : "completed"));
  const terminalAt = terminalStates.has(state) ? activity.lifecycle?.terminalAt ?? activity.completedAt : undefined;
  const output = processOutput(activity.output);
  const durationMs = boundedDurationMs(activity.durationMs, activity.startedAt, terminalAt);
  return [{
    version: 1,
    processId,
    kind: "subagent",
    executionMode: mode,
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
    ...(durationMs === undefined ? {} : { durationMs }),
    title: utf8Prefix(activity.title === "Pi Subagents" ? "Subagent" : activity.title, 512).value,
    ...(activity.currentTool ? { currentTool: utf8Prefix(activity.currentTool, 2_048).value } : {}),
    ...(activity.currentPath ? { currentPathBasename: utf8Prefix(basename(activity.currentPath), 2_048).value } : {}),
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

function commandHistory(manager: ReadonlySessionManager, excludedToolCallIds: ReadonlySet<string>): SessionProcessActivity[] {
  const declarations = new Map<string, { command: string; timestamp: string }>();
  const results: SessionProcessActivity[] = [];
  for (const entry of manager.getBranch()) {
    if (entry.type !== "message") continue;
    const message = entry.message;
    if (message.role === "assistant") {
      for (const part of message.content) {
        if (part.type !== "toolCall" || part.name !== "bash" || excludedToolCallIds.has(part.id)) continue;
        const raw = part.arguments && typeof part.arguments.command === "string" ? part.arguments.command : "Shell command";
        declarations.set(part.id, {
          command: utf8Prefix(raw, 2_048).value,
          timestamp: new Date(message.timestamp).toISOString(),
        });
      }
      continue;
    }
    if (message.role !== "toolResult" || message.toolName !== "bash") continue;
    const declaration = declarations.get(message.toolCallId);
    if (!declaration) continue;
    const outputValue = message.content.filter((part) => part.type === "text").map((part) => part.text).join("\n");
    const output = outputValue ? processOutput(outputValue) : undefined;
    const terminalAt = new Date(message.timestamp).toISOString();
    const durationMs = boundedDurationMs(undefined, declaration.timestamp, terminalAt);
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
      ...(durationMs === undefined ? {} : { durationMs }),
      title: "Command",
      command: redactProcessText(declaration.command),
      ...(output ? { outputTail: output.value } : {}),
      outputTruncated: output?.truncated === true,
      toolCallId: message.toolCallId,
    });
  }
  return results;
}

export function canonicalProcessHistory(manager: ReadonlySessionManager): SessionProcessActivity[] {
  const receipts = extensionActivityReceipts(manager.getBranch(), manager.getSessionId());
  const extensionToolCallIds = new Set(receipts.map(({ receipt }) => receipt.toolCallId));
  const commands = commandHistory(manager, extensionToolCallIds);
  const subagents = receipts
    .flatMap(({ receipt }) => subagentProcessesFromActivity(manager.getSessionId(), extensionReceiptActivity(receipt)))
    // Canonical pages are the Earlier partition. Mounted five-minute rows are
    // supplied independently by RuntimeSlot and deduplicated by processId.
    .map((activity) => ({ ...activity, visibility: "historical" as const }));
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
  const maximumEnd = Math.min(all.length, offset + boundedLimit);
  const activities: SessionProcessActivity[] = [];
  let bytes = 2;
  let omittedBytes = 0;
  let omittedCount = 0;
  let nextOffset = offset;
  for (let index = offset; index < maximumEnd; index += 1) {
    const activity = all[index]!;
    const size = Buffer.byteLength(JSON.stringify(activity)) + 1;
    if (bytes + size > MAX_PROCESS_HISTORY_BYTES) {
      // A row that only exhausts this page's remainder belongs at the next
      // cursor. Only a row too large for an otherwise empty page is omitted.
      if (activities.length > 0 || omittedCount > 0) break;
      omittedBytes += size;
      omittedCount += 1;
      nextOffset = index + 1;
      continue;
    }
    activities.push(activity);
    bytes += size;
    nextOffset = index + 1;
  }
  return {
    activities,
    historyRevision: revision,
    ...(nextOffset < all.length ? { nextCursor: `${revision}:${nextOffset}` } : {}),
    ...(omittedCount > 0 ? { omissions: { count: omittedCount, bytes: omittedBytes, reason: "bytes" as const } } : {}),
  };
}

export function processHistoryDetail(manager: ReadonlySessionManager, processId: string, expectedRevision?: string): SessionProcessActivity | undefined {
  if (expectedRevision !== undefined && processHistoryRevision(manager) !== expectedRevision) {
    throw new Error("process history generation conflict");
  }
  return canonicalProcessHistory(manager).find((activity) => activity.processId === processId);
}
