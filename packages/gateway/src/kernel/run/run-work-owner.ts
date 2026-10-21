import type { GatewayWorkHandle, GatewayWorkKind, GatewayWorkRegistry } from "./gateway-work-registry.js";

interface RunWorkContext {
  registry(): GatewayWorkRegistry;
  metadata(): { sessionId: string; hostEpoch: string };
  beforeSettle(operationId: string | undefined): void;
  retained(): Set<string>;
  administrativeRetained(): Set<string>;
  hasActiveAgentRun(): boolean;
  clearMarker(operationId: string, work: GatewayWorkHandle): Promise<void>;
  enqueueMarker(operationId: string): Promise<void>;
}

/** Per-runtime operation-handle authority; GatewayWorkRegistry owns the tokens.
 * Live retained-owner projections are sampled again after marker persistence. */
export class RunWorkOwner {
  private readonly operationWork = new Map<string, GatewayWorkHandle>();

  constructor(private readonly context: RunWorkContext) {}

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
    const work = this.context.registry().begin({
      kind,
      ...this.context.metadata(),
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
    const work = this.context.registry().beginDerived({
      kind,
      ...this.context.metadata(),
    });
    this.operationWork.set(operationId, work);
    return work;
  }

  settleOperationWork(operationId: string | undefined): void {
    this.context.beforeSettle(operationId);
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
    if (this.context.hasActiveAgentRun()) return new Set();
    const retained = this.context.administrativeRetained();
    return new Set([...this.operationWork.entries()].flatMap(([operationId, work]) =>
      retained.has(operationId) ? [] : [work.token]
    ));
  }

  settleRetiredOperationWork(): void {
    const retained = this.context.retained();
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
    if (this.context.hasActiveAgentRun()) return;
    const workFacts = new Map(this.context.registry().facts().map((fact) => [fact.token, fact]));
    const retained = this.context.administrativeRetained();
    const candidates = [...this.operationWork.entries()].filter(([operationId, work]) => {
      const fact = workFacts.get(work.token);
      return fact?.kind === "foreground-agent-operation" && !retained.has(operationId);
    });
    for (const [operationId, work] of candidates) {
      await this.context.clearMarker(operationId, work);
      // A delayed exact callback may have restored ownership while marker I/O
      // yielded. Reassert its marker rather than retiring live work.
      if (this.context.administrativeRetained().has(operationId)) {
        await this.context.enqueueMarker(operationId);
        continue;
      }
      this.settleOperationWork(operationId);
    }
  }

}
