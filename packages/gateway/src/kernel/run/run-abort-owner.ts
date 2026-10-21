import { GatewayError } from "../../errors.js";
import type { InvocationLifecycle, SessionOperationState } from "../../protocol/types.js";
import type { ImageContent } from "../pi/ai.js";
import type { AgentSession } from "../pi/coding-agent.js";
import type { DirectBashProcessOwner } from "./direct-bash-process-owner.js";
import type { HeldPromptQueue } from "./held-prompt-queue.js";
import type { HeldPrompt, PromptQueueDisplay, QueueBehavior, RuntimeQueuedMessage } from "./queue-input.js";

const FOREGROUND_ABORT_SETTLEMENT_GRACE_MS = 5_000;
interface AbortContext {
  runLane<T>(operation: () => T | Promise<T>): Promise<T>;
  assertAvailable(): void;
  taskWorker(): { identity: { operationId: string }; controlsActive: boolean; stop(): Promise<void> } | undefined;
  liveTaskOperationId(): string | undefined;
  queued(): RuntimeQueuedMessage[];
  replaceQueued(items: RuntimeQueuedMessage[]): void;
  pendingAdmission(): { behavior: QueueBehavior } | undefined;
  operation(): SessionOperationState | undefined;
  operationMatches(target: SessionOperationState): boolean;
  activeOperationId(): string | undefined;
  hasActiveAgentRun(): boolean;
  pendingPromptId(): string | undefined;
  session(): AgentSession;
  sessionId(): string;
  suppressQueueEvents(value: boolean): void;
  clearSdkSteeringIds(): void;
  bumpQueueRevision(): void;
  cancelRequest(operationId: string | undefined): void;
  invocation(operationId: string): { stopReason?: string; lifecycle: InvocationLifecycle } | undefined;
  directBashProcesses(): DirectBashProcessOwner | undefined;
  terminalizeInvocation(operationId: string, lifecycle: "interrupted", errorCode: string): Promise<unknown>;
  settleOperationWork(operationId: string): void;
  diagnostic(): ((data: { sessionId: string; queuedSteerCount: number; outcome: "started" | "completed" | "failed" | "stopped" | "unknown" }) => void) | undefined;
  heldQueue(): HeldPromptQueue;
  admitPrompt(...args: [string, ImageContent[], QueueBehavior, PromptQueueDisplay, undefined, undefined, string, HeldPrompt | undefined, RuntimeQueuedMessage | undefined, boolean]): Promise<unknown>;
  publishChanged(): void;
}

/** Owns foreground cancellation intent and the accepted Stop continuation.
 * Context reads remain live at each original SDK and post-await cut. */
export class RunAbortOwner {
  readonly stopSteeringRecoveryIDs = new Set<string>();
  readonly stopRecoveryHoldIDs = new Set<string>();
  stopRecoveryQueueClosed = false;
  stopSteeringContinuation: { operationId?: string; queuedSteerCount: number } | undefined;
  /** Set before SDK cancellation can synchronously settle. */
  readonly abortedOperations = new Set<string>();

  constructor(private readonly context: AbortContext) {}

  async abort(
    kind: "agent" | "compaction" | "retry" | "branchSummary" | "bash" = "agent",
    expectedOperationId?: string,
    terminalErrorCode = "user-abort",
  ): Promise<void> {
    let queuedAtStop: RuntimeQueuedMessage[] | undefined;
    // Finite task cancellation belongs to its report/controller, not the
    // ordinary Stop continuation. A sealed task can never admit another turn.
    if (!this.context.taskWorker() && (this.context.queued().some((item) => item.behavior === "steer")
      || this.context.pendingAdmission()?.behavior === "steer")
      && this.stopSteeringContinuation === undefined) {
      queuedAtStop = await this.context.runLane(() => {
        this.context.assertAvailable();
        if (expectedOperationId !== undefined && this.context.operation()?.id !== expectedOperationId) {
          throw new GatewayError("conflict", "The active operation changed before it could be stopped", true);
        }
        const accepted = this.context.queued().slice();
        if (!accepted.some((item) => item.behavior === "steer")) return undefined;
        // Close before clearing: any steer admitted while Stop waits stays in the
        // Gateway owner and joins the continuation, never Pi's queue.
        this.stopRecoveryQueueClosed = true;
        for (const item of accepted) this.stopSteeringRecoveryIDs.add(item.id);
        this.context.suppressQueueEvents(true);
        try { this.context.session().clearQueue(); }
        finally { this.context.suppressQueueEvents(false); }
        this.context.clearSdkSteeringIds();
        return accepted;
      });
    }
    const recovered = await this.abortSerialized(kind, expectedOperationId, terminalErrorCode, queuedAtStop);
    if (recovered.length > 0) {
      await this.context.runLane(() => this.redeliverStoppedSteering(recovered, true));
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
    this.context.assertAvailable();
    const taskOperationId = this.context.taskWorker()?.identity.operationId;
    const taskOwnsForeground = taskOperationId !== undefined && this.context.liveTaskOperationId() === taskOperationId;
    const targetsTask = expectedOperationId === taskOperationId
      || (expectedOperationId === undefined && (taskOwnsForeground || !this.context.operation()))
      || (taskOwnsForeground && expectedOperationId === this.context.operation()?.id);
    if (this.context.taskWorker()?.controlsActive && terminalErrorCode === "user-abort" && targetsTask) {
      await this.context.taskWorker()!.stop();
      return [];
    }
    if (expectedOperationId !== undefined && this.context.operation()?.id !== expectedOperationId
      && !(taskOwnsForeground && expectedOperationId === taskOperationId)) {
      throw new GatewayError("conflict", "The active operation changed before it could be stopped", true);
    }

    // `kind` is presentation metadata, not cancellation authority. A stale
    // retry/compaction/bash projection must never route Stop around another
    // foreground controller or the independently owned built-in bash process.
    // Keep the exact operation fence above, then fan cancellation out across
    // every foreground primitive and verify settlement before acknowledging.
    void kind;
    const target = this.context.operation() ? { ...this.context.operation()! } : undefined;
    const agentOperationId = this.context.activeOperationId();
    this.context.cancelRequest(agentOperationId);
    const invocationOperationId = agentOperationId
      ?? (target?.kind === "prompt" || target?.kind === "command" ? target.id : undefined);
    if (invocationOperationId) {
      const invocation = this.context.invocation(invocationOperationId);
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
    const stoppedTaskQueue = this.context.taskWorker() ? this.context.queued() : [];
    if (this.context.taskWorker()) {
      this.context.suppressQueueEvents(true);
      try { this.context.session().clearQueue(); }
      finally { this.context.suppressQueueEvents(false); }
      this.context.clearSdkSteeringIds();
      this.context.replaceQueued([]);
      this.context.bumpQueueRevision();
    }
    const queuedSteerCount = queuedAtStop?.filter((item) => item.behavior === "steer").length ?? 0;
    const redeliver = queuedAtStop !== undefined && queuedSteerCount > 0;
    const session = this.context.session();
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
      this.context.directBashProcesses()?.abortAll() ?? Promise.resolve(),
    ]);
    for (const item of stoppedTaskQueue) {
      await this.context.terminalizeInvocation(item.id, "interrupted", "task-stopped-before-delivery");
      this.context.settleOperationWork(item.id);
    }
    const settled = await this.waitForForegroundAbortSettlement(target, agentOperationId);
    if (!settled || this.context.directBashProcesses()?.hasActiveProcesses
      || abortResults.some((result) => result.status === "rejected")) {
      // Keep the SDK's actual abort outcome authoritative if cancellation partly
      // succeeded, but withdraw this unconfirmed invocation-level Stop intent.
      if (invocationOperationId) this.abortedOperations.delete(invocationOperationId);
      throw new GatewayError("conflict", "Foreground work did not stop", true);
    }

    let interruptionPersisted = false;
    if (invocationOperationId && !redeliver) {
      await this.context.terminalizeInvocation(invocationOperationId, "interrupted", terminalErrorCode);
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
      this.context.diagnostic()?.({ sessionId: this.context.sessionId(), queuedSteerCount, outcome: "started" });
      if (recovered.length === 0) {
        this.context.diagnostic()?.({ sessionId: this.context.sessionId(), queuedSteerCount, outcome: "completed" });
        this.stopSteeringContinuation = undefined;
      }
    }

    this.context.publishChanged();
    return recovered;
  }

  private async redeliverStoppedSteering(items: RuntimeQueuedMessage[], laneOwned: boolean): Promise<void> {
    const processed = new Set<string>();
    while (true) {
      const held = this.context.heldQueue().entries.filter((item) => this.stopRecoveryHoldIDs.has(item.id));
      const pending = [...items, ...held]
        .filter((item) => !processed.has(item.id)
          && (this.stopSteeringRecoveryIDs.has(item.id) || this.stopRecoveryHoldIDs.has(item.id)))
        .sort((left, right) => left.ordinal - right.ordinal);
      if (pending.length === 0) break;
      for (const item of pending) {
        const heldEntry = this.stopRecoveryHoldIDs.has(item.id)
          ? this.context.heldQueue().entries.find((entry) => entry.id === item.id)
          : undefined;
        const hasAcceptedInvocation = this.context.invocation(item.id) !== undefined;
        try {
          await this.context.admitPrompt(item.text, item.images, item.behavior, {
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
          const lifecycle = this.context.invocation(item.id)?.lifecycle;
          if (lifecycle === "completed" || lifecycle === "failed" || lifecycle === "interrupted") {
            this.consumeStopSteeringRecoveryOwner(item.id);
            this.context.heldQueue().removeHeldPrompt(item.id);
          }
        } catch (error) {
          this.context.diagnostic()?.({
            sessionId: this.context.sessionId(),
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
    const stillActive = () => this.context.directBashProcesses()?.hasActiveProcesses === true
      || (target !== undefined && this.context.operationMatches(target))
      || (agentOperationId !== undefined
        && this.context.activeOperationId() === agentOperationId
        && (this.context.hasActiveAgentRun()
          || this.context.pendingPromptId() === agentOperationId
          || this.context.operation()?.id === agentOperationId));
    while (stillActive() && performance.now() < deadline) {
      await new Promise<void>((resolveDelay) => { setTimeout(resolveDelay, 20); });
    }
    return !stillActive();
  }


  consumeStopSteeringRecoveryOwner(operationId: string): void {
    if (!this.stopSteeringRecoveryIDs.delete(operationId)) return;
    const retained = this.context.queued().filter((item) => item.id !== operationId);
    if (retained.length === this.context.queued().length) return;
    this.context.replaceQueued(retained);
    this.context.bumpQueueRevision();
  }

  completeContinuation(terminalLifecycle: InvocationLifecycle): void {
    if (this.stopSteeringContinuation) {
      this.context.diagnostic()?.({
        sessionId: this.context.sessionId(),
        queuedSteerCount: this.stopSteeringContinuation.queuedSteerCount,
        outcome: terminalLifecycle === "completed" ? "completed"
          : terminalLifecycle === "interrupted" ? "stopped"
            : terminalLifecycle === "failed" ? "failed" : "unknown",
      });
      this.stopSteeringContinuation = undefined;
    }
  }
}
