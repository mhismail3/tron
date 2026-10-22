import type { RunOperations } from "./run-operations.js";
import type { GatewayWorkHandle, GatewayWorkKind} from "./gateway-work-registry.js";


/** Per-runtime operation-handle authority; GatewayWorkRegistry owns the tokens.
 * Live retained-owner projections are sampled again after marker persistence. */
export class RunWorkOwner {
  private readonly operationWork = new Map<string, GatewayWorkHandle>();

  constructor(private readonly operations: RunOperations<unknown>) {}

  get(operationId: string): GatewayWorkHandle | undefined { return this.operationWork.get(operationId); }
  has(operationId: string): boolean { return this.operationWork.has(operationId); }
  settleAll(): void {
    for (const operationId of [...this.operationWork.keys()]) this.settleOperationWork(operationId);
  }

  beginOperationWork(operationId: string, kind: GatewayWorkKind = "prompt-preflight"): GatewayWorkHandle {
    const existing = this.operationWork.get(operationId);
    if (existing) {
      existing.transition(kind);
      return existing;
    }
    const work = this.operations.dependencies.workRegistry.begin({
      kind,
      ...{ sessionId: this.operations.id, hostEpoch: this.operations.ui.hostEpoch },
    });
    this.operationWork.set(operationId, work);
    return work;
  }

  beginDerivedOperationWork(operationId: string, kind: GatewayWorkKind): GatewayWorkHandle {
    const existing = this.operationWork.get(operationId);
    if (existing) {
      existing.transition(kind);
      return existing;
    }
    const work = this.operations.dependencies.workRegistry.beginDerived({
      kind,
      ...{ sessionId: this.operations.id, hostEpoch: this.operations.ui.hostEpoch },
    });
    this.operationWork.set(operationId, work);
    return work;
  }

  settleOperationWork(operationId: string | undefined): void {
    this.beforeSettle(operationId);
    if (!operationId) return;
    const work = this.operationWork.get(operationId);
    if (!work) return;
    this.operationWork.delete(operationId);
    work.settle();
  }

  /** Foreground tokens without an exact runtime, queue, or settlement owner
   * are orphaned projections. Age alone never makes work suspect. */
  administrativeSuspectForegroundWorkTokens(): ReadonlySet<string> {
    // Pi's broad streaming state is authoritative even if a projection callback
    // is temporarily missing. Ambiguous live ownership must wait, never repair.
    if (this.operations.hasActiveAgentRun) return new Set();
    const retained = this.administrativeRetainedOperationWorkIDs();
    return new Set([...this.operationWork.entries()].flatMap(([operationId, work]) =>
      retained.has(operationId) ? [] : [work.token]
    ));
  }

  settleRetiredOperationWork(): void {
    const retained = this.retainedOperationWorkIDs();
    for (const operationId of [...this.operationWork.keys()]) {
      if (!retained.has(operationId)) this.settleOperationWork(operationId);
    }
  }

  /** Administrative drain repairs only proven-orphaned foreground ownership.
   * Its exact durable marker is removed before the process-local token; active,
   * queued, and terminal-receipt owners remain untouched without a deadline. */
  async reconcileOrphanedForegroundWorkForDrain(): Promise<void> {
    // Never synthesize or transfer identity during repair. Once Pi settles, its
    // sequenced callback or the next reconciliation pass can prove an orphan.
    if (this.operations.hasActiveAgentRun) return;
    const workFacts = new Map(this.operations.dependencies.workRegistry.facts().map((fact) => [fact.token, fact]));
    const retained = this.administrativeRetainedOperationWorkIDs();
    const candidates = [...this.operationWork.entries()].filter(([operationId, work]) => {
      const fact = workFacts.get(work.token);
      return fact?.kind === "foreground-agent-operation" && !retained.has(operationId);
    });
    for (const [operationId, work] of candidates) {
      await this.operations.clearMarkerOwnership(operationId, work);
      // A delayed exact callback may have restored ownership while marker I/O
      // yielded. Reassert its marker rather than retiring live work.
      if (this.administrativeRetainedOperationWorkIDs().has(operationId)) {
        await this.operations.enqueueMarkerOwnership(operationId);
        continue;
      }
      this.settleOperationWork(operationId);
    }
  }

  private beforeSettle(operationId: string | undefined): void {
    this.operations.releaseSettleWaiters();
    if (!operationId) return;
    this.operations.lifecycle.cancelPreflight(operationId);
    // PendingPrompt is a provisional projection, not independent ownership.
    // Once its exact operation settles it must not keep an idle composer row
    // alive merely because Pi omitted or replaced the expected user callback.
    if (this.operations.pendingPrompt?.id === operationId) {
      this.operations.pendingPrompt = undefined;
      this.operations.pendingPromptMessage = undefined;
    }
  }

  public retainedOperationWorkIDs(): Set<string> {
    return new Set([
      this.operations.activeOperationId,
      this.operations.operation?.id,
      this.operations.pendingPrompt?.id,
      this.operations.pendingExtensionCommand?.id,
      this.operations.runAttention.pendingAssistantCompletion?.operationId,
      this.operations.runQueue.pendingQueueAdmission?.id,
      ...this.operations.runAttention.completionOwnershipQueue.map((item) => item.completion.operationId),
      ...[...this.operations.runTerminal.operationObservations.entries()]
        .filter(([, observation]) => observation.pendingCompletionId !== undefined)
        .map(([operationId]) => operationId),
      ...this.operations.runQueue.queuedMessages.map((item) => item.id),
      ...this.operations.heldQueue.entries.map((item) => item.id),
      ...this.operations.runQueue.dequeuedFollowUpOwners,
      ...this.operations.runQueue.dequeuedSteeringOwners,
      ...this.operations.runQueue.consumedSteeringOperationIDs,
    ].filter((value): value is string => typeof value === "string"));
  }

  public administrativeRetainedOperationWorkIDs(): Set<string> {
    const retained = this.retainedOperationWorkIDs();
    // A provisional prompt cannot represent foreground work after both Pi and
    // the Gateway have reached an operation-free terminal phase.
    if (!this.operations.hasActiveAgentRun
      && (this.operations.phase === "idle" || this.operations.phase === "interrupted")
      && this.operations.activeOperationId === undefined
      && this.operations.operation === undefined
      && this.operations.runAttention.pendingAssistantCompletion === undefined
      && this.operations.pendingPrompt) {
      retained.delete(this.operations.pendingPrompt.id);
    }
    return retained;
  }

}
