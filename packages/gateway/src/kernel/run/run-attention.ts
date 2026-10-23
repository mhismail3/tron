import type { RunOperations } from "./run-operations.js";
import { randomUUID } from "node:crypto";
import type { GatewayWorkHandle } from "./gateway-work-registry.js";
import { completionOwnedByMarker, type CanonicalAssistantCompletion, type SessionAttentionRebindDisposition } from "./completion-facts.js";

type CompletionOwnershipItem = {
  completion: CanonicalAssistantCompletion;
  stamp: Promise<void> | undefined;
  observationSettled: boolean;
  observationCursor?: { entryIndex: number };
  fallbackWork?: GatewayWorkHandle;
};

/** Runtime completion ownership; durable attention remains with its store. */
export class RunAttentionOwner {
  /** `message_end` precedes Pi's synchronous canonical append. Capture immutable
   * operation ownership in that callback turn so an immediate extension
   * continuation cannot inherit the completion's already-consumed owner. */
  private readonly pendingAssistantBindings = new Map<object, {
    operationId?: string;
    ownsPromptOperation: boolean;
  }>();

  captureAssistantBinding(): { operationId?: string; ownsPromptOperation: boolean } {
    return {
      ...(this.operations.activeOperationId ? { operationId: this.operations.activeOperationId } : {}),
      ownsPromptOperation: this.operations.operation?.kind === "prompt",
    };
  }

  get hasPendingAssistantBinding(): boolean { return this.pendingAssistantBindings.size > 0; }

  bindAssistant(message: object, binding: { operationId?: string; ownsPromptOperation: boolean }): void {
    this.pendingAssistantBindings.set(message, binding);
  }

  releaseAssistant(message: object): void { this.pendingAssistantBindings.delete(message); }

  /** Exact successful canonical assistant completion awaiting durable attention admission. */
  pendingAssistantCompletion: CanonicalAssistantCompletion | undefined;
  /** Exact completions retain canonical attention order. Their durable stamps
   * are started independently so a failed projection head cannot hide a newer
   * continuation from restart reconciliation. */
  readonly completionOwnershipQueue: CompletionOwnershipItem[] = [];
  attentionBarrier: Promise<void> | undefined;
  rebindAttentionDisposition: SessionAttentionRebindDisposition = "migrate";

  constructor(private readonly operations: RunOperations<unknown>) {}

  ensureAgentProjection(): void {
    if (!this.operations.hasActiveAgentRun) return;
    if (this.operations.phase === "idle" || this.operations.phase === "interrupted") this.operations.phase = "running";
    this.operations.activeOperationId ??= randomUUID();
    if (!this.operations.activeToolSegmentOwnerId) this.operations.ownToolSegment(this.operations.activeOperationId);
    this.operations.operation ??= { id: this.operations.activeOperationId, kind: "prompt", startedAt: new Date().toISOString() };
    this.operations.runWork.beginDerivedOperationWork(this.operations.activeOperationId, "foreground-agent-operation");
    if (!this.operations.activityHeartbeat) this.operations.startActivityHeartbeat();
  }

  private startCompletionStamp(item: CompletionOwnershipItem): Promise<void> {
    if (item.stamp) return item.stamp;
    const { completion } = item;
    if (!completion.operationId) return Promise.resolve();
    // A task's root marker belongs to the whole delegated operation, not one
    // reply: notices/reminders can produce several completions before report.
    // The dispatcher retains and acknowledges that marker at task settlement.
    if (completion.operationId === this.operations.taskWorker?.identity.operationId) return Promise.resolve();
    const stamp = this.operations.runPersistence.trackOwnershipWrite(() => this.operations.runPersistence.retryDurableWrite(
      `marker:completion:${completion.operationId}:${completion.id}`,
      () => this.operations.dependencies.markers.reassertAssistantCompletion(
        this.operations.id,
        completion.operationId!,
        completion.id,
        completion.completedAt,
      ),
    ), this.operations.runWork.get(completion.operationId) ?? item.fallbackWork);
    item.stamp = stamp;
    void stamp.catch(() => {
      if (item.stamp === stamp) item.stamp = undefined;
    });
    return stamp;
  }

  recordCompletionOwnership(completion: CanonicalAssistantCompletion): CompletionOwnershipItem {
    let item = this.completionOwnershipQueue.find((candidate) => candidate.completion.id === completion.id);
    if (item) {
      const existingOperationId = item.completion.operationId;
      // The first callback-turn binding is immutable. A later settlement view
      // may fill a missing owner, but mutable runtime state cannot replace one.
      if (!existingOperationId && completion.operationId) {
        item.completion = { ...item.completion, operationId: completion.operationId };
      }
    } else {
      // Canonical append admission is the single observation boundary. Later
      // attention settlement and agent_settled notification handling must read
      // this same disposition rather than resampling a close/completion race.
      this.operations.runTerminal.completionObserved(completion.id);
      const operationId = completion.operationId ?? this.operations.runTerminal.completionOperationId(completion.id);
      const exactOwner = operationId ? this.operations.runWork.get(operationId) : undefined;
      item = {
        completion: operationId && !completion.operationId ? { ...completion, operationId } : completion,
        stamp: undefined,
        observationSettled: false,
        ...(operationId && this.operations.runTerminal.operationObservations.get(operationId)?.cursor
          ? { observationCursor: this.operations.runTerminal.operationObservations.get(operationId)!.cursor }
          : {}),
        ...(exactOwner ? {} : {
          fallbackWork: this.operations.dependencies.workRegistry.beginDerived({
            kind: "terminal-receipt-persistence",
            sessionId: this.operations.id,
            hostEpoch: this.operations.ui.hostEpoch,
          }),
        }),
      };
      this.completionOwnershipQueue.push(item);
    }
    void this.startCompletionStamp(item).catch(() => {});
    return item;
  }

  beginAttentionSettlement(completion: CanonicalAssistantCompletion): Promise<void> {
    this.recordCompletionOwnership(completion);
    return this.drainCompletionOwnership();
  }

  drainCompletionOwnership(): Promise<void> {
    if (this.attentionBarrier) return this.attentionBarrier;
    const operation = (async () => {
      while (this.completionOwnershipQueue.length > 0) {
        const item = this.completionOwnershipQueue[0]!;
        try {
          await this.startCompletionStamp(item);
          await this.settleAssistantCompletion(item);
        } catch (error) {
          this.settleCompletionPersistenceFailure(item.completion, error, item.fallbackWork);
        }
        this.completionOwnershipQueue.shift();
        item.fallbackWork?.settle();
        // Normal completions already retired their operation token before the
        // final snapshot. Queue retirement must also publish configuration ready.
        this.operations.publishConfiguration();
      }
      this.operations.manualCompaction.startPendingManualCompaction();
    })().finally(() => {
      this.operations.runPersistence.pendingReceiptWrites.delete(operation);
      this.operations.releaseSettleWaiters();
      if (this.attentionBarrier === operation) this.attentionBarrier = undefined;
      this.operations.runWork.settleRetiredOperationWork();
    });
    this.attentionBarrier = operation;
    this.operations.runPersistence.pendingReceiptWrites.add(operation);
    void operation.catch(() => {});
    return operation;
  }

  settleCompletionPersistenceFailure(
    completion: CanonicalAssistantCompletion,
    _error: unknown,
    fallbackWork?: GatewayWorkHandle,
  ): void {
    const operationId = completion.operationId ?? this.operations.runTerminal.completionOperationId(completion.id);
    this.operations.dependencies.persistenceDiagnostic?.(this.operations.id, "terminal-receipt-persistence-failed");
    this.operations.emit("session.diagnostic", {
      code: "terminal-receipt-persistence-failed",
      message: "Terminal receipt was not proven durable; the run remains marked for interrupted recovery",
    });
    this.operations.runWork.settleOperationWork(operationId);
    fallbackWork?.settle();
    const pendingOwnerId = this.operations.runTerminal.completionOperationId(completion.id);
    if (pendingOwnerId) delete this.operations.runTerminal.operationObservations.get(pendingOwnerId)!.pendingCompletionId;
    if (this.pendingAssistantCompletion?.id === completion.id) this.pendingAssistantCompletion = undefined;
  }

  private admitCompletionObservation(item: CompletionOwnershipItem): void {
    if (item.observationSettled) return;
    const operationId = item.completion.operationId ?? this.operations.runTerminal.completionOperationId(item.completion.id);
    if (!operationId) return;
    const start = item.observationCursor ?? this.operations.runTerminal.operationObservations.get(operationId)?.cursor;
    if (!start) return;
    const entries = this.operations.canonicalSessionEntries();
    const completionIndex = entries.findIndex(entry => entry.id === item.completion.id);
    if (completionIndex < start.entryIndex) return;
    item.observationSettled = true;
    // The deduplication record belongs only to the operation whose eventual
    // agent_settled callback can consume it. A completion from an earlier
    // operation in a queued run may settle after its callback ownership ended.
    if (this.operations.activeOperationId === operationId) {
      this.operations.runTerminal.observationFor(operationId).observedCompletionId = item.completion.id;
    }
    if (this.operations.hasActiveAgentRun && this.operations.activeOperationId === operationId) {
      // The same foreground operation can continue after a completion (for
      // example, a consumed steer). Advance to the exact next canonical entry;
      // its later completion owns only the remaining range.
      this.operations.runTerminal.observationFor(operationId).cursor = { entryIndex: completionIndex + 1 };
    } else {
      this.operations.runTerminal.retireOperationObservation(operationId);
    }
  }

  private async settleAssistantCompletion(item: CompletionOwnershipItem): Promise<void> {
    const { completion } = item;
    try {
      let lastError: unknown;
      for (let attempt = 0; attempt < 3; attempt += 1) {
        try {
          await this.operations.hooks.assistantResponseCompleted(
            this.operations.id,
            completion,
            false,
            this.operations.runTerminal.completionObserved(completion.id),
          );
          lastError = undefined;
          break;
        } catch (error) {
          lastError = error;
        }
      }
      if (lastError !== undefined) throw lastError;
      if (!completion.operationId?.startsWith("automation:") && completion.operationId !== this.operations.taskWorker?.identity.operationId) {
        await this.operations.clearMarkerOwnership(completion.operationId, item.fallbackWork);
      }
      this.admitCompletionObservation(item);
      const completionWorkOwner = completion.operationId ?? this.operations.runTerminal.completionOperationId(completion.id);
      this.operations.runWork.settleOperationWork(completionWorkOwner);
      const pendingOwner = this.operations.runTerminal.completionOperationId(completion.id);
      if (pendingOwner) delete this.operations.runTerminal.operationObservations.get(pendingOwner)!.pendingCompletionId;
      if (this.pendingAssistantCompletion?.id === completion.id) this.pendingAssistantCompletion = undefined;
      // A continuation may already own the agent while this older durable write
      // unwinds. Settlement retires only its exact completion; the newer run
      // remains operationally running and owns final idle transition.
      if (this.operations.hasActiveAgentRun) {
        this.ensureAgentProjection();
        this.operations.publishSnapshot();
        return;
      }
      if (this.operations.manualCompaction.pendingManualCompaction) {
        // Compaction owns a separate marker. Start it only after the preceding
        // response's attention fact and exact marker retirement are durable.
        this.operations.phase = "idle";
        this.operations.revision += 1;
        this.operations.publishSnapshot();
        return;
      }
      this.operations.hooks.settled(this.operations.id);
      await this.operations.dependencies.modules.policy("runSettled")?.().quiescent(this.operations.id);
      this.operations.phase = this.operations.compactionOperation ? "compacting" : "idle";
      this.operations.noteHomeIdle();
      this.operations.operation ??= this.operations.compactionOperation;
      this.operations.revision += 1;
      this.operations.publishSnapshot();
    } catch (error) {
      // The failed exact completion stays at the ownership-lane head and retains
      // its durable marker. Reconciliation retries it before any continuation
      // marker or later completion can advance.
      this.operations.phase = "interrupted";
      this.operations.revision += 1;
      this.operations.publishSnapshot();
      throw error;
    }
  }

  async reconcileAttentionBody(): Promise<void> {
    if (this.attentionBarrier) {
      try {
        await this.attentionBarrier;
      } catch (error) {
        // A failed queue head remains retryable below; only an unowned barrier
        // failure is terminal to reconciliation.
        if (this.completionOwnershipQueue.length === 0) throw error;
      }
    }
    if (this.completionOwnershipQueue.length > 0) {
      await this.drainCompletionOwnership();
      return;
    }
    if (this.pendingAssistantCompletion) {
      await this.beginAttentionSettlement(this.pendingAssistantCompletion);
      return;
    }
    const markers = await this.operations.dependencies.markers.evidenceFor(this.operations.id);
    for (const marker of markers) {
      const completion = completionOwnedByMarker(this.operations.sessionManager, marker);
      if (!completion) continue;
      await this.operations.hooks.assistantResponseCompleted(this.operations.id, completion, true, false);
      await this.operations.clearMarkerOwnership(marker.operationId);
    }
  }

  async withRebindAttentionDisposition<T>(
    disposition: SessionAttentionRebindDisposition,
    operation: () => Promise<T>,
  ): Promise<T> {
    this.operations.assertSessionIdentityReplacement();
    const previous = this.rebindAttentionDisposition;
    this.rebindAttentionDisposition = disposition;
    try {
      return await operation();
    } finally {
      this.rebindAttentionDisposition = previous;
    }
  }

}
