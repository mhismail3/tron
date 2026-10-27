import type { ExtensionArtifactDiscoveryOutcome } from "../../sessions/extension-artifact-discovery.js";
import { resolve } from "node:path";
import type { ExtensionRunActivity, ExtensionRunChild } from "../../protocol/types.js";
import { safeJson } from "../projection/projection.js";
import { EXTENSION_LIFECYCLE_ARTIFACT_VERSION, admitExtensionRunActivity, extensionActivityId, extensionLifecycleState, observedPausedProcessTerminalAt, recoveredReplacementClaim, inspectExtensionLifecycleArtifact, normalizeExtensionArtifact, projectExtensionRunActivity } from "../projection/extension-run-projection.js";
import { type ArtifactReceiptOwner } from "./owned-turn-runtime.js";
import type { OwnedTurnOwner } from "./owned-turn-owner.js";
import { detachedWorkflowChildKeys, isEmbeddedLifecycleArtifact, preserveEmbeddedLifecycleMarker, OversizedExtensionArtifactError, ForeignExtensionArtifactSessionError, extensionArtifactReadFailureReason } from "./subagent-artifact-status.js";
import { type CanonicalExtensionRunFact, extensionActivityWatchRequired, upsertExtensionActivity, trimExtensionActivities, canonicalExtensionRunFacts, appendExtensionActivityReceipt, publishExtensionActivity } from "./subagent-activity.js";

function rediscoveredTerminalAt(state: string, producerEndedAt: string | undefined, observedAt: string): string {
  if (!["completed", "failed", "stopped", "rejected"].includes(state) || producerEndedAt === undefined) return observedAt;
  const ended = Date.parse(producerEndedAt);
  return Number.isFinite(ended) && ended <= Date.parse(observedAt) ? producerEndedAt : observedAt;
}

export async function refreshSubagentActivityFromArtifact(turns: OwnedTurnOwner,
  asyncDir: string,
  canonicalFacts?: ReadonlyMap<string, CanonicalExtensionRunFact>,
): Promise<ExtensionArtifactDiscoveryOutcome> {
  if (turns.operations.disposed) return "transient";
  let diagnosticOwner: string | undefined;
  let missingToolCallId: string | undefined;
  let claimedReceipt: { activityId: string; owner: ArtifactReceiptOwner } | undefined;
  try {
    const lexicalDirectory = resolve(asyncDir);
    const realAsyncDir = turns.canonicalExtensionArtifactDirectory(asyncDir);
    const bound = [...turns.extensionRunOwnership.entries()].find(([, binding]) =>
      binding.asyncDir !== undefined && (resolve(binding.asyncDir) === lexicalDirectory
        || realAsyncDir !== undefined
          && turns.canonicalExtensionArtifactDirectory(binding.asyncDir) === realAsyncDir));
    missingToolCallId = bound?.[1].toolCallId;
    if (!realAsyncDir) {
      if (bound) turns.observeMissingExtensionArtifact(bound[1].toolCallId);
      return "transient";
    }
    diagnosticOwner = turns.extensionArtifactOwnerForDirectory(realAsyncDir);
    const rawValue = await turns.artifacts.readExtensionStatusArtifactWithReplacementRetry(realAsyncDir);
    if (turns.operations.disposed) return "transient";
    if (rawValue === undefined) {
      if (bound) turns.observeMissingExtensionArtifact(bound[1].toolCallId);
      if (diagnosticOwner) turns.warnExtensionArtifact("artifact-replacement-in-progress", diagnosticOwner);
      return "transient";
    }
    if (bound) turns.extensionArtifactMissingSince.delete(bound[1].toolCallId);
    // Registry discovery is bounded but grants no ownership. Historical
    // artifacts become admissible only here, where the canonical tool result
    // or an exact live asyncDir binding proves the owning session/tool call.
    const admission = inspectExtensionLifecycleArtifact(rawValue, { exactOwnedLegacy: true });
    if (!admission.accepted) {
      if (diagnosticOwner) turns.warnExtensionArtifact(admission.reason, diagnosticOwner);
      return "rejected";
    }
    const raw = admission.artifact;
    const runId = raw.runId as string;
    if (!runId) return "rejected";
    // The file's declared directory is advisory. If present, it must agree
    // with the directory that was actually discovered/read; a declared path
    // this slot cannot resolve is retried rather than recorded.
    if (typeof raw.asyncDir === "string") {
      const declaredAsyncDir = turns.canonicalExtensionArtifactDirectory(raw.asyncDir);
      if (!declaredAsyncDir) return "transient";
      if (declaredAsyncDir !== realAsyncDir) {
        if (diagnosticOwner) turns.warnExtensionArtifact("ownership-mismatch", diagnosticOwner);
        return "rejected";
      }
    }
    const ownership = turns.extensionRunOwnership.get(runId);
    const canonical = (canonicalFacts ?? canonicalExtensionRunFacts(turns)).get(runId);
    const historicalArtifact = raw.lifecycleArtifactVersion !== EXTENSION_LIFECYCLE_ARTIFACT_VERSION;
    if (historicalArtifact && !ownership?.asyncDir && !canonical?.asyncDir) return "transient";
    // A duplicated runId in canonical JSONL has no safe artifact owner.
    if (canonical?.ambiguous) {
      if (diagnosticOwner) turns.warnExtensionArtifact("ownership-mismatch", diagnosticOwner);
      return "transient";
    }
    // An ownership or canonical comparison is decided against state this slot
    // re-reads every pass, so the same bytes may be admissible later.
    if (ownership?.asyncDir) {
      const ownershipAsyncDir = turns.canonicalExtensionArtifactDirectory(ownership.asyncDir);
      if (!ownershipAsyncDir || ownershipAsyncDir !== realAsyncDir) {
        if (diagnosticOwner) turns.warnExtensionArtifact("ownership-mismatch", diagnosticOwner);
        return "transient";
      }
    }
    if (canonical?.asyncDir) {
      const canonicalAsyncDir = turns.canonicalExtensionArtifactDirectory(canonical.asyncDir);
      if (!canonicalAsyncDir || canonicalAsyncDir !== realAsyncDir) {
        if (diagnosticOwner) turns.warnExtensionArtifact("ownership-mismatch", diagnosticOwner);
        return "transient";
      }
    }
    if (canonical?.toolCallId && ownership && ownership.toolCallId !== canonical.toolCallId) {
      // A synthetic artifact row may be re-keyed to its first real tool call,
      // but a real ownership binding must never switch to another call.
      if (!ownership.toolCallId.startsWith("subagent:") || ownership.toolCallId === canonical.toolCallId) {
        if (diagnosticOwner) turns.warnExtensionArtifact("ownership-mismatch", diagnosticOwner);
        return "transient";
      }
    }
    const matchingEntries = [...turns.extensionActivities.entries()].filter(([, activity]) => activity.runId === runId);
    // Correlation is Gateway-owned; never pick an arbitrary activity when a
    // malformed or legacy payload has produced duplicate run identities.
    if (!ownership && !canonical?.toolCallId && matchingEntries.length > 1) {
      if (diagnosticOwner) turns.warnExtensionArtifact("ownership-mismatch", diagnosticOwner);
      return "transient";
    }
    const boundToolCallId = canonical?.toolCallId ?? ownership?.toolCallId;
    if (isEmbeddedLifecycleArtifact(rawValue) && raw.toolCallId !== undefined && raw.toolCallId !== boundToolCallId) {
      if (diagnosticOwner) turns.warnExtensionArtifact("ownership-mismatch", diagnosticOwner);
      return "rejected";
    }
    let existingEntry: readonly [string, ExtensionRunActivity | undefined] | undefined = boundToolCallId
      ? ([boundToolCallId, turns.extensionActivities.get(boundToolCallId)] as const)
      : matchingEntries[0];
    // Synthetic rows are placeholders only. Re-key one to the first real
    // canonical tool call instead of retaining two rows for the same run.
    if (canonical?.toolCallId && !existingEntry?.[1]) {
      const synthetic = matchingEntries.find(([id]) => id.startsWith("subagent:"));
      if (synthetic) existingEntry = [canonical.toolCallId, synthetic[1]];
    }
    // A tool result is the ownership proof for an activity. Once that proof
    // exists, the artifact may enrich it. Unmatched artifacts still require
    // the exact cwd/session guard.
    // Artifact files are enrichment only. A current tool execution or a
    // canonical terminal tool result must establish ownership first; cwd,
    // sessionId, and a lone running tool are not attribution evidence.
    if (!existingEntry?.[1] && !canonical?.toolCallId) return "transient";
    if (!existingEntry?.[1] && canonical?.toolCallId) {
      existingEntry = [canonical.toolCallId, turns.extensionActivities.get(canonical.toolCallId)];
    }
    const toolCallId = existingEntry?.[0];
    if (!toolCallId) return "transient";
    const previous = existingEntry?.[1];
    const normalized = normalizeExtensionArtifact(raw, {
      now: new Date().toISOString(),
      ...(previous?.startedAt ? { fallbackStartedAt: previous.startedAt } : {}),
      ...(previous?.updatedAt ? { fallbackUpdatedAt: previous.updatedAt } : {}),
      // A recovery handoff has no launcher row to supply a start time.
      // Once admitted, keep that first start stable across later updates.
      useArtifactStartedAt: previous === undefined,
    });
    if (!normalized) {
      if (diagnosticOwner) turns.warnExtensionArtifact("invalid-timestamp", diagnosticOwner);
      return "rejected";
    }
    const { status: state, startedAt, updatedAt, completedAt, durationMs } = normalized;
    const facts = canonicalFacts ?? canonicalExtensionRunFacts(turns);
    const recoveryClaim = recoveredReplacementClaim(raw);
    const sourceFact = facts.get(runId);
    const pausedProcessSettledAt = observedPausedProcessTerminalAt(raw, runId);
    const processTerminal = pausedProcessSettledAt !== undefined;
    const rawLastUpdate = raw.lastUpdate;
    const rawEndedAt = raw.endedAt;
    // Only the exact provider recovery receipt plus the original paused
    // runner's terminal proof can settle this source. A later explicit
    // resume leaves the historical marker behind but has a new live state or
    // timestamps, so it must not be terminalized by that old marker.
    const superseded = extensionLifecycleState(raw.state ?? raw.status) === "paused"
      && recoveryClaim !== undefined
      && sourceFact?.recoveredReplacementRunId === recoveryClaim.replacementRunId
      && sourceFact.ambiguous !== true
      && processTerminal
      && typeof rawLastUpdate === "number" && Number.isSafeInteger(rawLastUpdate)
      && rawLastUpdate <= recoveryClaim.recoveredAt
      && typeof rawEndedAt === "number" && Number.isSafeInteger(rawEndedAt)
      && rawEndedAt <= recoveryClaim.recoveredAt;
    const effectiveState = superseded ? "completed" : state;
    const effectiveCompletedAt = superseded ? completedAt ?? updatedAt : completedAt;
    // A terminal lifecycle event is authoritative; a late running artifact
    // enriches neither status nor ownership and must not resurrect the pill.
    // The latch cannot lift for this identity, so the bytes are rejected.
    if (ownership?.terminal && state === "running") return "rejected";
    const artifactValue = ownership?.terminal
      ? preserveEmbeddedLifecycleMarker(raw, { ...raw, state: previous?.status === "failed" ? "failed" : "completed" })
      : superseded
        ? preserveEmbeddedLifecycleMarker(raw, { ...raw, state: "stopped", supersededByRunId: recoveryClaim!.replacementRunId })
        : raw;
    const activityKey = previous?.activityId ?? extensionActivityId(turns.operations.runtime.session.sessionManager.getSessionId(), toolCallId);
    const sequence = (turns.extensionActivitySequences.get(activityKey) ?? previous?.lifecycle?.sequence ?? 0) + 1;
    turns.extensionActivitySequences.set(activityKey, sequence);
    const observedAt = new Date().toISOString();
    const terminalAt = effectiveState === "running"
      ? previous?.lifecycle?.terminalAt
      : previous?.lifecycle?.terminalAt
        ?? (previous === undefined ? rediscoveredTerminalAt(effectiveState, effectiveCompletedAt, observedAt) : observedAt);
    const recentUntil = terminalAt ? new Date(Date.parse(terminalAt) + 900_000).toISOString() : undefined;
    const activity = turns.operations.childSessionAdmission.attach(projectExtensionRunActivity(artifactValue, {
      id: previous?.id ?? toolCallId,
      activityId: activityKey,
      toolCallId,
      source: previous?.source ?? turns.subagentExtensionOrigin(),
      title: previous?.title ?? "Subagents",
      mode: "asynchronous",
      status: effectiveState,
      authoritativeStatus: effectiveState !== "running" || previous?.lifecycle?.state === "completed" || previous?.lifecycle?.state === "failed" || previous?.lifecycle?.state === "stopped" || previous?.lifecycle?.state === "rejected",
      startedAt,
      updatedAt,
      ...(effectiveCompletedAt ? { completedAt: effectiveCompletedAt } : {}),
      ...(durationMs === undefined ? {} : { durationMs }),
      ...(previous ? { previous } : {}),
      sequence,
      observedAt,
      ...(terminalAt ? { terminalAt } : {}),
      ...(recentUntil ? { recentUntil } : {}),
      childIdentityStrategy: "piArtifact",
    }), artifactValue, "piArtifact");
    // Ambient discovery is another producer of lifecycle candidates. Apply
    // the same Gateway terminal latch and sequence admission as live tool
    // events before replacing an existing row.
    if (admitExtensionRunActivity(previous, activity) === previous) return "rejected";
    const terminalReceiptOwner = activity.status === "running"
      ? undefined
      : turns.claimExtensionReceiptOwnership(activityKey);
    // A full Gateway work registry is temporary: the terminal receipt can be
    // claimed by a later pass, so this artifact is not delivered yet.
    if (activity.status !== "running" && !terminalReceiptOwner) return "transient";
    if (terminalReceiptOwner) claimedReceipt = { activityId: activityKey, owner: terminalReceiptOwner };
    // Ownership facts are written before this frame's projection publishes:
    // settled paused presentation, dashboard activity, and drain accounting
    // all read them from the same frame.
    const ownershipAccepted = turns.bindExtensionRunOwnership(runId, {
      toolCallId,
      asyncDir: realAsyncDir,
      terminal: activity.status !== "running" || Boolean(ownership?.terminal),
      ...(pausedProcessSettledAt ? { pausedProcessQuiescentAt: pausedProcessSettledAt } : {}),
      detachedChildKeys: detachedWorkflowChildKeys(raw),
    });
    if (!ownershipAccepted) {
      turns.releaseExtensionReceiptOwnership(activityKey, terminalReceiptOwner);
      claimedReceipt = undefined;
      if (diagnosticOwner) turns.warnExtensionArtifact("ownership-mismatch", diagnosticOwner);
      return "transient";
    }
    if (existingEntry) turns.extensionActivities.delete(existingEntry[0]);
    const syntheticToolCallId = matchingEntries.find(([id]) => id.startsWith("subagent:") && id !== toolCallId)?.[0];
    if (syntheticToolCallId) turns.extensionActivities.delete(syntheticToolCallId);
    turns.extensionActivities.delete(toolCallId);
    turns.extensionActivities.set(toolCallId, activity);
    upsertExtensionActivity(turns, activity);
    if (activity.status !== "running") {
      void appendExtensionActivityReceipt(turns, activity).catch((error) => turns.operations.emit("session.extensionError", safeJson(error)));
      claimedReceipt = undefined;
    }
    if (extensionActivityWatchRequired(turns, activity)) turns.startExtensionActivityWatcher(toolCallId, realAsyncDir);
    else turns.stopExtensionActivityWatcher(toolCallId);
    trimExtensionActivities(turns);
    publishExtensionActivity(turns, activity);
    return "accepted";
  } catch (error) {
    if (claimedReceipt) turns.releaseExtensionReceiptOwnership(claimedReceipt.activityId, claimedReceipt.owner);
    if (turns.operations.disposed) return "transient";
    if (error instanceof OversizedExtensionArtifactError && missingToolCallId) {
      turns.observeMissingExtensionArtifact(missingToolCallId);
    }
    if (diagnosticOwner) turns.warnExtensionArtifact(extensionArtifactReadFailureReason(error), diagnosticOwner);
    // An artifact that is too large or belongs to another session keeps that
    // verdict for these bytes; every other failure is retried by the caller.
    return error instanceof OversizedExtensionArtifactError || error instanceof ForeignExtensionArtifactSessionError
      ? "rejected"
      : "transient";
  }
}


export async function refreshExtensionActivityFromArtifact(turns: OwnedTurnOwner, toolCallId: string, asyncDir: string): Promise<void> {
  const previous = turns.extensionActivities.get(toolCallId);
  const realAsyncDir = turns.canonicalExtensionArtifactDirectory(asyncDir);
  if (!previous || turns.operations.disposed || !realAsyncDir) return;
  const generation = (turns.extensionActivityReadGenerations.get(toolCallId) ?? 0) + 1;
  turns.extensionActivityReadGenerations.set(toolCallId, generation);
  let claimedReceiptOwner: ArtifactReceiptOwner | undefined;
  let claimedReceiptActivityId: string | undefined;
  try {
    const rawValue = await turns.artifacts.readExtensionStatusArtifact(realAsyncDir);
    if (rawValue === undefined) {
      const tracked = turns.extensionActivityWatchers.get(toolCallId);
      if (tracked && tracked.asyncDir === realAsyncDir) {
        // A pending debounce or retry already owns this re-read, so a read that
        // lost a replacement race waits for it instead of warning: the timer
        // fires a few milliseconds later, inside the same replacement.
        if (tracked.timer === undefined && tracked.readRetries < 3) {
          tracked.readRetries += 1;
          tracked.timer = setTimeout(() => {
            tracked.timer = undefined;
            void refreshExtensionActivityFromArtifact(turns, toolCallId, realAsyncDir);
          }, tracked.readRetries * 100);
          tracked.timer.unref();
        }
        if (tracked.timer !== undefined) return;
      }
      turns.observeMissingExtensionArtifact(toolCallId);
      turns.warnExtensionArtifact("artifact-replacement-in-progress", `${previous.runId ?? "run"}\0${toolCallId}`);
      return;
    }
    turns.extensionArtifactMissingSince.delete(toolCallId);
    const tracked = turns.extensionActivityWatchers.get(toolCallId);
    if (tracked?.asyncDir === realAsyncDir) tracked.readRetries = 0;
    const admission = inspectExtensionLifecycleArtifact(rawValue, { exactOwnedLegacy: true });
    if (!admission.accepted) {
      turns.warnExtensionArtifact(admission.reason, `${previous.runId ?? "run"}\0${toolCallId}`);
      return;
    }
    const raw = admission.artifact;
    if (turns.operations.disposed || turns.extensionActivityReadGenerations.get(toolCallId) !== generation) return;
    const runId = raw.runId as string;
    if (!runId || runId !== previous.runId) return;
    if (typeof raw.asyncDir === "string") {
      const declaredAsyncDir = turns.canonicalExtensionArtifactDirectory(raw.asyncDir);
      if (!declaredAsyncDir || declaredAsyncDir !== realAsyncDir) {
        turns.warnExtensionArtifact("ownership-mismatch", `${runId}\0${toolCallId}`);
        return;
      }
    }
    const canonical = canonicalExtensionRunFacts(turns).get(runId);
    const ownership = turns.extensionRunOwnership.get(runId);
    // Watcher refresh is bound to one tool and one canonical directory. A
    // duplicate canonical runId or either mismatch fails closed.
    if (canonical?.ambiguous || (canonical?.toolCallId && canonical.toolCallId !== toolCallId)
      || !ownership || ownership.toolCallId !== toolCallId) {
        turns.warnExtensionArtifact("ownership-mismatch", `${runId}\0${toolCallId}`);
      return;
    }
    if (ownership.asyncDir) {
      const ownershipAsyncDir = turns.canonicalExtensionArtifactDirectory(ownership.asyncDir);
      if (!ownershipAsyncDir || ownershipAsyncDir !== realAsyncDir) {
        turns.warnExtensionArtifact("ownership-mismatch", `${runId}\0${toolCallId}`);
        return;
      }
    }
    if (canonical?.asyncDir) {
      const canonicalAsyncDir = turns.canonicalExtensionArtifactDirectory(canonical.asyncDir);
      if (!canonicalAsyncDir || canonicalAsyncDir !== realAsyncDir) {
        turns.warnExtensionArtifact("ownership-mismatch", `${runId}\0${toolCallId}`);
        return;
      }
    }
    turns.syncWorkflowChildArtifactWatchers(toolCallId, raw);
    const normalized = normalizeExtensionArtifact(raw, {
      now: new Date().toISOString(),
      fallbackStartedAt: previous.startedAt,
      useArtifactStartedAt: false,
    });
    if (!normalized) {
        turns.warnExtensionArtifact("invalid-timestamp", `${runId}\0${toolCallId}`);
      return;
    }
    const { status: artifactState, updatedAt, completedAt, durationMs } = normalized;
    const facts = canonicalExtensionRunFacts(turns);
    const recoveryClaim = recoveredReplacementClaim(raw);
    const sourceFact = facts.get(runId);
    const pausedProcessSettledAt = observedPausedProcessTerminalAt(raw, runId);
    const processTerminal = pausedProcessSettledAt !== undefined;
    const rawLastUpdate = raw.lastUpdate;
    const rawEndedAt = raw.endedAt;
    const superseded = extensionLifecycleState(raw.state ?? raw.status) === "paused"
      && recoveryClaim !== undefined
      && sourceFact?.recoveredReplacementRunId === recoveryClaim.replacementRunId
      && sourceFact.ambiguous !== true
      && processTerminal
      && typeof rawLastUpdate === "number" && Number.isSafeInteger(rawLastUpdate)
      && rawLastUpdate <= recoveryClaim.recoveredAt
      && typeof rawEndedAt === "number" && Number.isSafeInteger(rawEndedAt)
      && rawEndedAt <= recoveryClaim.recoveredAt;
    const effectiveArtifactState = superseded ? "completed" : artifactState;
    const effectiveCompletedAt = superseded ? completedAt ?? updatedAt : completedAt;
    const terminalStates = ["completed", "failed", "stopped", "rejected"];
    if (ownership.terminal && artifactState === "running" && !superseded) return;
    // A latched terminal state is final: a re-read of a kept-open run may restate
    // it (its workflow children still report), never move it to another state.
    if (terminalStates.includes(previous.lifecycle?.state ?? "") && artifactState !== "running"
      && normalized.lifecycleState !== previous.lifecycle?.state) return;
    // A kept-open run restates its latched terminal lifecycle; only its children move.
    const latchedState = previous.lifecycle?.state !== undefined && terminalStates.includes(previous.lifecycle.state)
      ? previous.lifecycle.state : undefined;
    const artifactValue = ownership.terminal
      ? preserveEmbeddedLifecycleMarker(raw, { ...raw, state: latchedState ?? (previous.status === "failed" ? "failed" : "completed") })
      : superseded
        ? preserveEmbeddedLifecycleMarker(raw, { ...raw, state: "stopped", supersededByRunId: recoveryClaim!.replacementRunId })
        : raw;
    const activityKey = previous.activityId ?? extensionActivityId(turns.operations.runtime.session.sessionManager.getSessionId(), toolCallId);
    const sequence = (turns.extensionActivitySequences.get(activityKey) ?? previous.lifecycle?.sequence ?? 0) + 1;
    turns.extensionActivitySequences.set(activityKey, sequence);
    const observedAt = new Date().toISOString();
    const terminalAt = effectiveArtifactState === "running"
      ? previous.lifecycle?.terminalAt
      : previous.lifecycle?.terminalAt ?? observedAt;
    const recentUntil = terminalAt ? new Date(Date.parse(terminalAt) + 900_000).toISOString() : undefined;
    const activity = turns.operations.childSessionAdmission.attach(projectExtensionRunActivity(artifactValue, {
      id: previous.id,
      activityId: activityKey,
      toolCallId,
      source: previous.source,
      title: previous.title,
      mode: "asynchronous",
      status: effectiveArtifactState,
      authoritativeStatus: effectiveArtifactState !== "running" || previous.lifecycle?.state === "completed" || previous.lifecycle?.state === "failed" || previous.lifecycle?.state === "stopped" || previous.lifecycle?.state === "rejected",
      startedAt: previous.startedAt,
      updatedAt,
      ...(effectiveCompletedAt ? { completedAt: effectiveCompletedAt } : {}),
      ...(durationMs === undefined ? {} : { durationMs }),
      previous,
      sequence,
      observedAt,
      ...(terminalAt ? { terminalAt } : {}),
      ...(recentUntil ? { recentUntil } : {}),
      childIdentityStrategy: "piArtifact",
    }), artifactValue, "piArtifact");
    const current = turns.extensionActivities.get(toolCallId);
    if (!current) return;
    if (admitExtensionRunActivity(current, activity) === current) return;
    if (current.lifecycle?.sequence !== undefined && activity.lifecycle?.sequence !== undefined
      && activity.lifecycle.sequence <= current.lifecycle.sequence) return;
    if (activity.status !== "running") {
      claimedReceiptOwner = turns.claimExtensionReceiptOwnership(activityKey);
      if (!claimedReceiptOwner) return;
      claimedReceiptActivityId = activityKey;
    }
    // Ownership facts are written before this frame's projection publishes:
    // settled paused presentation, dashboard activity, and drain accounting
    // all read them from the same frame.
    turns.bindExtensionRunOwnership(runId, {
      toolCallId,
      asyncDir: realAsyncDir,
      terminal: activity.status !== "running" || Boolean(ownership.terminal),
      ...(pausedProcessSettledAt ? { pausedProcessQuiescentAt: pausedProcessSettledAt } : {}),
      detachedChildKeys: detachedWorkflowChildKeys(raw),
    });
    turns.extensionActivities.delete(toolCallId);
    turns.extensionActivities.set(toolCallId, activity);
    upsertExtensionActivity(turns, activity);
    turns.operations.updateToolExtensionActivityProjection(toolCallId, activity);
    publishExtensionActivity(turns, activity);
    if (activity.status === "running") {
      const tracked = turns.extensionActivityWatchers.get(toolCallId);
      if (activityNeedsChildSessionBinding(turns, activity.children)
        && artifactPublishesChildSession(turns, artifactValue)) {
        turns.scheduleExtensionBindingRetry(toolCallId, realAsyncDir);
      } else if (tracked?.asyncDir === realAsyncDir) {
        tracked.bindingRetries = 0;
      }
    }
    if (activity.status !== "running") {
      claimedReceiptOwner = undefined;
      claimedReceiptActivityId = undefined;
      void appendExtensionActivityReceipt(turns, activity).catch((error) => turns.operations.emit("session.extensionError", safeJson(error)));
    }
    if (!extensionActivityWatchRequired(turns, activity)) turns.stopExtensionActivityWatcher(toolCallId);
  } catch (error) {
    if (claimedReceiptActivityId) turns.releaseExtensionReceiptOwnership(claimedReceiptActivityId, claimedReceiptOwner);
    // The next filesystem event or normal snapshot retries; warning is bounded.
    turns.warnExtensionArtifact(
      extensionArtifactReadFailureReason(error),
      `${previous.runId ?? "run"}\0${toolCallId}`,
    );
  }
}


export function artifactPublishesChildSession(turns: OwnedTurnOwner, value: unknown): boolean {
  const root = value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined;
  const details = root?.details && typeof root.details === "object" && !Array.isArray(root.details)
    ? root.details as Record<string, unknown>
    : root;
  if (!details) return false;
  const visit = (candidate: unknown, depth: number): boolean => {
    if (depth > 4 || !candidate || typeof candidate !== "object" || Array.isArray(candidate)) return false;
    const record = candidate as Record<string, unknown>;
    const progress = record.progress && typeof record.progress === "object" && !Array.isArray(record.progress)
      ? record.progress as Record<string, unknown>
      : undefined;
    if (typeof record.sessionFile === "string" || typeof progress?.sessionFile === "string") return true;
    for (const key of ["results", "steps", "children", "progress"] as const) {
      const nested = record[key];
      if (Array.isArray(nested) && nested.slice(0, 64).some((child) => visit(child, depth + 1))) return true;
    }
    return false;
  };
  return visit(details, 0);
}


export function activityNeedsChildSessionBinding(turns: OwnedTurnOwner, children: readonly ExtensionRunChild[]): boolean {
  return children.some((child) => child.childSessionRef === undefined
    || child.children !== undefined && activityNeedsChildSessionBinding(turns, child.children));
}