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


/** Status, report admission and Stop select the same exact executions. A completed
 * workflow is not stoppable: its live detached children must be named instead. */
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


/** One liveness rule for detached extension work, shared by dashboard
 * accounting, administrative drain and task settlement. An async run is live
 * while it is, and also while a workflow child it launched is: a workflow can
 * complete while its detached children keep running. */
export function extensionActivityOwnsLiveWork(turns: OwnedTurnOwner, activity: ExtensionRunActivity): boolean {
  return extensionActivityOwnsOwnLiveWork(turns, activity) || liveWorkflowChildren(turns, activity).length > 0;
}


export function extensionActivityOwnsOwnLiveWork(turns: OwnedTurnOwner, activity: ExtensionRunActivity): boolean {
  const state = activity.lifecycle?.state;
  if (state === "queued" || state === "running") return true;
  if (state !== "paused") return false;
  return pausedProcessSettlementAt(turns, activity) === undefined;
}


/** Live runner-backed workflow children of a run, in the states of the run itself.
 * A child's state is its lifecycle when projected, else its coarse status. Their
 * exact-owned paused-process proof is admitted with the detached-child binding,
 * never copied from untrusted tool-result presentation fields. */
export function liveWorkflowChildren(turns: OwnedTurnOwner, activity: ExtensionRunActivity): ExtensionRunChild[] {
  const detached = activity.runId === undefined ? undefined : turns.extensionRunOwnership.get(activity.runId)?.detachedChildKeys;
  if (!detached?.size) return [];
  return activity.children.filter(child => {
    const state = child.lifecycle ?? child.status;
    return detached.has(child.producerId ?? child.id) && (state === "queued" || state === "running" || state === "paused");
  });
}


/** A run stays observed while it is running or a runner-backed child is live, so the
 * child's own status change still reaches the projection and the join. */
export function extensionActivityWatchRequired(turns: OwnedTurnOwner, activity: ExtensionRunActivity): boolean {
  return activity.status === "running" || liveWorkflowChildren(turns, activity).length > 0;
}


/** The Gateway-admitted settlement instant of one paused activity, recorded
 * when its artifact frame proved every process had exited. */
export function pausedProcessSettlementAt(turns: OwnedTurnOwner, activity: ExtensionRunActivity): string | undefined {
  if (activity.lifecycle?.state !== "paused" || !activity.runId) return undefined;
  const ownership = turns.extensionRunOwnership.get(activity.runId);
  return ownership?.toolCallId === activity.toolCallId ? ownership.pausedProcessQuiescentAt : undefined;
}


/** Rebuild terminal extension cards from canonical receipts before backfilling
 * tool results. This preserves the canonical terminalAt across a restart;
 * receipts are authoritative when the disposable result projection is rebuilt. */
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


/** Evict disposable rows by bucket, never allowing a recent terminal row to
 * displace queued/running/paused work from the 64-entry runtime map. */
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
    turns.extensionArtifactMissingSince.delete(oldest);
    turns.operations.replaceProcessesForToolCall(oldest, []);
    for (const [runId, binding] of turns.extensionRunOwnership) {
      if (binding.toolCallId === oldest) turns.extensionRunOwnership.delete(runId);
    }
  }
}


/** Canonical JSONL facts are the only reacquisition evidence for an
 * artifact-created activity. Runtime maps are intentionally disposable. */
export function canonicalExtensionRunFacts(turns: OwnedTurnOwner): Map<string, CanonicalExtensionRunFact> {
  const facts = new Map<string, CanonicalExtensionRunFact>();
  const recoveryReceipts: Array<{ sourceRunId: string; replacementRunId: string; toolCallId: string }> = [];
  const boundedRunId = (value: unknown): value is string => typeof value === "string"
    && value.length > 0 && Buffer.byteLength(value) <= 256 && !/[\\/\0]/u.test(value);
  for (const entry of turns.operations.runtime.session.sessionManager.getEntries()) {
    if (entry.type !== "message") continue;
    const message = entry.message as unknown as Record<string, unknown>;
    if (message.role !== "toolResult") continue;
    // Details.runId is untrusted presentation data. Require the canonical
    // tool identity and prove that its tool is currently extension-owned;
    // otherwise arbitrary tool results must not claim an artifact run.
    const toolCallId = typeof message.toolCallId === "string" ? message.toolCallId : undefined;
    const toolName = typeof message.toolName === "string" ? message.toolName : undefined;
    // Supervisor receipts reference the target run; they never launch or own
    // it. Counting a reply as a second owner blocks its terminal artifact.
    if (!toolCallId || !toolName || toolName === DELEGATED_SUPERVISOR_TOOL_NAME || !turns.operations.extensionToolOrigin(toolName)) continue;
    const details = message.details !== null && typeof message.details === "object" && !Array.isArray(message.details)
      ? message.details as Record<string, unknown>
      : undefined;
    // Auto-recovery returns a management receipt, not a second launcher
    // result. It can authorize only the exact provider-owned source run and
    // replacement pair; supervisor references never enter this path.
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
    // An async launcher acknowledgement has no child results and no explicit
    // terminal state; it remains live after the foreground tool returns.
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
      // Distinct real tool calls sharing a runId are ambiguous. Retaining an
      // arbitrary last writer would let a foreign artifact rebind the first.
      delete previous.toolCallId;
      previous.ambiguous = true;
      previous.terminal ||= terminal;
    }
  }
  // Bind an auto-recovery receipt to the original canonical launch. The
  // replacement has no distinct toolResult, so its artifact receives a
  // stable synthetic owner derived from this exact handoff, never from its
  // name/path alone. Conflicting handoffs fail closed on both runs.
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
        turns.operations.persistVerifiedCustomEntry({
          describe: "extension activity receipt",
          existing: () => extensionActivityReceipts(turns.operations.runtime.session.sessionManager.getEntries(), turns.operations.id)
            .some((record) => record.receipt.activityId === receipt.activityId) ? "matching" : "absent",
          append: () => {
            turns.operations.runtime.session.sessionManager.appendCustomEntry(EXTENSION_ACTIVITY_RECEIPT_TYPE, receipt);
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
    // Retain and identify the exact failed owner; drain recovery is process replacement.
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
  // The native supervisor is ordinary control-tool activity, not a new
  // delegated execution, even when its receipt includes the target runId.
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
    // Terminal admission is a Gateway fact: neither wall-clock order nor a
    // producer's later contradictory terminal may replace it.
    if (status === "running") return current;
    const requestedTerminal = status === "failed" ? "failed" : "completed";
    if (requestedTerminal !== current.lifecycle.state) return current;
    if (persistReceipt) void appendExtensionActivityReceipt(turns, current).catch(() => {});
    return current;
  }
  const sequence = (turns.extensionActivitySequences.get(activityKey) ?? current?.lifecycle?.sequence ?? 0) + 1;
  turns.extensionActivitySequences.set(activityKey, sequence);
  // Returning an async launch receipt completes only the outer tool call. The
  // delegated run remains current until its lifecycle artifact reaches a
  // terminal state; treating this acknowledgement as terminal made pills
  // flash directly into Recently Finished with a near-zero duration.
  const requestedAsyncDir = extensionRunAsyncDir(value);
  const asyncDir = requestedAsyncDir ? turns.canonicalExtensionArtifactDirectory(requestedAsyncDir) : undefined;
  const invalidDetachedDirectory = requestedAsyncDir !== undefined && asyncDir === undefined;
  const derivedStatus = extensionActivityStatusFromTool(value, status);
  // An async acknowledgement without an admitted observable directory cannot
  // author a detached live row. Settle the launcher projection instead of
  // creating unwatched runtime/drain ownership.
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
  // A synchronous result can be the first lifecycle payload carrying runId.
  // Re-key any artifact-created synthetic row to the real Pi tool call.
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


/** Lifecycle updates are compact presentation deltas, not transcript
 * changes. Avoid rebuilding and sending the canonical transcript for every
 * status artifact heartbeat. */
export function publishExtensionActivity(turns: OwnedTurnOwner, activity: ExtensionRunActivity): void {
  // The projection's `asOf` is refresh time, not execution recency. Artifact
  // reconciliation can publish an old terminal run during a cold open; use
  // the activity's own timestamp so observation alone cannot refresh history.
  turns.operations.noteDashboardActivity(activity.updatedAt);
  if (turns.operations.hasDetachedDashboardWork() && !turns.operations.activityHeartbeat) turns.operations.startActivityHeartbeat();
  turns.operations.emit("session.extensionActivity", safeJson({
    activity: activityProjection.extensionActivityWire(turns.operations.activitySource(), activity),
    liveActivityRevision: turns.liveActivityRevision,
    extensionActivityAsOf: turns.extensionActivityAsOf,
  }));
  turns.operations.publishProcessesForToolCall(activity.toolCallId);
  turns.operations.workerSettlement.publish("detached");
  // Detached lifecycle updates do not rebuild the full transcript snapshot,
  // but they are authoritative live catalog activity and must reorder rows.
  turns.operations.publishSummary();
  if (!turns.operations.hasCurrentDashboardWork()) turns.operations.stopActivityHeartbeat();
}


/** Recency is the sole expiry owner. At the wall-clock boundary remove the
 * disposable ambient rows, advance this slot's revision, and publish one
 * authoritative snapshot rather than waiting for a client request. */
export function onExtensionActivityExpiry(turns: OwnedTurnOwner, frame: ActivityExpiryFrame): void {
  if (turns.operations.disposed) return;
  let removed = false;
  for (const [toolCallId, activity] of turns.extensionActivities) {
    const key = activity.activityId ?? activity.id;
    if (!frame.expiredActivityIds.includes(key)) continue;
    turns.extensionActivities.delete(toolCallId);
    removed = true;
  }
  if (!removed) return;
  turns.liveActivityRevision += 1;
  turns.extensionActivityAsOf = frame.asOf;
  turns.operations.revision += 1;
  turns.operations.publishSnapshot();
}