import { createHash } from "node:crypto";
import type {
  ExtensionRunActivity,
  ExtensionRunChild,
  ExtensionRunStatus,
  ExtensionRunAttention,
  ExtensionRunHostStep,
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
export const MAX_EXTENSION_LIFECYCLE_HEADER_BYTES = 32 * 1_024;

export interface ExtensionLifecycleProjection {
  version: 1;
  runId: string;
  toolCallId?: string;
  sessionId?: string;
  generatedAt: number;
  caps: { maxRuns: number; maxChildrenPerNode: number; maxDepth: number; maxStringLength: number; maxSerializedBytes: number };
  omitted: { runs: number; children: number; byteLimitExceeded: boolean };
  root: Record<string, unknown>;
}

const strictUtf8 = new TextDecoder("utf-8", { fatal: true });

function headerJSON(bytes: Uint8Array): unknown {
  try { return JSON.parse(strictUtf8.decode(bytes)); } catch { return undefined; }
}

function headerStringEnd(bytes: Uint8Array, start: number): number | undefined {
  if (bytes[start] !== 0x22) return undefined;
  let escaped = false;
  for (let index = start + 1; index < bytes.length; index += 1) {
    const byte = bytes[index]!;
    if (escaped) { escaped = false; continue; }
    if (byte === 0x5c) { escaped = true; continue; }
    if (byte === 0x22) return index + 1;
    if (byte < 0x20) return undefined;
  }
  return undefined;
}

function headerValueEnd(bytes: Uint8Array, start: number): number | undefined {
  const first = bytes[start];
  if (first === 0x22) return headerStringEnd(bytes, start);
  if (first !== 0x7b && first !== 0x5b) {
    let index = start;
    while (index < bytes.length && ![0x2c, 0x7d, 0x5d, 0x20, 0x09, 0x0a, 0x0d].includes(bytes[index]!)) index += 1;
    return index > start ? index : undefined;
  }
  const stack: number[] = [first === 0x7b ? 0x7d : 0x5d];
  let inString = false;
  let escaped = false;
  for (let index = start + 1; index < bytes.length; index += 1) {
    const byte = bytes[index]!;
    if (inString) {
      if (escaped) escaped = false;
      else if (byte === 0x5c) escaped = true;
      else if (byte === 0x22) inString = false;
      else if (byte < 0x20) return undefined;
      continue;
    }
    if (byte === 0x22) { inString = true; continue; }
    if (byte === 0x7b) stack.push(0x7d);
    else if (byte === 0x5b) stack.push(0x5d);
    else if (byte === 0x7d || byte === 0x5d) {
      if (stack.pop() !== byte) return undefined;
      if (stack.length === 0) return index + 1;
    }
  }
  return undefined;
}

/** Parse only the complete first lifecycleProjection property. This scanner
 * never searches later keys or parses report-bearing status content. */
export function hasExtensionLifecycleProjectionProperty(bytes: Uint8Array): boolean {
  const bounded = bytes.subarray(0, Math.min(bytes.length, MAX_EXTENSION_LIFECYCLE_HEADER_BYTES));
  let index = 0;
  while (index < bounded.length && [0x20, 0x09, 0x0a, 0x0d].includes(bounded[index]!)) index += 1;
  if (bounded[index++] !== 0x7b) return false;
  while (index < bounded.length && [0x20, 0x09, 0x0a, 0x0d].includes(bounded[index]!)) index += 1;
  const prefix = Buffer.from('"lifecycleProjection', "utf8");
  const available = bounded.subarray(index, Math.min(bounded.length, index + prefix.length));
  if (available.length > 0 && prefix.subarray(0, available.length).every((byte, offset) => byte === available[offset])) {
    if (available.length < prefix.length) return true;
  }
  const end = headerStringEnd(bounded, index);
  if (end === undefined) return false;
  return headerJSON(bounded.subarray(index, end)) === "lifecycleProjection";
}

export function parseExtensionLifecycleProjectionHeader(bytes: Uint8Array): unknown {
  const bounded = bytes.subarray(0, Math.min(bytes.length, MAX_EXTENSION_LIFECYCLE_HEADER_BYTES));
  const limit = bounded.length;
  let index = 0;
  const whitespace = () => { while (index < limit && [0x20, 0x09, 0x0a, 0x0d].includes(bounded[index]!)) index += 1; };
  whitespace();
  if (bounded[index++] !== 0x7b) return undefined;
  whitespace();
  const keyStart = index;
  const keyEnd = headerStringEnd(bounded, index);
  if (keyEnd === undefined || headerJSON(bounded.subarray(keyStart, keyEnd)) !== "lifecycleProjection") return undefined;
  index = keyEnd;
  whitespace();
  if (bounded[index++] !== 0x3a) return undefined;
  whitespace();
  const valueStart = index;
  const valueEnd = headerValueEnd(bounded, valueStart);
  if (valueEnd === undefined || valueEnd > MAX_EXTENSION_LIFECYCLE_HEADER_BYTES) return undefined;
  return headerJSON(bounded.subarray(valueStart, valueEnd));
}

const lifecycleProjectionStates = new Set(["queued", "running", "complete", "failed", "partial", "paused", "stopped", "rejected"]);
// runId/workflowKey are private producer-header identity fields. They never
// widen the public snapshot; id/workflowKey remains the stable workflow row key.
const lifecycleProjectionNodeKeys = new Set(["id", "runId", "workflowKey", "kind", "label", "state", "startedAt", "updatedAt", "endedAt", "sessionFile", "sessionOwnerId", "activity", "hostStep", "children"]);
const lifecycleProjectionActivityKeys = new Set(["state", "currentTool", "lastActivityAt", "currentToolStartedAt", "turnCount", "toolCount"]);
const lifecycleProjectionHostKeys = new Set(["kind", "provider", "role", "state", "verdict", "reasonCode", "detail", "target", "stale", "report"]);

function boundedProjectionTime(value: unknown): boolean {
  return value === undefined || Number.isSafeInteger(value) && (value as number) >= 0;
}

function boundedProjectionString(value: unknown, maximumCharacters: number, required = false, maximumBytes = maximumCharacters * 4): boolean {
  // The producer caps display strings by JavaScript string length, not UTF-8
  // bytes. Keep the Gateway byte bound too, but do not reject valid emoji/CJK
  // values that occupy more than one byte per character.
  return typeof value === "string" && (!required || value.length > 0)
    && value.length <= maximumCharacters && Buffer.byteLength(value) <= maximumBytes && !/[\0]/u.test(value);
}

function validProjectionHost(value: unknown): boolean {
  const host = record(value);
  if (!host || [...Object.keys(host)].some((key) => !lifecycleProjectionHostKeys.has(key))) return false;
  return (host.kind === "command" || host.kind === "ci" || host.kind === "gate")
    && (host.state === "pending" || host.state === "running" || host.state === "done" || host.state === "error" || host.state === "cancelled")
    && (host.verdict === undefined || host.verdict === "pass" || host.verdict === "fail" || host.verdict === "inconclusive")
    && (host.stale === undefined || typeof host.stale === "boolean")
    && (host.provider === undefined || boundedProjectionString(host.provider, 160))
    && (host.role === undefined || boundedProjectionString(host.role, 160))
    && (host.reasonCode === undefined || boundedProjectionString(host.reasonCode, 160))
    && (host.detail === undefined || boundedProjectionString(host.detail, 2_048))
    && (host.target === undefined || boundedProjectionString(host.target, 512))
    && (host.report === undefined || boundedProjectionString(host.report, 512));
}

function validProjectionActivity(value: unknown): boolean {
  const activity = record(value);
  if (!activity || [...Object.keys(activity)].some((key) => !lifecycleProjectionActivityKeys.has(key))) return false;
  return (activity.state === undefined || boundedProjectionString(activity.state, 160))
    && (activity.currentTool === undefined || boundedProjectionString(activity.currentTool, 160))
    && boundedProjectionTime(activity.lastActivityAt) && boundedProjectionTime(activity.currentToolStartedAt)
    && (activity.turnCount === undefined || Number.isSafeInteger(activity.turnCount) && (activity.turnCount as number) >= 0)
    && (activity.toolCount === undefined || Number.isSafeInteger(activity.toolCount) && (activity.toolCount as number) >= 0);
}

function validProjectionNode(value: unknown, depth: number, runId: string, root: boolean): boolean {
  const node = record(value);
  if (!node || [...Object.keys(node)].some((key) => !lifecycleProjectionNodeKeys.has(key))) return false;
  if (!boundedProjectionString(node.id, 160, true) || !boundedProjectionString(node.label, 160, true)
    || (node.runId !== undefined && !boundedProjectionString(node.runId, 256, true, 256))
    || (node.workflowKey !== undefined && !boundedProjectionString(node.workflowKey, 160, true))
    || typeof node.kind !== "string" || !["subagent", "workflow", "step", "host-step"].includes(node.kind)
    || typeof node.state !== "string" || !lifecycleProjectionStates.has(node.state)
    || !boundedProjectionTime(node.startedAt) || !boundedProjectionTime(node.updatedAt) || !boundedProjectionTime(node.endedAt)
    || (node.sessionFile !== undefined && (!boundedProjectionString(node.sessionFile, 4_096, true, 4_096) || typeof node.sessionFile !== "string" || !node.sessionFile.startsWith("/")))
    || (node.sessionOwnerId !== undefined && !boundedProjectionString(node.sessionOwnerId, 256, true, 256))
    || (node.activity !== undefined && !validProjectionActivity(node.activity))
    || (node.hostStep !== undefined && (node.kind !== "host-step" || !validProjectionHost(node.hostStep)))) return false;
  if (root && ((node.runId ?? node.id) !== runId || (node.kind !== "subagent" && node.kind !== "workflow")
    || node.startedAt === undefined || node.updatedAt === undefined)) return false;
  if (node.kind === "host-step" && node.hostStep === undefined) return false;
  // Child completion may be reported without a child-local end timestamp;
  // the producer's canonical root timestamp remains the lifecycle authority.
  // A terminal root still needs an end timestamp because RuntimeSlot's
  // artifact admission requires one for the parent activity.
  if (root && terminalLifecycleStates.has(extensionLifecycleState(node.state)) && node.endedAt === undefined) return false;
  if (node.children !== undefined) {
    if (!Array.isArray(node.children) || node.children.length > 32 || depth >= MAX_DEPTH) return false;
    const childIDs = new Set<string>();
    if (!node.children.every((child) => {
      const childRecord = record(child);
      const childID = typeof childRecord?.id === "string" ? childRecord.id : undefined;
      if (!childID || childIDs.has(childID)) return false;
      childIDs.add(childID);
      return validProjectionNode(child, depth + 1, runId, false);
    })) return false;
  }
  return true;
}

function validLifecycleProjection(value: unknown): value is ExtensionLifecycleProjection {
  const source = record(value);
  const caps = record(source?.caps);
  const omitted = record(source?.omitted);
  const root = record(source?.root);
  if (!source || [...Object.keys(source)].some((key) => !["version", "runId", "toolCallId", "sessionId", "generatedAt", "caps", "omitted", "root"].includes(key))) return false;
  if (source.version !== 1 || !boundedProjectionString(source.runId, 256, true, 256)
    || (source.toolCallId !== undefined && !boundedProjectionString(source.toolCallId, 256, true, 256))
    || (source.sessionId !== undefined && !boundedProjectionString(source.sessionId, 256, true, 256))
    || !Number.isSafeInteger(source.generatedAt) || (source.generatedAt as number) < 0 || !caps || !omitted || !root
    || !validProjectionNode(root, 0, source.runId as string, true)) return false;
  const capValues = [caps.maxRuns, caps.maxChildrenPerNode, caps.maxDepth, caps.maxStringLength, caps.maxSerializedBytes];
  if (capValues.some((entry) => !Number.isSafeInteger(entry) || (entry as number) < 0 || (entry as number) > MAX_EXTENSION_LIFECYCLE_HEADER_BYTES * 8)) return false;
  return Number.isSafeInteger(omitted.runs) && (omitted.runs as number) >= 0
    && Number.isSafeInteger(omitted.children) && (omitted.children as number) >= 0
    && typeof omitted.byteLimitExceeded === "boolean";
}

export function inspectExtensionLifecycleProjection(value: unknown): ExtensionLifecycleProjection | undefined {
  return validLifecycleProjection(value) ? value : undefined;
}

export function lifecycleProjectionArtifact(projection: ExtensionLifecycleProjection): Record<string, unknown> {
  const root = projection.root;
  const activity = record(root.activity);
  const projectionNodeArtifact = (value: unknown): unknown => {
    const node = record(value);
    if (!node) return value;
    const nodeActivity = record(node.activity);
    const workflowKey = typeof node.workflowKey === "string" ? node.workflowKey : node.id;
    const executionRunId = typeof node.runId === "string" ? node.runId : node.id;
    return {
      id: workflowKey,
      workflowKey,
      runId: executionRunId,
      agent: node.label,
      state: node.state,
      status: node.state,
      updatedAt: node.updatedAt,
      startedAt: node.startedAt,
      endedAt: node.endedAt,
      sessionFile: node.sessionFile,
      sessionOwnerId: node.sessionOwnerId,
      ...(nodeActivity ? {
        activityState: nodeActivity.state,
        currentTool: nodeActivity.currentTool,
        currentToolStartedAt: nodeActivity.currentToolStartedAt,
        lastActivityAt: nodeActivity.lastActivityAt,
        turnCount: nodeActivity.turnCount,
        toolCount: nodeActivity.toolCount,
      } : {}),
      ...(Array.isArray(node.children) ? { children: node.children.map(projectionNodeArtifact) } : {}),
      hostStep: node.hostStep,
    };
  };
  const children = Array.isArray(root.children) ? root.children : [];
  const steps = children.map(projectionNodeArtifact);
  return {
    lifecycleArtifactVersion: 3,
    runId: projection.runId,
    ...(projection.toolCallId ? { toolCallId: projection.toolCallId } : {}),
    ...(projection.sessionId ? { sessionId: projection.sessionId } : {}),
    state: root.state,
    mode: root.kind,
    startedAt: root.startedAt,
    lastUpdate: root.updatedAt,
    ...(root.endedAt !== undefined ? {
      endedAt: root.endedAt,
      completedAt: root.endedAt,
      ...(typeof root.startedAt === "number" && typeof root.endedAt === "number" && root.endedAt >= root.startedAt ? { durationMs: root.endedAt - root.startedAt } : {}),
    } : {}),
    ...(activity?.state ? { activityState: activity.state } : {}),
    ...(activity?.currentTool ? { currentTool: activity.currentTool } : {}),
    ...(activity?.currentToolStartedAt ? { currentToolStartedAt: activity.currentToolStartedAt } : {}),
    ...(activity?.lastActivityAt ? { lastActivityAt: activity.lastActivityAt } : {}),
    ...(activity?.turnCount !== undefined ? { turnCount: activity.turnCount } : {}),
    ...(activity?.toolCount !== undefined ? { toolCount: activity.toolCount } : {}),
    ...(projection.omitted.children > 0 || projection.omitted.byteLimitExceeded ? { lifecycleOmissions: { children: projection.omitted.children, byteLimitExceeded: projection.omitted.byteLimitExceeded } } : {}),
    steps,
    lifecycleProjection: projection,
  };
}

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
  if (value === "failed" || value === "partial") return "failed";
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

/** A recovered steering target means this paused producer has been replaced by
 * a new async run. The producer keeps the source artifact resumable for
 * explicit history, but it no longer represents live work. Ambiguous recovery
 * claims fail closed so a malformed status file cannot settle another run. */
export function recoveredReplacementRunId(artifact: Record<string, unknown>): string | undefined {
  const steering = record(artifact.steering);
  const recent = steering && Array.isArray(steering.recent) ? steering.recent : [];
  const replacements = new Set<string>();
  for (const requestValue of recent) {
    const request = record(requestValue);
    const targets = request && Array.isArray(request.targets) ? request.targets : [];
    for (const targetValue of targets) {
      const target = record(targetValue);
      if (target?.state !== "recovered") continue;
      if (typeof target.replacementRunId !== "string" || target.replacementRunId.length === 0
        || Buffer.byteLength(target.replacementRunId) > 256 || /[\\/\0]/u.test(target.replacementRunId)) return undefined;
      replacements.add(target.replacementRunId);
    }
  }
  return replacements.size === 1 ? [...replacements][0] : undefined;
}

/** A paused workflow is logically resumable but owns no live OS work after the
 * producer has durably observed its exact runner and writer process trees exit.
 * This proof affects administrative quiescence only; it never fabricates a
 * terminal workflow lifecycle or success result. */
export function hasObservedPausedProcessTerminal(
  artifact: Record<string, unknown>,
  runId: string,
): boolean {
  if (extensionLifecycleState(artifact.state ?? artifact.status) !== "paused") return false;
  const proof = record(artifact.processTerminal);
  if (!proof || proof.version !== 1 || proof.state !== "observed" || proof.runId !== runId
    || typeof proof.runnerProcessInstanceId !== "string" || proof.runnerProcessInstanceId.length < 1
    || Buffer.byteLength(proof.runnerProcessInstanceId) > 256
    || number(proof.observedAt) === undefined || (proof.observedAt as number) < 0
    || !Array.isArray(proof.instances) || proof.instances.length < 1 || proof.instances.length > 128) return false;
  let matchingRunnerCount = 0;
  for (const candidate of proof.instances) {
    const instance = record(candidate);
    if (!instance || (instance.kind !== "runner" && instance.kind !== "pi-writer")
      || typeof instance.processInstanceId !== "string" || instance.processInstanceId.length < 1
      || Buffer.byteLength(instance.processInstanceId) > 256
      || number(instance.closeObservedAt) === undefined || (instance.closeObservedAt as number) < 0
      || !(instance.exitCode === null || Number.isSafeInteger(instance.exitCode))
      || !(instance.signal === null || typeof instance.signal === "string" && Buffer.byteLength(instance.signal) <= 64)) return false;
    if (instance.kind === "runner") {
      if (instance.processInstanceId !== proof.runnerProcessInstanceId || instance.attempt !== undefined) return false;
      matchingRunnerCount += 1;
      continue;
    }
    const tree = record(instance.processTree);
    if (!Number.isSafeInteger(instance.attempt) || (instance.attempt as number) < 0
      || !tree || tree.state !== "observed" || tree.mechanism !== "posix-process-group"
      || !Number.isSafeInteger(tree.processGroupId) || (tree.processGroupId as number) < 1
      || number(tree.verifiedAt) === undefined || (tree.verifiedAt as number) < 0) return false;
  }
  return matchingRunnerCount === 1;
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
  if (value === "partial") return "failed";
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
    attention: priorTerminal
      ? (prior?.attention ?? "none")
      : explicit === "partial" ? "needsAttention" : attention(details?.attention ?? details?.attentionState),
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

export type ExtensionRunChildIdentityStrategy = "declared" | "piForeground" | "piArtifact";

/** Resolve only producer-authored child identities. The two pi-subagents
 * strategies are selected by RuntimeSlot after proving the installed extension
 * owner or its exact owned lifecycle artifact. Array position is never trusted
 * for a generic extension. */
export function extensionRunChildProducerId(
  value: unknown,
  index: number,
  depth: number,
  strategy: ExtensionRunChildIdentityStrategy,
): string | undefined {
  const source = record(value);
  if (!source) return undefined;
  const progress = progressRecord(source);
  const declared = text(source.childId ?? progress?.childId, 256);
  const runIdentity = text(source.runId ?? source.id ?? source.asyncId ?? progress?.runId ?? progress?.id ?? progress?.asyncId, 256);
  if (strategy === "piArtifact") {
    const workflowKey = text(source.workflowKey ?? progress?.workflowKey, 256);
    const artifactRunIdentity = text(source.runId ?? progress?.runId, 256);
    return declared ?? workflowKey ?? artifactRunIdentity ?? (depth === 0 ? `step:${index}` : undefined);
  }
  if (strategy === "piForeground" && depth === 0) {
    const stableIndex = number(source.index ?? progress?.index) ?? index;
    return stableIndex >= 0 && stableIndex < MAX_CHILDREN_TOTAL
      ? `foreground-index:${stableIndex}`
      : undefined;
  }
  const stableIndex = number(source.index ?? progress?.index);
  return declared ?? runIdentity
    ?? (stableIndex !== undefined && stableIndex >= 0 && stableIndex < MAX_CHILDREN_TOTAL
      ? `foreground-index:${stableIndex}`
      : undefined);
}

function child(
  value: unknown,
  index: number,
  fallbackStatus: ExtensionRunStatus,
  depth: number,
  budget: { remaining: number },
  identityStrategy: ExtensionRunChildIdentityStrategy,
): ExtensionRunChild | undefined {
  if (budget.remaining <= 0) return undefined;
  budget.remaining -= 1;
  const source = record(value);
  if (!source) return undefined;
  const progress = progressRecord(source);
  const sourceActivity = record(source.activity);
  const label = text(progress?.agent ?? source.agent ?? source.label, 256) ?? `Child ${index + 1}`;
  const nestedValues = Array.isArray(source.children)
    ? source.children
    : Array.isArray(source.steps) ? source.steps : [];
  const nested = nestedValues
    .slice(0, MAX_CHILDREN)
    .map((item, nestedIndex) => child(item, nestedIndex, fallbackStatus, depth + 1, budget, identityStrategy))
    .filter((item): item is ExtensionRunChild => Boolean(item));
  const childLifecycle = extensionLifecycleState(progress?.state ?? progress?.status ?? source.state ?? source.status,
    fallbackStatus === "failed" ? "failed" : fallbackStatus === "completed" ? "completed" : "running");
  const childAttention = attention(progress?.attention ?? progress?.attentionState ?? source.attention ?? source.attentionState);
  const task = text(progress?.task ?? source.task ?? source.description ?? source.summary, 2_048);
  const lastActivityAt = isoTime(progress?.lastActivityAt ?? source.lastActivityAt ?? sourceActivity?.lastActivityAt ?? source.updatedAt);
  const currentTool = text(progress?.currentTool ?? source.currentTool ?? sourceActivity?.currentTool, 256);
  const currentToolStartedAt = isoTime(progress?.currentToolStartedAt ?? source.currentToolStartedAt ?? sourceActivity?.currentToolStartedAt);
  const startedAt = isoTime(progress?.startedAt ?? source.startedAt);
  const endedAt = isoTime(progress?.endedAt ?? source.endedAt);
  const currentPath = displayPath(progress?.currentPath ?? source.currentPath ?? sourceActivity?.currentPath);
  const model = text(progress?.model ?? source.model ?? sourceActivity?.model, 256);
  const thinking = text(progress?.thinking ?? source.thinking ?? sourceActivity?.thinking, 64);
  const toolCount = number(progress?.toolCount ?? source.toolCount ?? sourceActivity?.toolCount);
  const turnCount = number(progress?.turnCount ?? source.turnCount ?? sourceActivity?.turnCount);
  const durationMs = number(progress?.durationMs ?? source.durationMs);
  const recentOutput = output(
    progress?.recentOutput
      ?? source.recentOutput
      ?? source.output
      ?? source.error
  );
  const host = record(source.hostStep);
  const provider = text(host?.provider, 160);
  const role = text(host?.role, 160);
  const reasonCode = text(host?.reasonCode, 160);
  const detail = text(host?.detail, 2_048);
  const target = text(host?.target, 512);
  const report = text(host?.report, 512);
  const hostStep: ExtensionRunHostStep | undefined = host
    && (host.kind === "command" || host.kind === "ci" || host.kind === "gate")
    && (host.state === "pending" || host.state === "running" || host.state === "done" || host.state === "error" || host.state === "cancelled")
    ? {
      kind: host.kind,
      state: host.state,
      ...(provider ? { provider } : {}),
      ...(role ? { role } : {}),
      ...(host.verdict === "pass" || host.verdict === "fail" || host.verdict === "inconclusive" ? { verdict: host.verdict } : {}),
      ...(reasonCode ? { reasonCode } : {}),
      ...(detail ? { detail } : {}),
      ...(target ? { target } : {}),
      ...(typeof host.stale === "boolean" ? { stale: host.stale } : {}),
      ...(report ? { report } : {}),
    } : undefined;
  const producerId = extensionRunChildProducerId(source, index, depth, identityStrategy);
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
    ...(startedAt ? { startedAt } : {}),
    ...(endedAt ? { endedAt } : {}),
    ...(currentPath ? { currentPath } : {}),
    ...(model ? { model } : {}),
    ...(thinking ? { thinking } : {}),
    ...(toolCount === undefined ? {} : { toolCount: Math.max(0, Math.round(toolCount)) }),
    ...(turnCount === undefined ? {} : { turnCount: Math.max(0, Math.round(turnCount)) }),
    ...(durationMs === undefined ? {} : { durationMs: Math.max(0, Math.round(durationMs)) }),
    ...(recentOutput ? { output: recentOutput } : {}),
    ...(hostStep ? { hostStep } : {}),
    ...(depth < MAX_DEPTH && nested.length > 0 ? { children: nested } : {}),
  };
}

function detailsFrom(value: unknown): Record<string, unknown> | undefined {
  const root = record(value);
  return record(root?.details) ?? root;
}

/** True for the synchronous child/result contract. RuntimeSlot still proves
 * the installed pi-subagents owner before selecting its positional identity. */
export function usesForegroundSubagentChildIdentity(
  value: unknown,
  options: { allowTerminalResults?: boolean } = {},
): boolean {
  const details = detailsFrom(value);
  if (!details
    || !["single", "parallel", "chain"].includes(text(details.mode, 32) ?? "")
    || extensionRunAsyncDir(value) !== undefined) return false;
  const progress = Array.isArray(details.progress) ? details.progress : [];
  const results = Array.isArray(details.results) ? details.results : [];
  const candidates = progress.length > 0 ? progress : results;
  if (candidates.length === 0 || candidates.length > MAX_CHILDREN) return false;
  const explicitIndexes: Array<number | undefined> = [];
  for (const candidate of candidates) {
    const source = record(candidate);
    const projected = progressRecord(candidate);
    if (!source || !projected || !text(projected.agent ?? source.agent, 256)) return false;
    explicitIndexes.push(number(source.index ?? projected.index));
  }
  if (explicitIndexes.some((index) => index !== undefined)) {
    if (explicitIndexes.some((index) => index === undefined || index < 0 || index >= MAX_CHILDREN_TOTAL)) return false;
    return new Set(explicitIndexes).size === explicitIndexes.length;
  }
  // Terminal foreground results omit index; their bounded producer-owned array
  // order is the same child order used by live progress for this exact tool.
  // Running frames never receive this positional exception.
  return progress.length === 0 && options.allowTerminalResults === true;
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
    /** Gateway-selected identity contract after extension/artifact ownership proof. */
    childIdentityStrategy?: ExtensionRunChildIdentityStrategy;
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
  const childBudget = { remaining: MAX_CHILDREN_TOTAL };
  const children = candidates
    .slice(0, MAX_CHILDREN)
    .map((item, index) => child(item, index, activityStatus, 0, childBudget, base.childIdentityStrategy ?? "declared"))
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
    ...((() => {
      const omission = record(details?.lifecycleOmissions);
      return omission && Number.isSafeInteger(omission.children) && (omission.children as number) >= 0 && typeof omission.byteLimitExceeded === "boolean"
        ? { lifecycleOmissions: { children: omission.children as number, byteLimitExceeded: omission.byteLimitExceeded } }
        : {};
    })()),
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
