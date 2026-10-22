import { admitPrompt } from "./prompt-admission.js";
import type { RunOperations } from "./run-operations.js";
import { GatewayError } from "../../errors.js";
import type { InvocationLifecycle, SessionOperationState } from "../../protocol/types.js";
import type { RuntimeQueuedMessage } from "./queue-input.js";

const FOREGROUND_ABORT_SETTLEMENT_GRACE_MS = 5_000;

/** Owns foreground cancellation intent and the accepted Stop continuation.
 * Reads stay live across SDK calls and awaits so successor ownership is rechecked. */
export class RunAbortOwner {
  readonly stopSteeringRecoveryIDs = new Set<string>();
  readonly stopRecoveryHoldIDs = new Set<string>();
  stopRecoveryQueueClosed = false;
  stopSteeringContinuation: { operationId?: string; queuedSteerCount: number } | undefined;
  /** Set before SDK cancellation can synchronously settle. */
  readonly abortedOperations = new Set<string>();

  constructor(private readonly operations: RunOperations<unknown>) {}

  async abort(
    kind: "agent" | "compaction" | "retry" | "branchSummary" | "bash" = "agent",
    expectedOperationId?: string,
    terminalErrorCode = "user-abort",
  ): Promise<void> {
    let queuedAtStop: RuntimeQueuedMessage[] | undefined;
    // Finite task cancellation belongs to its report/controller, not the
    // ordinary Stop continuation. A sealed task can never admit another turn.
    if (!this.operations.taskWorker && (this.operations.runQueue.queuedMessages.some((item) => item.behavior === "steer")
      || this.operations.runQueue.pendingQueueAdmission?.behavior === "steer")
      && this.stopSteeringContinuation === undefined) {
      queuedAtStop = await this.operations.lane.run(() => {
        this.operations.assertAvailable();
        if (expectedOperationId !== undefined && this.operations.operation?.id !== expectedOperationId) {
          throw new GatewayError("conflict", "The active operation changed before it could be stopped", true);
        }
        const accepted = this.operations.runQueue.queuedMessages.slice();
        if (!accepted.some((item) => item.behavior === "steer")) return undefined;
        // Close before clearing: any steer admitted while Stop waits stays in the
        // Gateway owner and joins the continuation, never Pi's queue.
        this.stopRecoveryQueueClosed = true;
        for (const item of accepted) this.stopSteeringRecoveryIDs.add(item.id);
        (this.operations.runQueue.suppressQueueEvents = true);
        try { this.operations.runtime.session.clearQueue(); }
        finally { (this.operations.runQueue.suppressQueueEvents = false); }
        this.operations.runQueue.sdkQueuedSteeringIDs.clear();
        return accepted;
      });
    }
    const recovered = await this.abortSerialized(kind, expectedOperationId, terminalErrorCode, queuedAtStop);
    if (recovered.length > 0) {
      await this.operations.lane.run(() => this.redeliverStoppedSteering(recovered, true));
    }
  }

  private async abortSerialized(
    kind: "agent" | "compaction" | "retry" | "branchSummary" | "bash",
    expectedOperationId: string | undefined,
    terminalErrorCode: string,
    queuedAtStop?: RuntimeQueuedMessage[],
  ): Promise<RuntimeQueuedMessage[]> {
    // A persistence blocker must not disable the owner's Stop route. Stop still
    // proves exact operation identity and reports any unresolved receipt after
    // cancellation instead of clearing the persistence fence.
    this.operations.assertAvailable();
    const taskOperationId = this.operations.taskWorker?.identity.operationId;
    const taskOwnsForeground = taskOperationId !== undefined && this.operations.runTerminal.liveTaskOperationId() === taskOperationId;
    const targetsTask = expectedOperationId === taskOperationId
      || (expectedOperationId === undefined && (taskOwnsForeground || !this.operations.operation))
      || (taskOwnsForeground && expectedOperationId === this.operations.operation?.id);
    if (this.operations.taskWorker?.controlsActive && terminalErrorCode === "user-abort" && targetsTask) {
      await this.operations.taskWorker!.stop();
      return [];
    }
    if (expectedOperationId !== undefined && this.operations.operation?.id !== expectedOperationId
      && !(taskOwnsForeground && expectedOperationId === taskOperationId)) {
      throw new GatewayError("conflict", "The active operation changed before it could be stopped", true);
    }

    // `kind` is presentation metadata, not cancellation authority. A stale
    // retry/compaction/bash projection must never route Stop around another
    // foreground controller or the independently owned built-in bash process.
    // Keep the exact operation fence above, then fan cancellation out across
    // every foreground primitive and verify settlement before acknowledging.
    void kind;
    const target = this.operations.operation ? { ...this.operations.operation! } : undefined;
    const agentOperationId = this.operations.activeOperationId;
    this.operations.homeRequestPolicy?.cancel(agentOperationId);
    const invocationOperationId = agentOperationId
      ?? (target?.kind === "prompt" || target?.kind === "command" ? target.id : undefined);
    if (invocationOperationId) {
      const invocation = this.operations.runInvocations.invocationForOperation(invocationOperationId);
      // A Gateway-owned stop reason outranks the SDK outcome. User Stop is
      // provisional until cancellation settles; a refused attempt cannot claim
      // a later natural completion as its interruption.
      if (invocation && terminalErrorCode !== "user-abort") {
        // A limit crossing is authoritative even if another Gateway stop races it.
        if (!invocation.stopReason || terminalErrorCode === "chapter-limit") invocation.stopReason = terminalErrorCode;
      }
      this.abortedOperations.add(invocationOperationId);
    }
    if (target?.kind === "compaction" && target.id) this.abortedOperations.add(target.id);

    // Retire accepted queue ownership before abort emits queue_update: those
    // entries were not consumed. Keep their exact owners on this cancellation
    // frame until their not-delivered receipts are persisted below.
    const stoppedTaskQueue = this.operations.taskWorker ? this.operations.runQueue.queuedMessages : [];
    if (this.operations.taskWorker) {
      (this.operations.runQueue.suppressQueueEvents = true);
      try { this.operations.runtime.session.clearQueue(); }
      finally { (this.operations.runQueue.suppressQueueEvents = false); }
      this.operations.runQueue.sdkQueuedSteeringIDs.clear();
      (this.operations.runQueue.queuedMessages = []);
      (this.operations.runQueue.queueRevision += 1);
    }
    const queuedSteerCount = queuedAtStop?.filter((item) => item.behavior === "steer").length ?? 0;
    const redeliver = queuedAtStop !== undefined && queuedSteerCount > 0;
    const session = this.operations.runtime.session;
    for (const cancel of [
      () => session.abortCompaction(),
      () => session.abortRetry(),
      () => session.abortBranchSummary(),
      () => session.abortBash(),
    ]) {
      try { cancel(); } catch { /* Continue through every independent escape hatch. */ }
    }
    const abortResults = await Promise.allSettled([
      session.abort(),
      this.operations.directBashProcesses?.abortAll() ?? Promise.resolve(),
    ]);
    for (const item of stoppedTaskQueue) {
      await this.operations.runInvocations.terminalizeInvocation(item.id, "interrupted", "task-stopped-before-delivery");
      this.operations.runWork.settleOperationWork(item.id);
    }
    const settled = await this.waitForForegroundAbortSettlement(target, agentOperationId);
    if (!settled || this.operations.directBashProcesses?.hasActiveProcesses
      || abortResults.some((result) => result.status === "rejected")) {
      // Keep the SDK's actual abort outcome authoritative if cancellation partly
      // succeeded, but withdraw this unconfirmed invocation-level Stop intent.
      if (invocationOperationId) this.abortedOperations.delete(invocationOperationId);
      throw new GatewayError("conflict", "Foreground work did not stop", true);
    }

    let interruptionPersisted = false;
    if (invocationOperationId && !redeliver) {
      await this.operations.runInvocations.terminalizeInvocation(invocationOperationId, "interrupted", terminalErrorCode);
      interruptionPersisted = true;
    }
    if (invocationOperationId && interruptionPersisted) this.abortedOperations.delete(invocationOperationId);

    let recovered: RuntimeQueuedMessage[] = [];
    if (redeliver) {
      recovered = queuedAtStop.filter((item) => this.stopSteeringRecoveryIDs.has(item.id));
      this.stopSteeringContinuation = {
        ...(invocationOperationId === undefined ? {} : { operationId: invocationOperationId }),
        queuedSteerCount,
      };
      this.operations.dependencies.stopSteeringDiagnostic?.bind(this.operations.dependencies)?.({ sessionId: this.operations.id, queuedSteerCount, outcome: "started" });
      if (recovered.length === 0) {
        this.operations.dependencies.stopSteeringDiagnostic?.bind(this.operations.dependencies)?.({ sessionId: this.operations.id, queuedSteerCount, outcome: "completed" });
        this.stopSteeringContinuation = undefined;
      }
    }

    this.operations.publishChanged();
    return recovered;
  }

  private async redeliverStoppedSteering(items: RuntimeQueuedMessage[], laneOwned: boolean): Promise<void> {
    const processed = new Set<string>();
    while (true) {
      const held = this.operations.heldQueue.entries.filter((item) => this.stopRecoveryHoldIDs.has(item.id));
      const pending = [...items, ...held]
        .filter((item) => !processed.has(item.id)
          && (this.stopSteeringRecoveryIDs.has(item.id) || this.stopRecoveryHoldIDs.has(item.id)))
        .sort((left, right) => left.ordinal - right.ordinal);
      if (pending.length === 0) break;
      for (const item of pending) {
        const heldEntry = this.stopRecoveryHoldIDs.has(item.id)
          ? this.operations.heldQueue.entries.find((entry) => entry.id === item.id)
          : undefined;
        const hasAcceptedInvocation = this.operations.runInvocations.invocationForOperation(item.id) !== undefined;
        try {
          await admitPrompt(this.operations, item.text, item.images, item.behavior, {
            text: item.text,
            attachmentEnvelope: item.attachmentEnvelope,
            attachmentCount: item.attachmentCount,
            ...(item.photoCount === undefined ? {} : { photoCount: item.photoCount }),
            ...(item.fileAttachmentCount === undefined ? {} : { fileAttachmentCount: item.fileAttachmentCount }),
            ...(item.attachments === undefined ? {} : { attachments: item.attachments }),
            ...(item.resourceInvocations === undefined ? {} : { resourceInvocations: item.resourceInvocations }),
            inputSource: item.inputSource,
            ...(item.commandId === undefined ? {} : { commandId: item.commandId }),
          }, undefined, undefined, item.id, heldEntry, hasAcceptedInvocation ? item : undefined, laneOwned);
          processed.add(item.id);
          this.stopRecoveryHoldIDs.delete(item.id);
          // A handled input has no Agent message_start; its terminal receipt
          // from normal admission is the exact queue-row removal boundary.
          const lifecycle = this.operations.runInvocations.invocationForOperation(item.id)?.lifecycle;
          if (lifecycle === "completed" || lifecycle === "failed" || lifecycle === "interrupted") {
            this.consumeStopSteeringRecoveryOwner(item.id);
            this.operations.heldQueue.removeHeldPrompt(item.id);
          }
        } catch (error) {
          this.operations.dependencies.stopSteeringDiagnostic?.bind(this.operations.dependencies)?.({
            sessionId: this.operations.id,
            queuedSteerCount: items.filter((queued) => queued.behavior === "steer").length,
            outcome: "failed",
          });
          this.stopSteeringContinuation = undefined;
          throw error;
        }
      }
    }
    this.stopRecoveryQueueClosed = false;
    this.stopRecoveryHoldIDs.clear();
  }

  private async waitForForegroundAbortSettlement(
    target: SessionOperationState | undefined,
    agentOperationId: string | undefined,
  ): Promise<boolean> {
    const deadline = performance.now() + FOREGROUND_ABORT_SETTLEMENT_GRACE_MS;
    const stillActive = () => this.operations.directBashProcesses?.hasActiveProcesses === true
      || (target !== undefined && this.operations.operationMatches(target))
      || (agentOperationId !== undefined
        && this.operations.activeOperationId === agentOperationId
        && (this.operations.hasActiveAgentRun
          || this.operations.pendingPrompt?.id === agentOperationId
          || this.operations.operation?.id === agentOperationId));
    while (stillActive() && performance.now() < deadline) {
      await new Promise<void>((resolveDelay) => { setTimeout(resolveDelay, 20); });
    }
    return !stillActive();
  }

  consumeStopSteeringRecoveryOwner(operationId: string): void {
    if (!this.stopSteeringRecoveryIDs.delete(operationId)) return;
    const retained = this.operations.runQueue.queuedMessages.filter((item) => item.id !== operationId);
    if (retained.length === this.operations.runQueue.queuedMessages.length) return;
    (this.operations.runQueue.queuedMessages = retained);
    (this.operations.runQueue.queueRevision += 1);
  }

  completeContinuation(terminalLifecycle: InvocationLifecycle): void {
    if (this.stopSteeringContinuation) {
      this.operations.dependencies.stopSteeringDiagnostic?.bind(this.operations.dependencies)?.({
        sessionId: this.operations.id,
        queuedSteerCount: this.stopSteeringContinuation.queuedSteerCount,
        outcome: terminalLifecycle === "completed" ? "completed"
          : terminalLifecycle === "interrupted" ? "stopped"
            : terminalLifecycle === "failed" ? "failed" : "unknown",
      });
      this.stopSteeringContinuation = undefined;
    }
  }
}
