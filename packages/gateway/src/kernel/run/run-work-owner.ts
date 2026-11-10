import type { RunOperations } from "./run-operations.js";
import type { GatewayWorkHandle, GatewayWorkKind} from "./gateway-work-registry.js";


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

  administrativeSuspectForegroundWorkTokens(): ReadonlySet<string> {
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

  async reconcileOrphanedForegroundWorkForDrain(): Promise<void> {
    if (this.operations.hasActiveAgentRun) return;
    const workFacts = new Map(this.operations.dependencies.workRegistry.facts().map((fact) => [fact.token, fact]));
    const retained = this.administrativeRetainedOperationWorkIDs();
    const candidates = [...this.operationWork.entries()].filter(([operationId, work]) => {
      const fact = workFacts.get(work.token);
      return fact?.kind === "foreground-agent-operation" && !retained.has(operationId);
    });
    for (const [operationId, work] of candidates) {
      await this.operations.clearMarkerOwnership(operationId, work);
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
