import { randomUUID } from "node:crypto";
import type { FileEntry, SessionManager } from "../pi/coding-agent.js";
import type { ModuleHost } from "../host/module-host.js";
import type { JsonValue, SessionOperationState, SessionPhase } from "../../protocol/types.js";
import type { GatewayWorkHandle, GatewayWorkRegistry } from "./gateway-work-registry.js";
import type { RunMarkerStore } from "./run-markers.js";
import type { RunPersistence } from "./run-persistence.js";
import type { RunWorkOwner } from "./run-work-owner.js";
import type { RunTerminalOwner } from "./run-terminal.js";
import type { ManualCompactionOwner } from "./manual-compaction.js";
import { completionOwnedByMarker, type CanonicalAssistantCompletion, type SessionAttentionRebindDisposition } from "./completion-facts.js";

export interface RunAttentionContext {
  readonly id: string;
  readonly dependencies: { markers: RunMarkerStore; workRegistry: GatewayWorkRegistry; modules: ModuleHost; persistenceDiagnostic?: (id: string, code: "terminal-receipt-persistence-failed") => void };
  readonly ui: { readonly hostEpoch: string };
  readonly hooks: { assistantResponseCompleted(id: string, completion: CanonicalAssistantCompletion, recovery: boolean, observed: boolean): Promise<void>; settled(id: string): void };
  readonly runPersistence: RunPersistence;
  readonly runWork: RunWorkOwner;
  readonly runTerminal: RunTerminalOwner;
  readonly manualCompaction: ManualCompactionOwner;
  readonly taskWorker: { readonly identity: { readonly operationId: string } } | undefined;
  readonly compactionOperation: SessionOperationState | undefined;
  readonly hasActiveAgentRun: boolean;
  readonly sessionManager: Pick<SessionManager, "getEntry">;
  readonly activeToolSegmentOwnerId: string | undefined;
  readonly activityHeartbeat: unknown;
  phase: SessionPhase;
  revision: number;
  operation: SessionOperationState | undefined;
  activeOperationId: string | undefined;
  assertSessionIdentityReplacement(): void;
  ownToolSegment(id: string): void;
  startActivityHeartbeat(): void;
  canonicalSessionEntries(): FileEntry[];
  clearMarkerOwnership(id: string | undefined, work?: GatewayWorkHandle): Promise<void>;
  publishConfiguration(): void;
  releaseSettleWaiters(): void;
  publishSnapshot(): void;
  noteHomeIdle(): void;
  emit(topic: string, data: JsonValue): void;
}

type CompletionOwnershipItem = {
  completion: CanonicalAssistantCompletion;
  stamp: Promise<void> | undefined;
  observationSettled: boolean;
  observationCursor?: { entryIndex: number };
  fallbackWork?: GatewayWorkHandle;
};

/** Runtime completion ownership; durable attention remains with its store. */
export class RunAttentionOwner {
  /** Exact successful canonical assistant completion awaiting durable attention admission. */
  pendingAssistantCompletion: CanonicalAssistantCompletion | undefined;
  /** Exact completions retain canonical attention order. Their durable stamps
   * are started independently so a failed projection head cannot hide a newer
   * continuation from restart reconciliation. */
  readonly completionOwnershipQueue: CompletionOwnershipItem[] = [];
  attentionBarrier: Promise<void> | undefined;
  rebindAttentionDisposition: SessionAttentionRebindDisposition = "migrate";

  constructor(private readonly context: RunAttentionContext) {}

  ensureAgentProjection(): void {
    if (!this.context.hasActiveAgentRun) return;
    if (this.context.phase === "idle" || this.context.phase === "interrupted") this.context.phase = "running";
    this.context.activeOperationId ??= randomUUID();
    if (!this.context.activeToolSegmentOwnerId) this.context.ownToolSegment(this.context.activeOperationId);
    this.context.operation ??= { id: this.context.activeOperationId, kind: "prompt", startedAt: new Date().toISOString() };
    this.context.runWork.beginDerivedOperationWork(this.context.activeOperationId, "foreground-agent-operation");
    if (!this.context.activityHeartbeat) this.context.startActivityHeartbeat();
  }

  private startCompletionStamp(item: CompletionOwnershipItem): Promise<void> {
    if (item.stamp) return item.stamp;
    const { completion } = item;
    if (!completion.operationId) return Promise.resolve();
    const stamp = this.context.runPersistence.trackOwnershipWrite(() => this.context.runPersistence.retryDurableWrite(
      `marker:completion:${completion.operationId}:${completion.id}`,
      () => this.context.dependencies.markers.reassertAssistantCompletion(
        this.context.id,
        completion.operationId!,
        completion.id,
        completion.completedAt,
      ),
    ), this.context.runWork.get(completion.operationId) ?? item.fallbackWork);
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
      this.context.runTerminal.completionObserved(completion.id);
      const operationId = completion.operationId ?? this.context.runTerminal.completionOperationId(completion.id);
      const exactOwner = operationId ? this.context.runWork.get(operationId) : undefined;
      item = {
        completion: operationId && !completion.operationId ? { ...completion, operationId } : completion,
        stamp: undefined,
        observationSettled: false,
        ...(operationId && this.context.runTerminal.operationObservations.get(operationId)?.cursor
          ? { observationCursor: this.context.runTerminal.operationObservations.get(operationId)!.cursor }
          : {}),
        ...(exactOwner ? {} : {
          fallbackWork: this.context.dependencies.workRegistry.beginDerived({
            kind: "terminal-receipt-persistence",
            sessionId: this.context.id,
            hostEpoch: this.context.ui.hostEpoch,
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
        this.context.publishConfiguration();
      }
      this.context.manualCompaction.startPendingManualCompaction();
    })().finally(() => {
      this.context.runPersistence.pendingReceiptWrites.delete(operation);
      this.context.releaseSettleWaiters();
      if (this.attentionBarrier === operation) this.attentionBarrier = undefined;
      this.context.runWork.settleRetiredOperationWork();
    });
    this.attentionBarrier = operation;
    this.context.runPersistence.pendingReceiptWrites.add(operation);
    void operation.catch(() => {});
    return operation;
  }

  settleCompletionPersistenceFailure(
    completion: CanonicalAssistantCompletion,
    _error: unknown,
    fallbackWork?: GatewayWorkHandle,
  ): void {
    const operationId = completion.operationId ?? this.context.runTerminal.completionOperationId(completion.id);
    this.context.dependencies.persistenceDiagnostic?.(this.context.id, "terminal-receipt-persistence-failed");
    this.context.emit("session.diagnostic", {
      code: "terminal-receipt-persistence-failed",
      message: "Terminal receipt was not proven durable; the run remains marked for interrupted recovery",
    });
    this.context.runWork.settleOperationWork(operationId);
    fallbackWork?.settle();
    const pendingOwnerId = this.context.runTerminal.completionOperationId(completion.id);
    if (pendingOwnerId) delete this.context.runTerminal.operationObservations.get(pendingOwnerId)!.pendingCompletionId;
    if (this.pendingAssistantCompletion?.id === completion.id) this.pendingAssistantCompletion = undefined;
  }

  private admitCompletionObservation(item: CompletionOwnershipItem): void {
    if (item.observationSettled) return;
    const operationId = item.completion.operationId ?? this.context.runTerminal.completionOperationId(item.completion.id);
    if (!operationId) return;
    const start = item.observationCursor ?? this.context.runTerminal.operationObservations.get(operationId)?.cursor;
    if (!start) return;
    const entries = this.context.canonicalSessionEntries();
    const completionIndex = entries.findIndex(entry => entry.id === item.completion.id);
    if (completionIndex < start.entryIndex) return;
    item.observationSettled = true;
    // The deduplication record belongs only to the operation whose eventual
    // agent_settled callback can consume it. A completion from an earlier
    // operation in a queued run may settle after its callback ownership ended.
    if (this.context.activeOperationId === operationId) {
      this.context.runTerminal.observationFor(operationId).observedCompletionId = item.completion.id;
    }
    if (this.context.hasActiveAgentRun && this.context.activeOperationId === operationId) {
      // The same foreground operation can continue after a completion (for
      // example, a consumed steer). Advance to the exact next canonical entry;
      // its later completion owns only the remaining range.
      this.context.runTerminal.observationFor(operationId).cursor = { entryIndex: completionIndex + 1 };
    } else {
      this.context.runTerminal.retireOperationObservation(operationId);
    }
  }

  private async settleAssistantCompletion(item: CompletionOwnershipItem): Promise<void> {
    const { completion } = item;
    try {
      let lastError: unknown;
      for (let attempt = 0; attempt < 3; attempt += 1) {
        try {
          await this.context.hooks.assistantResponseCompleted(
            this.context.id,
            completion,
            false,
            this.context.runTerminal.completionObserved(completion.id),
          );
          lastError = undefined;
          break;
        } catch (error) {
          lastError = error;
        }
      }
      if (lastError !== undefined) throw lastError;
      if (!completion.operationId?.startsWith("automation:") && completion.operationId !== this.context.taskWorker?.identity.operationId) {
        await this.context.clearMarkerOwnership(completion.operationId, item.fallbackWork);
      }
      this.admitCompletionObservation(item);
      const completionWorkOwner = completion.operationId ?? this.context.runTerminal.completionOperationId(completion.id);
      this.context.runWork.settleOperationWork(completionWorkOwner);
      const pendingOwner = this.context.runTerminal.completionOperationId(completion.id);
      if (pendingOwner) delete this.context.runTerminal.operationObservations.get(pendingOwner)!.pendingCompletionId;
      if (this.pendingAssistantCompletion?.id === completion.id) this.pendingAssistantCompletion = undefined;
      // A continuation may already own the agent while this older durable write
      // unwinds. Settlement retires only its exact completion; the newer run
      // remains operationally running and owns final idle transition.
      if (this.context.hasActiveAgentRun) {
        this.ensureAgentProjection();
        this.context.publishSnapshot();
        return;
      }
      if (this.context.manualCompaction.pendingManualCompaction) {
        // Compaction owns a separate marker. Start it only after the preceding
        // response's attention fact and exact marker retirement are durable.
        this.context.phase = "idle";
        this.context.revision += 1;
        this.context.publishSnapshot();
        return;
      }
      this.context.hooks.settled(this.context.id);
      await this.context.dependencies.modules.policy("runSettled")?.().quiescent(this.context.id);
      this.context.phase = this.context.compactionOperation ? "compacting" : "idle";
      this.context.noteHomeIdle();
      this.context.operation ??= this.context.compactionOperation;
      this.context.revision += 1;
      this.context.publishSnapshot();
    } catch (error) {
      // The failed exact completion stays at the ownership-lane head and retains
      // its durable marker. Reconciliation retries it before any continuation
      // marker or later completion can advance.
      this.context.phase = "interrupted";
      this.context.revision += 1;
      this.context.publishSnapshot();
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
    const markers = await this.context.dependencies.markers.evidenceFor(this.context.id);
    for (const marker of markers) {
      const completion = completionOwnedByMarker(this.context.sessionManager, marker);
      if (!completion) continue;
      await this.context.hooks.assistantResponseCompleted(this.context.id, completion, true, false);
      await this.context.clearMarkerOwnership(marker.operationId);
    }
  }

  async withRebindAttentionDisposition<T>(
    disposition: SessionAttentionRebindDisposition,
    operation: () => Promise<T>,
  ): Promise<T> {
    this.context.assertSessionIdentityReplacement();
    const previous = this.rebindAttentionDisposition;
    this.rebindAttentionDisposition = disposition;
    try {
      return await operation();
    } finally {
      this.rebindAttentionDisposition = previous;
    }
  }

}
