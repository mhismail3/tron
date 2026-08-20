import type {
  ExtensionRunActivity,
  ExtensionRunChild,
  ExtensionRunStatus,
  ExtensionToolOrigin,
  JsonValue,
} from "../protocol/types.js";

const MAX_CHILDREN = 32;
const MAX_CHILDREN_TOTAL = 64;
const MAX_DEPTH = 3;
const MAX_TEXT_BYTES = 2_048;

function record(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined;
}

function text(value: unknown, maximumBytes = MAX_TEXT_BYTES): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  if (!trimmed) return undefined;
  const bytes = Buffer.from(trimmed);
  if (bytes.length <= maximumBytes) return trimmed;
  return `${bytes.subarray(0, Math.max(0, maximumBytes - 3)).toString("utf8").replace(/\uFFFD$/u, "")}…`;
}

function number(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && Number.isSafeInteger(value) ? value : undefined;
}

function isoTime(value: unknown): string | undefined {
  const milliseconds = number(value);
  if (milliseconds === undefined || milliseconds < 0 || milliseconds > 8.64e15) return undefined;
  return new Date(milliseconds).toISOString();
}

function status(value: unknown, fallback: ExtensionRunStatus): ExtensionRunStatus {
  if (value === "failed") return "failed";
  if (value === "completed" || value === "complete" || value === "stopped") return "completed";
  if (value === "running" || value === "pending" || value === "detached" || value === "paused") return "running";
  return fallback;
}

function output(value: unknown): string | undefined {
  if (typeof value === "string") return text(value, 1_200);
  if (!Array.isArray(value)) return undefined;
  const lines = value.filter((line): line is string => typeof line === "string").slice(-8);
  return text(lines.join("\n"), 1_200);
}

function displayPath(value: unknown): string | undefined {
  const candidate = text(value, 1_024);
  if (!candidate) return undefined;
  const segments = candidate.split(/[\\/]/u).filter(Boolean);
  return segments.at(-1) ?? candidate;
}

function progressRecord(value: unknown): Record<string, unknown> | undefined {
  const candidate = record(value);
  if (!candidate) return undefined;
  return record(candidate.progress) ?? candidate;
}

function child(
  value: unknown,
  index: number,
  fallbackStatus: ExtensionRunStatus,
  depth: number,
  budget: { remaining: number },
): ExtensionRunChild | undefined {
  if (budget.remaining <= 0) return undefined;
  budget.remaining -= 1;
  const source = record(value);
  if (!source) return undefined;
  const progress = progressRecord(source);
  const label = text(progress?.agent ?? source.agent, 256) ?? `Child ${index + 1}`;
  const nestedValues = Array.isArray(source.children)
    ? source.children
    : Array.isArray(source.steps) ? source.steps : [];
  const nested = nestedValues
    .slice(0, MAX_CHILDREN)
    .map((item, nestedIndex) => child(item, nestedIndex, fallbackStatus, depth + 1, budget))
    .filter((item): item is ExtensionRunChild => Boolean(item));
  const task = text(progress?.task ?? source.task ?? source.description ?? source.summary, 2_048);
  const lastActivityAt = isoTime(progress?.lastActivityAt ?? source.lastActivityAt ?? source.updatedAt);
  const currentTool = text(progress?.currentTool ?? source.currentTool, 256);
  const currentToolStartedAt = isoTime(progress?.currentToolStartedAt ?? source.currentToolStartedAt);
  const currentPath = displayPath(progress?.currentPath ?? source.currentPath);
  const toolCount = number(progress?.toolCount ?? source.toolCount);
  const turnCount = number(progress?.turnCount ?? source.turnCount);
  const durationMs = number(progress?.durationMs ?? source.durationMs);
  const recentOutput = output(
    progress?.recentOutput
      ?? source.recentOutput
      ?? source.output
      ?? source.error
  );
  return {
    id: text(source.runId ?? source.id ?? source.asyncId, 256) ?? `${label}:${index}`,
    label,
    status: status(progress?.status ?? source.status, fallbackStatus),
    ...(task ? { task } : {}),
    ...(lastActivityAt ? { lastActivityAt } : {}),
    ...(currentTool ? { currentTool } : {}),
    ...(currentToolStartedAt ? { currentToolStartedAt } : {}),
    ...(currentPath ? { currentPath } : {}),
    ...(toolCount === undefined ? {} : { toolCount: Math.max(0, Math.round(toolCount)) }),
    ...(turnCount === undefined ? {} : { turnCount: Math.max(0, Math.round(turnCount)) }),
    ...(durationMs === undefined ? {} : { durationMs: Math.max(0, Math.round(durationMs)) }),
    ...(recentOutput ? { output: recentOutput } : {}),
    ...(depth < MAX_DEPTH && nested.length > 0 ? { children: nested } : {}),
  };
}

function detailsFrom(value: unknown): Record<string, unknown> | undefined {
  const root = record(value);
  return record(root?.details) ?? root;
}

/**
 * Extracts the public progress convention used by extension-owned delegated
 * runs without depending on a package name or rendered widget text. Unknown
 * detail shapes still receive a truthful generic activity row from the tool
 * lifecycle; this function only enriches it when structured progress exists.
 */
export function projectExtensionRunActivity(
  value: unknown,
  base: {
    id: string;
    toolCallId: string;
    source: ExtensionToolOrigin;
    title: string;
    status: ExtensionRunStatus;
    /** Lifecycle terminal events outrank advisory artifact/detail state. */
    authoritativeStatus?: boolean;
    startedAt: string;
    updatedAt: string;
    completedAt?: string;
    durationMs?: number;
    previous?: ExtensionRunActivity;
  },
): ExtensionRunActivity {
  const details = detailsFrom(value);
  const previous = base.previous;
  const detailsResults = Array.isArray(details?.results) ? details.results : [];
  const progressValues = Array.isArray(details?.progress) ? details.progress : [];
  const stepValues = Array.isArray(details?.steps) ? details.steps : [];
  const childValues = Array.isArray(details?.children) ? details.children : [];
  const candidates = detailsResults.length > 0
    ? detailsResults
    : progressValues.length > 0
      ? progressValues
      : stepValues.length > 0
        ? stepValues
        : childValues;
  const explicitStatus = details?.state ?? details?.status;
  const terminalStatus = explicitStatus === "failed"
    ? "failed"
    : (explicitStatus === "completed" || explicitStatus === "complete" || explicitStatus === "stopped")
      ? "completed"
      : undefined;
  const priorTerminal = previous?.status === "completed" || previous?.status === "failed";
  const detachedRun = typeof details?.asyncId === "string"
    && detailsResults.length === 0
    && terminalStatus === undefined
    && !priorTerminal
    && !base.authoritativeStatus;
  // A launcher result carrying only asyncId is an acknowledgement, not the
  // delegated run's terminal result. It may keep a non-terminal activity live,
  // but never outranks an explicit terminal lifecycle/detail state.
  const activityStatus: ExtensionRunStatus = base.authoritativeStatus
    ? base.status
    : terminalStatus
      ?? (priorTerminal ? previous!.status : detachedRun ? "running" : base.status);
  const completedAt = activityStatus === "running" ? undefined : base.completedAt ?? previous?.completedAt;
  const children = candidates
    .slice(0, MAX_CHILDREN)
    .map((item, index) => child(item, index, activityStatus, 0, { remaining: MAX_CHILDREN_TOTAL }))
    .filter((item): item is ExtensionRunChild => Boolean(item));
  const firstProgress = candidates.length > 0 ? progressRecord(candidates[0]) : undefined;
  const runId = text(details?.runId ?? details?.asyncId, 256) ?? previous?.runId;
  const lastActivityAt = isoTime(firstProgress?.lastActivityAt ?? details?.lastActivityAt ?? details?.updatedAt) ?? previous?.lastActivityAt;
  const currentTool = text(firstProgress?.currentTool ?? details?.currentTool, 256) ?? previous?.currentTool;
  const currentToolStartedAt = isoTime(firstProgress?.currentToolStartedAt ?? details?.currentToolStartedAt) ?? previous?.currentToolStartedAt;
  const currentPath = displayPath(firstProgress?.currentPath ?? details?.currentPath) ?? previous?.currentPath;
  const toolCount = number(firstProgress?.toolCount ?? details?.toolCount) ?? previous?.toolCount;
  const turnCount = number(firstProgress?.turnCount ?? details?.turnCount) ?? previous?.turnCount;
  const durationMs = activityStatus === "running"
    ? number(firstProgress?.durationMs ?? details?.durationMs) ?? base.durationMs ?? previous?.durationMs
    : base.durationMs ?? number(firstProgress?.durationMs ?? details?.durationMs) ?? previous?.durationMs;
  const recentOutput = output(
    firstProgress?.recentOutput
      ?? firstProgress?.output
      ?? details?.recentOutput
      ?? details?.output
      ?? details?.summary
      ?? details?.error
  ) ?? previous?.output;
  const mode = text(details?.mode, 64) ?? previous?.mode;

  return {
    id: base.id,
    ...(runId ? { runId } : {}),
    toolCallId: base.toolCallId,
    source: base.source,
    title: base.title,
    ...(mode ? { mode } : {}),
    status: activityStatus,
    startedAt: base.startedAt,
    updatedAt: base.updatedAt,
    ...(completedAt ? { completedAt } : {}),
    ...(lastActivityAt ? { lastActivityAt } : {}),
    ...(currentTool ? { currentTool } : {}),
    ...(currentToolStartedAt ? { currentToolStartedAt } : {}),
    ...(currentPath ? { currentPath } : {}),
    ...(toolCount === undefined ? {} : { toolCount: Math.max(0, Math.round(toolCount)) }),
    ...(turnCount === undefined ? {} : { turnCount: Math.max(0, Math.round(turnCount)) }),
    ...(durationMs === undefined ? {} : { durationMs: Math.max(0, Math.round(durationMs)) }),
    ...(recentOutput ? { output: recentOutput } : {}),
    children: children.length > 0 ? children : previous?.children ?? [],
  } satisfies ExtensionRunActivity;
}

/** Returns the extension-owned artifact directory only for a structured run
 * detail. Callers must apply their own filesystem allowlist before reading it. */
export function extensionRunAsyncDir(value: unknown): string | undefined {
  const details = detailsFrom(value);
  return text(details?.asyncDir, 2_048);
}

export function extensionRunActivityJSON(activity: ExtensionRunActivity): JsonValue {
  return activity as unknown as JsonValue;
}
