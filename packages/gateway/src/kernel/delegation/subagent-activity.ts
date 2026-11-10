import * as activityProjection from "../projection/activity.js";
import { createHash } from "node:crypto";
import { DELEGATED_SUPERVISOR_TOOL_NAME } from "./delegated-provider.js";

import { GatewayError } from "../../errors.js";
import type { HomeTaskSubagentRun } from "./task-subagents.js";
import type { ExtensionRunActivity, ExtensionRunChild, ExtensionToolOrigin } from "../../protocol/types.js";
import { safeJson } from "../projection/projection.js";
import { admitExtensionRunActivity, extensionActivityId, extensionActivityStatusFromTool, extensionLifecycleState, extensionRunAsyncDir, hasForegroundSubagentRunActivity, hasStructuredExtensionRunActivity, projectExtensionRunActivity, usesForegroundSubagentChildIdentity, type ExtensionRunChildIdentityStrategy } from "../projection/extension-run-projection.js";
import { EXTENSION_ACTIVITY_RECEIPT_TYPE, extensionActivityReceipts, extensionReceiptActivity, makeExtensionActivityReceipt } from "../receipts/extension-activity-history.js";
import { type ActivityExpiryFrame, type ActivityVisibility } from "../../sessions/extension-activity-recency.js";
import type { OwnedTurnOwner } from "./owned-turn-owner.js";


export type CanonicalExtensionRunFact = {
  toolCallId?: string;
  asyncDir?: string;
  terminal: boolean;
  ambiguous: boolean;
  recoveredReplacementRunId?: string;
  recoveredSourceRunId?: string;
};


export function updateNestedExtensionActivity(turns: OwnedTurnOwner,
  event: { toolCallId: string; toolName: string },
  status: "running" | "completed" | "failed",
  value?: unknown,
): void {
  const now = new Date().toISOString();
  const startedAt = turns.extensionActivities.get(event.toolCallId)?.startedAt ?? now;
  const activity = updateExtensionActivity(turns,
    event.toolCallId,
    event.toolName,
    turns.operations.extensionToolOrigin(event.toolName),
    status,
    startedAt,
    now,
    value,
    status === "running" ? undefined : now,
    undefined,
    false,
  );
  if (activity) turns.operations.publishProcessesForToolCall(event.toolCallId);
}


export function liveActivitySubagentRuns(turns: OwnedTurnOwner, activity: ExtensionRunActivity): HomeTaskSubagentRun[] {
  if (extensionActivityOwnsOwnLiveWork(turns, activity)) return [{
    runId: activity.runId ?? activity.toolCallId,
    agent: activity.children[0]?.label ?? activity.title,
    state: activity.lifecycle?.state ?? activity.status,
    startedAt: activity.startedAt,
    lastActivityAt: activity.lastActivityAt ?? null,
  }];
  const detached = activity.runId === undefined ? undefined : turns.extensionRunOwnership.get(activity.runId)?.detachedChildKeys;
  return liveWorkflowChildren(turns, activity).flatMap(child => {
    const runId = detached?.get(child.producerId ?? child.id);
    return runId === undefined ? [] : [{ runId, agent: child.label, state: child.lifecycle ?? child.status,
      startedAt: child.startedAt ?? activity.startedAt, lastActivityAt: child.lastActivityAt ?? null }];
  });
}


export function extensionActivityOwnsLiveWork(turns: OwnedTurnOwner, activity: ExtensionRunActivity): boolean {
  return extensionActivityOwnsOwnLiveWork(turns, activity) || liveWorkflowChildren(turns, activity).length > 0;
}


function extensionActivityOwnsOwnLiveWork(turns: OwnedTurnOwner, activity: ExtensionRunActivity): boolean {
  if (!delegatedLifecycleOwner(turns, activity)) return false;
  const state = activity.lifecycle?.state;
  if (state === "queued" || state === "running") return true;
  if (state !== "paused") return false;
  return pausedProcessSettlementAt(turns, activity) === undefined;
}


function delegatedLifecycleOwner(turns: OwnedTurnOwner, activity: ExtensionRunActivity): boolean {
  const ownerId = activity.source.owner?.id;
  if (ownerId === undefined || ownerId === turns.subagentExtensionOrigin().owner?.id) return true;
  const binding = activity.runId === undefined ? undefined : turns.extensionRunOwnership.get(activity.runId);
  return binding?.toolCallId === activity.toolCallId && binding.asyncDir !== undefined;
}


function liveWorkflowChildren(turns: OwnedTurnOwner, activity: ExtensionRunActivity): ExtensionRunChild[] {
  const detached = activity.runId === undefined ? undefined : turns.extensionRunOwnership.get(activity.runId)?.detachedChildKeys;
  if (!detached?.size) return [];
  return activity.children.filter(child => {
    const state = child.lifecycle ?? child.status;
    return detached.has(child.producerId ?? child.id) && (state === "queued" || state === "running" || state === "paused");
  });
}


export function extensionActivityWatchRequired(turns: OwnedTurnOwner, activity: ExtensionRunActivity): boolean {
  return activity.status === "running" || liveWorkflowChildren(turns, activity).length > 0;
}


export function pausedProcessSettlementAt(turns: OwnedTurnOwner, activity: ExtensionRunActivity): string | undefined {
  if (activity.lifecycle?.state !== "paused" || !activity.runId) return undefined;
  const ownership = turns.extensionRunOwnership.get(activity.runId);
  return ownership?.toolCallId === activity.toolCallId ? ownership.pausedProcessQuiescentAt : undefined;
}


export function hydrateCanonicalExtensionActivities(turns: OwnedTurnOwner): void {
  const branch = turns.operations.sessionManager.getBranch();
  const receipts = extensionActivityReceipts(branch, turns.operations.id);
  const receiptToolCallIDs = new Set(receipts.map(({ receipt }) => receipt.toolCallId));
  for (const { receipt } of receipts) {
    const activity = extensionReceiptActivity(receipt);
    const visibility = upsertExtensionActivity(turns, activity).visibility;
    if (visibility === "current" || visibility === "recent") {
      turns.extensionActivities.set(activity.toolCallId, activity);
    }
  }
  for (const entry of branch) {
    if (entry.type !== "message" || entry.message.role !== "toolResult"
      || receiptToolCallIDs.has(entry.message.toolCallId)) continue;
    const toolName = entry.message.toolName;
    const origin = turns.operations.extensionToolOrigin(toolName);
    if (!origin) continue;
    const details = entry.message.details;
    if (!details || typeof details !== "object" || Array.isArray(details)) continue;
    const state = extensionLifecycleState((details as Record<string, unknown>).state ?? (details as Record<string, unknown>).status);
    if (!["completed", "failed", "stopped", "rejected"].includes(state)) continue;
    updateExtensionActivity(turns,
      entry.message.toolCallId,
      toolName,
      origin,
      state === "failed" ? "failed" : "completed",
      new Date(entry.message.timestamp).toISOString(),
      new Date(entry.message.timestamp).toISOString(),
      details,
      new Date(entry.message.timestamp).toISOString(),
    );
  }
}


export function upsertExtensionActivity(turns: OwnedTurnOwner, activity: ExtensionRunActivity): ActivityVisibility {
  const visibility = turns.operations.dependencies.extensionActivityRecency.upsert(activity);
  if (visibility.accepted) {
    turns.liveActivityRevision += 1;
    turns.extensionActivityAsOf = new Date().toISOString();
    turns.operations.syncSubagentProcesses(activity);
    turns.operations.workerSettlement.publish("detached");
  }
  return visibility;
}


export function trimExtensionActivities(turns: OwnedTurnOwner): void {
  while (turns.extensionActivities.size > 64) {
    const candidates = [...turns.extensionActivities.entries()];
    const ranked = candidates.sort((left, right) => {
      const bucket = (activity: ExtensionRunActivity): number => {
        const visibility = activityProjection.extensionActivityVisibility(turns.operations.activitySource(), activity);
        return visibility === "recent" || visibility === "historical" ? 0 : 1;
      };
      return bucket(left[1]) - bucket(right[1]) || left[1].updatedAt.localeCompare(right[1].updatedAt);
    });
    const oldest = ranked[0]?.[0];
    if (!oldest) break;
    turns.stopExtensionActivityWatcher(oldest);
    turns.extensionActivities.delete(oldest);
    turns.forgetExtensionArtifactReads(oldest);
    turns.extensionArtifactMissingSince.delete(oldest);
    turns.operations.replaceProcessesForToolCall(oldest, []);
    for (const [runId, binding] of turns.extensionRunOwnership) {
      if (binding.toolCallId === oldest) turns.extensionRunOwnership.delete(runId);
    }
  }
}


export function canonicalExtensionRunFacts(turns: OwnedTurnOwner): Map<string, CanonicalExtensionRunFact> {
  const facts = new Map<string, CanonicalExtensionRunFact>();
  const recoveryReceipts: Array<{ sourceRunId: string; replacementRunId: string; toolCallId: string }> = [];
  const boundedRunId = (value: unknown): value is string => typeof value === "string"
    && value.length > 0 && Buffer.byteLength(value) <= 256 && !/[\\/\0]/u.test(value);
  for (const entry of turns.operations.runtime.session.sessionManager.getEntries()) {
    if (entry.type !== "message") continue;
    const message = entry.message as unknown as Record<string, unknown>;
    if (message.role !== "toolResult") continue;
    const toolCallId = typeof message.toolCallId === "string" ? message.toolCallId : undefined;
    const toolName = typeof message.toolName === "string" ? message.toolName : undefined;
    if (!toolCallId || !toolName || toolName === DELEGATED_SUPERVISOR_TOOL_NAME || !turns.operations.extensionToolOrigin(toolName)) continue;
    const details = message.details !== null && typeof message.details === "object" && !Array.isArray(message.details)
      ? message.details as Record<string, unknown>
      : undefined;
    const steering = details?.steering !== null && typeof details?.steering === "object" && !Array.isArray(details.steering)
      ? details.steering as Record<string, unknown>
      : undefined;
    const recoveryTargets = steering && Array.isArray(steering.targets) ? steering.targets : [];
    const recoveryTarget = recoveryTargets.find((value) => value !== null && typeof value === "object" && !Array.isArray(value)
      && (value as Record<string, unknown>).state === "recovered") as Record<string, unknown> | undefined;
    const sourceRunId = steering && boundedRunId(steering.sourceRunId) ? steering.sourceRunId : undefined;
    const replacementRunId = steering && boundedRunId(steering.replacementRunId) ? steering.replacementRunId : undefined;
    if (turns.isForegroundSubagentTool(toolName, turns.operations.extensionToolOrigin(toolName)) && details?.mode === "management"
      && steering?.state === "recovered" && steering.deliveryStatus === "delivered"
      && sourceRunId && replacementRunId && sourceRunId !== replacementRunId
      && recoveryTarget && recoveryTarget.replacementRunId === replacementRunId) {
      recoveryReceipts.push({ sourceRunId, replacementRunId, toolCallId });
    }
    const runId = boundedRunId(details?.runId)
      ? details.runId
      : boundedRunId(details?.asyncId) ? details.asyncId : undefined;
    if (!runId) continue;
    const explicitTerminal = details?.state === "failed"
      || details?.state === "complete"
      || details?.state === "completed"
      || details?.state === "stopped"
      || details?.status === "failed"
      || details?.status === "complete"
      || details?.status === "completed"
      || details?.status === "stopped";
    const detached = typeof details?.asyncId === "string"
      && (!Array.isArray(details.results) || details.results.length === 0)
      && !explicitTerminal;
    const asyncDir = typeof details?.asyncDir === "string" ? details.asyncDir : undefined;
    const terminal = !detached && (explicitTerminal || typeof details?.runId === "string");
    const previous = facts.get(runId);
    if (!previous) {
      facts.set(runId, { toolCallId, ...(asyncDir ? { asyncDir } : {}), terminal, ambiguous: false });
    } else if (previous.ambiguous) {
      previous.terminal ||= terminal;
    } else if (previous.toolCallId === toolCallId) {
      if (previous.asyncDir && asyncDir && previous.asyncDir !== asyncDir) previous.ambiguous = true;
      if (!previous.asyncDir && asyncDir) previous.asyncDir = asyncDir;
      previous.terminal ||= terminal;
    } else if (previous.toolCallId?.startsWith("subagent:") && !toolCallId.startsWith("subagent:")) {
      previous.toolCallId = toolCallId;
      if (!previous.asyncDir && asyncDir) previous.asyncDir = asyncDir;
      previous.terminal ||= terminal;
    } else if (toolCallId.startsWith("subagent:") && previous.toolCallId && !previous.toolCallId.startsWith("subagent:")) {
      previous.terminal ||= terminal;
    } else {
      delete previous.toolCallId;
      previous.ambiguous = true;
      previous.terminal ||= terminal;
    }
  }
  for (const receipt of recoveryReceipts) {
    const source = facts.get(receipt.sourceRunId);
    if (!source || source.ambiguous || !source.toolCallId) continue;
    const syntheticToolCallId = `subagent:recovery:${createHash("sha256").update(`${receipt.toolCallId}\\0${receipt.sourceRunId}\\0${receipt.replacementRunId}`).digest("hex").slice(0, 48)}`;
    const replacement = facts.get(receipt.replacementRunId);
    if (replacement && (!replacement.toolCallId || replacement.toolCallId !== syntheticToolCallId || replacement.recoveredSourceRunId !== receipt.sourceRunId)) {
      replacement.ambiguous = true;
      delete replacement.toolCallId;
      continue;
    }
    if (source.recoveredReplacementRunId && source.recoveredReplacementRunId !== receipt.replacementRunId) {
      source.ambiguous = true;
      delete source.recoveredReplacementRunId;
      continue;
    }
    source.recoveredReplacementRunId = receipt.replacementRunId;
    facts.set(receipt.replacementRunId, {
      ...(replacement ?? {}),
      toolCallId: syntheticToolCallId,
      terminal: replacement?.terminal ?? false,
      ambiguous: replacement?.ambiguous ?? false,
      recoveredSourceRunId: receipt.sourceRunId,
    });
  }
  return facts;
}


export function appendExtensionActivityReceipt(turns: OwnedTurnOwner, activity: ExtensionRunActivity): Promise<void> {
  if (!activity.lifecycle || !["completed", "failed", "stopped", "rejected"].includes(activity.lifecycle.state)) return Promise.resolve();
  const receipt = makeExtensionActivityReceipt(activity, turns.operations.id);
  const activityId = receipt?.activityId ?? activity.activityId ?? activity.toolCallId;
  const owner = turns.extensionReceiptOwners.get(activityId);
  if (!receipt) {
    turns.releaseExtensionReceiptOwnership(activityId, owner);
    return Promise.resolve();
  }
  const existingWrite = turns.extensionReceiptWrites.get(receipt.activityId);
  if (existingWrite) return existingWrite;
  if (!owner) return Promise.reject(new GatewayError("busy", "Extension receipt ownership is unavailable", true));
  const write = turns.operations.runPersistence.trackOwnershipWrite(() => turns.operations.lane.run(() => turns.operations.runPersistence.retryDurableWrite(
    `extension-receipt:${receipt.activityId}`,
    async () => {
        const manager = turns.operations.runtime.session.sessionManager;
        turns.operations.persistVerifiedCustomEntry({
          manager,
          describe: "extension activity receipt",
          existing: () => extensionActivityReceipts(manager.getEntries(), turns.operations.id)
            .some((record) => record.receipt.activityId === receipt.activityId) ? "matching" : "absent",
          append: () => {
            manager.appendCustomEntry(EXTENSION_ACTIVITY_RECEIPT_TYPE, receipt);
            turns.operations.revision += 1;
            turns.operations.scheduleSnapshot();
          },
        });
    },
  )), owner);
  turns.extensionReceiptWrites.set(receipt.activityId, write);
  void write.then(() => {
    if (turns.extensionReceiptWrites.get(receipt.activityId) === write) turns.extensionReceiptWrites.delete(receipt.activityId);
    turns.releaseExtensionReceiptOwnership(receipt.activityId, owner);
  }, () => {
    owner.markSuspect();
  });
  return write;
}


export function updateExtensionActivity(turns: OwnedTurnOwner,
  toolCallId: string,
  toolName: string,
  extensionOrigin: ExtensionToolOrigin | undefined,
  status: "running" | "completed" | "failed",
  startedAt: string,
  updatedAt: string,
  value: unknown,
  completedAt?: string,
  durationMs?: number,
  persistReceipt = true,
): ExtensionRunActivity | undefined {
  if (!extensionOrigin || toolName === DELEGATED_SUPERVISOR_TOOL_NAME) return undefined;
  const current = turns.extensionActivities.get(toolCallId);
  const foregroundSubagentOwner = turns.isForegroundSubagentTool(toolName, extensionOrigin);
  const admittedForegroundSubagent = foregroundSubagentOwner && hasForegroundSubagentRunActivity(value);
  const childIdentityStrategy: ExtensionRunChildIdentityStrategy = foregroundSubagentOwner
    && current?.mode !== "asynchronous"
    && usesForegroundSubagentChildIdentity(value, { allowTerminalResults: status !== "running" })
    ? "piForeground" : "declared";
  if (!current && !hasStructuredExtensionRunActivity(value) && !admittedForegroundSubagent) return undefined;
  const activityKey = current?.activityId ?? extensionActivityId(turns.operations.runtime.session.sessionManager.getSessionId(), toolCallId);
  const terminalStates = ["completed", "failed", "stopped", "rejected"];
  if (current?.lifecycle && terminalStates.includes(current.lifecycle.state)) {
    if (status === "running") return current;
    const requestedTerminal = status === "failed" ? "failed" : "completed";
    if (requestedTerminal !== current.lifecycle.state) return current;
    if (persistReceipt) void appendExtensionActivityReceipt(turns, current).catch(() => {});
    return current;
  }
  const sequence = (turns.extensionActivitySequences.get(activityKey) ?? current?.lifecycle?.sequence ?? 0) + 1;
  turns.extensionActivitySequences.set(activityKey, sequence);
  const requestedAsyncDir = extensionRunAsyncDir(value);
  const asyncDir = requestedAsyncDir ? turns.canonicalExtensionArtifactDirectory(requestedAsyncDir) : undefined;
  const invalidDetachedDirectory = requestedAsyncDir !== undefined && asyncDir === undefined;
  const derivedStatus = extensionActivityStatusFromTool(value, status, childIdentityStrategy === "piForeground");
  const terminal = invalidDetachedDirectory ? true : derivedStatus.terminal;
  const reportedTerminal = derivedStatus.reportedTerminal;
  const effectiveStatus = invalidDetachedDirectory ? (status === "failed" ? "failed" : "completed") : derivedStatus.status;
  const observedAt = new Date().toISOString();
  const terminalAt = terminal ? current?.lifecycle?.terminalAt ?? observedAt : current?.lifecycle?.terminalAt;
  const recentUntil = terminalAt ? new Date(Date.parse(terminalAt) + 900_000).toISOString() : undefined;
  const activity = turns.operations.childSessionAdmission.attach(projectExtensionRunActivity(value, {
    id: toolCallId,
    activityId: activityKey,
    toolCallId,
    source: extensionOrigin,
    title: turns.operations.toolLabel(toolName) ?? toolName,
    ...(asyncDir ? { mode: "asynchronous" } : {}),
    status: current?.lifecycle && terminalStates.includes(current.lifecycle.state) ? current.status : effectiveStatus,
    authoritativeStatus: invalidDetachedDirectory || reportedTerminal || Boolean(current?.lifecycle && terminalStates.includes(current.lifecycle.state)),
    startedAt,
    updatedAt,
    ...(terminal && completedAt ? { completedAt } : {}),
    ...(!terminal || durationMs === undefined ? {} : { durationMs }),
    ...(current ? { previous: current } : {}),
    sequence,
    observedAt,
    ...(terminalAt ? { terminalAt } : {}),
    ...(recentUntil ? { recentUntil } : {}),
    childIdentityStrategy,
  }), value, childIdentityStrategy);
  if (admitExtensionRunActivity(current, activity) === current) return current;
  const terminalReceiptOwner = terminal && persistReceipt ? turns.claimExtensionReceiptOwnership(activityKey) : undefined;
  if (terminal && persistReceipt && !terminalReceiptOwner) return current;
  if (activity.runId && !turns.bindExtensionRunOwnership(activity.runId, {
    toolCallId,
    ...(asyncDir === undefined ? {} : { asyncDir }),
    terminal: activity.status !== "running",
  })) {
    turns.releaseExtensionReceiptOwnership(activityKey, terminalReceiptOwner);
    return current;
  }
  const ownership = activity.runId ? turns.extensionRunOwnership.get(activity.runId) : undefined;
  const syntheticToolCallId = ownership?.toolCallId?.startsWith("subagent:")
    ? ownership.toolCallId
    : undefined;
  const synthetic = syntheticToolCallId && syntheticToolCallId !== toolCallId
    ? turns.extensionActivities.get(syntheticToolCallId)
    : undefined;
  if (synthetic) {
    turns.stopExtensionActivityWatcher(syntheticToolCallId!);
    turns.extensionActivities.delete(syntheticToolCallId!);
    const merged = turns.operations.childSessionAdmission.attach(projectExtensionRunActivity(value, {
      id: toolCallId,
      activityId: activityKey,
      toolCallId,
      source: extensionOrigin,
      title: turns.operations.toolLabel(toolName) ?? toolName,
      ...(asyncDir ? { mode: "asynchronous" } : {}),
      status,
      startedAt,
      updatedAt,
      ...(completedAt ? { completedAt } : {}),
      ...(durationMs === undefined ? {} : { durationMs }),
      sequence,
      observedAt,
      ...(terminalAt ? { terminalAt } : {}),
      ...(recentUntil ? { recentUntil } : {}),
      childIdentityStrategy,
      previous: current
        ? {
            ...synthetic,
            ...current,
            children: current.children.length > 0 ? current.children : synthetic.children,
          }
        : synthetic,
    }), value, childIdentityStrategy);
    turns.extensionActivities.delete(toolCallId);
    turns.extensionActivities.set(toolCallId, merged);
    upsertExtensionActivity(turns, merged);
  } else {
    turns.extensionActivities.delete(toolCallId);
    turns.extensionActivities.set(toolCallId, activity);
    upsertExtensionActivity(turns, activity);
  }
  const retainedActivity = turns.extensionActivities.get(toolCallId)!;
  trimExtensionActivities(turns);
  if (asyncDir && retainedActivity.status === "running") turns.startExtensionActivityWatcher(toolCallId, asyncDir);
  if (retainedActivity.status !== "running") {
    turns.stopExtensionActivityWatcher(toolCallId);
    if (persistReceipt) void appendExtensionActivityReceipt(turns, retainedActivity).catch((error) => turns.operations.emit("session.extensionError", safeJson(error)));
  }
  return retainedActivity;
}


export function publishExtensionActivity(turns: OwnedTurnOwner, activity: ExtensionRunActivity): void {
  turns.operations.noteDashboardActivity(activity.updatedAt);
  if (turns.operations.hasDetachedDashboardWork() && !turns.operations.activityHeartbeat) turns.operations.startActivityHeartbeat();
  turns.operations.emit("session.extensionActivity", safeJson({
    activity: activityProjection.extensionActivityWire(turns.operations.activitySource(), activity),
    liveActivityRevision: turns.liveActivityRevision,
    extensionActivityAsOf: turns.extensionActivityAsOf,
  }));
  turns.operations.publishProcessesForToolCall(activity.toolCallId);
  turns.operations.workerSettlement.publish("detached");
  turns.operations.publishSummary();
  if (!turns.operations.hasCurrentDashboardWork()) turns.operations.stopActivityHeartbeat();
}


export function onExtensionActivityExpiry(turns: OwnedTurnOwner, frame: ActivityExpiryFrame): void {
  if (turns.operations.disposed) return;
  let removed = false;
  for (const [toolCallId, activity] of turns.extensionActivities) {
    const key = activity.activityId ?? activity.id;
    if (!frame.expiredActivityIds.includes(key)) continue;
    turns.extensionActivities.delete(toolCallId);
    turns.forgetExtensionArtifactReads(toolCallId);
    removed = true;
  }
  if (!removed) return;
  turns.liveActivityRevision += 1;
  turns.extensionActivityAsOf = frame.asOf;
  turns.operations.revision += 1;
  turns.operations.publishSnapshot();
}