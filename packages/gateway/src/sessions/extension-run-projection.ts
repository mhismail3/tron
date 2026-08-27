import { createHash } from "node:crypto";
import type {
  ExtensionRunActivity,
  ExtensionRunChild,
  ExtensionRunStatus,
  ExtensionRunAttention,
  ExtensionRunLifecycle,
  ExtensionRunLifecycleState,
  ExtensionToolOrigin,
  JsonValue,
} from "../protocol/types.js";

const MAX_CHILDREN = 32;
const MAX_CHILDREN_TOTAL = 64;
const MAX_DEPTH = 3;
const MAX_TEXT_BYTES = 2_048;
export const MAX_EXTENSION_ACTIVITY_COUNT = 32;
export const MAX_EXTENSION_ACTIVITY_BYTES = 256 * 1_024;

/** Stable native identity. It is intentionally independent of run/artifact
 * correlation so replacing a producer artifact cannot re-key a native row. */
export function extensionActivityId(sessionId: string, toolCallId: string): string {
  return `extension-activity:${createHash("sha256").update(`${sessionId}\0${toolCallId}`).digest("hex").slice(0, 32)}`;
}

export function boundExtensionActivities(activities: readonly ExtensionRunActivity[]): {
  activities: ExtensionRunActivity[];
  omittedCount: number;
  omittedBytes: number;
  hitCount: boolean;
  hitBytes: boolean;
} {
  const retained: ExtensionRunActivity[] = [];
  const ordered = [...activities].sort((left, right) => {
    const active = (activity: ExtensionRunActivity) => activity.lifecycle?.state === "queued"
      || activity.lifecycle?.state === "running" || activity.lifecycle?.state === "paused" ? 0 : 1;
    return active(left) - active(right) || right.updatedAt.localeCompare(left.updatedAt);
  });
  let bytes = 2;
  let omittedBytes = 0;
  let hitCount = false;
  let hitBytes = false;
  const seenIDs = new Set<string>();
  for (const activity of ordered) {
    const activityID = activity.activityId ?? activity.id;
    if (seenIDs.has(activityID)) {
      omittedBytes += Buffer.byteLength(JSON.stringify(activity)) + 1;
      continue;
    }
    seenIDs.add(activityID);
    const size = Buffer.byteLength(JSON.stringify(activity)) + 1;
    if (retained.length >= MAX_EXTENSION_ACTIVITY_COUNT || bytes + size > MAX_EXTENSION_ACTIVITY_BYTES) {
      if (retained.length >= MAX_EXTENSION_ACTIVITY_COUNT) hitCount = true;
      if (bytes + size > MAX_EXTENSION_ACTIVITY_BYTES) hitBytes = true;
      omittedBytes += size;
      continue;
    }
    retained.push(activity);
    bytes += size;
  }
  return { activities: retained, omittedCount: ordered.length - retained.length, omittedBytes, hitCount, hitBytes };
}

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

function producerTime(value: unknown): string | undefined {
  if (typeof value === "string" && Buffer.byteLength(value) <= 128) {
    const milliseconds = Date.parse(value);
    if (Number.isFinite(milliseconds) && milliseconds >= 0 && milliseconds <= 8.64e15) {
      return new Date(milliseconds).toISOString();
    }
  }
  return isoTime(value);
}

function status(value: unknown, fallback: ExtensionRunStatus): ExtensionRunStatus {
  if (value === "failed") return "failed";
  if (value === "completed" || value === "complete" || value === "stopped" || value === "rejected") return "completed";
  if (value === "running" || value === "pending" || value === "detached" || value === "paused" || value === "queued") return "running";
  return fallback;
}

const lifecycleStates = new Set<ExtensionRunLifecycleState>([
  "queued", "running", "paused", "completed", "failed", "stopped", "rejected", "unknown",
]);
export const terminalLifecycleStates = new Set<ExtensionRunLifecycleState>(["completed", "failed", "stopped", "rejected"]);
export const EXTENSION_LIFECYCLE_ARTIFACT_VERSION = 3;

export type ExtensionArtifactRejectionReason =
  | "invalid-timestamp"
  | "missing-terminal-time"
  | "ownership-mismatch"
  | "malformed-artifact"
  | "artifact-replacement-in-progress";

export type ExtensionArtifactAdmission =
  | { accepted: true; artifact: Record<string, unknown> }
  | { accepted: false; reason: "invalid-timestamp" | "missing-terminal-time" | "malformed-artifact" };

/** Admit the current versioned status artifact contract with a bounded reason.
 * Historical artifacts are accepted only after exact ownership is proven. */
export function inspectExtensionLifecycleArtifact(
  value: unknown,
  options: { exactOwnedLegacy?: boolean } = {},
): ExtensionArtifactAdmission {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return { accepted: false, reason: "malformed-artifact" };
  }
  const artifact = value as Record<string, unknown>;
  const historicalVersion = artifact.lifecycleArtifactVersion;
  const versionAccepted = historicalVersion === EXTENSION_LIFECYCLE_ARTIFACT_VERSION
    || (options.exactOwnedLegacy === true && (
      historicalVersion === undefined
      || (Number.isSafeInteger(historicalVersion)
        && (historicalVersion as number) >= 1
        && (historicalVersion as number) < EXTENSION_LIFECYCLE_ARTIFACT_VERSION)
    ));
  if (!versionAccepted
    || typeof artifact.runId !== "string" || artifact.runId.trim().length === 0
    || extensionLifecycleState(artifact.state ?? artifact.status) === "unknown") {
    return { accepted: false, reason: "malformed-artifact" };
  }
  const state = extensionLifecycleState(artifact.state ?? artifact.status);
  const startedAt = artifact.startedAt;
  const lastUpdate = artifact.lastUpdate;
  // completedAt is the supported older spelling of endedAt. If both are
  // present, an invalid primary value must not be hidden by the alias.
  const terminalAt = artifact.endedAt !== undefined ? artifact.endedAt : artifact.completedAt;
  for (const timestamp of [startedAt, lastUpdate]) {
    if (!Number.isSafeInteger(timestamp) || (timestamp as number) < 0) {
      return { accepted: false, reason: "invalid-timestamp" };
    }
  }
  if (artifact.endedAt !== undefined && (!Number.isSafeInteger(artifact.endedAt) || (artifact.endedAt as number) < 0)) {
    return { accepted: false, reason: "invalid-timestamp" };
  }
  if (artifact.completedAt !== undefined && (!Number.isSafeInteger(artifact.completedAt) || (artifact.completedAt as number) < 0)) {
    return { accepted: false, reason: "invalid-timestamp" };
  }
  if (terminalLifecycleStates.has(state) && terminalAt === undefined) {
    return { accepted: false, reason: "missing-terminal-time" };
  }
  const startedMilliseconds = startedAt as number;
  const updatedMilliseconds = lastUpdate as number;
  const terminalAliases = [artifact.endedAt, artifact.completedAt].filter((timestamp) => timestamp !== undefined) as number[];
  if (updatedMilliseconds < startedMilliseconds
    || terminalAliases.some((timestamp) => timestamp < startedMilliseconds || timestamp > updatedMilliseconds)) {
    return { accepted: false, reason: "invalid-timestamp" };
  }
  return { accepted: true, artifact };
}

export function admitExtensionLifecycleArtifact(
  value: unknown,
  options: { exactOwnedLegacy?: boolean } = {},
): Record<string, unknown> | undefined {
  const admission = inspectExtensionLifecycleArtifact(value, options);
  return admission.accepted ? admission.artifact : undefined;
}

/** Gateway sequence admission used by every producer projection. Producer
 * timestamps are intentionally absent from this decision. */
export function admitExtensionRunActivity(previous: ExtensionRunActivity | undefined, candidate: ExtensionRunActivity): ExtensionRunActivity {
  if (!previous) return candidate;
  const previousTerminal = previous.lifecycle && terminalLifecycleStates.has(previous.lifecycle.state);
  const candidateTerminal = candidate.lifecycle && terminalLifecycleStates.has(candidate.lifecycle.state);
  if (previousTerminal) {
    if (!candidateTerminal || candidate.lifecycle?.state !== previous.lifecycle?.state) return previous;
  }
  if (previous.lifecycle?.sequence !== undefined && candidate.lifecycle?.sequence !== undefined
    && candidate.lifecycle.sequence <= previous.lifecycle.sequence) return previous;
  return candidate;
}

/** Strictly admits the additive producer lifecycle vocabulary. Unsupported
 * values are unknown rather than silently becoming running. */
export function extensionLifecycleState(value: unknown, fallback: ExtensionRunLifecycleState = "unknown"): ExtensionRunLifecycleState {
  if (typeof value === "string" && lifecycleStates.has(value as ExtensionRunLifecycleState)) return value as ExtensionRunLifecycleState;
  if (value === "complete") return "completed";
  if (value === "pending" || value === "detached") return "running";
  return fallback;
}

export interface NormalizedExtensionArtifact {
  lifecycleState: ExtensionRunLifecycleState;
  status: "running" | "completed" | "failed";
  terminal: boolean;
  startedAt: string;
  updatedAt: string;
  completedAt?: string;
  durationMs?: number;
}

/** Purely normalize producer artifact state and timestamps. Filesystem
 * admission, ownership, receipts, and watcher policy remain RuntimeSlot work. */
export function normalizeExtensionArtifact(
  value: Record<string, unknown>,
  options: { now: string; fallbackStartedAt?: string; fallbackUpdatedAt?: string; useArtifactStartedAt?: boolean },
): NormalizedExtensionArtifact | undefined {
  const lifecycleState = extensionLifecycleState(value.state ?? value.status);
  if (lifecycleState === "unknown") return undefined;
  const terminal = terminalLifecycleStates.has(lifecycleState);
  const status = lifecycleState === "failed" ? "failed" : terminal ? "completed" : "running";
  const artifactStartedAt = value.startedAt === undefined ? undefined : isoTime(value.startedAt);
  const artifactUpdatedAt = value.lastUpdate === undefined ? undefined : isoTime(value.lastUpdate);
  const endedAtAlias = value.endedAt === undefined ? undefined : isoTime(value.endedAt);
  const completedAtAlias = value.completedAt === undefined ? undefined : isoTime(value.completedAt);
  const artifactEndedAt = endedAtAlias ?? completedAtAlias;
  if ((value.startedAt !== undefined && !artifactStartedAt)
      || (value.lastUpdate !== undefined && !artifactUpdatedAt)
      || (value.endedAt !== undefined && !endedAtAlias)
      || (value.completedAt !== undefined && !completedAtAlias)) return undefined;
  const startedAt = (options.useArtifactStartedAt !== false ? artifactStartedAt : undefined) ?? options.fallbackStartedAt;
  const updatedAt = artifactUpdatedAt ?? options.fallbackUpdatedAt ?? startedAt ?? options.now;
  const completedAt = terminal ? artifactEndedAt : undefined;
  if (terminal && !completedAt) return undefined;
  const startedMilliseconds = Date.parse(startedAt ?? options.now);
  const updatedMilliseconds = Date.parse(updatedAt);
  const terminalMilliseconds = [endedAtAlias, completedAtAlias]
    .filter((timestamp): timestamp is string => timestamp !== undefined)
    .map((timestamp) => Date.parse(timestamp));
  if (!Number.isFinite(startedMilliseconds) || !Number.isFinite(updatedMilliseconds)
      || updatedMilliseconds < startedMilliseconds
      || terminalMilliseconds.some((timestamp) => !Number.isFinite(timestamp)
        || timestamp < startedMilliseconds || timestamp > updatedMilliseconds)) return undefined;
  const durationMs = number(value.durationMs);
  return {
    lifecycleState,
    status,
    terminal,
    startedAt: startedAt ?? options.now,
    updatedAt,
    ...(completedAt ? { completedAt } : {}),
    ...(durationMs === undefined || durationMs < 0 ? {} : { durationMs }),
  };
}

function attention(value: unknown): ExtensionRunAttention {
  if (value === "activeLongRunning" || value === "needsAttention") return value;
  return "none";
}

function lifecycleFrom(
  details: Record<string, unknown> | undefined,
  base: { status: ExtensionRunStatus; updatedAt: string; completedAt?: string; previous?: ExtensionRunActivity; sequence?: number; observedAt?: string; terminalAt?: string; recentUntil?: string },
): ExtensionRunLifecycle {
  const explicit = details?.state ?? details?.status;
  const fallback = base.status === "failed" ? "failed" : base.status === "completed" ? "completed" : "running";
  const candidateState = explicit === undefined ? fallback : extensionLifecycleState(explicit);
  const prior = base.previous?.lifecycle;
  const priorTerminal = prior !== undefined && terminalLifecycleStates.has(prior.state);
  const state = priorTerminal && !terminalLifecycleStates.has(candidateState) ? prior.state : candidateState;
  const terminal = terminalLifecycleStates.has(state);
  const terminalAt = terminal ? base.terminalAt ?? prior?.terminalAt ?? base.completedAt : undefined;
  const producerUpdatedAt = producerTime(details?.updatedAt) ?? producerTime(details?.lastUpdate);
  return {
    version: 1,
    state,
    attention: priorTerminal ? (prior?.attention ?? "none") : attention(details?.attention ?? details?.attentionState),
    sequence: Math.max(0, Number.isSafeInteger(base.sequence) ? base.sequence! : (prior?.sequence ?? 0)),
    observedAt: base.observedAt ?? prior?.observedAt ?? base.updatedAt,
    ...(producerUpdatedAt ? { producerUpdatedAt } : {}),
    ...(terminalAt ? { terminalAt } : {}),
    ...(terminalAt ? { recentUntil: base.recentUntil ?? prior?.recentUntil ?? new Date(Date.parse(terminalAt) + 900_000).toISOString() } : {}),
  };
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
  const childLifecycle = extensionLifecycleState(progress?.state ?? progress?.status ?? source.state ?? source.status,
    fallbackStatus === "failed" ? "failed" : fallbackStatus === "completed" ? "completed" : "running");
  const childAttention = attention(progress?.attention ?? progress?.attentionState ?? source.attention ?? source.attentionState);
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
  const stableIndex = number(source.index ?? progress?.index);
  // Foreground pi-subagents progress has no child run ID until persistence,
  // but its producer-authored index is stable for the entire tool call. The
  // process ID also includes the canonical parent toolCallId, so this bounded
  // identity cannot collide across calls.
  const producerId = text(source.runId ?? source.id ?? source.asyncId, 256)
    ?? (stableIndex !== undefined && stableIndex >= 0 && stableIndex < MAX_CHILDREN_TOTAL
      ? `foreground-index:${stableIndex}`
      : undefined);
  return {
    id: producerId ?? `${label}:${index}`,
    ...(producerId ? { producerId } : {}),
    label,
    status: status(progress?.status ?? source.status, fallbackStatus),
    lifecycle: childLifecycle,
    attention: childAttention,
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

/** Exact current foreground pi-subagents progress convention. RuntimeSlot
 * applies this only after proving the canonical tool belongs to the installed
 * pi-subagents extension; generic extensions must keep using the stricter
 * runId/asyncId convention below. */
export function hasForegroundSubagentRunActivity(value: unknown): boolean {
  const details = detailsFrom(value);
  if (!details || !["single", "parallel", "chain"].includes(text(details.mode, 32) ?? "")) return false;
  const progress = Array.isArray(details.progress) ? details.progress : [];
  const results = Array.isArray(details.results) ? details.results : [];
  const candidates = progress.length > 0 ? progress : results;
  if (candidates.length === 0 || candidates.length > MAX_CHILDREN) return false;
  const indexes = new Set<number>();
  return candidates.every((candidate) => {
    const source = record(candidate);
    const projected = progressRecord(candidate);
    if (!source || !projected) return false;
    const index = number(source.index ?? projected.index);
    const agent = text(projected.agent ?? source.agent, 256);
    const state = projected.status ?? projected.state ?? source.status ?? source.state;
    if (index === undefined || index < 0 || index >= MAX_CHILDREN_TOTAL || indexes.has(index)) return false;
    indexes.add(index);
    return agent !== undefined
      && ["pending", "queued", "running", "paused", "completed", "failed", "detached"].includes(String(state));
  });
}

/** Generic extension tools remain ordinary service/tool activity. Only an
 * explicit delegated-run convention may create the ambient lifecycle hub. */
export function hasStructuredExtensionRunActivity(value: unknown): boolean {
  const details = detailsFrom(value);
  if (!details) return false;
  if (typeof details.runId === "string"
    || typeof details.asyncId === "string"
    || Number.isSafeInteger(details.lifecycleArtifactVersion)) return true;
  const nested = [details.results, details.progress, details.steps, details.children]
    .filter(Array.isArray)
    .flat() as unknown[];
  return nested.some((value) => {
    const item = record(value);
    if (!item) return false;
    const progress = record(item.progress);
    return typeof item.runId === "string"
      || typeof item.asyncId === "string"
      || typeof progress?.runId === "string"
      || typeof progress?.asyncId === "string";
  });
}

export function extensionActivityStatusFromTool(
  value: unknown,
  fallback: "running" | "completed" | "failed",
): { status: "running" | "completed" | "failed"; terminal: boolean; reportedTerminal: boolean } {
  const details = detailsFrom(value);
  const reported = extensionLifecycleState(details?.state ?? details?.status);
  const reportedTerminal = ["completed", "failed", "stopped", "rejected"].includes(reported);
  const reportedCurrent = ["queued", "running", "paused"].includes(reported);
  // asyncDir is an explicit detached-run receipt. The outer extension tool has
  // returned, but the delegated workflow has not reached a terminal state.
  const detachedCurrent = extensionRunAsyncDir(value) !== undefined && !reportedTerminal;
  const terminal = reportedTerminal || (!reportedCurrent && !detachedCurrent && fallback !== "running");
  const status = reportedCurrent || detachedCurrent
    ? "running"
    : reported === "failed" || fallback === "failed" ? "failed" : terminal ? "completed" : "running";
  return { status, terminal, reportedTerminal };
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
    /** Gateway-owned execution mode override after filesystem ownership admission. */
    mode?: string;
    status: ExtensionRunStatus;
    /** Lifecycle terminal events outrank advisory artifact/detail state. */
    authoritativeStatus?: boolean;
    startedAt: string;
    updatedAt: string;
    completedAt?: string;
    durationMs?: number;
    previous?: ExtensionRunActivity;
    /** Gateway facts are optional for old callers and make the projector deterministic in tests. */
    activityId?: string;
    sequence?: number;
    observedAt?: string;
    terminalAt?: string;
    recentUntil?: string;
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
  const explicitLifecycleState = extensionLifecycleState(explicitStatus);
  const terminalStatus = explicitLifecycleState === "failed"
    ? "failed"
    : (explicitLifecycleState === "completed" || explicitLifecycleState === "stopped" || explicitLifecycleState === "rejected")
      ? "completed"
      : undefined;
  const priorTerminal = previous?.status === "completed" || previous?.status === "failed";
  const detachedRun = extensionRunAsyncDir(value) !== undefined
    && detailsResults.length === 0
    && terminalStatus === undefined
    && !priorTerminal
    && !base.authoritativeStatus;
  // Only an admitted artifact directory can keep a launcher-owned run live.
  // asyncId by itself is correlation evidence, not observable lifecycle.
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
  // Aggregate fields belong to the lifecycle root. A first child must never
  // win merely because it happens to be present in the payload.
  const aggregateProgress = progressRecord(details?.aggregate ?? details?.progressState);
  const runId = text(details?.runId ?? details?.asyncId, 256) ?? previous?.runId;
  const lastActivityAt = isoTime(details?.lastActivityAt ?? aggregateProgress?.lastActivityAt ?? firstProgress?.lastActivityAt ?? details?.updatedAt) ?? previous?.lastActivityAt;
  const currentTool = text(details?.currentTool ?? aggregateProgress?.currentTool ?? firstProgress?.currentTool, 256) ?? previous?.currentTool;
  const currentToolStartedAt = isoTime(details?.currentToolStartedAt ?? aggregateProgress?.currentToolStartedAt ?? firstProgress?.currentToolStartedAt) ?? previous?.currentToolStartedAt;
  const currentPath = displayPath(details?.currentPath ?? aggregateProgress?.currentPath ?? firstProgress?.currentPath) ?? previous?.currentPath;
  const toolCount = number(details?.toolCount ?? aggregateProgress?.toolCount ?? firstProgress?.toolCount) ?? previous?.toolCount;
  const turnCount = number(details?.turnCount ?? aggregateProgress?.turnCount ?? firstProgress?.turnCount) ?? previous?.turnCount;
  const durationMs = activityStatus === "running"
    ? number(details?.durationMs ?? aggregateProgress?.durationMs ?? firstProgress?.durationMs) ?? base.durationMs ?? previous?.durationMs
    : base.durationMs ?? number(details?.durationMs ?? aggregateProgress?.durationMs ?? firstProgress?.durationMs) ?? previous?.durationMs;
  const recentOutput = output(
    details?.recentOutput
      ?? details?.output
      ?? aggregateProgress?.recentOutput
      ?? aggregateProgress?.output
      ?? firstProgress?.recentOutput
      ?? firstProgress?.output
      ?? details?.summary
      ?? details?.error
  ) ?? previous?.output;
  const mode = text(base.mode, 64) ?? text(details?.mode, 64) ?? previous?.mode;

  return {
    id: base.id,
    ...(base.activityId ? { activityId: base.activityId } : previous?.activityId ? { activityId: previous.activityId } : {}),
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
    lifecycle: lifecycleFrom(details, {
      status: activityStatus,
      updatedAt: base.updatedAt,
      ...(completedAt ? { completedAt } : {}),
      ...(previous ? { previous } : {}),
      ...(base.sequence === undefined ? {} : { sequence: base.sequence }),
      ...(base.observedAt ? { observedAt: base.observedAt } : {}),
      ...(base.terminalAt ? { terminalAt: base.terminalAt } : {}),
      ...(base.recentUntil ? { recentUntil: base.recentUntil } : {}),
    }),
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
