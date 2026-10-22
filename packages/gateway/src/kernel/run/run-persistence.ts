import type { RunOperations } from "./run-operations.js";
import { performance } from "node:perf_hooks";
import { asUncertainOutcome, isUncertainOutcome, uncertainOutcome } from "../../errors.js";
import type { GatewayWorkHandle } from "./gateway-work-registry.js";
import { RunMarkerCompletionConflictError } from "./run-markers.js";

/** Default bound on one durable ownership write's transient-failure retries.
 * Long enough to ride out a brief disk/permission outage, short enough that a
 * permanently broken canonical path cannot hold a session lane, a command
 * response, or the drain indefinitely. */
export const DEFAULT_OWNERSHIP_WRITE_RETRY_WINDOW_MS = 20_000;
export class CanonicalCustomEntryConflictError extends Error {}


/** Sole authority for pending receipt joins and unresolved durable writes.
 * The live session supplies effect/diagnostic cuts, never copies of this state. */
export class RunPersistence {
  /** Receipt persistence is runtime work: eviction and restart drain wait for
   * this bounded barrier rather than disposing the Pi manager underneath it. */
  readonly pendingReceiptWrites = new Set<Promise<void>>();
  /** A failed or timed-out persistence obligation keeps this runtime fenced.
   * Losing a waiter is not proof of a durable receipt or permission to evict the
   * only runtime holding Pi's potentially staged canonical entry. */
  readonly durableWrites = new Map<string, { waiter: Promise<void>; blocked: boolean; admittedAt: string }>();

  constructor(private readonly operations: RunOperations<unknown>) {}

  /** Admits one agent_settled settlement chain to the disposal join for its whole
   * life. The chain settles its own failures; this only orders disposal after it. */
  trackSettlementChain(chain: Promise<void>): void {
    this.pendingReceiptWrites.add(chain);
    void chain.finally(() => {
      this.pendingReceiptWrites.delete(chain);
      this.operations.releaseSettleWaiters();
    });
  }

  trackOwnershipWrite(
    startWrite: () => Promise<void>,
    existingOwner?: GatewayWorkHandle,
  ): Promise<void> {
    if (this.hasBlockedOwnershipWrite) {
      return Promise.reject(uncertainOutcome("Canonical ownership persistence is unresolved; no additional write may be admitted"));
    }
    const derived = existingOwner === undefined;
    const work = existingOwner ?? this.operations.dependencies.workRegistry.beginDerived({
      kind: "terminal-receipt-persistence", sessionId: this.operations.id, hostEpoch: this.operations.ui.hostEpoch,
    });
    work.progress();
    let write: Promise<void>;
    try {
      write = startWrite();
    } catch (error) {
      if (derived) work.settle();
      throw error;
    }
    this.pendingReceiptWrites.add(write);
    void write.then(() => {
      this.pendingReceiptWrites.delete(write);
      this.operations.releaseSettleWaiters();
      if (derived) work.settle();
    }, error => {
      this.pendingReceiptWrites.delete(write);
      this.operations.releaseSettleWaiters();
      // A confirmed contradictory identity rejects before any new write. Only
      // an unresolved persistence outcome keeps the derived owner admitted.
      if (derived && !isUncertainOutcome(error)) work.settle();
    });
    return write;
  }

  get hasBlockedOwnershipWrite(): boolean {
    return [...this.durableWrites.values()].some(write => write.blocked);
  }

  assertOwnershipPersistence(): void {
    if (this.hasBlockedOwnershipWrite) {
      throw uncertainOutcome("Canonical ownership persistence is unresolved; this runtime remains retained and cannot admit mutations, reload, or dispose");
    }
  }

  retryDurableWrite(key: string, operation: () => Promise<void>): Promise<void> {
    const existing = this.durableWrites.get(key);
    if (existing) return existing.waiter;
    this.assertOwnershipPersistence();
    const owner = { blocked: false, admittedAt: new Date().toISOString(), waiter: undefined as unknown as Promise<void> };
    const deadline = performance.now() + DEFAULT_OWNERSHIP_WRITE_RETRY_WINDOW_MS;
    let timer: NodeJS.Timeout | undefined;
    const expired = new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        owner.blocked = true;
        reject(uncertainOutcome("Canonical ownership persistence exceeded its wait deadline; the exact write remains unresolved"));
      }, DEFAULT_OWNERSHIP_WRITE_RETRY_WINDOW_MS);
    });
    const completion = (async () => {
      let attempt = 0;
      for (;;) {
        try {
          await operation();
          return;
        } catch (error) {
          if (owner.blocked || performance.now() >= deadline
            || error instanceof RunMarkerCompletionConflictError
            || error instanceof CanonicalCustomEntryConflictError
            || this.operations.dependencies.modules.policy("appendGuard")?.(this.operations.canonicalAppendContext).isPreAppendRefusal(error)
            || isUncertainOutcome(error)) throw error;
          attempt += 1;
          if (attempt === 1) this.diagnostic("canonical-ownership-persistence-retrying");
          await new Promise<void>(resolve => setTimeout(resolve, Math.min(1_000, 25 * attempt, Math.max(0, deadline - performance.now()))));
          if (owner.blocked) throw uncertainOutcome("Canonical ownership persistence remains unresolved");
        }
      }
    })();
    owner.waiter = Promise.race([completion, expired]).then(() => {
      if (this.durableWrites.get(key) === owner) this.durableWrites.delete(key);
    }, error => {
      if (!owner.blocked && (error instanceof RunMarkerCompletionConflictError
        || error instanceof CanonicalCustomEntryConflictError || this.operations.dependencies.modules.policy("appendGuard")?.(this.operations.canonicalAppendContext).isPreAppendRefusal(error))) {
        // These owner-validated conflicts reject before a new effect. Existing
        // canonical evidence remains authoritative; no unresolved write exists.
        if (this.durableWrites.get(key) === owner) this.durableWrites.delete(key);
        throw error;
      }
      // Even a pre-provider marker may have been renamed before an fsync error.
      // A timeout cannot certify rejection, and late completion cannot certify
      // that the abandoned caller finished its dependent canonical transitions.
      owner.blocked = true;
      this.block();
      this.diagnostic("canonical-ownership-persistence-blocked");
      throw asUncertainOutcome(error, "Canonical ownership persistence could not be proven");
    }).finally(() => { if (timer) clearTimeout(timer); });
    this.durableWrites.set(key, owner);
    // Promise.race observes late completion/rejection without releasing the
    // blocked owner or appending a second record. A supported SDK recovery
    // boundary is required before this runtime may be retired safely.
    return owner.waiter;
  }

  /** Joins pending canonical ownership writes within a bounded window. Every
   * write already bounds its own retry, so an exhausted wait means a permanent
   * storage fault: report a blocker instead of hanging disposal, and leave the
   * outstanding writes admitted so a later attempt can still settle them. */
  async waitForReceiptWrites(): Promise<void> {
    // Every write bounds its own retry, so an exhausted wait means a backstop
    // promise that cannot settle or a continuous stream of new writes. Race each
    // join against the remaining grace instead of awaiting without a clock, then
    // report a bounded blocker and leave the outstanding writes admitted so a
    // later attempt can still settle them.
    this.assertOwnershipPersistence();
    const deadline = performance.now() + DEFAULT_OWNERSHIP_WRITE_RETRY_WINDOW_MS;
    while (this.pendingReceiptWrites.size > 0) {
      const remaining = deadline - performance.now();
      if (remaining <= 0) break;
      let timer: NodeJS.Timeout | undefined;
      const expiry = new Promise<"expired">((resolve) => { timer = setTimeout(() => resolve("expired"), remaining); });
      let settled: "joined" | "expired";
      try {
        settled = await Promise.race([
          Promise.allSettled([...this.pendingReceiptWrites]).then(() => "joined" as const),
          expiry,
        ]);
      } finally {
        if (timer) clearTimeout(timer);
      }
      if (settled === "expired") break;
    }
    this.assertOwnershipPersistence();
    if (this.pendingReceiptWrites.size > 0) {
      throw uncertainOutcome(
        `Canonical ownership persistence did not settle within its bounded disposal window (${this.pendingReceiptWrites.size} pending write(s))`,
      );
    }
  }

  private block(): void {
    this.operations.lifecycle.beginDrain();
    // Stop further foreground effects through their SDK owners, without
    // claiming they have settled or disposing the potentially staged branch.
    const session = this.operations.runtime?.session;
    if (session) {
      for (const cancel of [() => session.abortCompaction(), () => session.abortRetry(), () => session.abortBranchSummary(), () => session.abortBash()]) {
        try { cancel(); } catch { /* Continue requesting each independent stop. */ }
      }
      void session.abort().catch(() => {});
      void this.operations.directBashProcesses?.abortAll().catch(() => {});
    }
  }

  private diagnostic(code: string): void {
    this.operations.dependencies.persistenceDiagnostic?.(this.operations.id, code);
    this.operations.emit("session.diagnostic", { code, message: "Canonical ownership persistence requires attention" });
  }

}
